///|
/// Contract pins for `EventScope` projection (P1): the core dispatches ONLY
/// the scoped variants (`Observer::on_event_at`, `Hook::on_post_event_at`),
/// and every run-bound event carries the identity minted for its turn.
/// Out-of-run diagnostics (stream chunks, secondary failures) may carry
/// `None`.

///|
/// Observer double recording (tag, scope) for every scoped dispatch.
struct ScopedObserver {
  records : Array[(String, @types.EventScope?)]
}

///|
/// Tag just the variants these tests drive; everything else is "other".
fn scope_projection_event_tag(event : @types.TurnEvent) -> String {
  match event {
    @types.TurnStarted => "turn_started"
    @types.ModelResponseReceived(..) => "model_response"
    @types.ToolCallPending(_) => "tool_pending"
    @types.ToolCallResult(..) => "tool_result"
    @types.TurnCompleted => "turn_completed"
    @types.TurnFailed(_) => "turn_failed"
    _ => "other"
  }
}

///|
pub impl @port.Observer for ScopedObserver with fn on_event_at(
  self,
  scope,
  event : @types.TurnEvent,
) -> Unit {
  self.records.push((scope_projection_event_tag(event), scope))
}

///|
/// Hook double recording (tag, scope) for every scoped post-event dispatch.
struct ScopedHook {
  stages : Array[(String, @types.EventScope?)]
}

///|
pub impl @port.Hook for ScopedHook with fn on_post_event_at(
  self,
  scope,
  stage : @port.HookStage,
) -> Unit {
  let tag = match stage {
    @port.HookStage::ModelCompleted(..) => "model_completed"
    @port.HookStage::ModelFailed(..) => "model_failed"
    @port.HookStage::ToolCompleted(..) => "tool_completed"
    @port.HookStage::ToolFailed(..) => "tool_failed"
  }
  self.stages.push((tag, scope))
}

///|
/// A plain stop turn emits TurnStarted → ModelResponseReceived →
/// TurnCompleted, all carrying the SAME Some(scope), and the scope names the
/// session the product passed to `run_turn`.
async test "scope_projection/turn_events_carry_one_run_identity" {
  let observer = ScopedObserver::{ records: [] }
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(ScriptedModel([Respond(tk_stop_response("hi"))])),
      ),
      tk_ext(id="io", sessions=[RecordingSessionStore()], observers=[observer]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hello"), "s_scope"))
  let tags = observer.records.map(fn(r) { r.0 })
  assert_eq(tags, ["turn_started", "model_response", "turn_completed"])
  guard observer.records[0].1 is Some(first) else {
    fail("TurnStarted must carry Some(scope)")
  }
  for record in observer.records {
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
  let observer = ScopedObserver::{ records: [] }
  let model = ScriptedModel([
    Respond(tk_stop_response("a")),
    Respond(tk_stop_response("b")),
  ])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[RecordingSessionStore()], observers=[observer]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("one"), "s_scope"))
  ignore(agent.run_turn(tk_user_msg("two"), "s_scope"))
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
  let observer = ScopedObserver::{ records: [] }
  let hook = ScopedHook::{ stages: [] }
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([
      ("echo", ScriptedToolOutcome::OutcomeOk(tk_ok_result("echoed"))),
    ]),
  )
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(
        id="tools",
        tools=[tools],
        sessions=[RecordingSessionStore()],
        observers=[observer],
        hooks=[hook],
      ),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hi"), "s_loop"))
  let tags = observer.records.map(fn(r) { r.0 })
  assert_eq(tags, [
    "turn_started", "model_response", "tool_pending", "tool_result", "model_response",
    "turn_completed",
  ])
  guard observer.records[0].1 is Some(turn_scope) else {
    fail("TurnStarted must carry Some(scope)")
  }
  for record in observer.records {
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

///|
/// Back-compat: observers/hooks overriding only the legacy unscoped methods
/// keep working — the scoped dispatch delegates through the defaults.
async test "scope_projection/legacy_observer_and_hook_unchanged" {
  let observer = RecordingObserver()
  let hook = RecordingHook()
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(ScriptedModel([Respond(tk_stop_response("hi"))])),
      ),
      tk_ext(
        id="io",
        sessions=[RecordingSessionStore()],
        observers=[observer],
        hooks=[hook],
      ),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hello"), "s_legacy"))
  let events = observer.events()
  assert_eq(events.length(), 3)
  guard events[0] is @types.TurnStarted else {
    fail("first event must be TurnStarted")
  }
  guard events[2] is @types.TurnCompleted else {
    fail("last event must be TurnCompleted")
  }
  let labels = hook.records().map(fn(r) { r.label })
  assert_true(labels.contains("before_model"))
  assert_true(labels.contains("on_post_event"))
}
