///|
using @support {type FakeRuntime, type ToolPublisher}

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
) -> (Agent, FakeRuntime, @test_support.ScriptedModel) raise @error.CompositionError {
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(@test_support.tk_stop_response("done")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(@test_support.tk_ok_result("echoed")))]),
  )
  let port_runtime = @runtime.PortRuntime(model~)
  let fake = FakeRuntime(port_runtime)
  fake.abort_on_tool = abort_on_tool
  let agent = Agent::with_runtime(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[tools], sessions=[
        @test_support.RecordingSessionPort(),
      ]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
    runtime=fake as &@runtime.Runtime,
  )
  fake.control = Some(agent.control())
  (agent, fake, model)
}

///|
async test "runtime seam/custom runtime receives full effect context" {
  let (agent, fake, model) = build_fake_runtime_agent(abort_on_tool=false)
  let result = agent.run_turn(
    @test_support.tk_user_msg("hi"),
    "session_seam_ctx",
  )
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
    agent.run_turn(@test_support.tk_user_msg("hi"), "session_seam_abort"),
  ) catch {
    error => Err(error)
  }
  guard result is Err(Cancelled(_)) else {
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
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(@test_support.tk_stop_response("first done")),
    Respond(@test_support.tk_stop_response("follow-up done")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(@test_support.tk_ok_result("echoed")))]),
  )
  let port_runtime = @runtime.PortRuntime(model~)
  let fake = FakeRuntime(port_runtime)
  fake.follow_up_on_tool = true
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let agent = Agent::with_runtime(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(model),
        tools=[tools],
        sessions=[store],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
    runtime=fake as &@runtime.Runtime,
  )
  fake.control = Some(agent.control())
  let result = agent.run_turn(
    @test_support.tk_user_msg("hi"),
    "session_seam_followup",
  )
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
    agent.control().enqueue_follow_up(@test_support.tk_user_msg("too late"))
    is RejectedStale(_),
  )
}

///|
/// Names of the tool definitions the scripted model saw at its n-th call.
fn tool_names_seen(
  model : @test_support.ScriptedModel,
  call : Int32,
) -> Array[String] {
  model.received_tools[call].map(fn(def) { def.name.to_string() })
}

///|
async test "runtime seam/publication applies at the next operation boundary" {
  let echo = @test_support.tk_tool_def("echo", "echo tool")
  let web = @test_support.tk_tool_def("web", "web tool")
  let publisher = ToolPublisher(
    @test_support.RecordingToolProvider([echo], Map([])),
  )
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("one")),
    Respond(@test_support.tk_stop_response("two")),
  ])
  let agent = Agent::with_runtime(
    events=EventSystem(),
    exts=[@test_support.tk_ext(id="model", model=Some(model)), publisher],
    config=agent_config(max_tool_rounds=Some(10)),
    runtime=FakeRuntime(@runtime.PortRuntime(model~)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("one"), "seam-publish"))
  assert_eq(tool_names_seen(model, 0), ["echo"])
  publisher.publish(@test_support.RecordingToolProvider([echo, web], Map([])))
  ignore(agent.run_turn(@test_support.tk_user_msg("two"), "seam-publish"))
  assert_eq(tool_names_seen(model, 1), ["echo", "web"])
  agent.shutdown()
}

