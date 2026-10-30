///|
/// NewThread diversion regression coverage. The fork terminal, both compact
/// NewThread terminals (idle standalone and mid-turn manual), and their shared
/// tail (`persist_new_thread_session`) are covered here. The Agent is the only
/// SessionPort writer: the child core fact is established first, the output is
/// written to every store, then the cursor advances and one SessionRedirect is
/// emitted. A failure keeps the core fact and pending snapshot; the next
/// operation must recover that exact child before running a new request.
///
/// Parent-transcript provenance is asserted from the recorded store writes,
/// not from guessed counts: during a fork turn the parent grows by two
/// incremental checkpoints (input, then the assistant tool-call message), and
/// the tool result is never persisted because the fork safe point stops the
/// turn before the next boundary write.

///|
/// Collect `(from, to, before, after)` from SessionRedirect events, in order.
fn newthread_redirects(
  events : Array[@types.TurnEvent],
) -> Array[(String, String, Int32, Int32)] {
  let found : Array[(String, String, Int32, Int32)] = []
  for event in events {
    match event {
      SessionRedirect(from~, to~, messages_before~, messages_after~) =>
        found.push((from, to, messages_before, messages_after))
      _ => ()
    }
  }
  found
}

///|
fn newthread_started_events(events : Array[@types.TurnEvent]) -> (Int32, Int32) {
  let mut turns = 0
  let mut compacts = 0
  for event in events {
    match event {
      TurnStarted => turns = turns + 1
      CompactStarted(_) => compacts = compacts + 1
      _ => ()
    }
  }
  (turns, compacts)
}

///|
fn newthread_failure_terminals(events : Array[@types.TurnEvent]) -> Int32 {
  let mut count = 0
  for event in events {
    match event {
      OperationFinalized(outcome="failed", ..) => count = count + 1
      TurnFailed(_) => count = count + 1
      _ => ()
    }
  }
  count
}

///|
fn newthread_finished_for(
  events : Array[@types.TurnEvent],
  session_id : String,
) -> Int32 {
  let mut count = 0
  for event in events {
    match event {
      CompactFinished(final_session_id~, ..) =>
        if final_session_id == session_id {
          count = count + 1
        }
      _ => ()
    }
  }
  count
}

///|
/// Count the full saves recorded for one session id. NewThread output is
/// written once by the Agent; recovery may repeat a previously successful
/// store, so failure tests assert the final state rather than exactly-once.
fn newthread_save_count(store : RecordingSessionPort, target : String) -> Int32 {
  let mut count = 0
  for op in store.ops() {
    match op {
      OpSave(id~, ..) => if id == target { count = count + 1 }
      _ => ()
    }
  }
  count
}

///|
/// Model whose first chat call blocks until `released`, so the test can
/// enqueue a mailbox command while the run is bound and before the next pump
/// safe point drains it. Later chat calls answer with a stop response.
struct GatedTurnModel {
  mut entered : Bool
  mut released : Bool
  mut calls : Int32
  compacted : Array[@kernel.Message]
}

///|
impl @port.ModelPort for GatedTurnModel with fn chat(
  self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  self.calls = self.calls + 1
  if self.calls == 1 {
    self.entered = true
    while !self.released {
      @async.pause()
    }
    tk_tool_call_response("leaf", "call_1", Json::null())
  } else {
    tk_stop_response("done")
  }
}

///|
impl @port.ModelPort for GatedTurnModel with fn compact(
  self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  { compacted_messages: self.compacted.copy(), mode: NewThread, }
}

