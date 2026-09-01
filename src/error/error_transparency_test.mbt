///|
/// M0-T07-core regression tests: error transparency in core paths.
///
/// T07-1: malformed streamed tool-call JSON must produce a typed
///        ModelError::ResponseParse, not silently become {}.
/// T07-2: terminal failure publishes exactly one terminal event
///        (TurnFailed OR TurnCompleted, never both).
fn err_config() -> @posoco.AgentConfig {
  {
    max_tool_rounds: Some(10),
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
    compact_threshold: None,
    system_prompt: None,
    memory_inbound_timeout_ms: None,
  }
}

// ---------------------------------------------------------------------------
// T07-1: StreamAccumulator malformed tool JSON → ModelError::ResponseParse.
// ---------------------------------------------------------------------------

///|
async test "t07_malformed_tool_json_raises_response_parse" {
  // A tool-call delta with invalid JSON arguments must NOT silently become {}.
  // It must raise ModelError::ResponseParse so the caller knows the stream
  // was malformed.
  let acc = @types.StreamAccumulator()
  // Push a tool-call delta with a name but malformed arguments JSON.
  acc.push(
    @types.StreamChunk::ToolCallDelta(
      index=0,
      id=Some("tc_1"),
      name=Some("broken"),
      arguments_delta=Some("{not json"),
    ),
  )
  let result : Result[@kernel.Completion, @error.ModelError] = Ok(
    acc.to_completion(),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@error.ModelError::ResponseParse(msg)) => {
      assert_true(msg.contains("malformed"))
      assert_true(!msg.contains("{not json"))
    }
    _ =>
      fail(
        "expected ModelError::ResponseParse for malformed tool JSON, got a response",
      )
  }
}

///|
async test "t07_incomplete_tool_call_is_loud" {
  let acc = @types.StreamAccumulator()
  acc.push(
    @types.StreamChunk::ToolCallDelta(
      index=0,
      id=Some("tc_incomplete"),
      name=None,
      arguments_delta=Some("{}"),
    ),
  )
  let result : Result[@kernel.Completion, @error.ModelError] = Ok(
    acc.to_completion(),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@error.ModelError::ResponseParse(msg)) => {
      assert_true(msg.contains("incomplete"))
      assert_true(msg.contains("name"))
    }
    _ => fail("expected incomplete tool call to raise ResponseParse")
  }
}

///|
async test "t07_tool_parse_error_omits_untrusted_identifiers_and_payload" {
  let raw_id = "id-line-one\nid-line-two-" + "i".repeat(100)
  let raw_name = "name-line-one\nname-line-two-" + "n".repeat(100)
  let raw_arguments = "{\"api_key\":\"RAW_TOOL_SECRET"
  let acc = @types.StreamAccumulator()
  acc.push(
    @types.StreamChunk::ToolCallDelta(
      index=0,
      id=Some(raw_id),
      name=Some(raw_name),
      arguments_delta=Some(raw_arguments),
    ),
  )
  let result : Result[@kernel.Completion, @error.ModelError] = Ok(
    acc.to_completion(),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@error.ModelError::ResponseParse(message)) => {
      assert_true(message.contains("index 0"))
      assert_true(!message.contains("id-line"))
      assert_true(!message.contains("name-line"))
      assert_true(!message.contains("RAW_TOOL_SECRET"))
      assert_true(!message.contains("\n"))
      assert_true(message.length() < 200)
    }
    _ => fail("expected malformed tool call to raise ResponseParse")
  }
}

// ---------------------------------------------------------------------------
// T07-1b: valid tool JSON still works (no false positive).
// ---------------------------------------------------------------------------

///|
async test "t07_valid_tool_json_still_parses" {
  let acc = @types.StreamAccumulator()
  acc.push(
    @types.StreamChunk::ToolCallDelta(
      index=0,
      id=Some("tc_1"),
      name=Some("ok"),
      arguments_delta=Some("{\"x\":1}"),
    ),
  )
  let resp = acc.to_completion()
  assert_eq(resp.message.tool_calls.length(), 1)
  assert_eq(resp.message.tool_calls[0].name.to_string(), "ok")
}

