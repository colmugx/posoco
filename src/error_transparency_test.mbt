///|
/// M0-T07-core regression tests: error transparency in core paths.
///
/// T07-1: malformed streamed tool-call JSON must produce a typed
///        ModelError::ResponseParse, not silently become {}.
/// T07-2: terminal failure publishes exactly one terminal event
///        (TurnFailed OR TurnCompleted, never both).
fn err_config() -> AgentConfig {
  {
    max_tool_rounds: 10,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: None,
    model_context_window: None,
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
  let acc = StreamAccumulator::new()
  // Push a tool-call delta with a name but malformed arguments JSON.
  acc.push(
    ToolCallDelta(
      index=0,
      id=Some("tc_1"),
      name=Some("broken"),
      arguments_delta=Some("{not json"),
    ),
  )
  let result : Result[ModelResponse, ModelError] = Ok(acc.to_response()) catch {
    e => Err(e)
  }
  match result {
    Err(ResponseParse(msg)) => {
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
  let acc = StreamAccumulator::new()
  acc.push(
    ToolCallDelta(
      index=0,
      id=Some("tc_incomplete"),
      name=None,
      arguments_delta=Some("{}"),
    ),
  )
  let result : Result[ModelResponse, ModelError] = Ok(acc.to_response()) catch {
    e => Err(e)
  }
  match result {
    Err(ResponseParse(msg)) => {
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
  let acc = StreamAccumulator::new()
  acc.push(
    ToolCallDelta(
      index=0,
      id=Some(raw_id),
      name=Some(raw_name),
      arguments_delta=Some(raw_arguments),
    ),
  )
  let result : Result[ModelResponse, ModelError] = Ok(acc.to_response()) catch {
    error => Err(error)
  }
  match result {
    Err(ResponseParse(message)) => {
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
  let acc = StreamAccumulator::new()
  acc.push(
    ToolCallDelta(
      index=0,
      id=Some("tc_1"),
      name=Some("ok"),
      arguments_delta=Some("{\"x\":1}"),
    ),
  )
  let resp = acc.to_response()
  assert_eq(resp.tool_calls.length(), 1)
  assert_eq(resp.tool_calls[0].name, "ok")
}

// ---------------------------------------------------------------------------
// T07-2: terminal failure emits exactly one terminal event.
// ---------------------------------------------------------------------------

///|
async test "t07_model_error_emits_turnfailed_not_turncompleted" {
  // When the model raises, the observer must see TurnFailed (from the model
  // error path) and MUST NOT see TurnCompleted.
  let model = ScriptedModel::new([Fail(Transport("network down"))])
  let store = RecordingSessionStore::new()
  let obs = RecordingObserver::new()
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs],
    sessions=[store],
    lifecycle=None,
    config=err_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("hello"), "s1")) catch {
    e => Err(e)
  }
  // Must raise.
  match result {
    Err(Model(_)) => ()
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
fn has_secondary_failure(
  events : Array[TurnEvent],
  expected_stage : String,
) -> Bool {
  events
  .iter()
  .any(fn(event) {
    match event {
      Custom(
        source="posoco.core",
        label="secondary_failure",
        data=Json::Object(fields)
      ) =>
        fields.contains("stage") &&
        fields["stage"] == Json::string(expected_stage) &&
        fields.contains("operation") &&
        fields.contains("error_category") &&
        !fields.contains("message")
      _ => false
    }
  })
}

///|
async test "t07_save_error_emits_exactly_one_turnfailed" {
  let model = ScriptedModel::new([Respond(tk_stop_response("done"))])
  let store = RecordingSessionStore::new()
  store.fail_save("save-fail")
  let obs = RecordingObserver::new()
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs],
    sessions=[store],
    lifecycle=None,
    config=err_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("hello"), "save-fail")) catch {
    e => Err(e)
  }
  match result {
    Err(Session(_)) => ()
    _ => fail("expected session save failure")
  }
  let events = obs.events()
  assert_eq(count_terminal_events(events), 1)
  assert_true(events.iter().any(fn(event) { event is TurnFailed(_) }))
}

///|
async test "t07_load_error_emits_one_safe_turnfailed" {
  let model = ScriptedModel::new([])
  let store = RecordingSessionStore::new()
  store.fail_load("load-fail", Load("backend detail must stay with caller"))
  let obs = RecordingObserver::new()
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs],
    sessions=[store],
    lifecycle=None,
    config=err_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("private prompt"), "load-fail")) catch {
    error => Err(error)
  }
  match result {
    Err(Session(error)) =>
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
  let model = ScriptedModel::new([Respond(tk_stop_response("done"))])
  let store = RecordingSessionStore::new()
  let obs = RecordingObserver::new()
  let hook = RecordingHook::new()
  hook.abort_when("AfterTurn", "after-turn cleanup failed")
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[hook],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs],
    sessions=[store],
    lifecycle=None,
    config=err_config(),
  )
  let _ = agent.run_turn(tk_user_msg("hello"), "hook-secondary")
  let events = obs.events()
  assert_eq(count_terminal_events(events), 1)
  assert_true(has_secondary_failure(events, "AfterTurn"))
}

///|
async test "t07_error_hook_failure_preserves_primary_and_is_observable" {
  let model = ScriptedModel::new([Fail(Transport("primary network failure"))])
  let store = RecordingSessionStore::new()
  let obs = RecordingObserver::new()
  let hook = RecordingHook::new()
  hook.abort_when("ModelError", "secondary model-error hook failure")
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[hook],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs],
    sessions=[store],
    lifecycle=None,
    config=err_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("hello"), "primary-error")) catch {
    e => Err(e)
  }
  match result {
    Err(Model(msg)) => assert_true(msg.contains("primary network failure"))
    _ => fail("expected primary model error to survive secondary hook error")
  }
  let events = obs.events()
  assert_eq(count_terminal_events(events), 1)
  assert_true(has_secondary_failure(events, "ModelError"))
}