///|
impl @port.ModelPort for GatedTurnModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
async test "newthread/fork_persists_sibling_with_lineage_and_emits_redirect" {
  let model = GatedTurnModel::{
    entered: false,
    released: false,
    calls: 0,
    compacted: [],
  }
  let store = RecordingSessionPort()
  store.seed("s1", {
    messages: [tk_user_msg("one"), tk_user_msg("two")],
    metadata: Map::from_array([]),
  })
  let observer = RecordingObserver()
  let tools = RecordingToolProvider(
    [tk_tool_def("leaf", "leaf tool")],
    Map::from_array([("leaf", OutcomeOk(tk_ok_result("ok")))]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools]),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  @async.with_task_group(async fn(group) {
    let turn = group.spawn(() => agent.run_turn(tk_user_msg("go"), "s1"))
    // The gate always opens when the bounded enqueue phase exits — success,
    // assertion failure, or timeout — so the parked turn never outlives the
    // phase that was supposed to release it.
    let enqueued : Result[Bool, Error] = Ok(
      @async.with_timeout(60, async fn() -> Bool {
        defer {
          model.released = true
        }
        while !model.entered {
          @async.pause()
        }
        let mut fork_port : &@port.CommandPort? = None
        for port in agent.commands() {
          for def in port.commands() {
            if def.id == "fork-here" {
              fork_port = Some(port)
            }
          }
        }
        guard fork_port is Some(port) else { return false }
        guard port.invoke(
            "fork-here",
            Json::object(Map::from_array([("index", Json::number(2.0))])),
          )
          is Success(..) else {
          return false
        }
        true
      }),
    ) catch {
      e => Err(e)
    }
    guard enqueued is Ok(true) else {
      fail("fork enqueue failed: \{repr(enqueued)}")
    }
    let result = turn.wait()
    guard result.final_session_id == "s1" else {
      fail("fork must leave the caller on the original thread")
    }
  })
  // Exactly one redirect, sibling side counted from the fork point.
  let redirects = newthread_redirects(observer.events())
  guard redirects.length() == 1 else {
    fail("expected exactly one SessionRedirect, got \{redirects.length()}")
  }
  let (from, to, before, after) = redirects[0]
  assert_eq(from, "s1")
  assert_true(to.has_prefix("s1_fork_"))
  assert_eq(before, 2)
  assert_eq(after, 2)
  // The sibling carries the forked prefix and the parent lineage.
  let sibling = store.load(to) catch {
    e => fail("expected the fork sibling to persist: \{e}")
  }
  guard sibling.messages.length() == 2 else {
    fail(
      "expected the first two transcript messages, got \{sibling.messages.length()}",
    )
  }
  assert_true(sibling.messages[0] == tk_user_msg("one"))
  assert_true(sibling.messages[1] == tk_user_msg("two"))
  assert_eq(sibling.metadata[@types.PARENT_THREAD_ID_KEY], Json::string("s1"))
  // The sibling cursor advanced so the next turn appends instead of resaving.
  assert_eq(agent.runtime.progress.cursors.get(to), Some(2))
  // Parent provenance (evidence from the recorded writes): two incremental
  // checkpoints — the input at cursor 2, then the assistant tool-call message
  // at cursor 3. The tool result is never persisted: the fork safe point
  // stops the turn before the next boundary write.
  let checkpoints : Array[(Int32, Int32)] = []
  for op in store.ops() {
    match op {
      OpCheckpoint(id~, checkpoint~, ..) =>
        if id == "s1" {
          checkpoints.push(
            (
              checkpoint.from_index,
              checkpoint.from_index + checkpoint.messages.length(),
            ),
          )
        }
      _ => ()
    }
  }
  guard checkpoints.length() == 1 else {
    fail(
      "expected one parent checkpoint after initial full alignment, got \{checkpoints.length()}",
    )
  }
  assert_eq(checkpoints[0].0, 3)
  assert_eq(checkpoints[0].1, 4)
  let original = store.load("s1") catch { e => fail("parent missing: \{e}") }
  guard original.messages.length() == 4 else {
    fail(
      "parent must hold input + assistant tool-call appends, got \{original.messages.length()}",
    )
  }
  match original.messages[3] {
    AssistantMessage(tool_calls~, ..) => {
      guard tool_calls.length() == 1 else {
        fail("expected the appended assistant message to carry one tool call")
      }
      assert_eq(tool_calls[0].name.to_string(), "leaf")
      assert_eq(tool_calls[0].call_id.to_string(), "call_1")
    }
    _ => fail("the 4th parent message must be the assistant tool-call message")
  }
  assert_true(original.messages[0] == sibling.messages[0])
  assert_true(original.messages[1] == sibling.messages[1])
  assert_false(original.metadata.contains(@types.PARENT_THREAD_ID_KEY))
  // The Agent is the only NewThread output owner.
  assert_eq(newthread_save_count(store, to), 1)
}

///|
async test "newthread/compact_newthread_persists_sibling_with_lineage_and_emits_redirect" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("summary")],
      mode: NewThread,
    }),
  ])
  let store = RecordingSessionPort()
  store.seed("c1", {
    messages: [tk_user_msg("old-one"), tk_user_msg("old-two")],
    metadata: Map::from_array([]),
  })
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let outcome = agent.compact_session("c1")
  let to = outcome.final_session_id
  assert_true(to.has_prefix("c1_compact_"))
  assert_eq(outcome.messages_after, 1)
  let redirects = newthread_redirects(observer.events())
  guard redirects.length() == 1 else {
    fail("expected exactly one SessionRedirect, got \{redirects.length()}")
  }
  let (from, redirect_to, before, after) = redirects[0]
  assert_eq(from, "c1")
  assert_eq(redirect_to, to)
  assert_eq(before, 1)
  assert_eq(after, 1)
  // The sibling carries the compacted body and the parent lineage.
  let sibling = store.load(to) catch {
    e => fail("expected the compact sibling to persist: \{e}")
  }
  assert_eq(sibling.messages.length(), 1)
  assert_true(sibling.messages[0] == tk_user_msg("summary"))
  assert_eq(sibling.metadata[@types.PARENT_THREAD_ID_KEY], Json::string("c1"))
  assert_eq(agent.runtime.progress.cursors.get(to), Some(1))
  // Real alias isolation: mutate what load() handed out, then reload — the
  // persisted state must be untouched because saves carry deep snapshots.
  sibling.messages.push(tk_user_msg("poison"))
  sibling.metadata[@types.PARENT_THREAD_ID_KEY] = Json::string("hijacked")
  let reloaded = store.load(to) catch { e => fail("reload failed: \{e}") }
  assert_eq(reloaded.messages.length(), 1)
  assert_eq(reloaded.metadata[@types.PARENT_THREAD_ID_KEY], Json::string("c1"))
  // The original thread is preserved untouched.
  let original = store.load("c1") catch { e => fail("parent missing: \{e}") }
  assert_eq(original.messages.length(), 2)
  assert_false(original.metadata.contains(@types.PARENT_THREAD_ID_KEY))
  // The Agent is the only NewThread output owner.
  assert_eq(newthread_save_count(store, to), 1)
}

