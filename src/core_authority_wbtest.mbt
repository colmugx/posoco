///|
fn core_authority_has_session(agent : Agent, session_id : String) -> Bool {
  let read : Result[@types.Session, @core_facts.CoreReadError] = Ok(
    agent.runtime.core_facts.read_session(session_id),
  ) catch {
    error => Err(error)
  }
  read is Ok(_)
}

///|
fn core_authority_file_load_count(
  store : @test_support.RecordingSessionPort,
) -> Int32 {
  let mut count = 0
  for op in store.ops() {
    match op {
      @test_support.SessionOp::OpLoad(..) => count = count + 1
      _ => ()
    }
  }
  count
}

///|
async test "core_authority/failed_initial_load_is_not_cached" {
  let store = @test_support.RecordingSessionPort()
  store.seed("retry-load", {
    messages: [@test_support.tk_user_msg("seed")],
    metadata: Map::from_array([]),
  })
  store.fail_load("retry-load", Load("offline"))
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("first"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("next"),
    ),
  ])
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let failed : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(@test_support.tk_user_msg("one"), "retry-load"),
  ) catch {
    error => Err(error)
  }
  guard failed is Err(Session(_)) else {
    fail("expected the first store load to fail")
  }
  assert_eq(model.call_count(), 0)
  assert_false(core_authority_has_session(agent, "retry-load"))
  // Clearing the failure must let the SAME Agent retry initialization.
  store.load_failures.remove("retry-load")
  ignore(agent.run_turn(@test_support.tk_user_msg("one"), "retry-load"))
  assert_eq(core_authority_file_load_count(store), 2)
  assert_eq(model.call_count(), 1)
  assert_true(core_authority_has_session(agent, "retry-load"))
  // The initialized session now reads core; no third store load.
  ignore(agent.run_turn(@test_support.tk_user_msg("next"), "retry-load"))
  assert_eq(core_authority_file_load_count(store), 2)
  assert_eq(model.call_count(), 2)
  assert_eq(model.received_messages[1][0], @test_support.tk_user_msg("seed"))
}

///|
async test "core_authority/fresh_agent_recovers_child_with_only_parent_id" {
  let store = @test_support.RecordingSessionPort()
  store.seed("parentless-child", {
    messages: [@test_support.tk_user_msg("child-old")],
    metadata: Map::from_array([
      (@types.PARENT_THREAD_ID_KEY, Json::string("absent-parent")),
    ]),
  })
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("child-ok"),
    ),
  ])
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let result = agent.run_turn(
    @test_support.tk_user_msg("child-next"),
    "parentless-child",
  )
  assert_eq(result.final_session_id, "parentless-child")
  assert_eq(model.call_count(), 1)
  assert_eq(model.received_messages[0].length(), 2)
  assert_eq(
    model.received_messages[0][0],
    @test_support.tk_user_msg("child-old"),
  )
  assert_eq(
    model.received_messages[0][1],
    @test_support.tk_user_msg("child-next"),
  )
  let persisted = store.store["parentless-child"]
  assert_eq(persisted.messages.length(), 3)
  assert_eq(
    persisted.metadata.get(@types.PARENT_THREAD_ID_KEY),
    Some(Json::string("absent-parent")),
  )
  assert_false(core_authority_has_session(agent, "absent-parent"))
}

