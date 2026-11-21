///|
/// Regression tests: tool outcome consistency and collision fail-fast.
///
/// The observer's terminal tool event MUST carry the same failure
/// payload as the ToolOutcome (split events: ToolCallSucceeded /
/// ToolCallFailed / ToolCallRejected; the variant IS the error status).
/// Two providers registering the same tool name MUST fail composition
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

///|
async test "t06a_business_error_event_matches_result" {
  // Provider returns Ok(ToolReportedError). The emitted terminal event
  // MUST be ToolCallFailed carrying the same payload.
  let first_response = @test_support.tk_tool_call_response(
    "probe",
    "tc_1",
    Json::null(),
  )
  let final_response = @test_support.tk_stop_response("after")
  let business_result = @test_support.tk_error_result("denied")
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(first_response),
    Respond(final_response),
  ])
  let outcomes : Map[String, @test_support.ScriptedToolOutcome] = Map::from_array([
      ("probe", OutcomeOk(business_result)),
    ],
  )
  let provider = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("probe", "")],
    outcomes,
  )
  let obs = @test_support.RecordingObserver()
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[provider], sessions=[store], observers=[
        obs,
      ]),
    ],
    config=outcome_config(),
  )
  let turn_result = agent.run_turn(@test_support.tk_user_msg("run probe"), "s1")
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

