///|
using @support {type FakeRuntime}

///|
/// End-to-end contract tests for the public runtime seam: a custom
/// `@runtime.Runtime` plugged into `Agent::with_runtime` receives full
/// effect context, and aborts propagate to its `cancel_effects`.

///|
/// Build an Agent on `Agent::with_runtime` whose model requests one `echo`
/// tool call and then stops. Returns the agent plus the fakes the test
/// asserts on.
fn build_fake_runtime_agent(
  abort_on_tool~ : Bool,
) -> (Agent, FakeRuntime, ScriptedModel) raise @error.CompositionError {
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(tk_stop_response("done")),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(tk_ok_result("echoed")))]),
  )
  let port_runtime = @runtime.PortRuntime(model~)
  let fake = FakeRuntime(port_runtime)
  fake.abort_on_tool = abort_on_tool
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[tools], sessions=[RecordingSessionStore()]),
    ],
    config=tk_config(),
    runtime=fake as &@runtime.Runtime,
  )
  fake.control = Some(agent.control())
  (agent, fake, model)
}

///|
async test "runtime seam/custom runtime receives full effect context" {
  let (agent, fake, model) = build_fake_runtime_agent(abort_on_tool=false)
  let result = agent.run_turn(tk_user_msg("hi"), "session_seam_ctx")
  assert_eq(result.final_session_id, "session_seam_ctx")
  assert_eq(model.call_count(), 2)
  assert_eq(fake.seen_contexts.length(), 1)
  let ctx = fake.seen_contexts[0]
  assert_eq(ctx.call_id.to_string(), "call_1")
  assert_eq(ctx.tool_name.to_string(), "echo")
  // Reducer allocation order: CallModel = effect 1, first ExecuteTool = 2.
  assert_eq(ctx.effect_id.to_int(), 2)
  assert_true(ctx.owner.to_string() != "")
  // Both CallModel effects crossed the seam carrying this run's identity:
  // the session the product passed, one shared run id, and the reducer-
  // allocated effect ids 1 and 3 (ExecuteTool was 2).
  let scopes = fake.seen_scopes
  assert_eq(scopes.length(), 2)
  assert_eq(scopes[0].session_id.to_string(), "session_seam_ctx")
  assert_eq(scopes[0].run_id, scopes[1].run_id)
  assert_eq(scopes.map(fn(s) { s.effect_id.map(fn(id) { id.to_int() }) }), [
    Some(1),
    Some(3),
  ])
}

///|
async test "runtime seam/abort during execution propagates to cancel_effects" {
  let (agent, fake, model) = build_fake_runtime_agent(abort_on_tool=true)
  let result : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(tk_user_msg("hi"), "session_seam_abort"),
  ) catch {
    error => Err(error)
  }
  guard result is Err(@error.AgentError::Cancelled(_)) else {
    fail("expected the cancelled turn to surface as a structured outcome")
  }
  // The abort landed during execute_tool: the pump observed it at the next
  // loop top and went terminal, so the second scripted model step was never
  // consumed.
  assert_eq(model.call_count(), 1)
  // The terminal CancelOutstanding crossed the public seam exactly once. No
  // effects were still outstanding (the tool had already committed), so the
  // cancellation carried an empty id set — the wiring is what is asserted.
  assert_eq(fake.cancel_calls, 1)
  assert_eq(fake.cancel_seen.length(), 1)
  // After the tool batch commits, the next CallModel intent (effect 3) is
  // already declared and pending; the terminal cancel lists exactly that
  // outstanding effect. The host correlates it by id — this is the seam's
  // end-to-end guarantee.
  assert_eq(fake.cancel_seen[0].map(id => id.to_int()), [3])
}

