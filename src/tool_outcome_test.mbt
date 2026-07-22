///|
/// M0-T06 regression tests: tool outcome consistency and collision fail-fast.
///
/// T06-A: the ToolCallResult event's is_error MUST equal the ToolResult's
///        is_error. The bug: agent hardcoded is_error=false for Ok(results).
/// T06-B: two providers registering the same tool name MUST fail composition
///        with CompositionError::ToolCollision, not last-wins.
fn outcome_config() -> AgentConfig {
  {
    max_tool_rounds: 10,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: None,
    model_context_window: None,
  }
}

///|
fn expected_tool_trace(
  first_response : @types.ModelResponse,
  call : @types.ToolCall,
  tool_result : @types.ToolResult,
  final_response : @types.ModelResponse,
) -> Array[@types.TurnEvent] {
  [
    @types.TurnEvent::TurnStarted,
    @types.TurnEvent::ModelResponseReceived(
      message=first_response.message,
      usage=first_response.usage,
      reasoning_content=first_response.reasoning_content,
    ),
    @types.TurnEvent::ToolCallPending(call),
    @types.TurnEvent::ToolCallResult(
      call~,
      result=tool_result,
      is_error=tool_result.is_error,
    ),
    @types.TurnEvent::ModelResponseReceived(
      message=final_response.message,
      usage=final_response.usage,
      reasoning_content=final_response.reasoning_content,
    ),
    @types.TurnEvent::TurnCompleted,
  ]
}

// ---------------------------------------------------------------------------
// T06-A regression 1: provider returns Ok(is_error=true) → event must match.
// ---------------------------------------------------------------------------

///|
async test "t06a_business_error_event_matches_result" {
  // Provider returns Ok(ToolResult { is_error: true }). The emitted
  // ToolCallResult event MUST have is_error=true (bug: was hardcoded false).
  let first_response = tk_tool_call_response("probe", "tc_1", Json::null())
  let final_response = tk_stop_response("after")
  let business_result = tk_error_result("denied")
  let model = ScriptedModel::new([
    Respond(first_response),
    Respond(final_response),
  ])
  let outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([
    ("probe", ScriptedToolOutcome::OutcomeOk(business_result)),
  ])
  let provider = RecordingToolProvider::new(
    [tk_tool_def("probe", "")],
    outcomes,
  )
  let obs = RecordingObserver::new()
  let store = RecordingSessionStore::new()
  let agent = Agent::new(
    model,
    tools=[provider],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs],
    sessions=[store],
    lifecycle=None,
    config=outcome_config(),
  )
  let turn_result = agent.run_turn(tk_user_msg("run probe"), "s1")
  // Find the ToolCallResult event for tc_1.
  let events = obs.events()
  assert_events_eq(
    expected_tool_trace(
      first_response,
      first_response.tool_calls[0],
      business_result,
      final_response,
    ),
    events,
  )
  let mut event_is_error : Bool? = None
  let mut event_result : @types.ToolResult? = None
  for e in events {
    match e {
      @types.TurnEvent::ToolCallResult(call~, result~, is_error~) =>
        if call.id == "tc_1" {
          // The event's is_error must equal the result's is_error.
          assert_true(is_error == result.is_error)
          event_is_error = Some(is_error)
          event_result = Some(result)
        }
      _ => ()
    }
  }
  match event_is_error {
    Some(v) => assert_true(v) // the result was is_error=true, so event must be too
    None => fail("expected a ToolCallResult event for tc_1")
  }
  assert_eq(turn_result.tool_results.length(), 1)
  match event_result {
    Some(observed) => assert_true(observed == turn_result.tool_results[0])
    None => fail("expected event result for tc_1")
  }
  // The exact same outcome semantics must be persisted in the tool message
  // that is fed into the next model round.
  match store.load("s1") {
    Ok(saved) => {
      let mut saw_matching_tool_message = false
      for message in saved.messages {
        match message {
          {
            role: @types.Tool,
            content: [@types.Text(content)],
            tool_call_id: Some(id),
            ..,
          } =>
            if id == "tc_1" {
              assert_eq(content, turn_result.tool_results[0].content)
              saw_matching_tool_message = true
            }
          _ => ()
        }
      }
      assert_true(saw_matching_tool_message)
    }
    Err(_) => fail("expected completed session to be loadable")
  }
}