///|
/// Mid-turn manual compact: the model's NewThread compact answer during a
/// live run reaches `complete_compact_turn` (the mailbox safe-point path),
/// not the idle standalone entry.
async test "newthread/midturn_compact_newthread_reaches_complete_compact_turn" {
  let model = GatedTurnModel::{
    entered: false,
    released: false,
    calls: 0,
    compacted: [tk_user_msg("mid-turn summary")],
  }
  let store = RecordingSessionPort()
  store.seed("m1", {
    messages: [tk_user_msg("old-one"), tk_user_msg("old-two")],
    metadata: Map::from_array([]),
  })
  let observer = RecordingObserver()
  let tools = RecordingToolProvider(
    [tk_tool_def("leaf", "leaf tool")],
    Map::from_array([("leaf", OutcomeOk(tk_ok_result("ok")))]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools]),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let result = @async.with_task_group(async fn(group) {
    let turn = group.spawn(() => agent.run_turn(tk_user_msg("go"), "m1"))
    // Same bounded-gate contract as the fork test: the compact enqueue phase
    // always opens the gate on exit, before the turn is joined.
    let enqueued : Result[Bool, Error] = Ok(
      @async.with_timeout(60, async fn() -> Bool {
        defer {
          model.released = true
        }
        while !model.entered {
          @async.pause()
        }
        let mut compact_port : &@port.CommandPort? = None
        for port in agent.commands() {
          for def in port.commands() {
            if def.id == "compact" {
              compact_port = Some(port)
            }
          }
        }
        guard compact_port is Some(port) else { return false }
        guard port.invoke("compact", Json::null()) is Success(..) else {
          return false
        }
        true
      }),
    ) catch {
      e => Err(e)
    }
    guard enqueued is Ok(true) else {
      fail("mid-run compact enqueue failed: \{repr(enqueued)}")
    }
    turn.wait()
  })
  // First minted compact command id is `compact_1`, so the mid-run sibling
  // sid is deterministic: session + "_compact_" + command id.
  guard result.final_session_id == "m1_compact_compact_1" else {
    fail(
      "expected the mid-turn compact to divert to the sibling, got \{result.final_session_id}",
    )
  }
  assert_eq(model.calls, 1)
  let redirects = newthread_redirects(observer.events())
  guard redirects.length() == 1 else {
    fail("expected exactly one SessionRedirect, got \{redirects.length()}")
  }
  let (from, to, before, after) = redirects[0]
  assert_eq(from, "m1")
  assert_eq(to, "m1_compact_compact_1")
  assert_eq(before, 1)
  assert_eq(after, 1)
  let sibling = store.load(to) catch {
    e => fail("expected the compact sibling to persist: \{e}")
  }
  assert_eq(sibling.messages.length(), 1)
  assert_true(sibling.messages[0] == tk_user_msg("mid-turn summary"))
  assert_eq(sibling.metadata[@types.PARENT_THREAD_ID_KEY], Json::string("m1"))
  assert_eq(agent.runtime.progress.cursors.get(to), Some(1))
  // Single writer on the mid-turn path as well.
  assert_eq(newthread_save_count(store, to), 1)
}

///|
/// Store that fails saves from the `fail_from`-th call on until disarmed,
/// counting across ids. NewThread output is one Agent write per store;
/// recovery may repeat a store that already succeeded.
struct NewThreadFailStore {
  saves : Array[String]
  seen : Map[String, @types.Session]
  mut armed : Bool
  fail_from : Int32
  seeded : Array[@kernel.Message]
}

///|

///|
impl @port.SessionPort for NewThreadFailStore with fn load(self, _id) -> @types.Session {
  { messages: self.seeded.copy(), metadata: Map::from_array([]), }
}

///|
impl @port.SessionPort for NewThreadFailStore with fn save(self, id, session) -> Unit raise @error.SessionError {
  self.saves.push(id)
  if self.armed && self.saves.length() >= self.fail_from {
    raise Save("store offline")
  }
  self.seen[id] = session
}

///|
async test "newthread/failed_output_recovers_and_old_terminal_stays" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("summary-one")],
      mode: NewThread,
    }),
    Compact(result={
      compacted_messages: [tk_user_msg("summary-two")],
      mode: NewThread,
    }),
  ])
  let store = NewThreadFailStore::{
    saves: [],
    seen: Map::from_array([]),
    armed: true,
    fail_from: 1,
    seeded: [tk_user_msg("old-one"), tk_user_msg("old-two")],
  }
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let first_sid = "f1_compact_agent_compact_session_1"
  let outcome = Ok(agent.compact_session("f1")) catch { error => Err(error) }
  guard outcome is Err(Session(error)) else {
    let why = match outcome {
      Err(other) => other.to_string()
      Ok(_) => "compact completed"
    }
    fail("expected a Session error from the failed sibling save, got \{why}")
  }
  assert_true(error.to_string().contains("compact_newthread_save"))
  // The first attempt wrote nothing successfully; the core fact and pending
  // output remain in memory.
  assert_eq(store.saves, [first_sid])
  assert_false(store.seen.contains(first_sid))
  assert_eq(newthread_redirects(observer.events()).length(), 0)
  for key, _cursor in agent.runtime.progress.cursors {
    assert_false(key.has_prefix("f1_compact_"))
  }
  let old_failures = newthread_failure_terminals(observer.events())
  // The next operation first recovers the old child, then executes the new
  // compact request. Recovery consumes no model call and creates no new child.
  store.armed = false
  let retried = agent.compact_session("f1")
  let second_sid = retried.final_session_id
  assert_eq(second_sid, "f1_compact_agent_compact_session_2")
  assert_eq(retried.messages_after, 1)
  assert_eq(model.compact_call_count(), 2)
  let redirects = newthread_redirects(observer.events())
  assert_eq(redirects.length(), 2)
  assert_eq(redirects[0].1, first_sid)
  assert_eq(redirects[1].1, second_sid)
  // The first child is recovered with its original body, not the new answer.
  guard store.seen.get(first_sid) is Some(first_body) else {
    fail("expected recovery to persist the failed attempt's child")
  }
  assert_eq(first_body.messages.length(), 1)
  assert_true(first_body.messages[0] == tk_user_msg("summary-one"))
  assert_eq(
    first_body.metadata.get(@types.PARENT_THREAD_ID_KEY),
    Some(Json::string("f1")),
  )
  guard store.seen.get(second_sid) is Some(second_body) else {
    fail("expected the retried sibling to persist")
  }
  assert_eq(second_body.messages.length(), 1)
  assert_true(second_body.messages[0] == tk_user_msg("summary-two"))
  assert_eq(
    second_body.metadata.get(@types.PARENT_THREAD_ID_KEY),
    Some(Json::string("f1")),
  )
  assert_eq(agent.runtime.progress.cursors.get(first_sid), Some(1))
  assert_eq(agent.runtime.progress.cursors.get(second_sid), Some(1))
  assert_eq(store.saves, [first_sid, first_sid, second_sid])
  // Recovery only adds the old redirect; the old compact failure terminal is
  // not replaced by a success and no CompactFinished is invented for it.
  assert_eq(newthread_failure_terminals(observer.events()), old_failures)
  assert_eq(newthread_finished_for(observer.events(), first_sid), 0)
  assert_eq(newthread_finished_for(observer.events(), second_sid), 1)
}

