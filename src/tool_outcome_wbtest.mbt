///|
/// M0-T06 regression tests: tool outcome consistency and collision fail-fast.
///
/// T06-A: the ToolCallResult event's is_error MUST equal the ToolOutcome's
///        `is_failure` (bug historically: agent hardcoded is_error=false for
///        Ok(results)). R3 M3.7: ToolResult → ToolOutcome (ADT).
/// T06-B: two providers registering the same tool name MUST fail composition
///        with CompositionError::ToolCollision, not last-wins.
fn outcome_config() -> AgentConfig {
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

///|
/// Extract the underlying text content from a ToolOutcome. Used by tests
/// that need to compare error/success message bodies regardless of variant.
fn outcome_text(outcome : @kernel.ToolOutcome) -> String {
  match outcome {
    @kernel.Success(content~, ..) => content
    @kernel.ToolReportedError(content~, ..) => content
    @kernel.RuntimeFailure(message~, ..) => message
    @kernel.NotExecuted(reason~, ..) => reason.to_string()
  }
}

// ---------------------------------------------------------------------------
// T06-A regression 1: provider returns business-error outcome → event
// is_error must be true.
// ---------------------------------------------------------------------------

///|
async test "t06a_business_error_event_matches_result" {
  // Provider returns Ok(ToolReportedError). The emitted ToolCallResult event
  // MUST have is_error=true.
  let first_response = tk_tool_call_response("probe", "tc_1", Json::null())
  let final_response = tk_stop_response("after")
  let business_result = tk_error_result("denied")
  let model = ScriptedModel([Respond(first_response), Respond(final_response)])
  let outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([
    ("probe", ScriptedToolOutcome::OutcomeOk(business_result)),
  ])
  let provider = RecordingToolProvider([tk_tool_def("probe", "")], outcomes)
  let obs = RecordingObserver()
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[provider], sessions=[store], observers=[obs]),
    ],
    config=outcome_config(),
  )
  let turn_result = agent.run_turn(tk_user_msg("run probe"), "s1")
  let events = obs.events()
  // Find the ToolCallResult event for tc_1.
  let mut event_is_error : Bool? = None
  let mut event_result : @kernel.ToolOutcome? = None
  for e in events {
    match e {
      @types.TurnEvent::ToolCallResult(call~, result~, is_error~) =>
        if call.call_id.to_string() == "tc_1" {
          assert_true(is_error == result.is_failure())
          event_is_error = Some(is_error)
          event_result = Some(result)
        }
      _ => ()
    }
  }
  match event_is_error {
    Some(v) => assert_true(v) // ToolReportedError → is_failure=true
    None => fail("expected a ToolCallResult event for tc_1")
  }
  assert_eq(turn_result.tool_results.length(), 1)
  match event_result {
    Some(observed) => assert_true(observed == turn_result.tool_results[0])
    None => fail("expected event result for tc_1")
  }
  // The same outcome semantics must be persisted in the tool message
  // that is fed into the next model round.
  try {
    let saved = store.load("s1")
    let mut saw_matching_tool_message = false
    for message in saved.messages {
      match message {
        @kernel.ToolMessage(call_id~, outcome~, ..) =>
          if call_id.to_string() == "tc_1" {
            assert_eq(
              outcome_text(outcome),
              outcome_text(turn_result.tool_results[0]),
            )
            saw_matching_tool_message = true
          }
        _ => ()
      }
    }
    assert_true(saw_matching_tool_message)
  } catch {
    _ => fail("expected completed session to be loadable")
  }
}

// ---------------------------------------------------------------------------
// T06-A regression 2: success path — event is_error must be false.
// ---------------------------------------------------------------------------

///|
async test "t06a_success_event_is_not_error" {
  let first_response = tk_tool_call_response("safe", "tc_2", Json::null())
  let final_response = tk_stop_response("done")
  let success_result = tk_ok_result("ok")
  let model = ScriptedModel([Respond(first_response), Respond(final_response)])
  let outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([
    ("safe", ScriptedToolOutcome::OutcomeOk(success_result)),
  ])
  let provider = RecordingToolProvider([tk_tool_def("safe", "")], outcomes)
  let obs = RecordingObserver()
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[provider], sessions=[store], observers=[obs]),
    ],
    config=outcome_config(),
  )
  let turn_result = agent.run_turn(tk_user_msg("run safe"), "s1")
  let events = obs.events()
  assert_eq(turn_result.tool_results.length(), 1)
  assert_true(turn_result.tool_results[0] == success_result)
  for e in events {
    match e {
      @types.TurnEvent::ToolCallResult(call~, result~, is_error~) =>
        if call.call_id.to_string() == "tc_2" {
          assert_true(is_error == result.is_failure())
          assert_true(!is_error)
        }
      _ => ()
    }
  }
}

// ---------------------------------------------------------------------------
// T06-A regression 3: runtime raised error → event is_error=true.
// ---------------------------------------------------------------------------