///|
async test "runtime seam/follow-up during turn drives a subsequent turn" {
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(tk_stop_response("first done")),
    Respond(tk_stop_response("follow-up done")),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(tk_ok_result("echoed")))]),
  )
  let port_runtime = @runtime.PortRuntime(model~)
  let fake = FakeRuntime(port_runtime)
  fake.follow_up_on_tool = true
  let store = RecordingSessionStore()
  let observer = RecordingObserver()
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model), tools=[tools], sessions=[store], observers=[
        observer,
      ]),
    ],
    config=tk_config(),
    runtime=fake as &@runtime.Runtime,
  )
  fake.control = Some(agent.control())
  let result = agent.run_turn(tk_user_msg("hi"), "session_seam_followup")
  // The follow-up drained into its own full turn on the same session: three
  // model calls total (tool-call, first stop, follow-up stop), and the
  // returned TurnResult is the follow-up turn's.
  assert_eq(result.final_session_id, "session_seam_followup")
  assert_eq(model.call_count(), 3)
  let mut result_text = ""
  match result.message {
    AssistantMessage(content~, ..) =>
      for block in content {
        match block {
          Text(text) => result_text = text
          _ => ()
        }
      }
    _ => ()
  }
  assert_eq(result_text, "follow-up done")
  // Each drained turn is a real turn boundary for observers.
  let mut started = 0
  let mut completed = 0
  for event in observer.events() {
    match event {
      TurnStarted => started = started + 1
      TurnCompleted => completed = completed + 1
      _ => ()
    }
  }
  assert_eq(started, 2)
  assert_eq(completed, 2)
  // The follow-up message was committed to the session as a user message.
  assert_true(store.store.contains("session_seam_followup"))
  let saved = store.store["session_seam_followup"]
  let mut follow_up_committed = false
  for message in saved.messages {
    match message {
      UserMessage(content~) =>
        for block in content {
          match block {
            Text(text) =>
              if text == "background task finished" {
                follow_up_committed = true
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  assert_true(follow_up_committed)
  // Once every turn has ended there is no active run; a late follow-up is
  // rejected at enqueue time rather than sneaking into a later run.
  assert_true(
    agent.control().enqueue_follow_up(tk_user_msg("too late"))
    is RejectedStale(_),
  )
}

///|
/// Names of the tool definitions the scripted model saw at its n-th call.
fn tool_names_seen(model : ScriptedModel, call : Int32) -> Array[String] {
  model.received_tools[call].map(fn(def) { def.name.to_string() })
}

///|
async test "runtime seam/publication applies at the next operation boundary" {
  let echo = tk_tool_def("echo", "echo tool")
  let web = tk_tool_def("web", "web tool")
  let publisher = ToolPublisher(RecordingToolProvider([echo], Map([])))
  let model = ScriptedModel([
    Respond(tk_stop_response("one")),
    Respond(tk_stop_response("two")),
  ])
  let agent = Agent::with_runtime(
    exts=[tk_ext(id="model", model=Some(model)), publisher],
    config=tk_config(),
    runtime=FakeRuntime(@runtime.PortRuntime(model~)),
  )
  ignore(agent.run_turn(tk_user_msg("one"), "seam-publish"))
  assert_eq(tool_names_seen(model, 0), ["echo"])
  publisher.publish(RecordingToolProvider([echo, web], Map([])))
  ignore(agent.run_turn(tk_user_msg("two"), "seam-publish"))
  assert_eq(tool_names_seen(model, 1), ["echo", "web"])
  agent.shutdown()
}

///|
async test "runtime seam/publication mid-operation preserves captured execution" {
  let echo = tk_tool_def("echo", "echo tool")
  let web = tk_tool_def("web", "web tool")
  let old = RecordingToolProvider(
    [echo],
    Map([("echo", OutcomeOk(tk_ok_result("old")))]),
  )
  let next = RecordingToolProvider(
    [echo, web],
    Map([("echo", OutcomeOk(tk_ok_result("new")))]),
  )
  let publisher = ToolPublisher(old)
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(tk_stop_response("one")),
    Respond(tk_tool_call_response("echo", "call_2", Json::null())),
    Respond(tk_stop_response("two")),
  ])
  let runtime = FakeRuntime(@runtime.PortRuntime(model~))
  runtime.on_first_execute = Some(() => publisher.publish(next))
  let agent = Agent::with_runtime(
    exts=[tk_ext(id="model", model=Some(model)), publisher],
    config=tk_config(),
    runtime~,
  )
  let one = agent.run_turn(tk_user_msg("one"), "seam-captured")
  guard one.tool_results is [Success(content="old", ..)] else {
    fail("captured executor changed mid-operation")
  }
  assert_eq(tool_names_seen(model, 0), ["echo"])
  assert_eq(tool_names_seen(model, 1), ["echo"])
  let two = agent.run_turn(tk_user_msg("two"), "seam-captured")
  guard two.tool_results is [Success(content="new", ..)] else {
    fail("next operation did not adopt executor")
  }
  assert_eq(tool_names_seen(model, 2), ["echo", "web"])
  assert_eq(old.exec_records().length(), 1)
  assert_eq(next.exec_records().length(), 1)
  agent.shutdown()
}

///|
async test "runtime seam/rejected publication retains the last valid group" {
  let echo = tk_tool_def("echo", "echo tool")
  let web = tk_tool_def("web", "web tool")
  let publisher = ToolPublisher(RecordingToolProvider([echo], Map([])))
  let model = ScriptedModel([
    Respond(tk_stop_response("one")),
    Respond(tk_stop_response("two")),
    Respond(tk_stop_response("three")),
  ])
  let agent = Agent::with_runtime(
    exts=[tk_ext(id="model", model=Some(model)), publisher],
    config=tk_config(),
    runtime=FakeRuntime(@runtime.PortRuntime(model~)),
  )
  ignore(agent.run_turn(tk_user_msg("one"), "seam-invalid"))
  assert_eq(tool_names_seen(model, 0), ["echo"])
  let bad = RecordingToolProvider(
    [echo, tk_tool_def("echo", "duplicate")],
    Map([]),
  )
  guard publisher.capability().replace(provider=bad) is Err(@port.Rejected(..)) else {
    fail("collision was accepted")
  }
  assert_eq(publisher.capability().revision(), Some(1))
  ignore(agent.run_turn(tk_user_msg("two"), "seam-invalid"))
  assert_eq(tool_names_seen(model, 1), ["echo"])
  publisher.publish(RecordingToolProvider([echo, web], Map([])))
  ignore(agent.run_turn(tk_user_msg("three"), "seam-invalid"))
  assert_eq(tool_names_seen(model, 2), ["echo", "web"])
  agent.shutdown()
}