// ---------------------------------------------------------------------------
// T06-A regression 2: success path — event is_error must be false (no flip).
// ---------------------------------------------------------------------------

///|
async test "t06a_success_event_is_not_error" {
  let first_response = tk_tool_call_response("safe", "tc_2", Json::null())
  let final_response = tk_stop_response("done")
  let success_result = tk_ok_result("ok")
  let model = ScriptedModel::new([
    Respond(first_response),
    Respond(final_response),
  ])
  let outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([
    ("safe", ScriptedToolOutcome::OutcomeOk(success_result)),
  ])
  let provider = RecordingToolProvider::new([tk_tool_def("safe", "")], outcomes)
  let obs = RecordingObserver::new()
  let store = RecordingSessionStore::new()
  let agent = Agent::new(
    model,
    tools=[provider],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs],
    sessions=[store],
    lifecycle=None,
    config=outcome_config(),
  )
  let turn_result = agent.run_turn(tk_user_msg("run safe"), "s1")
  let events = obs.events()
  assert_events_eq(
    expected_tool_trace(
      first_response,
      first_response.tool_calls[0],
      success_result,
      final_response,
    ),
    events,
  )
  assert_eq(turn_result.tool_results.length(), 1)
  assert_true(turn_result.tool_results[0] == success_result)
  for e in events {
    match e {
      @types.TurnEvent::ToolCallResult(call~, result~, is_error~) =>
        if call.id == "tc_2" {
          assert_true(is_error == result.is_error)
          assert_true(!is_error)
        }
      _ => ()
    }
  }
}

// ---------------------------------------------------------------------------
// T06-A regression 3: runtime raised error → event is_error=true, single value.
// ---------------------------------------------------------------------------

///|
async test "t06a_runtime_error_event_is_error_true" {
  let first_response = tk_tool_call_response("boom", "tc_3", Json::null())
  let final_response = tk_stop_response("after")
  let raised_error : @error.RuntimeError = @error.RuntimeError::InvocationFailed(
    "crash",
  )
  let error_result : @types.ToolResult = {
    content: raised_error.to_string(),
    structured: None,
    is_error: true,
  }
  let model = ScriptedModel::new([
    Respond(first_response),
    Respond(final_response),
  ])
  let outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([
    ("boom", ScriptedToolOutcome::OutcomeErr(raised_error)),
  ])
  let provider = RecordingToolProvider::new([tk_tool_def("boom", "")], outcomes)
  let obs = RecordingObserver::new()
  let store = RecordingSessionStore::new()
  let agent = Agent::new(
    model,
    tools=[provider],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs],
    sessions=[store],
    lifecycle=None,
    config=outcome_config(),
  )
  let result = agent.run_turn(tk_user_msg("run boom"), "s1")
  // The error must be non-fatal: turn completes, result fed to model.
  let events = obs.events()
  assert_events_eq(
    expected_tool_trace(
      first_response,
      first_response.tool_calls[0],
      error_result,
      final_response,
    ),
    events,
  )
  let mut seen_error_event = false
  for e in events {
    match e {
      @types.TurnEvent::ToolCallResult(call~, result~, is_error~) =>
        if call.id == "tc_3" {
          assert_true(is_error)
          assert_true(result.is_error)
          seen_error_event = true
        }
      _ => ()
    }
  }
  assert_true(seen_error_event)
  // The error result must appear in the turn's tool_results.
  assert_eq(result.tool_results.length(), 1)
  assert_true(result.tool_results[0] == error_result)
  // The same standardized runtime error content must be persisted in the
  // tool message that was fed into the second model round.
  match store.load("s1") {
    Ok(saved) => {
      let mut saw_matching_tool_message = false
      for message in saved.messages {
        match message {
          {
            role: @types.Tool,
            content: [@types.Text(content)],
            tool_call_id: Some(id),
            ..,
          } =>
            if id == "tc_3" {
              assert_eq(content, error_result.content)
              saw_matching_tool_message = true
            }
          _ => ()
        }
      }
      assert_true(saw_matching_tool_message)
    }
    Err(_) => fail("expected completed runtime-error session to be loadable")
  }
}