///|
async test "core_authority/two_store_seed_uses_first_then_full_aligns_both" {
  let first = @test_support.RecordingSessionPort()
  let second = @test_support.RecordingSessionPort()
  first.seed("align-two", {
    messages: [@test_support.tk_user_msg("a1"), @test_support.tk_user_msg("a2")],
    metadata: Map::from_array([]),
  })
  second.seed("align-two", {
    messages: [@test_support.tk_user_msg("stale")],
    metadata: Map::from_array([]),
  })
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("one"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("two"),
    ),
  ])
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[first, second]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("new-one"), "align-two"))
  assert_eq(core_authority_file_load_count(first), 1)
  assert_eq(core_authority_file_load_count(second), 0)
  // The first write is a full save of the complete core window, not an append
  // starting from the first store's old length.
  let first_ops = first.ops()
  let second_ops = second.ops()
  let first_write_is_save = fn(ops : Array[@test_support.SessionOp]) -> Bool {
    for op in ops {
      match op {
        @test_support.SessionOp::OpLoad(..) => ()
        @test_support.SessionOp::OpSave(id="align-two", ..) => return true
        _ => return false
      }
    }
    false
  }
  assert_true(first_write_is_save(first_ops))
  assert_true(first_write_is_save(second_ops))
  let first_saved = first.store["align-two"]
  let second_saved = second.store["align-two"]
  assert_eq(first_saved.messages.length(), 4)
  assert_eq(second_saved.messages.length(), 4)
  assert_true(first_saved.messages[0] == @test_support.tk_user_msg("a1"))
  assert_true(first_saved.messages[1] == @test_support.tk_user_msg("a2"))
  assert_true(second_saved.messages[0] == @test_support.tk_user_msg("a1"))
  // The next turn reads core and never reloads either store.
  ignore(agent.run_turn(@test_support.tk_user_msg("new-two"), "align-two"))
  assert_eq(core_authority_file_load_count(first), 1)
  assert_eq(core_authority_file_load_count(second), 0)
  assert_true(
    @core_facts.messages_equal(
      first.store["align-two"].messages,
      second.store["align-two"].messages,
    ),
  )
}

///|
async test "core_authority/real_terminal_mismatch_makes_core_unreadable" {
  let store = @test_support.RecordingSessionPort()
  store.seed("unreadable", {
    messages: [@test_support.tk_user_msg("stale-store")],
    metadata: Map::from_array([]),
  })
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("must-not-run"),
    ),
  ])
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  // Drive a real internal terminal-body mismatch, not an arbitrary flag.
  ignore(
    agent.runtime.core_facts.hydrate(
      "unreadable",
      [@test_support.tk_user_msg("old")],
      Map::from_array([]),
    ),
  )
  ignore(
    agent.runtime.core_facts.admit(
      "unreadable",
      [@test_support.tk_user_msg("old")],
      Map::from_array([]),
      [@test_support.tk_user_msg("old")],
      "run-unreadable",
    ),
  )
  agent.runtime.core_facts.record_boundary(
    "run-unreadable",
    "unreadable",
    1,
    "sp-unreadable",
    false,
    [
      @test_support.tk_user_msg("old"),
      AssistantMessage(
        content=[Text("committed")],
        tool_calls=[],
        reasoning=None,
        finish_reason=Stop,
      ),
    ],
  )
  ignore(
    agent.runtime.core_facts.record_terminal(
      "unreadable",
      "run-unreadable",
      [
        @test_support.tk_user_msg("old"),
        AssistantMessage(
          content=[Text("different")],
          tool_calls=[],
          reasoning=None,
          finish_reason=Stop,
        ),
      ],
      Map::from_array([]),
    ),
  )
  let loads_before = core_authority_file_load_count(store)
  let failed : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(@test_support.tk_user_msg("next"), "unreadable"),
  ) catch {
    error => Err(error)
  }
  guard failed is Err(Runtime(InvocationFailed(detail))) else {
    fail("expected the unreadable core to fail explicitly")
  }
  assert_true(detail.contains("unreadable"))
  assert_eq(model.call_count(), 0)
  assert_eq(core_authority_file_load_count(store), loads_before)
}

///|
struct NthSaveFailStore {
  inner : @test_support.RecordingSessionPort
  mut fail_at : Int32
  mut saves : Int32
}

///|
impl @port.SessionPort for NthSaveFailStore with fn load(self, id : String) -> @types.Session raise @error.SessionError {
  self.inner.load(id)
}

///|
impl @port.SessionPort for NthSaveFailStore with fn save(
  self,
  id : String,
  session : @types.Session,
) -> Unit raise @error.SessionError {
  self.saves = self.saves + 1
  if self.saves == self.fail_at {
    raise Save("terminal output failed")
  }
  self.inner.save(id, session)
}

///|
impl @port.SessionPort for NthSaveFailStore with fn checkpoint(
  self,
  id : String,
  checkpoint : @port.SessionCheckpoint,
) -> Unit raise @error.SessionError {
  self.inner.checkpoint(id, checkpoint)
}

///|
fn core_authority_task_marker_count(
  messages : Array[@kernel.Message],
  marker : String,
) -> Int32 {
  let mut count = 0
  for message in messages {
    if task_test_has_marker(
        { messages: [message], metadata: Map::from_array([]), },
        marker,
      ) {
      count = count + 1
    }
  }
  count
}

