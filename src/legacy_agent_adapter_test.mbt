///|
/// Blackbox tests for the M1-T10 legacy_agent_adapter (opt-in kernel facade).
///
/// These tests verify that `run_turn_via_kernel` produces a legacy
/// TurnResult for the simple happy path. They reuse the M0 testkit mocks.
async test "Facade: simple no-tool run returns TurnResult" {
  // Build a minimal Agent using M0 testkit mocks.
  let model = ScriptedModel::new([
    Respond(tk_stop_response("hello from kernel")),
  ])
  let tools = RecordingToolProvider::new([], Map::from_array([]))
  let store = RecordingSessionStore::new()
  let observer = RecordingObserver::new()
  let config = tk_config()
  let agent = Agent::new(
    model,
    tools=[tools],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let result = agent.run_turn_via_kernel(tk_user_msg("hi"), "sess_facade")
  // Sanity: a TurnResult came back.
  assert_eq(result.final_session_id, "sess_facade")
  // Observer should have seen at least TurnStarted + TurnCompleted.
  let events = observer.events()
  let has_started = events
    .iter()
    .any(fn(e) {
      match e {
        TurnStarted => true
        _ => false
      }
    })
  let has_completed = events
    .iter()
    .any(fn(e) {
      match e {
        TurnCompleted => true
        _ => false
      }
    })
  assert_true(has_started)
  assert_true(has_completed)
  let mut started_count = 0
  let mut completed_count = 0
  for event in events {
    match event {
      TurnStarted => started_count = started_count + 1
      TurnCompleted => completed_count = completed_count + 1
      _ => ()
    }
  }
  assert_eq(started_count, 1)
  assert_eq(completed_count, 1)
}

///|
async test "Facade: one-tool run executes the tool and returns TurnResult" {
  let model = ScriptedModel::new([
    Respond(tk_tool_call_response("greet", "call_1", Json::null())),
    Respond(tk_stop_response("done after tool")),
  ])
  let tools = RecordingToolProvider::new(
    [tk_tool_def("greet", "say hello")],
    Map::from_array([("greet", OutcomeOk(tk_ok_result("hi from tool")))]),
  )
  let store = RecordingSessionStore::new()
  let observer = RecordingObserver::new()
  let config = tk_config()
  let agent = Agent::new(
    model,
    tools=[tools],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let result = agent.run_turn_via_kernel(tk_user_msg("hi"), "sess_tool")
  assert_eq(result.final_session_id, "sess_tool")
  assert_eq(result.tool_results.length(), 1)
  assert_eq(result.tool_results[0].content, "hi from tool")
  // Tool should have been executed.
  let exec_records = tools.exec_records()
  assert_true(exec_records.length() >= 1)
  let mut tool_event_count = 0
  for event in observer.events() {
    match event {
      ToolCallResult(call~, ..) => {
        tool_event_count = tool_event_count + 1
        assert_eq(call.name, "greet")
        assert_eq(call.id, "call_1")
      }
      _ => ()
    }
  }
  assert_eq(tool_event_count, 1)
}

///|
async test "Facade: source-less providers resolve by tool name" {
  let model = ScriptedModel::new([
    Respond(tk_tool_call_response("second", "call_2", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  // Both providers use the legacy source-less owner fallback. The tool name
  // is the composition-unique identity and must select the right provider;
  // owner-first lookup would incorrectly select the last provider for both.
  let first = RecordingToolProvider::new(
    [tk_tool_def("first", "first tool")],
    Map::from_array([("first", OutcomeOk(tk_ok_result("from first")))]),
  )
  let second = RecordingToolProvider::new(
    [tk_tool_def("second", "second tool")],
    Map::from_array([("second", OutcomeOk(tk_ok_result("from second")))]),
  )
  let store = RecordingSessionStore::new()
  let config = tk_config()
  let agent = Agent::new(
    model,
    tools=[first, second],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let result = agent.run_turn_via_kernel(tk_user_msg("hi"), "sess_owner")
  assert_eq(result.tool_results.length(), 1)
  assert_eq(result.tool_results[0].content, "from second")
  assert_eq(second.exec_records().length(), 1)
  assert_eq(first.exec_records().length(), 0)
}
