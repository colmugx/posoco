///|
async test "rate-limit resume replays persisted user without duplicating transcript" {
  let model = ScriptedModel([
    Fail(
      RateLimited({
        message: "quota exhausted",
        reset_at_ms: Some(1000L),
        provider_code: Some("429"),
      }),
    ),
    Respond(tk_stop_response("resumed")),
  ])
  let store = RecordingSessionPort()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let first = Ok(agent.run_turn(tk_user_msg("original task"), "resume-user")) catch {
    error => Err(error)
  }
  match first {
    Err(Model(msg)) => {
      assert_true(msg.contains("model quota exhausted"))
      assert_true(msg.contains("code=429"))
      assert_true(msg.contains("reset_at_ms=1000"))
      assert_true(msg.contains("message=quota exhausted"))
    }
    _ => fail("expected AgentError::Model carrying the rate-limit verdict")
  }
  ignore(agent.resume_turn("resume-user"))
  assert_eq(model.received_messages.length(), 2)
  let retried = model.received_messages[1]
  assert_eq(retried.length(), 1)
  assert_true(retried[0] == tk_user_msg("original task"))
  let persisted = store.store["resume-user"]
  assert_eq(persisted.messages.length(), 2)
  assert_true(persisted.messages[0] == tk_user_msg("original task"))
  assert_true(
    persisted.messages[1] is AssistantMessage(content=[Text("resumed"), ..], ..),
  )
}

///|
async test "rate-limit resume appends literal continue after persisted progress" {
  let model = ScriptedModel([Respond(tk_stop_response("continued"))])
  let store = RecordingSessionPort()
  let seeded : Session = {
    messages: [
      tk_user_msg("original task"),
      AssistantMessage(
        content=[Content::Text("partial progress")],
        reasoning=None,
        tool_calls=[],
        finish_reason=Stop,
      ),
    ],
    metadata: Map::from_array([]),
  }
  store.seed("resume-progress", seeded)
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.resume_turn("resume-progress"))
  let request = model.received_messages[0]
  assert_eq(request.length(), 3)
  assert_true(request[2] == tk_user_msg("continue"))
  let persisted = store.store["resume-progress"]
  assert_eq(persisted.messages.length(), 4)
  assert_true(persisted.messages[2] == tk_user_msg("continue"))
  assert_true(
    persisted.messages[3]
    is AssistantMessage(content=[Text("continued"), ..], ..),
  )
}

///|
async test "rate-limit resume after tool progress appends continue" {
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "call_1", Json::null())),
    Fail(
      RateLimited({
        message: "quota after tool progress",
        reset_at_ms: Some(2000L),
        provider_code: Some("429"),
      }),
    ),
    Respond(tk_stop_response("finished")),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo")],
    Map::from_array([("echo", OutcomeOk(tk_ok_result("echoed")))]),
  )
  let store = RecordingSessionPort()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[tools], sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let first = Ok(agent.run_turn(tk_user_msg("do work"), "resume-progress-real")) catch {
    error => Err(error)
  }
  match first {
    Err(Model(msg)) => {
      assert_true(msg.contains("model quota exhausted"))
      assert_true(msg.contains("message=quota after tool progress"))
    }
    _ => fail("expected AgentError::Model carrying the rate-limit verdict")
  }
  let failed = store.store["resume-progress-real"]
  assert_eq(failed.messages.length(), 3)
  assert_true(failed.messages[2] is ToolMessage(..))
  ignore(agent.resume_turn("resume-progress-real"))
  let resumed_request = model.received_messages[2]
  assert_eq(resumed_request.length(), 4)
  assert_true(resumed_request[0] == tk_user_msg("do work"))
  assert_true(resumed_request[3] == tk_user_msg("continue"))
  let persisted = store.store["resume-progress-real"]
  assert_eq(persisted.messages.length(), 5)
  assert_true(
    persisted.messages[4]
    is AssistantMessage(content=[Text("finished"), ..], ..),
  )
}

///|
/// Store whose save fails from the `fail_from`-th call onward, so the
/// failed-turn transcript path can be observed end to end through the public
/// Agent interface.
struct SaveFailingStore {
  mut saves : Int32
  fail_from : Int32
}

///|
impl @port.SessionPort for SaveFailingStore with fn load(_self, _id) -> @types.Session {
  { messages: [], metadata: Map::from_array([]), }
}

///|
impl @port.SessionPort for SaveFailingStore with fn save(self, _id, _session) -> Unit raise @error.SessionError {
  self.saves = self.saves + 1
  if self.saves >= self.fail_from {
    raise Save("store offline")
  }
}

///|
async test "rate-limit failure persists best-effort and reports save failure as secondary" {
  let model = ScriptedModel([
    // Usage on the completed step gives the Puppet a context reading, so the
    // failed turn's terminal save carries changed metadata (a real store
    // write) instead of collapsing into the incremental checkpoints.
    Respond(scope_test_tool_call_with_usage(10)),
    Fail(
      RateLimited({
        message: "quota exhausted",
        reset_at_ms: Some(1000L),
        provider_code: Some("429"),
      }),
    ),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo")],
    Map::from_array([("echo", OutcomeOk(tk_ok_result("echoed")))]),
  )
  let store = SaveFailingStore::{ saves: 0, fail_from: 4, }
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools]),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(
      max_tool_rounds=Some(10),
      model_context_window=Some(1000),
      compact_threshold=Some(0.9),
    ),
  )
  let first = Ok(agent.run_turn(tk_user_msg("original task"), "failed-save")) catch {
    error => Err(error)
  }
  guard first is Err(Model(msg)) else {
    let why = match first {
      Err(e) => e.to_string()
      Ok(_) => "turn completed"
    }
    fail("expected Model error, got \{why}; saves=\{store.saves}")
  }
  assert_true(msg.contains("model quota exhausted"))
  // The failed turn attempted exactly one transcript save against the store
  // (after the admission and per-boundary checkpoint saves).
  assert_eq(store.saves, 4)
  // The save failure stays observable without replacing the primary error.
  let failures = secondary_failure_errors(
    observer, "failed_turn_transcript_save",
  )
  assert_eq(failures.length(), 1)
  assert_true(failures[0].contains("session_id=failed-save"))
  assert_true(failures[0].contains("SessionError::Save"))
}