// ---------------------------------------------------------------------------
// T07-2: terminal failure emits exactly one terminal event.
// ---------------------------------------------------------------------------

///|
async test "t07_model_error_emits_turnfailed_not_turncompleted" {
  // When the model raises, the observer must see TurnFailed (from the model
  // error path) and MUST NOT see TurnCompleted.
  let model = @posoco.ScriptedModel([
    @posoco.Fail(@error.ModelError::Transport("network down")),
  ])
  let store = @posoco.RecordingSessionStore()
  let obs = @posoco.RecordingObserver()
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[store], observers=[obs]),
    ],
    config=err_config(),
  )
  let result = Ok(agent.run_turn(@posoco.tk_user_msg("hello"), "s1")) catch {
    e => Err(e)
  }
  // Must raise.
  match result {
    Err(@error.AgentError::Model(_)) => ()
    _ => fail("expected AgentError::Model")
  }
  let events = obs.events()
  let mut saw_failed = false
  let mut saw_completed = false
  for e in events {
    match e {
      TurnEvent::TurnFailed(_) => saw_failed = true
      TurnEvent::TurnCompleted => saw_completed = true
      _ => ()
    }
  }
  assert_true(saw_failed)
  assert_true(!saw_completed)
}

///|
async test "t07_rate_limited_model_surfaces_quota_scheduling_data" {
  // A provider quota verdict must reach the caller with its provider code,
  // reset time, and message intact — never collapsed to a generic failure.
  let model = @posoco.ScriptedModel([
    @posoco.Fail(
      @error.ModelError::RateLimited({
        message: "free quota exceeded",
        reset_at_ms: Some(1756400000000L),
        provider_code: Some("1308"),
      }),
    ),
  ])
  let store = @posoco.RecordingSessionStore()
  let obs = @posoco.RecordingObserver()
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[store], observers=[obs]),
    ],
    config=err_config(),
  )
  let result = Ok(agent.run_turn(@posoco.tk_user_msg("hello"), "s1")) catch {
    e => Err(e)
  }
  match result {
    Err(@error.AgentError::Model(msg)) => {
      assert_true(msg.contains("model quota exhausted"))
      assert_true(msg.contains("code=1308"))
      assert_true(msg.contains("reset_at_ms=1756400000000"))
      assert_true(msg.contains("message=free quota exceeded"))
    }
    _ => fail("expected AgentError::Model with quota scheduling data")
  }
  let events = obs.events()
  let mut saw_failed = false
  for e in events {
    match e {
      TurnEvent::TurnFailed(_) => saw_failed = true
      _ => ()
    }
  }
  assert_true(saw_failed)
}

///|
fn count_terminal_events(events : Array[TurnEvent]) -> Int {
  let mut count = 0
  for event in events {
    match event {
      TurnFailed(_) | TurnCompleted => count = count + 1
      _ => ()
    }
  }
  count
}

///|
async test "t07_save_error_emits_exactly_one_turnfailed" {
  let model = @posoco.ScriptedModel([
    @posoco.Respond(@posoco.tk_stop_response("done")),
  ])
  let store = @posoco.RecordingSessionStore()
  store.fail_save("save-fail")
  let obs = @posoco.RecordingObserver()
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[store], observers=[obs]),
    ],
    config=err_config(),
  )
  let result = Ok(agent.run_turn(@posoco.tk_user_msg("hello"), "save-fail")) catch {
    e => Err(e)
  }
  match result {
    Err(@error.AgentError::Session(_)) => ()
    _ => fail("expected session save failure")
  }
  let events = obs.events()
  assert_eq(count_terminal_events(events), 1)
  assert_true(events.iter().any(fn(event) { event is TurnFailed(_) }))
}

///|
async test "t07_load_error_emits_one_safe_turnfailed" {
  let model = @posoco.ScriptedModel([])
  let store = @posoco.RecordingSessionStore()
  store.fail_load("load-fail", Load("backend detail must stay with caller"))
  let obs = @posoco.RecordingObserver()
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[store], observers=[obs]),
    ],
    config=err_config(),
  )
  let result = Ok(
    agent.run_turn(@posoco.tk_user_msg("private prompt"), "load-fail"),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(@error.AgentError::Session(error)) =>
      assert_true(error.to_string().contains("backend detail"))
    _ => fail("expected session load failure")
  }
  let events = obs.events()
  assert_eq(count_terminal_events(events), 1)
  for event in events {
    match event {
      TurnFailed(reason) => {
        assert_true(reason.contains("AgentError::Session"))
        assert_true(!reason.contains("backend detail"))
        assert_true(!reason.contains("private prompt"))
      }
      _ => ()
    }
  }
}

