///|
struct MinimalSaveOnlyStore {
  data : Map[String, @types.Session]
  loads : Ref[Int32]
  saves : Ref[Int32]
}

///|
fn MinimalSaveOnlyStore::new() -> MinimalSaveOnlyStore {
  { data: Map::from_array([]), loads: Ref(0), saves: Ref(0), }
}

///|
pub impl @port.SessionPort for MinimalSaveOnlyStore with fn load(
  self,
  id : String,
) -> @types.Session raise @error.SessionError {
  self.loads.val = self.loads.val + 1
  match self.data.get(id) {
    Some(s) =>
      {
        messages: @message_snapshot.snapshot_messages(s.messages),
        metadata: @message_snapshot.snapshot_metadata(s.metadata),
      }
    None => { messages: [], metadata: Map::from_array([]), }
  }
}

///|
pub impl @port.SessionPort for MinimalSaveOnlyStore with fn save(
  self,
  id : String,
  session : @types.Session,
) -> Unit raise @error.SessionError {
  self.saves.val = self.saves.val + 1
  self.data[id] = {
    messages: @message_snapshot.snapshot_messages(session.messages),
    metadata: @message_snapshot.snapshot_metadata(session.metadata),
  }
}

///|
fn assistant_text(text : String) -> @kernel.Message {
  AssistantMessage(
    content=[Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
  )
}

///|
struct GateModel {
  entered : @aqueue.Queue[Unit]
  release : @aqueue.Queue[Unit]
}

///|
impl @port.ModelPort for GateModel with fn chat(
  self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  try {
    self.entered.put(())
    ignore(self.release.get())
  } catch {
    _ => ()
  }
  @test_support.tk_stop_response("done")
}

///|
impl @port.ModelPort for GateModel with fn compact(
  _self,
  _scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  { compacted_messages: messages.to_owned(), mode: Replace, }
}

///|
impl @port.ModelPort for GateModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
struct MemoryProbe {
  inbound_calls : Ref[Int32]
}

///|
impl @port.MemoryPort for MemoryProbe with fn inbound(
  self,
  session_id~ : String,
  request~ : String,
) -> String? raise @error.MemoryError {
  ignore(session_id)
  ignore(request)
  self.inbound_calls.val = self.inbound_calls.val + 1
  Some("remembered context")
}

///|
impl @port.MemoryPort for MemoryProbe with fn store(
  _self,
  content~ : String,
  metadata~ : Map[String, Json],
) -> String raise @error.MemoryError {
  ignore(content)
  ignore(metadata)
  "m1"
}

///|
impl @port.MemoryPort for MemoryProbe with fn search(
  _self,
  query~ : String,
  top_k? : Int32,
) -> String? raise @error.MemoryError {
  ignore(query)
  ignore(top_k)
  None
}

///|
impl @port.MemoryPort for MemoryProbe with fn delete(_self, _id : String) -> Unit raise @error.MemoryError {
  ()
}

///|
async fn invoke_agent_command(
  agent : Agent,
  id : String,
  args : Json,
) -> @port.CommandOutcome {
  for port in agent.commands() {
    for def in port.commands() {
      if def.id == id {
        return port.invoke(id, args)
      }
    }
  }
  abort("command not found: \{id}")
}

///|
struct TailForkModel {
  mut calls : Int32
  on_first_chat : Ref[(async () -> @port.CommandOutcome)?]
  mut outcome : @port.CommandOutcome?
}

///|
impl @port.ModelPort for TailForkModel with fn chat(
  self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  self.calls = self.calls + 1
  if self.calls == 1 {
    if self.on_first_chat.val is Some(cb) {
      self.on_first_chat.val = None
      self.outcome = Some(cb() catch { e => Failure(reason=e.to_string()) })
    }
    @test_support.tk_tool_call_response("leaf", "call_tail", Json::null())
  } else {
    @test_support.tk_stop_response("done")
  }
}

///|
impl @port.ModelPort for TailForkModel with fn compact(
  _self,
  _scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  { compacted_messages: messages.to_owned(), mode: Replace, }
}

///|
impl @port.ModelPort for TailForkModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
async test "fork_session/cold_single_store_uses_op_fork_strips_internal_meta_and_appends" {
  let store = @test_support.RecordingSessionPort()
  store.seed("parent", {
    messages: [
      @test_support.tk_user_msg("u1"),
      assistant_text("a1"),
      @test_support.tk_user_msg("u2"),
    ],
    metadata: Map::from_array([("parent_only", Json::string("secret"))]),
  })
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("child-reply")),
  ])
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let caller_meta : Map[String, Json] = Map::from_array([
    ("workspace", Json::string("/repo/a")),
    ("posoco.context_state", Json::string("stale")),
    ("posoco.task.applied_ids", Json::array([Json::string("t1")])),
    (@types.PARENT_THREAD_ID_KEY, Json::string("forged")),
    (@types.PARENT_FORK_INDEX_KEY, Json::number(99.0)),
  ])
  let outcome = agent.fork_session(
    "parent",
    new_session_id="child-1",
    at_message_index=2,
    metadata=caller_meta,
  )
  assert_eq(outcome.parent_session_id, "parent")
  assert_eq(outcome.new_session_id, "child-1")
  assert_eq(outcome.fork_index, 2)
  assert_eq(outcome.messages_after, 2)

  let mut fork_ops = 0
  let mut save_ops = 0
  for op in store.ops() {
    match op {
      OpFork(id="child-1", fork~, ..) => {
        fork_ops = fork_ops + 1
        assert_eq(fork.from_id, "parent")
        assert_eq(fork.at_index, 2)
        assert_eq(fork.messages.length(), 2)
      }
      OpSave(id="child-1", ..) => save_ops = save_ops + 1
      _ => ()
    }
  }
  assert_eq(fork_ops, 1)
  assert_eq(save_ops, 0)

  let child = store.load("child-1") catch { e => fail("child load: \{e}") }
  assert_eq(child.messages.length(), 2)
  assert_eq(child.parent_thread_id(), Some("parent"))
  assert_eq(child.parent_fork_index(), Some(2))
  assert_eq(child.metadata.get("workspace"), Some(Json::string("/repo/a")))
  assert_false(child.metadata.contains("parent_only"))
  assert_false(child.metadata.contains("posoco.context_state"))
  assert_false(child.metadata.contains("posoco.task.applied_ids"))

  let parent = store.load("parent") catch { e => fail("parent load: \{e}") }
  assert_eq(parent.messages.length(), 3)
  assert_false(parent.metadata.contains(@types.PARENT_THREAD_ID_KEY))

  let mut saw_redirect = false
  let mut saw_finalized = false
  for ev in observer.events() {
    match ev {
      SessionRedirect(
        from="parent",
        to="child-1",
        messages_before=2,
        messages_after=2,
      ) => saw_redirect = true
      OperationFinalized(operation="fork", outcome="completed", ..) =>
        saw_finalized = true
      _ => ()
    }
  }
  assert_true(saw_redirect)
  assert_true(saw_finalized)

  assert_true(agent.context_state("child-1") is Some(_))

  let ops_before_turn = store.ops().length()
  ignore(agent.run_turn(@test_support.tk_user_msg("follow"), "child-1"))
  let new_ops = store.ops()[ops_before_turn:]
  let mut child_saves = 0
  let mut child_checkpoints = 0
  for op in new_ops {
    match op {
      OpSave(id="child-1", ..) => child_saves = child_saves + 1
      OpCheckpoint(id="child-1", ..) =>
        child_checkpoints = child_checkpoints + 1
      _ => ()
    }
  }
  assert_eq(child_saves, 0)
  assert_true(child_checkpoints >= 1)
}