///|
async test "runtime seam/publication mid-operation preserves captured execution" {
  let echo = @test_support.tk_tool_def("echo", "echo tool")
  let web = @test_support.tk_tool_def("web", "web tool")
  let old = @test_support.RecordingToolProvider(
    [echo],
    Map([("echo", OutcomeOk(@test_support.tk_ok_result("old")))]),
  )
  let next = @test_support.RecordingToolProvider(
    [echo, web],
    Map([("echo", OutcomeOk(@test_support.tk_ok_result("new")))]),
  )
  let publisher = ToolPublisher(old)
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_tool_call_response("echo", "call_1", Json::null())),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("one"),
    ),
    Respond(@test_support.tk_tool_call_response("echo", "call_2", Json::null())),
    Respond(@test_support.tk_stop_response("two")),
  ])
  let runtime = FakeRuntime(@runtime.PortRuntime(model~))
  runtime.on_first_execute = Some(() => publisher.publish(next))
  let agent = Agent::with_runtime(
    events=EventSystem(),
    exts=[@test_support.tk_ext(id="model", model=Some(model)), publisher],
    config=agent_config(max_tool_rounds=Some(10)),
    runtime~,
  )
  let one = agent.run_turn(@test_support.tk_user_msg("one"), "seam-captured")
  guard one.tool_results is [Success(content="old", ..)] else {
    fail("captured executor changed mid-operation")
  }
  assert_eq(tool_names_seen(model, 0), ["echo"])
  assert_eq(tool_names_seen(model, 1), ["echo"])
  let two = agent.run_turn(@test_support.tk_user_msg("two"), "seam-captured")
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
  let echo = @test_support.tk_tool_def("echo", "echo tool")
  let web = @test_support.tk_tool_def("web", "web tool")
  let publisher = ToolPublisher(
    @test_support.RecordingToolProvider([echo], Map([])),
  )
  let model = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("one")),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("two"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("three"),
    ),
  ])
  let agent = Agent::with_runtime(
    events=EventSystem(),
    exts=[@test_support.tk_ext(id="model", model=Some(model)), publisher],
    config=agent_config(max_tool_rounds=Some(10)),
    runtime=FakeRuntime(@runtime.PortRuntime(model~)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("one"), "seam-invalid"))
  assert_eq(tool_names_seen(model, 0), ["echo"])
  let bad = @test_support.RecordingToolProvider(
    [echo, @test_support.tk_tool_def("echo", "duplicate")],
    Map([]),
  )
  guard publisher.capability().replace(provider=bad) is Err(@port.Rejected(..)) else {
    fail("collision was accepted")
  }
  assert_eq(publisher.capability().revision(), Some(1))
  ignore(agent.run_turn(@test_support.tk_user_msg("two"), "seam-invalid"))
  assert_eq(tool_names_seen(model, 1), ["echo"])
  publisher.publish(@test_support.RecordingToolProvider([echo, web], Map([])))
  ignore(agent.run_turn(@test_support.tk_user_msg("three"), "seam-invalid"))
  assert_eq(tool_names_seen(model, 2), ["echo", "web"])
  agent.shutdown()
}

///|
/// Graceful abort must reach an effect WHILE it is executing (model stream in
/// flight, tool wave in flight), not only at safe points between effects:
/// the pump races the effect await against the mailbox abort flag, cancels
/// the effect task, and finalizes through the ordinary CancelRequested path —
/// CancelOutstanding reaches `Runtime::cancel_effects`, the terminal outcome
/// is Cancelled, the committed transcript prefix is still saved, and the
/// Agent accepts the next turn immediately.

///|
/// Runtime decorator that parks the first model call and/or the first call to
/// a named tool in a cancellable pause loop, and records every
/// `cancel_effects` delivery. Parking mirrors a hung SSE read or a long
/// shell command: the await only unwinds when the pump's abort watcher
/// cancels the effect task.
struct MidEffectAbortRuntime {
  inner : &@runtime.Runtime
  park_model : Bool
  park_tool_names : Array[String]
  mut model_parks : Int32
  mut tool_parks : Int32
  cancelled_effect_ids : Array[@kernel.EffectId]
  settled_tool_ids : Map[Int32, Bool]
}

///|
fn MidEffectAbortRuntime::MidEffectAbortRuntime(
  inner~ : &@runtime.Runtime,
  park_model~ : Bool = false,
  park_tool_names~ : Array[String] = [],
) -> MidEffectAbortRuntime {
  {
    inner,
    park_model,
    park_tool_names,
    model_parks: 0,
    tool_parks: 0,
    cancelled_effect_ids: [],
    settled_tool_ids: Map::from_array([]),
  }
}

///|
/// Park the current effect task until the pump cancels it. `pause()` is the
/// cancellation point: the abort watcher's task cancellation raises out of
/// the suspension and the coroutine terminates as cancelled.
async fn park_until_cancelled() -> Unit noraise {
  while !@async.is_being_cancelled() {
    @async.pause()
  }
}

///|
impl @runtime.Runtime for MidEffectAbortRuntime with fn call_model(
  self,
  scope,
  messages,
  tool_definitions,
  call_options,
  on_chunk,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  if self.park_model && self.model_parks == 0 {
    self.model_parks = self.model_parks + 1
    park_until_cancelled()
  }
  self.inner.call_model(
    scope, messages, tool_definitions, call_options, on_chunk,
  )
}

///|
impl @runtime.Runtime for MidEffectAbortRuntime with fn execute_tool(
  self,
  ctx : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  if self.tool_parks == 0 &&
    self.park_tool_names.contains(ctx.tool_name.to_string()) {
    self.tool_parks = self.tool_parks + 1
    // This mock owns only the parked coroutine. Its unwind is the real
    // terminal receipt; no downstream provider has been entered.
    defer {
      self.settled_tool_ids[ctx.effect_id.to_int()] = true
    }
    park_until_cancelled()
  }
  self.inner.execute_tool(ctx)
}

///|
impl @runtime.Runtime for MidEffectAbortRuntime with fn cancel_effects(
  self,
  run_id~,
  effect_ids : Array[@kernel.EffectId],
  _reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  let _ = run_id

  for id in effect_ids {
    self.cancelled_effect_ids.push(id)
  }
  effect_ids.map(id => {
    (
      id,
      if self.settled_tool_ids.contains(id.to_int()) {
        @kernel.Stopped
      } else {
        @kernel.NotPropagated
      },
    )
  })
}

