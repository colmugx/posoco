///|
/// Run-bound callbacks carry the identity minted for their turn;
/// out-of-run notifications may carry None.

///|
/// Observer double recording (tag, scope) for every scoped dispatch.
struct ScopedObserver {
  records : Array[(String, @types.EventScope?)]
}

///|
/// Tag just the variants these tests drive; everything else is "other".
fn scope_projection_event_tag(event : @types.TurnEvent) -> String {
  match event {
    TurnStarted => "turn_started"
    ModelResponseReceived(..) => "model_response"
    ToolCallPending(_) => "tool_pending"
    ToolCallApproved(..) => "tool_approved"
    ToolCallStarted(..) => "tool_started"
    ToolCallSucceeded(..)
    | ToolCallFailed(..)
    | ToolCallRejected(..)
    | ToolCallAbandoned(..) => "tool_result"
    TurnCompleted => "turn_completed"
    TurnFailed(_) => "turn_failed"
    _ => "other"
  }
}

///|
pub extend ScopedObserver with @port.Observer::{on_event}

///|
pub impl @port.Observer for ScopedObserver with fn on_event(
  self,
  scope,
  event : @types.TurnEvent,
) -> Unit {
  self.records.push((scope_projection_event_tag(event), scope))
}

///|
/// PipelineHook double recording (tag, scope) for every scoped post-event dispatch.
struct ScopedHook {
  stages : Array[(String, @types.EventScope?)]
}

///|
pub extend ScopedHook with @port.PipelineHook::{
  tool_exposure,
  on_turn_begin,
  on_post_event,
  before_model,
  before_tool,
  on_turn_end,
}

///|
pub impl @port.PipelineHook for ScopedHook with fn on_post_event(
  self,
  scope,
  stage : @port.HookStage,
) -> Unit {
  let tag = match stage {
    ModelCompleted(..) => "model_completed"
    ModelFailed(..) => "model_failed"
    ToolCompleted(..) => "tool_completed"
    ToolFailed(..) => "tool_failed"
  }
  self.stages.push((tag, scope))
}

///|
/// A plain stop turn emits TurnStarted → ModelResponseReceived →
/// TurnCompleted, all carrying the SAME Some(scope), and the scope names the
/// session the product passed to `run_turn`.
async test "scope_projection/turn_events_carry_one_run_identity" {
  let observer = ScopedObserver::{ records: [], }
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_stop_response("hi"),
            ),
          ]),
        ),
      ),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("hello"), "s_scope"))
  // The operation projection is deliberately out-of-run (scope None, session
  // in the payload); the run-bound invariants below cover the TURN events.
  let turn_records = observer.records.filter(fn(r) { r.0 != "other" })
  let tags = turn_records.map(fn(r) { r.0 })
  assert_eq(tags, ["turn_started", "model_response", "turn_completed"])
  guard turn_records[0].1 is Some(first) else {
    fail("TurnStarted must carry Some(scope)")
  }
  for record in turn_records {
    guard record.1 is Some(scope) else {
      fail("run-bound event must carry Some(scope): " + record.0)
    }
    assert_eq(scope, first)
    assert_eq(scope.session_id.to_string(), "s_scope")
  }
}

///|
/// Two turns on one agent/session are two runs: distinct run_id and turn_id,
/// same session_id.
async test "scope_projection/two_turns_distinct_runs_same_session" {
  let observer = ScopedObserver::{ records: [], }
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("a"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("b"),
    ),
  ])
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("one"), "s_scope"))
  ignore(agent.run_turn(@test_support.tk_user_msg("two"), "s_scope"))
  let started : Array[@types.EventScope] = []
  for record in observer.records {
    if record.0 == "turn_started" && record.1 is Some(scope) {
      started.push(scope)
    }
  }
  assert_eq(started.length(), 2)
  assert_true(started[0].run_id != started[1].run_id)
  assert_true(started[0].turn_id != started[1].turn_id)
  assert_eq(started[0].session_id, started[1].session_id)
}

///|
/// A tool-loop turn projects envelope events (tool pending/result, model
/// responses) under the same run identity as the turn lifecycle, and
/// post-event hook stages observe that same identity.
async test "scope_projection/tool_loop_events_and_hook_stages_share_run" {
  let observer = ScopedObserver::{ records: [], }
  let hook = ScopedHook::{ stages: [], }
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
          @test_support.tk_ok_result("echoed"),
        ),
      ),
    ]),
  )
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="tools",
        tools=[tools],
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
        hooks=[hook],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("hi"), "s_loop"))
  let tags = observer.records
    .filter(fn(r) { r.0 != "other" })
    .map(fn(r) { r.0 })
  assert_eq(tags, [
    "turn_started", "model_response", "tool_pending", "tool_approved", "tool_started",
    "tool_result", "model_response", "turn_completed",
  ])
  let turn_records = observer.records.filter(fn(r) { r.0 != "other" })
  guard turn_records[0].1 is Some(turn_scope) else {
    fail("TurnStarted must carry Some(scope)")
  }
  for record in turn_records {
    guard record.1 is Some(scope) else {
      fail("envelope-projected event must carry Some(scope): " + record.0)
    }
    assert_eq(scope.run_id, turn_scope.run_id)
    assert_eq(scope.turn_id, turn_scope.turn_id)
  }
  // Post-event stages: model step → tool completion → model step.
  let stage_tags = hook.stages.map(fn(s) { s.0 })
  assert_eq(stage_tags, ["model_completed", "tool_completed", "model_completed"])
  for stage in hook.stages {
    guard stage.1 is Some(scope) else {
      fail("post-event stage must carry Some(scope): " + stage.0)
    }
    assert_eq(scope.run_id, turn_scope.run_id)
    assert_eq(scope.turn_id, turn_scope.turn_id)
  }
}