///|
async test "fork_session/defaults_clamping_and_target_validation" {
  let store = @test_support.RecordingSessionPort()
  store.seed("s1", {
    messages: [
      @test_support.tk_user_msg("one"),
      @test_support.tk_user_msg("two"),
    ],
    metadata: Map::from_array([]),
  })
  let model = @test_support.ScriptedModel([])
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let tail_fork = agent.fork_session("s1")
  assert_true(tail_fork.new_session_id.has_prefix("s1_fork_"))
  assert_eq(tail_fork.fork_index, 2)
  assert_eq(tail_fork.messages_after, 2)

  let clamped_high = agent.fork_session(
    "s1",
    new_session_id="s1-high",
    at_message_index=99,
  )
  assert_eq(clamped_high.fork_index, 2)

  let clamped_neg = agent.fork_session(
    "s1",
    new_session_id="s1-zero",
    at_message_index=-5,
  )
  assert_eq(clamped_neg.fork_index, 0)
  let zero_loaded = store.load("s1-zero") catch { e => fail("load: \{e}") }
  assert_eq(zero_loaded.messages.length(), 0)
  assert_eq(zero_loaded.parent_fork_index(), Some(0))

  for bad_id in ["", "s1", "s1-high"] {
    let attempted : Result[@types.ForkOutcome, @error.AgentError] = Ok(
      agent.fork_session("s1", new_session_id=bad_id),
    ) catch {
      e => Err(e)
    }
    guard attempted is Err(Session(Conflict(_))) else {
      fail("expected Session(Conflict) for bad target '\{bad_id}'")
    }
  }
}