///|
async test "t06a_runtime_error_event_is_error_true" {
  let first_response = tk_tool_call_response("boom", "tc_3", Json::null())
  let final_response = tk_stop_response("after")
  let raised_error : @error.RuntimeError = @error.RuntimeError::InvocationFailed(
    "crash",
  )
  let model = ScriptedModel([Respond(first_response), Respond(final_response)])
  let outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([
    ("boom", ScriptedToolOutcome::OutcomeErr(raised_error)),
  ])
  let provider = RecordingToolProvider([tk_tool_def("boom", "")], outcomes)
  let obs = RecordingObserver()
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[provider], sessions=[store], observers=[obs]),
    ],
    config=outcome_config(),
  )
  let result = agent.run_turn(tk_user_msg("run boom"), "s1")
  let events = obs.events()
  let mut seen_error_event = false
  for e in events {
    match e {
      @types.TurnEvent::ToolCallResult(call~, result~, is_error~) =>
        if call.call_id.to_string() == "tc_3" {
          assert_true(is_error)
          assert_true(result.is_failure())
          seen_error_event = true
        }
      _ => ()
    }
  }
  assert_true(seen_error_event)
  // The runtime-failure outcome must appear in turn tool_results.
  assert_eq(result.tool_results.length(), 1)
  assert_true(result.tool_results[0].is_failure())
  // The same standardized runtime error content must be persisted in the
  // tool message that was fed into the second model round.
  try {
    let saved = store.load("s1")
    let expected_text = outcome_text(result.tool_results[0])
    let mut saw_matching_tool_message = false
    for message in saved.messages {
      match message {
        @kernel.ToolMessage(call_id~, outcome~, ..) =>
          if call_id.to_string() == "tc_3" {
            assert_eq(outcome_text(outcome), expected_text)
            saw_matching_tool_message = true
          }
        _ => ()
      }
    }
    assert_true(saw_matching_tool_message)
  } catch {
    _ => fail("expected completed runtime-error session to be loadable")
  }
}

// ---------------------------------------------------------------------------
// T06-B regression: tool name collision fails composition (not last-wins).
// ---------------------------------------------------------------------------

///|
/// Provider that declares a single tool with a configurable provenance.
struct SingleToolProvider {
  tool : @kernel.ToolDef
}

///|
pub impl @port.ToolProvider for SingleToolProvider with fn list_tools(self) {
  [self.tool]
}

///|
pub impl @port.ToolProvider for SingleToolProvider with fn execute(
  _self,
  name : String,
  _call : @kernel.ToolCall,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  raise @error.RuntimeError::UnknownTool(
    "SingleToolProvider does not execute '\{name}'",
  )
}

///|
async test "t06b_collision_fails_composition" {
  // Two providers register a tool named "shared". Agent::new MUST raise
  // CompositionError::ToolCollision (fail-fast), not silently pick the last.
  let p1 = RecordingToolProvider(
    [
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("shared"),
        description="from p1",
        input_schema=Json::object(Map::from_array([])),
        owner=@kernel.OwnerId::unchecked("provider-alpha"),
        policy=@kernel.Parallel,
        provenance=Some("provider-alpha"),
      ),
    ],
    Map::from_array([]),
  )
  let p2 = RecordingToolProvider(
    [
      @kernel.ToolDef(
        name=@kernel.ToolName::unchecked("shared"),
        description="from p2",
        input_schema=Json::object(Map::from_array([])),
        owner=@kernel.OwnerId::unchecked("provider-beta"),
        policy=@kernel.Parallel,
        provenance=Some("provider-beta"),
      ),
    ],
    Map::from_array([]),
  )
  let model = ScriptedModel([])
  let store = RecordingSessionStore()
  let composition_result = Ok(
    Agent(
      exts=[
        tk_ext(id="model", model=Some(model)),
        tk_ext(id="io", tools=[p1, p2], sessions=[store]),
      ],
      config=outcome_config(),
    ),
  ) catch {
    e => Err(e)
  }
  match composition_result {
    Err(@error.CompositionError::ToolCollision(name, msg, ..)) => {
      assert_eq(name, "shared")
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
  let p1 = SingleToolProvider::{ tool: tk_tool_def("shared", "first"), }
  let p2 = SingleToolProvider::{ tool: tk_tool_def("shared", "second"), }
  let model = ScriptedModel([])
  let store = RecordingSessionStore()
  let composition_result = Ok(
    Agent(
      exts=[
        tk_ext(id="model", model=Some(model)),
        tk_ext(id="io", tools=[p1, p2], sessions=[store]),
      ],
      config=outcome_config(),
    ),
  ) catch {
    e => Err(e)
  }
  match composition_result {
    Err(@error.CompositionError::ToolCollision(name, msg, ..)) => {
      assert_eq(name, "shared")
      // tk_tool_def sets provenance=None; the message must point to
      // ToolDef.provenance as the actionable field.
      assert_true(msg.contains("ToolDef.provenance"))
      assert_eq(model.call_count(), 0)
    }
    _ => fail("expected actionable provenance for collision")
  }
}
