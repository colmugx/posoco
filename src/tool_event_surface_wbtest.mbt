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
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(tk_ok_result("ok")))]),
  )
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools], sessions=[RecordingSessionStore()], observers=[
        observer,
      ]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "s_surface_happy"))
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
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "call_rej", Json::null())),
    Respond(tk_stop_response("recovered")),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(tk_ok_result("ok")))]),
  )
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(
        id="tools",
        tools=[tools],
        sessions=[RecordingSessionStore()],
        observers=[observer],
        hooks=[RejectAllHook::{ reason: "not allowed", }],
      ),
    ],
    config=tk_config(),
  )
  let turn = agent.run_turn(tk_user_msg("hi"), "s_surface_reject")
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
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "call_consent", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(tk_ok_result("ok")))]),
  )
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(
        id="tools",
        tools=[tools],
        sessions=[RecordingSessionStore()],
        observers=[observer],
        hooks=[ConsentAllHook::{ scope: "echo:read", }],
      ),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "s_surface_consent"))
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
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "call_boom", Json::null())),
    Respond(tk_stop_response("unreached")),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(tk_ok_result("ok")))]),
  )
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(
        id="tools",
        tools=[tools],
        sessions=[RecordingSessionStore()],
        observers=[observer],
        hooks=[RaiseAllHook::{ }],
      ),
    ],
    config=tk_config(),
  )
  try {
    ignore(agent.run_turn(tk_user_msg("hi"), "s_surface_raise"))
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
  let model = ScriptedModel([
    Respond(
      tk_tool_call_response(
        "slow_tool",
        "call_cancel",
        Json::object(Map::from_array([])),
      ),
    ),
    Respond(tk_stop_response("after")),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("slow_tool", "slow tool")],
    Map::from_array([]),
  )
  let store = RecordingSessionStore()
  store.seed("s_surface_cancel", {
    messages: [],
    metadata: Map::from_array([]),
  })
  let observer = RecordingObserver()
  let port_runtime = @runtime.PortRuntime(
    model~,
    tools=Map::from_array([("slow_tool", tools as &@port.ToolProvider)]),
  )
  let probe = MidEffectAbortRuntime(inner=port_runtime as &@runtime.Runtime, park_tool_names=[
    "slow_tool",
  ])
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model), sessions=[store]),
      tk_ext(id="tools", tools=[tools], observers=[observer]),
    ],
    config=tk_config(),
    runtime=probe as &@runtime.Runtime,
  )
  let control = agent.control()
  let outcome : Ref[Result[@types.TurnResult, @error.AgentError]] = Ref(
    Err(Runtime(InvocationFailed("unset"))),
  )
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      let r : Result[@types.TurnResult, @error.AgentError] = Ok(
        agent.run_turn(tk_user_msg("run slow"), "s_surface_cancel"),
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
  // The runtime's cancel disposition folds the parked effect as a failure
  // outcome (never a fabricated success), so the pending slot is consumed
  // by ToolCallFailed; the turn then fails. No orphan remains.
  let tags = turn_surface_events(observer.events()).map(event_surface_tag)
  assert_eq(tags, [
    "TurnStarted", "ModelRequestStarted", "ModelResponseReceived", "ToolCallPending",
    "ToolCallApproved", "ToolCallStarted", "ToolCallFailed", "TurnFailed",
  ])
}