///|
async test "core_authority/task_outcome_and_applied_ids_fail_atomic_output_once" {
  let capture = TaskCapture::new()
  let store = NthSaveFailStore::{
    inner: @test_support.RecordingSessionPort(),
    fail_at: 2,
    saves: 0,
  }
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("first"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("retry"),
    ),
  ])
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
      @test_support.tk_ext(
        id="tasks",
        lifecycle=[capture as &@port.Lifecycle],
        requires=[@port.Capability::Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  agent.run_scoped(async fn(agent) {
    let handle = task_test_submit(capture, "task-output-fail", "task")
    let marker = "[posoco-task-outcome id=\{handle.receipt().id}]"
    ignore(handle.wait())
    let first : Result[@types.TurnResult, @error.AgentError] = Ok(
      agent.run_turn(@test_support.tk_user_msg("first"), "task-output-fail"),
    ) catch {
      error => Err(error)
    }
    guard first is Err(_) else { fail("expected terminal output failure") }
    let current = agent.runtime.core_facts.read_session("task-output-fail") catch {
      _ => fail("expected the committed core after terminal failure")
    }
    assert_eq(core_authority_task_marker_count(current.messages, marker), 1)
    match current.metadata.get("posoco.task.applied_ids") {
      Some(Json::Array(ids)) =>
        assert_true(ids.contains(Json::string(handle.receipt().id)))
      _ => fail("core is missing applied task ids")
    }
    store.fail_at = 0
    ignore(
      agent.run_turn(@test_support.tk_user_msg("retry"), "task-output-fail"),
    )
    let retry_prompt = model.received_messages[1]
    assert_eq(core_authority_task_marker_count(retry_prompt, marker), 1)
    let saved = store.inner.store["task-output-fail"]
    assert_eq(core_authority_task_marker_count(saved.messages, marker), 1)
    match saved.metadata.get("posoco.task.applied_ids") {
      Some(Json::Array(ids)) =>
        assert_true(ids.contains(Json::string(handle.receipt().id)))
      _ => fail("store is missing applied task ids")
    }
    assert_false(agent.runtime.task_runtime.has_inflight("task-output-fail"))
    assert_true(
      agent.runtime.task_runtime.peek_outcomes("task-output-fail").is_empty(),
    )
  })
}

///|
struct TerminalGateStore {
  inner : @test_support.RecordingSessionPort
  mut saves : Int32
  mut gated : Bool
  mut entered : Bool
  gate : @cond_var.Cond
}

///|
impl @port.SessionPort for TerminalGateStore with fn load(self, id : String) -> @types.Session raise @error.SessionError {
  self.inner.load(id)
}

///|
impl @port.SessionPort for TerminalGateStore with fn save(
  self,
  id : String,
  session : @types.Session,
) -> Unit raise @error.SessionError {
  self.saves = self.saves + 1
  if self.gated && self.saves == 2 {
    self.gated = false
    self.entered = true
    self.gate.broadcast()
    self.gate.wait()
  }
  self.inner.save(id, session)
}

///|
impl @port.SessionPort for TerminalGateStore with fn checkpoint(
  self,
  id : String,
  checkpoint : @port.SessionCheckpoint,
) -> Unit raise @error.SessionError {
  self.inner.checkpoint(id, checkpoint)
}

///|
async fn core_authority_wait_gate(store : TerminalGateStore) -> Unit {
  let waited : Unit = @async.with_timeout(60, async fn() {
    while !store.entered {
      @async.pause()
    }
  }) catch {
    _ => fail("terminal save gate did not enter")
  }
  ignore(waited)
}

///|
async test "core_authority/task_outcome_cancel_at_terminal_output_once" {
  let capture = TaskCapture::new()
  let store = TerminalGateStore::{
    inner: @test_support.RecordingSessionPort(),
    saves: 0,
    gated: true,
    entered: false,
    gate: @cond_var.Cond::Cond(),
  }
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("first"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("retry"),
    ),
  ])
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
      @test_support.tk_ext(
        id="tasks",
        lifecycle=[capture as &@port.Lifecycle],
        requires=[@port.Capability::Tasks],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  agent.run_scoped(async fn(agent) {
    let handle = task_test_submit(capture, "task-output-cancel", "task")
    let marker = "[posoco-task-outcome id=\{handle.receipt().id}]"
    ignore(handle.wait())
    @async.with_task_group(async fn(group) {
      let running = group.spawn(() => {
        let r : Result[@types.TurnResult, @error.AgentError] = Ok(
          agent.run_turn(
            @test_support.tk_user_msg("first"),
            "task-output-cancel",
          ),
        ) catch {
          error => Err(error)
        }
        r
      })
      core_authority_wait_gate(store)
      let current = agent.runtime.core_facts.read_session("task-output-cancel") catch {
        _ => fail("expected core outcome before terminal output")
      }
      assert_eq(core_authority_task_marker_count(current.messages, marker), 1)
      match current.metadata.get("posoco.task.applied_ids") {
        Some(Json::Array(ids)) =>
          assert_true(ids.contains(Json::string(handle.receipt().id)))
        _ => fail("core is missing applied task ids")
      }
      running.cancel()
      let waited : Result[Result[@types.TurnResult, @error.AgentError], Error] = Ok(
        running.wait(),
      ) catch {
        error => Err(error)
      }
      guard waited is Ok(Err(Cancelled("turn cancelled"))) else {
        fail("expected the real cancelled turn shape, got " + repr(waited))
      }
    })
    // Release any residual gate waiter, then retry on the same Agent.
    store.gate.broadcast()
    store.gated = false
    ignore(
      agent.run_turn(@test_support.tk_user_msg("retry"), "task-output-cancel"),
    )
    let retry_prompt = model.received_messages[1]
    assert_eq(core_authority_task_marker_count(retry_prompt, marker), 1)
    let saved = store.inner.store["task-output-cancel"]
    assert_eq(core_authority_task_marker_count(saved.messages, marker), 1)
    match saved.metadata.get("posoco.task.applied_ids") {
      Some(Json::Array(ids)) =>
        assert_true(ids.contains(Json::string(handle.receipt().id)))
      _ => fail("store is missing applied task ids")
    }
    assert_false(agent.runtime.task_runtime.has_inflight("task-output-cancel"))
    assert_true(
      agent.runtime.task_runtime.peek_outcomes("task-output-cancel").is_empty(),
    )
  })
}