///|
async test "t06a_runtime_error_event_is_runtime_failure" {
  let first_response = @test_support.tk_tool_call_response(
    "boom",
    "tc_3",
    Json::null(),
  )
  let final_response = @test_support.tk_stop_response("after")
  let raised_error : @error.RuntimeError = InvocationFailed("crash")
  let model = @test_support.ScriptedModel([
    Respond(first_response),
    Respond(final_response),
  ])
  let outcomes : Map[String, @test_support.ScriptedToolOutcome] = Map::from_array([
      ("boom", OutcomeErr(raised_error)),
    ],
  )
  let provider = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("boom", "")],
    outcomes,
  )
  let obs = @test_support.RecordingObserver()
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[provider], sessions=[store], observers=[
        obs,
      ]),
    ],
    config=outcome_config(),
  )
  let result = agent.run_turn(@test_support.tk_user_msg("run boom"), "s1")
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
  let p1 = @test_support.RecordingToolProvider(
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
  let p2 = @test_support.RecordingToolProvider(
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
  let model = @test_support.ScriptedModel([])
  let store = @test_support.RecordingSessionPort()
  let composition_result = Ok(
    Agent(
      events=EventSystem(),
      exts=[
        @test_support.tk_ext(id="model", model=Some(model)),
        @test_support.tk_ext(id="io", tools=[p1, p2], sessions=[store]),
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
  let p1 = SingleToolProvider::{
    tool: @test_support.tk_tool_def("shared", "first"),
  }
  let p2 = SingleToolProvider::{
    tool: @test_support.tk_tool_def("shared", "second"),
  }
  let model = @test_support.ScriptedModel([])
  let store = @test_support.RecordingSessionPort()
  let composition_result = Ok(
    Agent(
      events=EventSystem(),
      exts=[
        @test_support.tk_ext(id="model", model=Some(model)),
        @test_support.tk_ext(id="io", tools=[p1, p2], sessions=[store]),
      ],
      config=outcome_config(),
    ),
  ) catch {
    e => Err(e)
  }
  match composition_result {
    Err(ToolCollision(name, msg, ..)) => {
      assert_eq(name, "shared")
      // @test_support.tk_tool_def sets provenance=None; the message must point to
      // ToolDef.provenance as the actionable field.
      assert_true(msg.contains("ToolDef.provenance"))
      assert_eq(model.call_count(), 0)
    }
    _ => fail("expected actionable provenance for collision")
  }
}

///|
async test "attachments_outcome_flows_to_result_event_and_transcript" {
  let first_response = @test_support.tk_tool_call_response(
    "probe",
    "tc_att",
    Json::null(),
  )
  let final_response = @test_support.tk_stop_response("seen")
  let image : @kernel.Content = Image(media_type="image/png", data="aGVsbG8=")
  let outcome = @test_support.tk_ok_attachments_result("captured", attachments=[
    image,
  ])
  let model = @test_support.ScriptedModel([
    Respond(first_response),
    Respond(final_response),
  ])
  let outcomes : Map[String, @test_support.ScriptedToolOutcome] = Map::from_array([
      ("probe", OutcomeOk(outcome)),
    ],
  )
  let provider = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("probe", "")],
    outcomes,
  )
  let obs = @test_support.RecordingObserver()
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[provider], sessions=[store], observers=[
        obs,
      ]),
    ],
    config=outcome_config(),
  )
  let turn_result = agent.run_turn(
    @test_support.tk_user_msg("capture"),
    "s_att",
  )
  // Turn result keeps the variant and the block.
  assert_eq(turn_result.tool_results.length(), 1)
  match turn_result.tool_results[0] {
    SuccessWithAttachments(content~, attachments~, structured=None) => {
      assert_eq(content, "captured")
      assert_eq(attachments.length(), 1)
      assert_true(attachments[0] is Image(..))
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

///|
/// Tool event surface regression tests: one observable node per lifecycle
/// state, no shared/double-duty events, all nodes delivered through the
/// Observer channel.
///
/// State machine under test:
///   Pending → Approved → Started → Succeeded/Failed
///   Pending → Rejected (hook decision)
///   Pending → Abandoned (terminal hook failure, cancel)
///   (pre-pass rejects: Rejected without Pending — covered in posoco_wbtest)

///|
/// The core operation projection brackets every turn stream; the surface
/// assertions below describe the turn/tool event sequence.
fn turn_surface_events(
  events : Array[@types.TurnEvent],
) -> Array[@types.TurnEvent] {
  events.filter(fn(event) {
    match event {
      Custom(source~, ..) => source != "posoco.operation"
      _ => true
    }
  })
}

///|
fn event_surface_tag(event : @types.TurnEvent) -> String {
  match event {
    TurnStarted => "TurnStarted"
    ModelRequestStarted => "ModelRequestStarted"
    ModelResponseReceived(..) => "ModelResponseReceived"
    ToolCallPending(_) => "ToolCallPending"
    ToolCallApproved(..) => "ToolCallApproved"
    ToolCallStarted(..) => "ToolCallStarted"
    ToolCallSucceeded(..) => "ToolCallSucceeded"
    ToolCallFailed(..) => "ToolCallFailed"
    ToolCallRejected(..) => "ToolCallRejected"
    ToolCallAbandoned(..) => "ToolCallAbandoned"
    TurnCompleted => "TurnCompleted"
    TurnFailed(_) => "TurnFailed"
    TurnCancelled => "TurnCancelled"
    _ => "other"
  }
}

///|
/// Hook that consents to every call with a fixed scope.
struct ConsentAllHook {
  scope : String
}

///|
impl @port.PipelineHook for ConsentAllHook with fn before_tool(
  self : ConsentAllHook,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  ApproveAfterConsent(call~, consent_scope=self.scope)
}

///|
/// Hook that rejects every call.
struct RejectAllHook {
  reason : String
}

///|
impl @port.PipelineHook for RejectAllHook with fn before_tool(
  self : RejectAllHook,
  _call : @kernel.ToolCall,
) -> @port.ToolDecision {
  Reject(reason=self.reason)
}

///|
/// Hook whose before_tool always raises a hook defect.
struct RaiseAllHook {}

///|
impl @port.PipelineHook for RaiseAllHook with fn before_tool(
  _self : RaiseAllHook,
  _call : @kernel.ToolCall,
) -> @port.ToolDecision raise {
  raise @port.HookAbort::Aborted(reason="hook exploded")
}

///|
async test "tool_event_surface/happy_path_pending_approved_started_succeeded" {
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(@test_support.tk_stop_response("done")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(@test_support.tk_ok_result("ok")))]),
  )
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="tools",
        tools=[tools],
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("hi"), "s_surface_happy"))
  assert_eq(turn_surface_events(observer.events()).map(event_surface_tag), [
    "TurnStarted", "ModelRequestStarted", "ModelResponseReceived", "ToolCallPending",
    "ToolCallApproved", "ToolCallStarted", "ToolCallSucceeded", "ModelRequestStarted",
    "ModelResponseReceived", "TurnCompleted",
  ])
  // Plain approval chain: the approval event carries no consent scope.
  for event in observer.events() {
    if event is ToolCallApproved(call=_, consent_scope=scope) {
      assert_true(scope is None)
    }
  }
}

///|
async test "tool_event_surface/hook_reject_surfaces_as_rejected_run_continues" {
  let model = @test_support.ScriptedModel([
    Respond(
      @test_support.tk_tool_call_response("echo", "call_rej", Json::null()),
    ),
    Respond(@test_support.tk_stop_response("recovered")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(@test_support.tk_ok_result("ok")))]),
  )
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="tools",
        tools=[tools],
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
        hooks=[RejectAllHook::{ reason: "not allowed", }],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let turn = agent.run_turn(@test_support.tk_user_msg("hi"), "s_surface_reject")
  // The provider never executed; the model got the rejection feedback.
  assert_eq(tools.exec_records().length(), 0)
  match turn.tool_results[0] {
    NotExecuted(reason=RejectedByHook(..), ..) => ()
    _ => fail("expected NotExecuted(RejectedByHook)")
  }
  let tags = turn_surface_events(observer.events()).map(event_surface_tag)
  assert_eq(tags, [
    "TurnStarted", "ModelRequestStarted", "ModelResponseReceived", "ToolCallPending",
    "ToolCallRejected", "ModelRequestStarted", "ModelResponseReceived", "TurnCompleted",
  ])
  for event in observer.events() {
    if event is ToolCallRejected(call=_, reason=RejectedByHook(reason~)) {
      assert_true(reason.contains("not allowed"))
    }
  }
}

