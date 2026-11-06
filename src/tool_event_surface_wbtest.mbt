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
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_1", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    Map::from_array([
      (
        "echo",
        @test_support.ScriptedToolOutcome::OutcomeOk(
          @test_support.tk_ok_result("ok"),
        ),
      ),
    ]),
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
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_rej", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("recovered"),
    ),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    Map::from_array([
      (
        "echo",
        @test_support.ScriptedToolOutcome::OutcomeOk(
          @test_support.tk_ok_result("ok"),
        ),
      ),
    ]),
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
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_consent", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    Map::from_array([
      (
        "echo",
        @test_support.ScriptedToolOutcome::OutcomeOk(
          @test_support.tk_ok_result("ok"),
        ),
      ),
    ]),
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
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_boom", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("unreached"),
    ),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    Map::from_array([
      (
        "echo",
        @test_support.ScriptedToolOutcome::OutcomeOk(
          @test_support.tk_ok_result("ok"),
        ),
      ),
    ]),
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
    @test_support.ScriptedModelStep::Respond(
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
  guard outcome.val is Err(@error.AgentError::Cancelled(_)) else {
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