///|
async test "fork_session/unaligned_two_stores_falls_back_to_save_all" {
  let first = @test_support.RecordingSessionPort()
  let second = @test_support.RecordingSessionPort()
  first.seed("two-store", {
    messages: [@test_support.tk_user_msg("a1"), @test_support.tk_user_msg("a2")],
    metadata: Map::from_array([]),
  })
  second.seed("two-store", {
    messages: [@test_support.tk_user_msg("stale")],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(@test_support.ScriptedModel([])),
      ),
      @test_support.tk_ext(id="io", sessions=[first, second]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let outcome = agent.fork_session(
    "two-store",
    new_session_id="two-child",
    at_message_index=2,
  )
  assert_eq(outcome.messages_after, 2)
  for store in [first, second] {
    let mut saves = 0
    let mut forks = 0
    for op in store.ops() {
      match op {
        OpSave(id="two-child", ..) => saves = saves + 1
        OpFork(id="two-child", ..) => forks = forks + 1
        _ => ()
      }
    }
    assert_eq(saves, 1)
    assert_eq(forks, 0)
    let saved = store.load("two-child") catch { e => fail("load: \{e}") }
    assert_eq(saved.messages.length(), 2)
    assert_eq(saved.messages[1], @test_support.tk_user_msg("a2"))
  }
}

///|
async test "fork_session/minimal_store_uses_default_fork_without_extra_load" {
  let store = MinimalSaveOnlyStore::new()
  store.data["min-parent"] = {
    messages: [@test_support.tk_user_msg("m1"), @test_support.tk_user_msg("m2")],
    metadata: Map::from_array([]),
  }
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(@test_support.ScriptedModel([])),
      ),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let outcome = agent.fork_session(
    "min-parent",
    new_session_id="min-child",
    at_message_index=1,
  )
  assert_eq(outcome.messages_after, 1)
  assert_eq(store.loads.val, 1)
  assert_eq(store.saves.val, 1)
  let child = store.data["min-child"]
  assert_eq(child.messages.length(), 1)
  assert_eq(child.messages[0], @test_support.tk_user_msg("m1"))
  assert_eq(child.parent_thread_id(), Some("min-parent"))
  assert_eq(child.parent_fork_index(), Some(1))
}

///|
async test "fork_session/save_failure_recovers_before_next_operation" {
  let store = @test_support.RecordingSessionPort()
  store.seed("p1", {
    messages: [
      @test_support.tk_user_msg("one"),
      @test_support.tk_user_msg("two"),
    ],
    metadata: Map::from_array([]),
  })
  store.fail_save("p1-child")
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("next-ok")),
  ])
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let failed : Result[@types.ForkOutcome, @error.AgentError] = Ok(
    agent.fork_session("p1", new_session_id="p1-child", at_message_index=1),
  ) catch {
    e => Err(e)
  }
  guard failed is Err(Session(_)) else {
    fail("expected Session error on fork write failure")
  }
  assert_false(store.store.contains("p1-child"))

  store.heal_save("p1-child")
  ignore(agent.run_turn(@test_support.tk_user_msg("continue"), "p1"))
  let recovered = store.load("p1-child") catch { e => fail("load: \{e}") }
  assert_eq(recovered.messages.length(), 1)
  assert_eq(recovered.messages[0], @test_support.tk_user_msg("one"))
  assert_eq(recovered.parent_fork_index(), Some(1))
}