///|
async test "tool_event_surface/consent_hook_approval_carries_scope" {
  let model = @test_support.ScriptedModel([
    Respond(
      @test_support.tk_tool_call_response("echo", "call_consent", Json::null()),
    ),
    Respond(@test_support.tk_stop_response("done")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(@test_support.tk_ok_result("ok")))]),
  )
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="tools",
        tools=[tools],
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
        hooks=[ConsentAllHook::{ scope: "echo:read", }],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("hi"), "s_surface_consent"))
  let mut saw_scoped_approval = false
  for event in observer.events() {
    if event is ToolCallApproved(call=_, consent_scope=Some(scope)) {
      assert_eq(scope, "echo:read")
      saw_scoped_approval = true
    }
  }
  assert_true(saw_scoped_approval)
}

///|
async test "tool_event_surface/hook_raise_abandons_pending_calls" {
  let model = @test_support.ScriptedModel([
    Respond(
      @test_support.tk_tool_call_response("echo", "call_boom", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("unreached"),
    ),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(@test_support.tk_ok_result("ok")))]),
  )
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="tools",
        tools=[tools],
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
        hooks=[RaiseAllHook::{ }],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  try {
    ignore(agent.run_turn(@test_support.tk_user_msg("hi"), "s_surface_raise"))
    fail("expected the turn to fail with a hook defect")
  } catch {
    _ => ()
  }
  // The run died after the pending declaration: the terminal drain must
  // close the orphan with ToolCallAbandoned, then the turn fails.
  let tags = turn_surface_events(observer.events()).map(event_surface_tag)
  assert_eq(tags, [
    "TurnStarted", "ModelRequestStarted", "ModelResponseReceived", "ToolCallPending",
    "ToolCallAbandoned", "TurnFailed",
  ])
  for event in observer.events() {
    if event is ToolCallAbandoned(call=_, reason~) {
      assert_eq(reason, "turn failed")
    }
  }
}

///|
async test "tool_event_surface/mid_wave_cancel_abandons_pending_calls" {
  let model = @test_support.ScriptedModel([
    Respond(
      @test_support.tk_tool_call_response(
        "slow_tool",
        "call_cancel",
        Json::object(Map::from_array([])),
      ),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("after"),
    ),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("slow_tool", "slow tool")],
    Map::from_array([]),
  )
  let store = @test_support.RecordingSessionPort()
  store.seed("s_surface_cancel", {
    messages: [],
    metadata: Map::from_array([]),
  })
  let observer = @test_support.RecordingObserver()
  let port_runtime = @runtime.PortRuntime(model~)
  let probe = MidEffectAbortRuntime(inner=port_runtime as &@runtime.Runtime, park_tool_names=[
    "slow_tool",
  ])
  let agent = Agent::with_runtime(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model), sessions=[store]),
      @test_support.tk_ext(id="tools", tools=[tools], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
    runtime=probe as &@runtime.Runtime,
  )
  let control = agent.control()
  let outcome : Ref[Result[@types.TurnResult, @error.AgentError]] = Ref(
    Err(Runtime(InvocationFailed("unset"))),
  )
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      let r : Result[@types.TurnResult, @error.AgentError] = Ok(
        agent.run_turn(
          @test_support.tk_user_msg("run slow"),
          "s_surface_cancel",
        ),
      ) catch {
        e => Err(e)
      }
      outcome.val = r
    })
    while probe.tool_parks == 0 {
      @async.pause()
    }
    assert_true(control.abort_active(Some("esc")) is @runtime.Accepted(_))
    ignore(task.wait())
  })
  guard outcome.val is Err(Cancelled(_)) else {
    fail("expected structured Cancelled, got \{repr(outcome.val)}")
  }
  assert_eq(probe.tool_parks, 1)
  // The cancel disposition folds the parked effect as a failure outcome, so
  // the pending slot is consumed by ToolCallFailed and the turn ends
  // cancelled.
  let tags = turn_surface_events(observer.events()).map(event_surface_tag)
  assert_eq(tags, [
    "TurnStarted", "ModelRequestStarted", "ModelResponseReceived", "ToolCallPending",
    "ToolCallApproved", "ToolCallStarted", "ToolCallFailed", "TurnCancelled",
  ])
}
