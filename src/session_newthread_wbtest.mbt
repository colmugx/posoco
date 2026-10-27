///|
/// NewThread diversion regression coverage. Until this file, the fork
/// terminal, both compact NewThread terminals (idle standalone and mid-turn
/// manual), and their shared persistence tail (`persist_new_thread_session`)
/// ran under zero tests. These tests pin the batch-4-reviewed contract: the
/// sibling save succeeds first, then the cursor advances, then exactly one
/// SessionRedirect reaches observers; a save failure yields the labeled
/// Session error, none of the three, and the same Agent stays reusable.
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
/// Count the full saves recorded for one session id (the dual-write
/// sentinel: Puppet save first, Agent persistence tail second).
fn newthread_save_count(
  store : RecordingSessionStore,
  target : String,
) -> Int32 {
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
  let store = RecordingSessionStore()
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
  assert_eq(agent.runtime.session_cursors.get(to), Some(2))
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
  guard checkpoints.length() == 2 else {
    fail("expected two parent checkpoints, got \{checkpoints.length()}")
  }
  assert_eq(checkpoints[0].0, 2)
  assert_eq(checkpoints[0].1, 3)
  assert_eq(checkpoints[1].0, 3)
  assert_eq(checkpoints[1].1, 4)
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
  // Dual-write sentinel: Puppet save first, Agent persistence tail second.
  assert_eq(newthread_save_count(store, to), 2)
}

///|
async test "newthread/compact_newthread_persists_sibling_with_lineage_and_emits_redirect" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("summary")],
      mode: NewThread,
    }),
  ])
  let store = RecordingSessionStore()
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
  assert_eq(agent.runtime.session_cursors.get(to), Some(1))
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
  // Dual-write sentinel: Puppet save first, Agent persistence tail second.
  assert_eq(newthread_save_count(store, to), 2)
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
  let store = RecordingSessionStore()
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
  assert_eq(agent.runtime.session_cursors.get(to), Some(1))
  // Dual-write sentinel on the mid-turn path as well.
  assert_eq(newthread_save_count(store, to), 2)
}

///|
/// Store that fails saves from the `fail_from`-th call on until disarmed,
/// counting across ids. On a standalone NewThread compact the Puppet's
/// sibling save is call 1 and the Agent's shared persistence tail is call 2,
/// both targeting the same deterministic sid.
struct NewThreadFailStore {
  saves : Array[String]
  seen : Map[String, @types.Session]
  mut armed : Bool
  fail_from : Int32
  seeded : Array[@kernel.Message]
}

///|

///|
impl @port.SessionStore for NewThreadFailStore with fn load(self, _id) -> @types.Session {
  { messages: self.seeded.copy(), metadata: Map::from_array([]), }
}

///|
impl @port.SessionStore for NewThreadFailStore with fn save(self, id, session) -> Unit raise @error.SessionError {
  self.saves.push(id)
  self.seen[id] = session
  if self.armed && self.saves.length() >= self.fail_from {
    raise Save("store offline")
  }
}

///|
async test "newthread/tail_save_failure_keeps_error_and_same_agent_stays_reusable" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("summary-one")],
      mode: NewThread,
    }),
    Compact(result={
      compacted_messages: [tk_user_msg("summary-two")],
      mode: NewThread,
    }),
    Respond(tk_stop_response("after failure")),
  ])
  let store = NewThreadFailStore::{
    saves: [],
    seen: Map::from_array([]),
    armed: true,
    fail_from: 2,
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
  let outcome = Ok(agent.compact_session("f1")) catch { error => Err(error) }
  guard outcome is Err(Session(error)) else {
    let why = match outcome {
      Err(other) => other.to_string()
      Ok(_) => "compact completed"
    }
    fail("expected a Session error from the failed sibling save, got \{why}")
  }
  // The failure is labeled with the shared tail's operation name.
  assert_true(error.to_string().contains("compact_newthread_save"))
  // Store-write order sentinel: both writes targeted the same deterministic
  // sibling sid — Puppet first, Agent tail second (the failing one).
  let first_sid = "f1_compact_agent_compact_session_1"
  assert_eq(store.saves, [first_sid, first_sid])
  // Nothing after the failed tail save ran: no redirect, no sibling cursor.
  assert_eq(newthread_redirects(observer.events()).length(), 0)
  for key, _cursor in agent.runtime.session_cursors {
    assert_false(key.has_prefix("f1_compact_"))
  }
  // The same Agent admits the next operation immediately — not Busy — and
  // its second NewThread compact succeeds end to end.
  store.armed = false
  let retried = agent.compact_session("f1")
  let second_sid = retried.final_session_id
  assert_eq(second_sid, "f1_compact_agent_compact_session_2")
  assert_eq(retried.messages_after, 1)
  assert_eq(newthread_redirects(observer.events()).length(), 1)
  // The failed attempt's Puppet save (call 1) still persisted the first
  // sibling with its lineage before the tail failed on call 2.
  guard store.seen.get(first_sid) is Some(first_body) else {
    fail("expected the failed attempt's Puppet save to persist the sibling")
  }
  assert_true(first_body.messages[0] == tk_user_msg("summary-one"))
  assert_eq(
    first_body.metadata.get(@types.PARENT_THREAD_ID_KEY),
    Some(Json::string("f1")),
  )
  // The retry persisted its own sibling with the new body and lineage.
  guard store.seen.get(second_sid) is Some(second_body) else {
    fail("expected the retried sibling to persist")
  }
  assert_eq(second_body.messages.length(), 1)
  assert_true(second_body.messages[0] == tk_user_msg("summary-two"))
  assert_eq(
    second_body.metadata.get(@types.PARENT_THREAD_ID_KEY),
    Some(Json::string("f1")),
  )
  // The turn guard re-arms too: a plain run on the same Agent succeeds.
  let turn = agent.run_turn(tk_user_msg("again"), "f1")
  assert_eq(turn.final_session_id, "f1")
  // Total write order across the failure, the retry, and the turn: the
  // follow-up run performs exactly two whole-session saves of the parent
  // (input checkpoint + final save), matching the rewrite-falls-back-to-save
  // model.
  assert_eq(store.saves, [
    first_sid, first_sid, second_sid, second_sid, "f1", "f1",
  ])
}