///|
/// Agent-only fork output failure: the core child fact exists and the pending
/// snapshot remains, but no sibling, redirect, or cursor is published. The
/// next operation recovers that child before running its own request.
async test "newthread/fork_save_failure_recovers_pending_before_next_turn" {
  let model = GatedTurnModel::{
    entered: false,
    released: false,
    calls: 0,
    compacted: [],
  }
  let store = RecordingSessionPort()
  store.seed("s1", {
    messages: [tk_user_msg("one"), tk_user_msg("two")],
    metadata: Map::from_array([]),
  })
  // The first minted fork command id is `fork_1`, so the child sid is
  // deterministic.
  store.fail_save("s1_fork_fork_1")
  let observer = RecordingObserver()
  let tools = RecordingToolProvider(
    [tk_tool_def("leaf", "leaf tool")],
    Map::from_array([("leaf", OutcomeOk(tk_ok_result("ok")))]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools]),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  @async.with_task_group(async fn(group) {
    let turn_body : async () -> Result[@types.TurnResult, @error.AgentError] = () => {
      let r : Result[@types.TurnResult, @error.AgentError] = Ok(
        agent.run_turn(tk_user_msg("go"), "s1"),
      ) catch {
        e => Err(e)
      }
      r
    }
    let turn = group.spawn(turn_body)
    let enqueued : Result[Bool, Error] = Ok(
      @async.with_timeout(60, async fn() -> Bool {
        defer {
          model.released = true
        }
        while !model.entered {
          @async.pause()
        }
        let mut fork_port : &@port.CommandPort? = None
        for port in agent.commands() {
          for def in port.commands() {
            if def.id == "fork-here" {
              fork_port = Some(port)
            }
          }
        }
        guard fork_port is Some(port) else { return false }
        guard port.invoke(
            "fork-here",
            Json::object(Map::from_array([("index", Json::number(2.0))])),
          )
          is Success(..) else {
          return false
        }
        true
      }),
    ) catch {
      e => Err(e)
    }
    guard enqueued is Ok(true) else {
      fail("fork enqueue failed: \{repr(enqueued)}")
    }
    let outcome = turn.wait()
    guard outcome is Err(Session(error)) else {
      let why = match outcome {
        Ok(_) => "turn completed"
        Err(other) => other.to_string()
      }
      fail("expected a Session error from the failed fork save, got \{why}")
    }
    assert_true(error.to_string().contains("fork_save"))
  })
  let child_sid = "s1_fork_fork_1"
  assert_false(store.store.contains(child_sid))
  assert_eq(newthread_redirects(observer.events()).length(), 0)
  for key, _cursor in agent.runtime.progress.cursors {
    assert_false(key.has_prefix("s1_fork_"))
  }
  // The failed turn still persists its own parent progress, without lineage.
  let parent = store.load("s1") catch { e => fail("parent missing: \{e}") }
  guard parent.messages.length() == 4 else {
    fail(
      "expected the parent's pre-fork state, got \{parent.messages.length()}",
    )
  }
  assert_true(parent.messages[2] == tk_user_msg("go"))
  assert_false(parent.metadata.contains(@types.PARENT_THREAD_ID_KEY))
  let old_failures = newthread_failure_terminals(observer.events())
  // Recovery precedes the next turn: old child first, then the new request.
  store.heal_save(child_sid)
  let retried = agent.run_turn(tk_user_msg("again"), "s1")
  assert_eq(retried.final_session_id, "s1")
  let child = store.load(child_sid) catch {
    e => fail("expected recovery to persist the fork child: \{e}")
  }
  assert_eq(child.messages.length(), 2)
  assert_true(child.messages[0] == tk_user_msg("one"))
  assert_true(child.messages[1] == tk_user_msg("two"))
  assert_eq(
    child.metadata.get(@types.PARENT_THREAD_ID_KEY),
    Some(Json::string("s1")),
  )
  let redirects = newthread_redirects(observer.events())
  assert_eq(redirects.length(), 1)
  assert_eq(redirects[0].1, child_sid)
  assert_eq(agent.runtime.progress.cursors.get(child_sid), Some(2))
  assert_eq(newthread_failure_terminals(observer.events()), old_failures)
}

///|
/// Shared append-only order tape: stores and the observer record completion
/// markers on one timeline. Async single-writer appends are atomic between
/// await points, so no locking is needed.
priv struct OrderTape {
  entries : Array[String]
}

///|
fn OrderTape::OrderTape() -> OrderTape {
  { entries: [], }
}

///|
fn OrderTape::mark(self : OrderTape, entry : String) -> Unit {
  self.entries.push(entry)
}

