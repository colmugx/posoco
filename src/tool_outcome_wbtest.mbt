///|
/// M0-T06 regression tests: tool outcome consistency and collision fail-fast.
///
/// T06-A: the observer's terminal tool event MUST carry the same failure
/// payload as the ToolOutcome (split events: ToolCallSucceeded /
/// ToolCallFailed / ToolCallRejected; the variant IS the error status).
/// T06-B: two providers registering the same tool name MUST fail composition
/// with CompositionError::ToolCollision, not last-wins.
fn outcome_config() -> AgentConfig {
  agent_config(max_tool_rounds=Some(10))
}

///|
/// Whether the event-side failure payload matches the outcome-side fact.
/// Encodes the projection mapping so the test asserts it explicitly.
fn failure_matches_outcome(
  failure : @kernel.ToolFailure,
  outcome : @kernel.ToolOutcome,
) -> Bool {
  match (outcome, failure) {
    (
      ToolReportedError(content~, structured~),
      ReportedError(content=fc, structured=fs),
    ) => content == fc && structured == fs
    (RuntimeFailure(error_category~, message~), Runtime(category=fc, message=fm)
    ) => error_category == fc && message == fm
    _ => false
  }
}

///|
/// Extract the underlying text content from a ToolOutcome. Used by tests
/// that need to compare error/success message bodies regardless of variant.
fn outcome_text(outcome : @kernel.ToolOutcome) -> String {
  match outcome {
    Success(content~, ..) => content
    SuccessWithAttachments(content~, ..) => content
    ToolReportedError(content~, ..) => content
    RuntimeFailure(message~, ..) => message
    NotExecuted(reason~, ..) => reason.to_string()
  }
}

// ---------------------------------------------------------------------------
// T06-A regression 1: provider returns business-error outcome → the observer
// sees ToolCallFailed(ReportedError).
// ---------------------------------------------------------------------------