///|
impl @runtime.Runtime for MidEffectAbortRuntime with fn compact(
  self,
  scope,
  messages,
  tools,
  call_options,
  trigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  self.inner.compact(scope, messages, tools, call_options, trigger)
}

///|
async test "abort/mid-model-call: structured Cancelled, cancel_effects delivered, prefix saved, agent reusable" {
  let model = @test_support.ScriptedModel([
    // The parked first call never consumes a step; this serves the turn run
    // after the abort.
    Respond(@test_support.tk_stop_response("after esc")),
  ])
  let store = @test_support.RecordingSessionPort()
  store.seed("abort-model", { messages: [], metadata: Map::from_array([]), })
  let port_runtime = @runtime.PortRuntime(model~)
  let probe = MidEffectAbortRuntime(
    inner=port_runtime as &@runtime.Runtime,
    park_model=true,
  )
  let agent = Agent::with_runtime(
    events=EventSystem(),
    exts=[@test_support.tk_ext(id="model", model=Some(model), sessions=[store])],
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
        agent.run_turn(@test_support.tk_user_msg("long stream"), "abort-model"),
      ) catch {
        e => Err(e)
      }
      outcome.val = r
    })
    while probe.model_parks == 0 {
      @async.pause()
    }
    assert_true(control.abort_active(Some("esc")) is @runtime.Accepted(_))
    ignore(task.wait())
  })
  guard outcome.val is Err(Cancelled(_)) else {
    fail("expected structured Cancelled, got \{repr(outcome.val)}")
  }
  // The pump finalized through CancelOutstanding: the in-flight CallModel
  // effect id reached the runtime's cancellation seam.
  assert_eq(probe.model_parks, 1)
  assert_eq(probe.cancelled_effect_ids.length(), 1)
  // Graceful abort still persists the committed prefix: the user message of
  // the interrupted turn must survive into the session store.
  let saved = store.store["abort-model"]
  assert_eq(saved.messages.length(), 1)
  assert_true(saved.messages[0] == @test_support.tk_user_msg("long stream"))
  // Cancellation ends the operation, not the session.
  let next = agent.run_turn(@test_support.tk_user_msg("next"), "abort-model")
  guard next.message is AssistantMessage(content=[Text("after esc")], ..) else {
    fail("expected the post-abort turn to complete normally")
  }
}

///|
async test "abort/mid-tool-wave: structured Cancelled, tool effect cancelled, interrupted marker saved, agent reusable" {
  let model = @test_support.ScriptedModel([
    Respond(
      @test_support.tk_tool_call_response(
        "slow_tool",
        "call_slow",
        Json::object(Map::from_array([])),
      ),
    ),
    Respond(@test_support.tk_stop_response("after esc")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("slow_tool", "slow tool")],
    Map::from_array([]),
  )
  let store = @test_support.RecordingSessionPort()
  store.seed("abort-tools", { messages: [], metadata: Map::from_array([]), })
  let port_runtime = @runtime.PortRuntime(model~)
  let probe = MidEffectAbortRuntime(inner=port_runtime as &@runtime.Runtime, park_tool_names=[
    "slow_tool",
  ])
  let agent = Agent::with_runtime(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model), sessions=[store]),
      // The catalog must know the tool (manifest contribution); execution
      // still routes through the runtime override below.
      @test_support.tk_ext(id="tools", tools=[tools]),
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
          @test_support.tk_user_msg("run the slow tool"),
          "abort-tools",
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
  assert_eq(probe.cancelled_effect_ids.length(), 1)
  // The saved transcript keeps the user message, the assistant's tool call,
  // and the reducer's interrupted marker for the cancelled tool — never a
  // fabricated success.
  let saved = store.store["abort-tools"]
  assert_eq(saved.messages.length(), 3)
  assert_true(
    saved.messages[0] == @test_support.tk_user_msg("run the slow tool"),
  )
  guard saved.messages[1] is AssistantMessage(..) else {
    fail("expected assistant tool-call message")
  }
  guard saved.messages[2] is ToolMessage(call_id~, outcome~, ..) else {
    fail("expected a tool message for the cancelled tool")
  }
  assert_eq(call_id.to_string(), "call_slow")
  guard outcome is RuntimeFailure(..) else {
    fail("expected interrupted marker for the cancelled tool")
  }
  let next = agent.run_turn(@test_support.tk_user_msg("next"), "abort-tools")
  guard next.message is AssistantMessage(content=[Text("after esc")], ..) else {
    fail("expected the post-abort turn to complete normally")
  }
  // A late abort for the finished run is stale, not accepted.
  assert_true(
    control.abort_active(Some("late esc")) is @runtime.RejectedStale(_),
  )
}