///|
fn OrderTape::first_index_of(self : OrderTape, entry : String) -> Int32? {
  for i, candidate in self.entries {
    if candidate == entry {
      return Some(i)
    }
  }
  None
}

///|
/// Indexes of the save-completion markers for one sibling sid. Deliberately
/// order-agnostic across stores: the write-all tail is parallel, so the
/// relative order of two stores' markers is not assumed anywhere.
fn OrderTape::save_indexes_for(self : OrderTape, sid : String) -> Array[Int32] {
  let out : Array[Int32] = []
  for i, entry in self.entries {
    if entry.has_prefix("saved:") && entry.has_suffix(":" + sid) {
      out.push(i)
    }
  }
  out
}

///|
/// Store wrapper that records every completed save on the shared tape. The
/// wrapped RecordingSessionPort keeps the seeded state and the persisted
/// sessions; the marker is appended only after the inner save returned.
priv struct TapeStore {
  name : String
  tape : OrderTape
  inner : RecordingSessionPort
}

///|
impl @port.SessionPort for TapeStore with fn load(self, id : String) -> @types.Session raise @error.SessionError {
  self.inner.load(id)
}

///|
impl @port.SessionPort for TapeStore with fn save(
  self,
  id : String,
  session : @types.Session,
) -> Unit raise @error.SessionError {
  self.inner.save(id, session)
  self.tape.mark("saved:\{self.name}:\{id}")
}

///|
/// Observer wrapper that records the three order-relevant event variants on
/// the shared tape. Names verified against the producers: SessionRedirect is
/// emitted inside `persist_new_thread_session`; CompactFinished and
/// OperationFinalized(completed) right after it in `run_compact_operation`.
priv struct TapeObserver {
  tape : OrderTape
}

///|
impl @port.Observer for TapeObserver with fn on_event(
  self,
  _scope : @types.EventScope?,
  event : @types.TurnEvent,
) -> Unit {
  let name = match event {
    SessionRedirect(..) => "SessionRedirect"
    CompactFinished(..) => "CompactFinished"
    OperationFinalized(..) => "OperationFinalized"
    _ => return
  }
  self.tape.mark("event:\{name}")
}

///|
/// Write-all tail with two stores where exactly one store fails. The Agent
/// writes all stores in parallel; a partial success keeps the core fact and
/// pending snapshot, and the next operation retries both stores.
async test "newthread/partial_output_retry_repeats_store_without_exactly_once" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("summary-one")],
      mode: NewThread,
    }),
    Compact(result={
      compacted_messages: [tk_user_msg("summary-two")],
      mode: NewThread,
    }),
  ])
  let first = RecordingSessionPort()
  let second = RecordingSessionPort()
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[first, second], observers=[observer]),
    ],
    config=tk_config(),
  )
  let failed_sid = "p2_compact_agent_compact_session_1"
  second.fail_save(failed_sid)
  let outcome : Result[@types.CompactOutcome, @error.AgentError]? = @async.with_timeout_opt(
    250,
    async fn() {
      let r : Result[@types.CompactOutcome, @error.AgentError] = Ok(
        agent.compact_session("p2"),
      ) catch {
        e => Err(e)
      }
      r
    },
  )
  guard outcome is Some(Err(Session(error))) else {
    let why = match outcome {
      Some(Ok(v)) => "compact completed: \{v.final_session_id}"
      Some(Err(other)) => other.to_string()
      None => "compact_session timed out after 250ms"
    }
    fail("expected a Session error from the failing store, got \{why}")
  }
  assert_true(error.to_string().contains("compact_newthread_save"))
  // One store succeeded on the first attempt; the failing store did not.
  assert_eq(newthread_save_count(first, failed_sid), 1)
  let kept = first.load(failed_sid) catch {
    e => fail("expected the successful store to retain the sibling: \{e}")
  }
  assert_eq(kept.messages.length(), 1)
  assert_true(kept.messages[0] == tk_user_msg("summary-one"))
  assert_eq(
    kept.metadata.get(@types.PARENT_THREAD_ID_KEY),
    Some(Json::string("p2")),
  )
  assert_false(second.store.contains(failed_sid))
  // No diversion side effects: no redirect, no sibling cursor.
  assert_eq(newthread_redirects(observer.events()).length(), 0)
  for key, _cursor in agent.runtime.progress.cursors {
    assert_false(key.has_prefix("p2_compact_"))
  }
  let old_failures = newthread_failure_terminals(observer.events())
  // The next operation recovers the old child first (repeating the successful
  // store), then runs the new compact on its own deterministic sibling.
  second.heal_save(failed_sid)
  let retried : Result[@types.CompactOutcome, @error.AgentError]? = @async.with_timeout_opt(
    250,
    async fn() {
      let r : Result[@types.CompactOutcome, @error.AgentError] = Ok(
        agent.compact_session("p2"),
      ) catch {
        e => Err(e)
      }
      r
    },
  )
  guard retried is Some(Ok(retry_ok)) else {
    fail("expected the retried compact to succeed after lifting the failure")
  }
  let retry_sid = retry_ok.final_session_id
  assert_eq(retry_sid, "p2_compact_agent_compact_session_2")
  assert_eq(retry_ok.messages_after, 1)
  let redirects = newthread_redirects(observer.events())
  assert_eq(redirects.length(), 2)
  assert_eq(redirects[0].1, failed_sid)
  assert_eq(redirects[1].1, retry_sid)
  assert_eq(agent.runtime.progress.cursors.get(failed_sid), Some(1))
  assert_eq(agent.runtime.progress.cursors.get(retry_sid), Some(1))
  // The recovered child is written to both stores; the store that already
  // succeeded receives the same body again. This is intentionally not
  // exactly-once.
  assert_eq(newthread_save_count(first, failed_sid), 2)
  assert_true(second.store.contains(failed_sid))
  let recovered = second.load(failed_sid) catch {
    e => fail("expected the recovered child in the second store: \{e}")
  }
  assert_eq(recovered.messages.length(), 1)
  assert_true(recovered.messages[0] == tk_user_msg("summary-one"))
  assert_eq(newthread_save_count(first, retry_sid), 1)
  assert_eq(newthread_save_count(second, retry_sid), 1)
  assert_eq(newthread_failure_terminals(observer.events()), old_failures)
  assert_eq(newthread_finished_for(observer.events(), failed_sid), 0)
  assert_eq(newthread_finished_for(observer.events(), retry_sid), 1)
}