///|
async test "t06a_business_error_event_matches_result" {
  // Provider returns Ok(ToolReportedError). The emitted terminal event
  // MUST be ToolCallFailed carrying the same payload.
  let first_response = tk_tool_call_response("probe", "tc_1", Json::null())
  let final_response = tk_stop_response("after")
  let business_result = tk_error_result("denied")
  let model = ScriptedModel([Respond(first_response), Respond(final_response)])
  let outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([
    ("probe", OutcomeOk(business_result)),
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
  // Find the ToolCallFailed event for tc_1 (ToolReportedError shape).
  let mut event_failure : @kernel.ToolFailure? = None
  for e in events {
    match e {
      ToolCallFailed(call~, failure~) =>
        if call.call_id.to_string() == "tc_1" {
          event_failure = Some(failure)
        }
      _ => ()
    }
  }
  match event_failure {
    Some(failure) => {
      // The event's failure payload must match the outcome that the turn
      // returned and the transcript persisted.
      assert_true(failure_matches_outcome(failure, turn_result.tool_results[0]))
      assert_true(turn_result.tool_results[0].is_failure())
    }
    None => fail("expected a ToolCallFailed event for tc_1")
  }
  assert_eq(turn_result.tool_results.length(), 1)
  // The same outcome semantics must be persisted in the tool message
  // that is fed into the next model round.
  try {
    let saved = store.load("s1")
    let mut saw_matching_tool_message = false
    for message in saved.messages {
      match message {
        ToolMessage(call_id~, outcome~, ..) =>
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
// T06-A regression 2: success path — the observer sees ToolCallSucceeded.
// ---------------------------------------------------------------------------

///|
async test "t06a_success_event_is_not_error" {
  let first_response = tk_tool_call_response("safe", "tc_2", Json::null())
  let final_response = tk_stop_response("done")
  let success_result = tk_ok_result("ok")
  let model = ScriptedModel([Respond(first_response), Respond(final_response)])
  let outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([
    ("safe", OutcomeOk(success_result)),
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
  let mut saw_success_event = false
  for e in events {
    match e {
      ToolCallSucceeded(call~, ..) =>
        if call.call_id.to_string() == "tc_2" {
          saw_success_event = true
        }
      _ => ()
    }
  }
  assert_true(saw_success_event)
}

// ---------------------------------------------------------------------------
// T06-A regression 3: runtime raised error → the observer sees
// ToolCallFailed(Runtime).
// ---------------------------------------------------------------------------

///|
async test "t06a_runtime_error_event_is_runtime_failure" {
  let first_response = tk_tool_call_response("boom", "tc_3", Json::null())
  let final_response = tk_stop_response("after")
  let raised_error : @error.RuntimeError = InvocationFailed("crash")
  let model = ScriptedModel([Respond(first_response), Respond(final_response)])
  let outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([
    ("boom", OutcomeErr(raised_error)),
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
      ToolCallFailed(call~, failure~) =>
        if call.call_id.to_string() == "tc_3" {
          assert_true(failure is Runtime(..))
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
        ToolMessage(call_id~, outcome~, ..) =>
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
pub extend SingleToolProvider with @port.ToolProvider::{execute, list_tools}

///|
pub impl @port.ToolProvider for SingleToolProvider with fn list_tools(self) {
  [self.tool]
}

///|
pub impl @port.ToolProvider for SingleToolProvider with fn execute(
  _self,
  ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  raise UnknownTool(
    "SingleToolProvider does not execute '\{ctx.name.to_string()}'",
  )
}

///|
async test "t06b_collision_fails_composition" {
  // Two providers register a tool named "shared". Agent::new MUST raise
  // CompositionError::ToolCollision (fail-fast), not silently pick the last.
  let p1 = RecordingToolProvider(
    [
      ToolDef(
        name=@kernel.ToolName::unchecked("shared"),
        description="from p1",
        input_schema=Json::object(Map::from_array([])),
        owner=@kernel.OwnerId::unchecked("provider-alpha"),
        policy=Parallel,
        provenance=Some("provider-alpha"),
      ),
    ],
    Map::from_array([]),
  )
  let p2 = RecordingToolProvider(
    [
      ToolDef(
        name=@kernel.ToolName::unchecked("shared"),
        description="from p2",
        input_schema=Json::object(Map::from_array([])),
        owner=@kernel.OwnerId::unchecked("provider-beta"),
        policy=Parallel,
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
    Err(ToolCollision(name, msg, ..)) => {
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
    Err(ToolCollision(name, msg, ..)) => {
      assert_eq(name, "shared")
      // tk_tool_def sets provenance=None; the message must point to
      // ToolDef.provenance as the actionable field.
      assert_true(msg.contains("ToolDef.provenance"))
      assert_eq(model.call_count(), 0)
    }
    _ => fail("expected actionable provenance for collision")
  }
}

// ---------------------------------------------------------------------------
// Tool attachments: a provider returning SuccessWithAttachments keeps the
// blocks end-to-end (turn result, observer event, transcript) without ever
// leaking the payload into single-line summaries.
// ---------------------------------------------------------------------------

///|
async test "attachments_outcome_flows_to_result_event_and_transcript" {
  let first_response = tk_tool_call_response("probe", "tc_att", Json::null())
  let final_response = tk_stop_response("seen")
  let image : @kernel.Content = @kernel.Content::Image(
    media_type="image/png",
    data="aGVsbG8=",
  )
  let outcome = tk_ok_attachments_result("captured", attachments=[image])
  let model = ScriptedModel([Respond(first_response), Respond(final_response)])
  let outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([
    ("probe", OutcomeOk(outcome)),
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
  let turn_result = agent.run_turn(tk_user_msg("capture"), "s_att")
  // Turn result keeps the variant and the block.
  assert_eq(turn_result.tool_results.length(), 1)
  match turn_result.tool_results[0] {
    SuccessWithAttachments(content~, attachments~, structured=None) => {
      assert_eq(content, "captured")
      assert_eq(attachments.length(), 1)
      assert_true(attachments[0] is @kernel.Content::Image(..))
      assert_false(turn_result.tool_results[0].is_failure())
    }
    _ => fail("expected SuccessWithAttachments")
  }
  // Summary counts attachments, never payloads.
  let summary = turn_result.tool_results[0].summary()
  assert_true(summary.contains("attachments=1"))
  assert_false(summary.contains("aGVsbG8="))
  // The observer event carries the same blocks.
  let mut event_attachments : Array[@kernel.Content] = []
  for e in obs.events() {
    match e {
      ToolCallSucceeded(call~, attachments~, ..) =>
        if call.call_id.to_string() == "tc_att" {
          event_attachments = attachments
        }
      _ => ()
    }
  }
  assert_eq(event_attachments.length(), 1)
  // The persisted transcript tool message keeps the outcome intact.
  try {
    let saved = store.load("s_att")
    let mut found = false
    for msg in saved.messages {
      match msg {
        @kernel.ToolMessage(outcome=SuccessWithAttachments(..), ..) =>
          found = true
        _ => ()
      }
    }
    assert_true(found)
  } catch {
    _ => fail("expected the session to load")
  }
}
