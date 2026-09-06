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
  let store = RecordingSessionStore()
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
  assert_true(first is Err(_))
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
  let store = RecordingSessionStore()
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
  let store = RecordingSessionStore()
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
  assert_true(first is Err(_))
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