///|
/// Cross-component order on one shared tape: for a successful NewThread
/// compact every store save completes before the SessionRedirect, and the
/// redirect precedes the terminal projection events (CompactFinished, then
/// OperationFinalized). The two stores' tail writes run in parallel — their
/// relative order is deliberately not assumed.
async test "newthread/all_stores_persist_before_redirect_precedes_terminal_events" {
  let tape = OrderTape::OrderTape()
  let store_a = TapeStore::{ name: "A", tape, inner: RecordingSessionPort(), }
  let store_b = TapeStore::{ name: "B", tape, inner: RecordingSessionPort(), }
  for wrapped in [store_a, store_b] {
    wrapped.inner.seed("w1", {
      messages: [tk_user_msg("old-one"), tk_user_msg("old-two")],
      metadata: Map::from_array([]),
    })
  }
  let observer = TapeObserver::{ tape, }
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("summary")],
      mode: NewThread,
    }),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store_a, store_b], observers=[observer]),
    ],
    config=tk_config(),
  )
  let outcome : Result[@types.CompactOutcome, @error.AgentError]? = @async.with_timeout_opt(
    250,
    async fn() {
      let r : Result[@types.CompactOutcome, @error.AgentError] = Ok(
        agent.compact_session("w1"),
      ) catch {
        e => Err(e)
      }
      r
    },
  )
  guard outcome is Some(Ok(ok)) else {
    fail("expected the compact to succeed within the timeout")
  }
  let sid = ok.final_session_id
  assert_true(sid.has_prefix("w1_compact_"))
  // Both stores hold the sibling with body and lineage.
  for wrapped in [store_a, store_b] {
    let session = wrapped.inner.load(sid) catch {
      e => fail("expected store \{wrapped.name} to hold the sibling: \{e}")
    }
    assert_eq(session.messages.length(), 1)
    assert_true(session.messages[0] == tk_user_msg("summary"))
    assert_eq(
      session.metadata.get(@types.PARENT_THREAD_ID_KEY),
      Some(Json::string("w1")),
    )
  }
  // Exactly two completions for this sibling: one Agent write-all save per
  // store. There is no Puppet sibling write.
  let saves = tape.save_indexes_for(sid)
  guard saves.length() == 2 else {
    fail(
      "expected 2 store save completions before review, got \{saves.length()}",
    )
  }
  // Every save completed before the redirect. Max over an order-agnostic set:
  // no assumption about the two stores' internal completion order.
  let redirect_idx = tape.first_index_of("event:SessionRedirect")
  guard redirect_idx is Some(redirect_at) else {
    fail("expected a SessionRedirect marker on the tape")
  }
  for at in saves {
    assert_true(
      at < redirect_at,
      msg="a store save completed after the SessionRedirect",
    )
  }
  // The redirect precedes the terminal projection events, in producer order.
  let finished_idx = tape.first_index_of("event:CompactFinished")
  guard finished_idx is Some(finished_at) else {
    fail("expected a CompactFinished marker on the tape")
  }
  assert_true(redirect_at < finished_at)
  let finalized_idx = tape.first_index_of("event:OperationFinalized")
  guard finalized_idx is Some(finalized_at) else {
    fail("expected an OperationFinalized marker on the tape")
  }
  assert_true(finished_at < finalized_at)
  assert_eq(agent.runtime.progress.cursors.get(sid), Some(1))
}

///|
async test "newthread/single_store_single_write_and_redirect" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("single-summary")],
      mode: NewThread,
    }),
  ])
  let store = RecordingSessionPort()
  store.seed("single-parent", {
    messages: [tk_user_msg("old")],
    metadata: Map::from_array([]),
  })
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let outcome = agent.compact_session("single-parent")
  let child = outcome.final_session_id
  assert_eq(newthread_save_count(store, child), 1)
  assert_eq(newthread_redirects(observer.events()).length(), 1)
}