///|
async test "command/fork_here_omitted_index_forks_at_tail_and_idle_fork_works" {
  let store = @test_support.RecordingSessionPort()
  store.seed("cmd-s", {
    messages: [
      @test_support.tk_user_msg("old-1"),
      @test_support.tk_user_msg("old-2"),
    ],
    metadata: Map::from_array([]),
  })
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("leaf", "leaf tool")],
    Map::from_array([("leaf", OutcomeOk(@test_support.tk_ok_result("ok")))]),
  )
  let model = TailForkModel::{
    calls: 0,
    on_first_chat: Ref(None),
    outcome: None,
  }
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="tools", tools=[tools]),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let missing_sid = invoke_agent_command(
    agent,
    "fork-here",
    Json::object(Map::from_array([])),
  )
  assert_true(missing_sid is Failure(..))

  // Idle fork with omitted index forks at full tail (2 messages).
  let idle_ok = invoke_agent_command(
    agent,
    "fork-here",
    Json::object(
      Map::from_array([
        ("session_id", Json::string("cmd-s")),
        ("new_session_id", Json::string("cmd-tail")),
      ]),
    ),
  )
  assert_true(idle_ok is Success(..))
  let forked = store.load("cmd-tail") catch { e => fail("load: \{e}") }
  assert_eq(forked.messages.length(), 2)
  assert_eq(forked.parent_fork_index(), Some(2))

  // Mid-turn fork-here with empty `{}` forks at current transcript tail (4 messages).
  model.on_first_chat.val = Some(async fn() {
    invoke_agent_command(agent, "fork-here", Json::object(Map::from_array([])))
  })
  ignore(agent.run_turn(@test_support.tk_user_msg("mid-turn"), "cmd-s"))
  assert_true(model.outcome is Some(Success(..)))
  let mut mid_child : String? = None
  for ev in observer.events() {
    match ev {
      SessionRedirect(from="cmd-s", to~, ..) if to != "cmd-tail" =>
        mid_child = Some(to)
      _ => ()
    }
  }
  guard mid_child is Some(child_id) else {
    fail("expected mid-turn SessionRedirect")
  }
  let mid_forked = store.load(child_id) catch { e => fail("load: \{e}") }
  assert_eq(mid_forked.messages.length(), 4)
  assert_eq(mid_forked.parent_fork_index(), Some(4))
}

///|
async test "rewind_session/live_agent_sees_rewound_history_truncates_store_and_appends" {
  let store = @test_support.RecordingSessionPort()
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("first-reply")),
    Respond(@test_support.tk_stop_response("second-reply")),
    Respond(@test_support.tk_stop_response("third-reply")),
  ])
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("hello"), "rw1"))
  ignore(agent.run_turn(@test_support.tk_user_msg("mistake"), "rw1"))

  let ops_before = store.ops().length()
  let rewound = agent.rewind_session("rw1", 2)
  assert_eq(rewound.session_id, "rw1")
  assert_eq(rewound.messages_before, 4)
  assert_eq(rewound.messages_after, 2)

  let mut saw_truncate = false
  let mut saw_save = false
  for op in store.ops()[ops_before:] {
    match op {
      OpTruncate(id="rw1", from_index=2, ..) => saw_truncate = true
      OpSave(id="rw1", ..) => saw_save = true
      _ => ()
    }
  }
  assert_true(saw_truncate)
  assert_false(saw_save)

  let mut saw_rewound_event = false
  let mut saw_finalized = false
  for ev in observer.events() {
    match ev {
      SessionRewound(session_id="rw1", messages_before=4, messages_after=2) =>
        saw_rewound_event = true
      OperationFinalized(operation="rewind", outcome="completed", ..) =>
        saw_finalized = true
      _ => ()
    }
  }
  assert_true(saw_rewound_event)
  assert_true(saw_finalized)

  guard agent.context_state("rw1") is Some(ctx_after) else {
    fail("expected context_state after partial rewind")
  }
  assert_eq(ctx_after.reading_message_count, 2)

  let ops_before_turn3 = store.ops().length()
  ignore(agent.run_turn(@test_support.tk_user_msg("retry"), "rw1"))
  let prompt3 = model.received_messages[2]
  assert_eq(prompt3.length(), 3)
  assert_eq(prompt3[0], @test_support.tk_user_msg("hello"))
  assert_eq(prompt3[2], @test_support.tk_user_msg("retry"))

  let mut turn3_saves = 0
  let mut turn3_checkpoints = 0
  for op in store.ops()[ops_before_turn3:] {
    match op {
      OpSave(id="rw1", ..) => turn3_saves = turn3_saves + 1
      OpCheckpoint(id="rw1", ..) => turn3_checkpoints = turn3_checkpoints + 1
      _ => ()
    }
  }
  assert_eq(turn3_saves, 0)
  assert_true(turn3_checkpoints >= 1)
}

