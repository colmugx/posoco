///|
/// Whitebox tests for the `PipelineHook::on_turn_end` interception point:
/// dispatch ordering (after the terminal observer projection), registration
/// order across hooks, and isolation of the turn's primary outcome when a
/// hook raises. `on_turn_end` carries no payload — the terminal outcome
/// lives on the Observer channel (`TurnCompleted` / `TurnFailed`).

///|
/// A hook that appends to a shared sequence log when `on_turn_end` fires.
priv struct TurnEndLogHook {
  id : String
  log : Array[String]
}

///|
impl @port.PipelineHook for TurnEndLogHook with fn on_turn_end(self) -> Unit {
  self.log.push("hook:\{self.id}")
}

///|
suberror TurnEndHookDefect {
  Defect(detail~ : String)
}

///|
/// A hook whose `on_turn_end` always raises after logging — stands in for
/// an extension whose turn-end commit fails.
priv struct RaisingTurnEndHook {
  log : Array[String]
}

///|
impl @port.PipelineHook for RaisingTurnEndHook with fn on_turn_end(self) -> Unit raise Error {
  self.log.push("hook:raising")
  raise TurnEndHookDefect::Defect(detail="commit failed")
}

///|
/// A hook logging both `on_turn_begin` and `before_model`, to pin the
/// turn-begin dispatch between the `TurnStarted` projection and the pump's
/// first model call.
priv struct TurnBeginLogHook {
  log : Array[String]
}

///|
impl @port.PipelineHook for TurnBeginLogHook with fn on_turn_begin(self) -> Unit {
  self.log.push("hook:begin")
}

///|
impl @port.PipelineHook for TurnBeginLogHook with fn before_model(
  self,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] {
  self.log.push("hook:before_model")
  messages
}

///|
async test "turn_begin/dispatched_after_turn_started_before_first_model" {
  let log : Array[String] = []
  let hook = TurnBeginLogHook::{ log, }
  let obs = TurnEndLogObserver::{ log, }
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(ScriptedModel([Respond(tk_stop_response("hi"))])),
      ),
      tk_ext(id="io", sessions=[RecordingSessionStore()], observers=[
        obs as &@port.Observer,
      ]),
      tk_ext(id="hooks", hooks=[hook as &@port.PipelineHook]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hello"), "s1"))
  assert_eq(log.filter(fn(e) { e == "hook:begin" }).length(), 1)
  assert_eq(log[0], "obs:TurnStarted")
  assert_eq(log[1], "hook:begin")
  assert_eq(log[2], "hook:before_model")
}

///|
suberror TurnBeginHookDefect {
  Defect(detail~ : String)
}

///|
/// An observer writing the same shared log, for ordering assertions
/// against hook records.
priv struct TurnEndLogObserver {
  log : Array[String]
}

///|
priv struct RaisingTurnBeginHook {
  log : Array[String]
}

///|
impl @port.PipelineHook for RaisingTurnBeginHook with fn on_turn_begin(self) -> Unit raise Error {
  self.log.push("hook:begin-raising")
  raise TurnBeginHookDefect::Defect(detail="boot failed")
}

///|
async test "turn_begin/raised_hook_is_secondary_failure_turn_proceeds" {
  let log : Array[String] = []
  let bad = RaisingTurnBeginHook::{ log, }
  let after = TurnBeginLogHook::{ log, }
  let obs = TurnEndLogObserver::{ log, }
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(ScriptedModel([Respond(tk_stop_response("hi"))])),
      ),
      tk_ext(id="io", sessions=[RecordingSessionStore()], observers=[
        obs as &@port.Observer,
      ]),
      tk_ext(id="hooks", hooks=[
        bad as &@port.PipelineHook,
        after as &@port.PipelineHook,
      ]),
    ],
    config=tk_config(),
  )
  let result = agent.run_turn(tk_user_msg("hello"), "s1")
  // The raise never fails the turn; the model still answered.
  assert_eq(result.final_session_id, "s1")
  assert_eq(log[0], "obs:TurnStarted")
  assert_eq(log[1], "hook:begin-raising")
  assert_eq(log[2], "obs:Custom(source:posoco.core, label:secondary_failure)")
  // The later hook still runs, and the pump proceeds to the model.
  assert_eq(log[3], "hook:begin")
  // Only `after` logs before_model (`bad` uses the default pass-through),
  // and the model is called once for this single-step turn.
  assert_eq(log.filter(fn(e) { e == "hook:before_model" }).length(), 1)
}