///|
async test "newthread/failed_output_gate_blocks_then_recovers_before_body" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("pending-summary")],
      mode: NewThread,
    }),
    Respond(tk_stop_response("new request")),
  ])
  let store = RecordingSessionPort()
  store.seed("gate-parent", {
    messages: [tk_user_msg("old")],
    metadata: Map::from_array([]),
  })
  let child_sid = "gate-parent_compact_agent_compact_session_1"
  store.fail_save(child_sid)
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let first : Result[@types.CompactOutcome, @error.AgentError] = Ok(
    agent.compact_session("gate-parent"),
  ) catch {
    error => Err(error)
  }
  guard first is Err(_) else {
    fail("expected the first child output save to fail")
  }
  assert_eq(newthread_redirects(observer.events()).length(), 0)
  assert_false(store.store.contains(child_sid))
  guard agent.runtime.pending_new_thread.get(child_sid) is Some(pending) else {
    fail("expected a pending child output snapshot")
  }
  assert_eq(pending.parent_session_id, "gate-parent")
  assert_eq(pending.child_session_id, child_sid)
  assert_eq(pending.messages.length(), 1)
  assert_true(pending.messages[0] == tk_user_msg("pending-summary"))
  assert_eq(
    pending.metadata.get(@types.PARENT_THREAD_ID_KEY),
    Some(Json::string("gate-parent")),
  )
  assert_eq(pending.scope.run_id, @kernel.RunId::unchecked("agent_run_1"))
  assert_eq(pending.scope.turn_id, @kernel.TurnId::unchecked("agent_turn_1"))
  assert_eq(
    pending.scope.session_id,
    @kernel.SessionId::unchecked("gate-parent"),
  )
  let (turns_before, compacts_before) = newthread_started_events(
    observer.events(),
  )
  assert_eq(turns_before, 0)
  assert_eq(compacts_before, 1)
  // The pending output is not recovered yet: the gate must fail before any
  // new model request is dispatched.
  let blocked : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(tk_user_msg("next"), "gate-parent"),
  ) catch {
    error => Err(error)
  }
  guard blocked is Err(Session(_)) else {
    fail("expected recovery failure to surface as a Session error")
  }
  assert_eq(model.call_count(), 0)
  assert_eq(newthread_redirects(observer.events()).length(), 0)
  assert_false(store.store.contains(child_sid))
  assert_eq(agent.runtime.pending_new_thread.length(), 1)
  let (turns_after_failure, compacts_after_failure) = newthread_started_events(
    observer.events(),
  )
  assert_eq(turns_after_failure, turns_before)
  assert_eq(compacts_after_failure, compacts_before)
  // Healing the store lets the next operation recover the old output first,
  // then execute the new request.
  store.heal_save(child_sid)
  let next = agent.run_turn(tk_user_msg("next"), "gate-parent")
  assert_eq(next.final_session_id, "gate-parent")
  assert_eq(model.call_count(), 1)
  assert_eq(model.compact_call_count(), 1)
  let (turns_after, compacts_after) = newthread_started_events(
    observer.events(),
  )
  assert_eq(turns_after, 1)
  assert_eq(compacts_after, 1)
  let redirects = newthread_redirects(observer.events())
  assert_eq(redirects.length(), 1)
  assert_eq(redirects[0].1, child_sid)
  let child = store.store[child_sid]
  assert_eq(child.messages.length(), 1)
  assert_true(child.messages[0] == tk_user_msg("pending-summary"))
  assert_eq(agent.runtime.progress.cursors.get(child_sid), Some(1))
  assert_eq(agent.runtime.pending_new_thread.length(), 0)
}

///|
async test "newthread/child_fact_failure_blocks_all_output" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("must-not-save")],
      mode: NewThread,
    }),
  ])
  let store = RecordingSessionPort()
  store.seed("fact-parent", {
    messages: [tk_user_msg("old")],
    metadata: Map::from_array([]),
  })
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let child_sid = "fact-parent_compact_agent_compact_session_1"
  ignore(
    agent.runtime.core_shadow.store.record_full(
      child_sid,
      [tk_user_msg("pre-existing")],
      Map::from_array([]),
    ),
  )
  let outcome : Result[@types.CompactOutcome, @error.AgentError] = Ok(
    agent.compact_session("fact-parent"),
  ) catch {
    error => Err(error)
  }
  guard outcome is Err(Runtime(InvocationFailed(detail))) else {
    fail("expected an explicit child core fact failure")
  }
  assert_true(detail.contains("core child fact"))
  assert_false(store.store.contains(child_sid))
  assert_eq(newthread_redirects(observer.events()).length(), 0)
  for key, _cursor in agent.runtime.progress.cursors {
    assert_false(key.has_prefix("fact-parent_compact_"))
  }
}

///|
priv struct ScopedRedirectObserver {
  redirects : Array[(@types.EventScope?, String)]
}

///|
impl @port.Observer for ScopedRedirectObserver with fn on_event(
  self,
  scope,
  event,
) -> Unit {
  match event {
    SessionRedirect(to~, ..) => self.redirects.push((scope, to))
    _ => ()
  }
}