///|
async test "rewind_session/to_zero_clears_title_context_and_rearms_memory_inbound" {
  let store = @test_support.RecordingSessionPort()
  let mem = MemoryProbe::{ inbound_calls: Ref(0), }
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("first")),
    Respond(@test_support.tk_stop_response("second")),
  ])
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store], memory=[mem]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("initial topic"), "rw-zero"))
  assert_eq(mem.inbound_calls.val, 1)
  let persisted_before = store.load("rw-zero") catch { e => fail("load: \{e}") }
  assert_eq(
    persisted_before.metadata.get(@types.SESSION_TITLE_METADATA_KEY),
    Some(Json::string("initial topic")),
  )

  let outcome = agent.rewind_session("rw-zero", 0)
  assert_eq(outcome.messages_after, 0)
  assert_true(agent.context_state("rw-zero") is None)
  let persisted_zero = store.load("rw-zero") catch { e => fail("load: \{e}") }
  assert_eq(persisted_zero.messages.length(), 0)
  assert_false(
    persisted_zero.metadata.contains(@types.SESSION_TITLE_METADATA_KEY),
  )
  assert_false(persisted_zero.metadata.contains("posoco.context_state"))

  ignore(agent.run_turn(@test_support.tk_user_msg("fresh topic"), "rw-zero"))
  assert_eq(mem.inbound_calls.val, 2)
  let persisted_after = store.load("rw-zero") catch { e => fail("load: \{e}") }
  assert_eq(
    persisted_after.metadata.get(@types.SESSION_TITLE_METADATA_KEY),
    Some(Json::string("fresh topic")),
  )
}

///|
async test "rewind_session/preserves_fork_lineage_and_recovers_after_store_failure" {
  let store = @test_support.RecordingSessionPort()
  store.seed("root", {
    messages: [@test_support.tk_user_msg("r1"), assistant_text("a1")],
    metadata: Map::from_array([]),
  })
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("child-extra")),
    Respond(@test_support.tk_stop_response("child-clean")),
  ])
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(
    agent.fork_session("root", new_session_id="child-rw", at_message_index=2),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("bad-step"), "child-rw"))
  store.fail_save("child-rw")
  let failed : Result[@types.RewindOutcome, @error.AgentError] = Ok(
    agent.rewind_session("child-rw", 2),
  ) catch {
    e => Err(e)
  }
  guard failed is Err(Session(Conflict(_))) else {
    fail("expected Session(Conflict) when rewind store write fails")
  }

  store.heal_save("child-rw")
  ignore(agent.run_turn(@test_support.tk_user_msg("good-step"), "child-rw"))
  let child_prompt = model.received_messages[1]
  assert_eq(child_prompt.length(), 3)
  assert_eq(child_prompt[0], @test_support.tk_user_msg("r1"))
  assert_eq(child_prompt[2], @test_support.tk_user_msg("good-step"))

  let persisted = store.load("child-rw") catch { e => fail("load: \{e}") }
  assert_eq(persisted.parent_thread_id(), Some("root"))
  assert_eq(persisted.parent_fork_index(), Some(2))
}

///|
async test "fork_and_rewind/reject_while_operation_is_active" {
  let gate_model = GateModel::{
    entered: @aqueue.Queue(kind=Unbounded),
    release: @aqueue.Queue(kind=Unbounded),
  }
  let store = @test_support.RecordingSessionPort()
  store.seed("busy-s", {
    messages: [@test_support.tk_user_msg("seed")],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(gate_model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  @async.with_task_group(async fn(group) {
    let running = group.spawn(() => {
      agent.run_turn(@test_support.tk_user_msg("hold"), "busy-s")
    })
    ignore(gate_model.entered.get())
    let fork_busy : Result[@types.ForkOutcome, @error.AgentError] = Ok(
      agent.fork_session("busy-s"),
    ) catch {
      e => Err(e)
    }
    let rewind_busy : Result[@types.RewindOutcome, @error.AgentError] = Ok(
      agent.rewind_session("busy-s", 0),
    ) catch {
      e => Err(e)
    }
    assert_true(fork_busy is Err(Busy(..)))
    assert_true(rewind_busy is Err(Busy(..)))
    gate_model.release.put(())
    ignore(running.wait())
  })
}