// ---------------------------------------------------------------------------
// T06-B regression: tool name collision fails composition (not last-wins).
// ---------------------------------------------------------------------------

///|
/// Provider that declares a single tool with a configurable source label.
struct SingleToolProvider {
  tool : @types.ToolDef
}

///|
pub impl @port.ToolProvider for SingleToolProvider with fn list_tools(self) {
  [self.tool]
}

///|
pub impl @port.ToolProvider for SingleToolProvider with fn execute(
  _self,
  name : String,
  _call : @types.ToolCall,
) -> @types.ToolResult raise @error.RuntimeError {
  raise @error.RuntimeError::UnknownTool(
    "SingleToolProvider does not execute '\{name}'",
  )
}

///|
async test "t06b_collision_fails_composition" {
  // Two providers register a tool named "shared". Agent::new MUST raise
  // CompositionError::ToolCollision (fail-fast), not silently pick the last.
  let p1 = RecordingToolProvider::new(
    [
      {
        name: "shared",
        description: "from p1",
        input_schema: Json::object(Map::from_array([])),
        metadata: None,
        source: Some("provider-alpha"),
      },
    ],
    Map::from_array([]),
  )
  let p2 = RecordingToolProvider::new(
    [
      {
        name: "shared",
        description: "from p2",
        input_schema: Json::object(Map::from_array([])),
        metadata: None,
        source: Some("provider-beta"),
      },
    ],
    Map::from_array([]),
  )
  let model = ScriptedModel::new([])
  let store = RecordingSessionStore::new()
  let composition_result = Ok(
    Agent::new(
      model,
      tools=[p1, p2],
      hooks=[],
      memory=[],
      compressors=[NoopCompressor::{  }],
      observers=[],
      sessions=[store],
      lifecycle=None,
      config=outcome_config(),
    ),
  ) catch {
    e => Err(e)
  }
  match composition_result {
    Err(@error.CompositionError::ToolCollision(name, msg)) => {
      assert_eq(name, "shared")
      // The message must identify both conflicting sources.
      assert_true(msg.contains("collision"))
      if !msg.contains("provider-alpha") {
        fail("missing provider-alpha provenance: \{msg}")
      }
      assert_true(msg.contains("provider-beta"))
      assert_eq(model.call_count(), 0)
      assert_eq(p1.exec_records().length(), 0)
      assert_eq(p2.exec_records().length(), 0)
    }
    _ => fail("expected CompositionError::ToolCollision for 'shared'")
  }
}

///|
async test "t06b_missing_collision_provenance_is_actionable" {
  let p1 = SingleToolProvider::{ tool: tk_tool_def("shared", "first") }
  let p2 = SingleToolProvider::{ tool: tk_tool_def("shared", "second") }
  let model = ScriptedModel::new([])
  let store = RecordingSessionStore::new()
  let composition_result = Ok(
    Agent::new(
      model,
      tools=[p1, p2],
      hooks=[],
      memory=[],
      compressors=[NoopCompressor::{  }],
      observers=[],
      sessions=[store],
      lifecycle=None,
      config=outcome_config(),
    ),
  ) catch {
    e => Err(e)
  }
  match composition_result {
    Err(@error.CompositionError::ToolCollision(name, msg)) => {
      assert_eq(name, "shared")
      assert_true(msg.contains("ToolDef.source"))
      assert_true(!msg.contains("provider["))
      assert_eq(model.call_count(), 0)
    }
    _ => fail("expected actionable provenance for collision")
  }
}