///|
async test "t07_turnerror_hook_failure_preserves_primary_and_is_observable" {
  let model = ScriptedModel::new([Fail(Transport("primary network failure"))])
  let store = RecordingSessionStore::new()
  let obs = RecordingObserver::new()
  let hook = RecordingHook::new()
  hook.abort_when("TurnError", "secondary turn-error hook failure")
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[hook],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs],
    sessions=[store],
    lifecycle=None,
    config=err_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("hello"), "turnerror")) catch {
    e => Err(e)
  }
  match result {
    Err(Model(msg)) => assert_true(msg.contains("primary network failure"))
    _ => fail("expected primary model error to survive TurnError hook error")
  }
  let events = obs.events()
  assert_eq(count_terminal_events(events), 1)
  assert_true(has_secondary_failure(events, "TurnError"))
}

///|
async test "t07_aftertool_hook_failure_is_observable_but_nonfatal" {
  let model = ScriptedModel::new([
    Respond(tk_tool_call_response("probe", "tc_secondary", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let provider = RecordingToolProvider::new(
    [tk_tool_def("probe", "")],
    Map::from_array([
      ("probe", ScriptedToolOutcome::OutcomeOk(tk_ok_result("ok"))),
    ]),
  )
  let store = RecordingSessionStore::new()
  let obs = RecordingObserver::new()
  let hook = RecordingHook::new()
  hook.abort_when("AfterTool", "secondary after-tool hook failure")
  let agent = Agent::new(
    model,
    tools=[provider],
    hooks=[hook],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs],
    sessions=[store],
    lifecycle=None,
    config=err_config(),
  )
  let result = agent.run_turn(tk_user_msg("run"), "aftertool")
  assert_eq(result.tool_results.length(), 1)
  assert_true(!result.tool_results[0].is_error)
  let events = obs.events()
  assert_eq(count_terminal_events(events), 1)
  assert_true(has_secondary_failure(events, "AfterTool"))
}

///|
async test "t07_beforemodel_abort_emits_exactly_one_turnfailed" {
  let model = ScriptedModel::new([])
  let store = RecordingSessionStore::new()
  let obs = RecordingObserver::new()
  let hook = RecordingHook::new()
  hook.abort_when("BeforeModel", "policy rejected model call")
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[hook],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs],
    sessions=[store],
    lifecycle=None,
    config=err_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("private prompt"), "hook-abort")) catch {
    e => Err(e)
  }
  match result {
    Err(HookAborted(_)) => ()
    _ => fail("expected BeforeModel hook abort")
  }
  let events = obs.events()
  assert_eq(count_terminal_events(events), 1)
  for event in events {
    match event {
      TurnFailed(reason) => {
        assert_true(reason.contains("AgentError::HookAborted"))
        assert_true(!reason.contains("private prompt"))
      }
      _ => ()
    }
  }
  assert_eq(model.call_count(), 0)
}

///|
async test "t07_beforeturn_abort_does_not_start_or_terminalize_turn" {
  let model = ScriptedModel::new([])
  let store = RecordingSessionStore::new()
  let obs = RecordingObserver::new()
  let hook = RecordingHook::new()
  hook.abort_when("BeforeTurn", "turn rejected before start")
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[hook],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs],
    sessions=[store],
    lifecycle=None,
    config=err_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("hello"), "beforeturn")) catch {
    e => Err(e)
  }
  match result {
    Err(HookAborted(_)) => ()
    _ => fail("expected BeforeTurn hook abort")
  }
  let events = obs.events()
  assert_true(!events.iter().any(fn(event) { event is TurnStarted }))
  assert_eq(count_terminal_events(events), 0)
  assert_eq(model.call_count(), 0)
}

///|
async test "t07_tool_loop_emits_exactly_one_turnfailed" {
  let model = ScriptedModel::new([
    Respond(tk_tool_call_response("probe", "tc_loop", Json::null())),
  ])
  let provider = RecordingToolProvider::new(
    [tk_tool_def("probe", "")],
    Map::from_array([
      ("probe", ScriptedToolOutcome::OutcomeOk(tk_ok_result("ok"))),
    ]),
  )
  let store = RecordingSessionStore::new()
  let obs = RecordingObserver::new()
  let config : AgentConfig = {
    max_tool_rounds: 0,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: None,
    model_context_window: None,
  }
  let agent = Agent::new(
    model,
    tools=[provider],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let result = Ok(agent.run_turn(tk_user_msg("loop"), "tool-loop")) catch {
    e => Err(e)
  }
  match result {
    Err(ToolLoopExceeded) => ()
    _ => fail("expected tool loop failure")
  }
  assert_eq(count_terminal_events(obs.events()), 1)
}

///|
struct FailingLifecycle {}

///|
pub impl Lifecycle for FailingLifecycle with fn on_shutdown(_self) -> Unit {
  abort("shutdown cleanup failed")
}

///|
async test "panic t07_shutdown_failure_is_not_swallowed" {
  let model = ScriptedModel::new([])
  let store = RecordingSessionStore::new()
  let lifecycle = FailingLifecycle::{  }
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[],
    sessions=[store],
    lifecycle=Some(lifecycle),
    config=err_config(),
  )
  agent.shutdown()
}