///|
async test "core_authority/title_and_context_core_metadata_survive_second_turn" {
  let store = @test_support.RecordingSessionPort()
  let initial_context : @types.ContextState = {
    session_id: "title-context",
    model_id: "agent",
    context_version: 0,
    last_measured_tokens: Some(10),
    estimated_added_tokens: 0,
    window_tokens: Some(100),
    compact_threshold: 0.9,
    source: Measured,
    reading_message_count: 0,
  }
  store.seed("title-context", {
    messages: [],
    metadata: Map::from_array([
      (@types.CONTEXT_STATE_METADATA_KEY, initial_context.to_metadata_json()),
    ]),
  })
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("first"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("second"),
    ),
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
    agent.run_turn(@test_support.tk_user_msg("known title"), "title-context"),
  )
  let first = agent.runtime.core_facts.read_session("title-context") catch {
    _ => fail("expected core after first turn")
  }
  assert_eq(
    first.metadata.get(@types.SESSION_TITLE_METADATA_KEY),
    Some(Json::string("known title")),
  )
  guard @types.ContextState::from_metadata(first.metadata)
    is Some(first_context) else {
    fail("expected context metadata after first turn")
  }
  assert_eq(first_context.session_id, "title-context")
  assert_eq(first_context.model_id, "agent")
  assert_eq(first_context.window_tokens, Some(100))
  ignore(agent.run_turn(@test_support.tk_user_msg("second"), "title-context"))
  assert_eq(core_authority_file_load_count(store), 1)
  let second = agent.runtime.core_facts.read_session("title-context") catch {
    _ => fail("expected core after second turn")
  }
  assert_eq(
    second.metadata.get(@types.SESSION_TITLE_METADATA_KEY),
    Some(Json::string("known title")),
  )
  guard @types.ContextState::from_metadata(second.metadata)
    is Some(second_context) else {
    fail("expected context metadata after second turn")
  }
  assert_eq(second_context.session_id, "title-context")
  assert_eq(second_context.model_id, "agent")
  assert_eq(second_context.window_tokens, Some(100))
  let second_prompt = model.received_messages[1]
  assert_true(second_prompt.length() >= 3)
  assert_eq(second_prompt[0], @test_support.tk_user_msg("known title"))
}