///|
async test "t07_afterturn_hook_failure_is_observable_but_nonfatal" {
  // In the Puppet path, PostEventHook is non-failable (returns Unit without
  // raise). PipelineHook abort scenarios are now handled through PreModelHook.
  // This test verifies that a PreModelHook abort still emits exactly one
  // terminal event (TurnFailed).
  let model = @posoco.ScriptedModel([
    @posoco.Respond(@posoco.tk_stop_response("done")),
  ])
  let store = @posoco.RecordingSessionStore()
  let obs = @posoco.RecordingObserver()
  let hook = @posoco.RecordingHook()
  hook.abort_when("before_model", "hook blocked the model call")
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", hooks=[hook], sessions=[store], observers=[obs]),
    ],
    config=err_config(),
  )
  let result = Ok(
    agent.run_turn(@posoco.tk_user_msg("hello"), "hook-secondary"),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@error.AgentError::PipelineAborted(_)) => ()
    _ =>
      fail(
        "expected hook abort (non-fatal PostEventHook modeled via PreModelHook)",
      )
  }
  let events = obs.events()
  assert_eq(count_terminal_events(events), 1)
}

///|
async test "t07_error_hook_failure_preserves_primary_and_is_observable" {
  // Puppet path: PreModelHook can abort before the model is called. When the
  // model would have failed but the hook aborts first, the primary error is
  // the PipelineAborted (not the model error). This test verifies the abort is
  // observable as PipelineAborted.
  let model = @posoco.ScriptedModel([
    @posoco.Fail(@error.ModelError::Transport("primary network failure")),
  ])
  let store = @posoco.RecordingSessionStore()
  let obs = @posoco.RecordingObserver()
  let hook = @posoco.RecordingHook()
  hook.abort_when("before_model", "hook aborted before model call")
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", hooks=[hook], sessions=[store], observers=[obs]),
    ],
    config=err_config(),
  )
  let result = Ok(agent.run_turn(@posoco.tk_user_msg("hello"), "primary-error")) catch {
    e => Err(e)
  }
  match result {
    Err(@error.AgentError::PipelineAborted(_)) => ()
    _ => fail("expected PipelineAborted (PreModelHook fires before model call)")
  }
  let events = obs.events()
  assert_eq(count_terminal_events(events), 1)
}

///|
async test "t07_turnerror_hook_failure_preserves_primary_and_is_observable" {
  let model = @posoco.ScriptedModel([
    @posoco.Fail(@error.ModelError::Transport("primary network failure")),
  ])
  let store = @posoco.RecordingSessionStore()
  let obs = @posoco.RecordingObserver()
  let hook = @posoco.RecordingHook()
  hook.abort_when("before_model", "hook aborted before model call")
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", hooks=[hook], sessions=[store], observers=[obs]),
    ],
    config=err_config(),
  )
  let result = Ok(agent.run_turn(@posoco.tk_user_msg("hello"), "turnerror")) catch {
    e => Err(e)
  }
  match result {
    Err(@error.AgentError::PipelineAborted(_)) => ()
    _ => fail("expected PipelineAborted")
  }
  let events = obs.events()
  assert_eq(count_terminal_events(events), 1)
}