///|
async test "newthread/recovery_preserves_parent_and_original_scope" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("scope-summary")],
      mode: NewThread,
    }),
    Respond(tk_stop_response("other request")),
  ])
  let store = RecordingSessionPort()
  store.seed("scope-parent", {
    messages: [tk_user_msg("parent-old")],
    metadata: Map::from_array([("kept", Json::string("parent-meta"))]),
  })
  let child_sid = "scope-parent_compact_agent_compact_session_1"
  store.fail_save(child_sid)
  let observer = ScopedRedirectObserver::{ redirects: [], }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let first : Result[@types.CompactOutcome, @error.AgentError] = Ok(
    agent.compact_session("scope-parent"),
  ) catch {
    error => Err(error)
  }
  guard first is Err(_) else { fail("expected the first child output to fail") }
  assert_eq(observer.redirects.length(), 0)
  let parent_before = store.load("scope-parent") catch {
    e => fail("expected the parent to remain loaded: \{e}")
  }
  let parent_cursor_before = agent.runtime.progress.cursor_or_zero(
    "scope-parent",
  )
  // The failed diversion never confirmed parent output, so no persisted
  // cursor exists until a successful write.
  assert_eq(parent_cursor_before, 0)
  match agent.runtime.core_shadow.state.get("scope-parent") {
    Some(Stopped(run_id~, ..)) => assert_eq(run_id, "agent_run_1")
    _ => fail("expected the parent core tracking to be stopped after diversion")
  }
  // Recover while executing a different request/session. The parent is not
  // part of the recovery write and must stay byte-for-byte unchanged.
  store.heal_save(child_sid)
  let next = agent.run_turn(tk_user_msg("other"), "scope-other")
  assert_eq(next.final_session_id, "scope-other")
  assert_eq(model.call_count(), 1)
  assert_eq(model.compact_call_count(), 1)
  assert_eq(observer.redirects.length(), 1)
  let (scope, to) = observer.redirects[0]
  assert_eq(to, child_sid)
  guard scope is Some(scope) else {
    fail("expected the recovery redirect to carry a scope")
  }
  assert_eq(scope.run_id, @kernel.RunId::unchecked("agent_run_1"))
  assert_eq(scope.turn_id, @kernel.TurnId::unchecked("agent_turn_1"))
  assert_eq(scope.session_id, @kernel.SessionId::unchecked("scope-parent"))
  let parent_after = store.load("scope-parent") catch {
    e => fail("expected the parent to remain loaded: \{e}")
  }
  assert_eq(parent_after.messages.length(), parent_before.messages.length())
  assert_true(parent_after.messages[0] == parent_before.messages[0])
  assert_eq(parent_after.metadata, parent_before.metadata)
  assert_eq(
    agent.runtime.progress.cursor_or_zero("scope-parent"),
    parent_cursor_before,
  )
  match agent.runtime.core_shadow.state.get("scope-parent") {
    Some(Stopped(run_id~, ..)) => assert_eq(run_id, "agent_run_1")
    _ => fail("recovery must not change the stopped parent core state")
  }
  assert_eq(agent.runtime.progress.cursors.get(child_sid), Some(1))
  assert_eq(agent.runtime.pending_new_thread.length(), 0)
  let child = store.load(child_sid) catch {
    e => fail("expected the recovered child: \{e}")
  }
  assert_eq(child.messages.length(), 1)
  assert_true(child.messages[0] == tk_user_msg("scope-summary"))
  assert_false(child.metadata.contains("kept"))
  assert_eq(
    child.metadata.get(@types.PARENT_THREAD_ID_KEY),
    Some(Json::string("scope-parent")),
  )
}

///|
/// Test store that parks the first child save on a real async gate. The
/// operation can only reach cancellation after the child core fact and pending
/// snapshot exist; releasing the gate after cancellation lets the next
/// operation prove it recovers the same child and body.
priv struct CancelGateStore {
  inner : RecordingSessionPort
  child_sid : String
  mut armed : Bool
  mut entered : Bool
  gate : @async.CondVar
}

///|
impl @port.SessionPort for CancelGateStore with fn load(self, id : String) -> @types.Session raise @error.SessionError {
  self.inner.load(id)
}

///|
impl @port.SessionPort for CancelGateStore with fn save(
  self,
  id : String,
  session : @types.Session,
) -> Unit raise @error.SessionError {
  if self.armed && id == self.child_sid {
    self.armed = false
    self.entered = true
    self.gate.broadcast()
    self.gate.wait()
  }
  self.inner.save(id, session)
}

///|
impl @port.SessionPort for CancelGateStore with fn checkpoint(
  self,
  id : String,
  checkpoint : @port.SessionCheckpoint,
) -> Unit raise @error.SessionError {
  self.inner.checkpoint(id, checkpoint)
}

///|
async test "newthread/cancel_after_core_fact_keeps_pending_for_recovery" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("cancel-summary")],
      mode: NewThread,
    }),
    Respond(tk_stop_response("after cancel")),
  ])
  let child_sid = "cancel-parent_compact_agent_compact_session_1"
  let store = CancelGateStore::{
    inner: RecordingSessionPort(),
    child_sid,
    armed: true,
    entered: false,
    gate: @async.CondVar::Cond(),
  }
  store.inner.seed("cancel-parent", {
    messages: [tk_user_msg("old")],
    metadata: Map::from_array([]),
  })
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  @async.with_task_group(async fn(group) {
    let running = group.spawn(() => {
      let r : Result[@types.CompactOutcome, @error.AgentError] = Ok(
        agent.compact_session("cancel-parent"),
      ) catch {
        error => Err(error)
      }
      r
    })
    while !store.entered {
      @async.pause()
    }
    running.cancel()
    let waited : Result[Result[@types.CompactOutcome, @error.AgentError], Error] = Ok(
      running.wait(),
    ) catch {
      _ => Err(Error::Failure("cancelled"))
    }
    ignore(waited)
  })
  assert_eq(agent.runtime.pending_new_thread.length(), 1)
  assert_true(
    agent.runtime.core_shadow.store.sessions.contains(child_sid),
    msg="the child core fact must survive cancellation",
  )
  assert_false(store.inner.store.contains(child_sid))
  assert_eq(newthread_redirects(observer.events()).length(), 0)
  assert_false(agent.runtime.progress.cursors.contains(child_sid))
  // Release the gate without changing the snapshot; the next operation
  // recovers the same child and body, then executes its own request.
  store.gate.broadcast()
  let next = agent.run_turn(tk_user_msg("next"), "cancel-parent")
  assert_eq(next.final_session_id, "cancel-parent")
  assert_eq(agent.runtime.pending_new_thread.length(), 0)
  assert_eq(model.call_count(), 1)
  assert_eq(model.compact_call_count(), 1)
  let child = store.inner.load(child_sid) catch {
    e => fail("expected cancel recovery to persist the child: \{e}")
  }
  assert_eq(child.messages.length(), 1)
  assert_true(child.messages[0] == tk_user_msg("cancel-summary"))
  assert_eq(
    child.metadata.get(@types.PARENT_THREAD_ID_KEY),
    Some(Json::string("cancel-parent")),
  )
  assert_eq(agent.runtime.progress.cursors.get(child_sid), Some(1))
  let redirects = newthread_redirects(observer.events())
  assert_eq(redirects.length(), 1)
  assert_eq(redirects[0].1, child_sid)
}