///|
impl @port.Observer for TurnEndLogObserver with fn on_event(
  self,
  event : @types.TurnEvent,
) -> Unit {
  self.log.push("obs:" + event.to_string())
}

///|
async test "turn_end/completed_dispatched_once_after_turn_completed" {
  let log : Array[String] = []
  let hook = TurnEndLogHook::{ id: "only", log, }
  let obs = TurnEndLogObserver::{ log, }
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(ScriptedModel([Respond(tk_stop_response("hi"))])),
      ),
      tk_ext(id="io", sessions=[RecordingSessionStore()], observers=[
        obs as &@port.Observer,
      ]),
      tk_ext(id="hooks", hooks=[hook as &@port.PipelineHook]),
    ],
    config=tk_config(),
  )
  let result = agent.run_turn(tk_user_msg("hello"), "s1")
  assert_eq(result.final_session_id, "s1")
  assert_eq(log.filter(fn(e) { e == "hook:only" }).length(), 1)
  assert_eq(log[log.length() - 2], "obs:TurnCompleted")
  assert_eq(log[log.length() - 1], "hook:only")
}

///|
async test "turn_end/failed_path_also_dispatches_after_turn_failed" {
  let log : Array[String] = []
  let hook = TurnEndLogHook::{ id: "only", log, }
  let obs = TurnEndLogObserver::{ log, }
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(ScriptedModel([Fail(@error.ModelError::Transport("boom"))])),
      ),
      tk_ext(id="io", sessions=[RecordingSessionStore()], observers=[
        obs as &@port.Observer,
      ]),
      tk_ext(id="hooks", hooks=[hook as &@port.PipelineHook]),
    ],
    config=tk_config(),
  )
  try agent.run_turn(tk_user_msg("hello"), "s1") catch {
    @error.AgentError::Model(_) => ()
    _ => fail("expected AgentError::Model from the failed script")
  } noraise {
    _ => fail("expected the failed-script turn to raise")
  }
  assert_eq(log.filter(fn(e) { e == "hook:only" }).length(), 1)
  assert_eq(
    log[log.length() - 2],
    "obs:TurnFailed(turn failed: AgentError::Model)",
  )
  assert_eq(log[log.length() - 1], "hook:only")
}

///|
async test "turn_end/hooks_dispatched_in_registration_order" {
  let log : Array[String] = []
  let first = TurnEndLogHook::{ id: "first", log, }
  let second = TurnEndLogHook::{ id: "second", log, }
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(ScriptedModel([Respond(tk_stop_response("hi"))])),
      ),
      tk_ext(id="io", sessions=[RecordingSessionStore()]),
      tk_ext(id="hooks", hooks=[
        first as &@port.PipelineHook,
        second as &@port.PipelineHook,
      ]),
    ],
    config=tk_config(),
  )
  ignore(agent.run_turn(tk_user_msg("hello"), "s1"))
  assert_eq(log[log.length() - 2], "hook:first")
  assert_eq(log[log.length() - 1], "hook:second")
}

///|
async test "turn_end/raised_hook_is_secondary_failure_not_turn_failure" {
  let log : Array[String] = []
  let bad = RaisingTurnEndHook::{ log, }
  let good = TurnEndLogHook::{ id: "good", log, }
  let obs = TurnEndLogObserver::{ log, }
  let agent = Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(ScriptedModel([Respond(tk_stop_response("hi"))])),
      ),
      tk_ext(id="io", sessions=[RecordingSessionStore()], observers=[
        obs as &@port.Observer,
      ]),
      tk_ext(id="hooks", hooks=[
        bad as &@port.PipelineHook,
        good as &@port.PipelineHook,
      ]),
    ],
    config=tk_config(),
  )
  let result = agent.run_turn(tk_user_msg("hello"), "s1")
  // The turn still completes; the raise never replaces the primary outcome.
  assert_eq(result.final_session_id, "s1")
  assert_eq(log.filter(fn(e) { e == "obs:TurnCompleted" }).length(), 1)
  // The raise is reported to observers, then the later hook still runs.
  assert_eq(log[log.length() - 3], "hook:raising")
  assert_eq(
    log[log.length() - 2],
    "obs:Custom(source:posoco.core, label:secondary_failure)",
  )
  assert_eq(log[log.length() - 1], "hook:good")
}