///|
async test "t07_aftertool_hook_failure_is_observable_but_nonfatal" {
  // Puppet path: tool execution is followed by PreModelHook in the next
  // pump iteration. A pre_model_hook abort before the second model call
  // surfaces as PipelineAborted.
  let model = @posoco.ScriptedModel([
    @posoco.Respond(
      @posoco.tk_tool_call_response("probe", "tc_secondary", Json::null()),
    ),
    @posoco.Respond(@posoco.tk_stop_response("done")),
  ])
  let provider = @posoco.RecordingToolProvider(
    [@posoco.tk_tool_def("probe", "")],
    Map::from_array([
      (
        "probe",
        @posoco.ScriptedToolOutcome::OutcomeOk(@posoco.tk_ok_result("ok")),
      ),
    ]),
  )
  let store = @posoco.RecordingSessionStore()
  let obs = @posoco.RecordingObserver()
  let hook = @posoco.RecordingHook()
  hook.abort_when("before_model", "hook blocked after tool execution")
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(
        id="io",
        tools=[provider],
        hooks=[hook],
        sessions=[store],
        observers=[obs],
      ),
    ],
    config=err_config(),
  )
  let result = Ok(agent.run_turn(@posoco.tk_user_msg("run"), "aftertool")) catch {
    e => Err(e)
  }
  match result {
    Err(@error.AgentError::PipelineAborted(_)) => ()
    _ => fail("expected PipelineAborted")
  }
  let events = obs.events()
  assert_eq(count_terminal_events(events), 1)
}

///|
async test "t07_beforemodel_abort_emits_exactly_one_turnfailed" {
  let model = @posoco.ScriptedModel([])
  let store = @posoco.RecordingSessionStore()
  let obs = @posoco.RecordingObserver()
  let hook = @posoco.RecordingHook()
  hook.abort_when("before_model", "policy rejected model call")
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", hooks=[hook], sessions=[store], observers=[obs]),
    ],
    config=err_config(),
  )
  let result = Ok(
    agent.run_turn(@posoco.tk_user_msg("private prompt"), "hook-abort"),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@error.AgentError::PipelineAborted(_)) => ()
    _ => fail("expected BeforeModel hook abort")
  }
  let events = obs.events()
  assert_eq(count_terminal_events(events), 1)
  for event in events {
    match event {
      TurnFailed(reason) => {
        assert_true(reason.contains("AgentError::PipelineAborted"))
        assert_true(!reason.contains("private prompt"))
      }
      _ => ()
    }
  }
  assert_eq(model.call_count(), 0)
}

///|
async test "t07_premodel_abort_emits_turnstarted_and_one_terminal_event" {
  let model = @posoco.ScriptedModel([])
  let store = @posoco.RecordingSessionStore()
  let obs = @posoco.RecordingObserver()
  let hook = @posoco.RecordingHook()
  hook.abort_when("before_model", "turn rejected before start")
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", hooks=[hook], sessions=[store], observers=[obs]),
    ],
    config=err_config(),
  )
  let result = Ok(
    agent.run_turn(@posoco.tk_user_msg("hello"), "premodel_abort"),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@error.AgentError::PipelineAborted(_)) => ()
    _ => fail("expected PreModelHook abort")
  }
  let events = obs.events()
  // TurnStarted IS emitted by run_turn before the Puppet starts.
  assert_true(events.iter().any(fn(event) { event is TurnStarted }))
  assert_eq(count_terminal_events(events), 1)
  assert_eq(model.call_count(), 0)
}

///|
async test "t07_tool_loop_emits_exactly_one_turnfailed" {
  let model = @posoco.ScriptedModel([
    @posoco.Respond(
      @posoco.tk_tool_call_response("probe", "tc_loop", Json::null()),
    ),
  ])
  let provider = @posoco.RecordingToolProvider(
    [@posoco.tk_tool_def("probe", "")],
    Map::from_array([
      (
        "probe",
        @posoco.ScriptedToolOutcome::OutcomeOk(@posoco.tk_ok_result("ok")),
      ),
    ]),
  )
  let store = @posoco.RecordingSessionStore()
  let obs = @posoco.RecordingObserver()
  let config : AgentConfig = {
    max_tool_rounds: Some(0),
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
    compact_threshold: None,
    system_prompt: None,
    memory_inbound_timeout_ms: None,
  }
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", tools=[provider], sessions=[store], observers=[
        obs,
      ]),
    ],
    config~,
  )
  let result = Ok(agent.run_turn(@posoco.tk_user_msg("loop"), "tool-loop")) catch {
    e => Err(e)
  }
  match result {
    Err(@error.AgentError::ToolLoopExceeded(..)) => ()
    _ => fail("expected tool loop failure")
  }
  assert_eq(count_terminal_events(obs.events()), 1)
}
