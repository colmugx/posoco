///|
/// End-to-end contract tests for the public runtime seam: a custom
/// `@runtime.Runtime` plugged into `Agent::with_runtime` receives full
/// effect context, and aborts propagate to its `cancel_effects`.

///|
/// Custom-runtime fake: wraps a `PortRuntime` and records what crosses the
/// public seam (effect contexts, cancel calls). `control` is wired after
/// Agent construction so `execute_tool` can abort mid-run.
priv struct FakeRuntime {
  inner : @runtime.PortRuntime
  seen_contexts : Array[@runtime.EffectContext]
  seen_scopes : Array[@kernel.InvocationScope]
  mut cancel_calls : Int
  cancel_seen : Array[Array[@kernel.EffectId]]
  mut control : @runtime.RuntimeControl?
  mut abort_on_tool : Bool
  mut follow_up_on_tool : Bool
  mut follow_up_sent : Bool
  /// One-shot hook fired inside the first `execute_tool` — lets a test
  /// mutate external state (e.g. a CatalogSource) mid-run.
  mut on_first_execute : (() -> Unit)?
}

///|
fn FakeRuntime::FakeRuntime(inner : @runtime.PortRuntime) -> FakeRuntime {
  {
    inner,
    seen_contexts: [],
    seen_scopes: [],
    cancel_calls: 0,
    cancel_seen: [],
    control: None,
    abort_on_tool: false,
    follow_up_on_tool: false,
    follow_up_sent: false,
    on_first_execute: None,
  }
}

///|
impl @runtime.Runtime for FakeRuntime with fn call_model(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tool_definitions : Array[@kernel.ToolDef],
  call_options : Json,
  on_chunk : ((@types.StreamChunk) -> Unit)?,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  self.seen_scopes.push(scope)
  return self.inner.call_model(
    scope, messages, tool_definitions, call_options, on_chunk,
  )
}

///|
impl @runtime.Runtime for FakeRuntime with fn execute_tool(
  self,
  ctx : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  self.seen_contexts.push(ctx)
  match self.on_first_execute {
    Some(hook) => {
      self.on_first_execute = None
      hook()
    }
    None => ()
  }
  if self.abort_on_tool {
    match self.control {
      Some(control) => ignore(control.abort_active(Some("fake runtime abort")))
      None => ()
    }
  }
  if self.follow_up_on_tool && !self.follow_up_sent {
    self.follow_up_sent = true
    match self.control {
      Some(control) =>
        ignore(
          control.enqueue_follow_up(
            @kernel.UserMessage(content=[
              @kernel.Text("background task finished"),
            ]),
          ),
        )
      None => ()
    }
  }
  self.inner.execute_tool(ctx)
}

///|
impl @runtime.Runtime for FakeRuntime with fn cancel_effects(
  self,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  self.cancel_calls = self.cancel_calls + 1
  self.cancel_seen.push(effect_ids.copy())
  self.inner.cancel_effects(effect_ids, reason)
}

///|
impl @runtime.Runtime for FakeRuntime with fn compact(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  call_options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  self.inner.compact(scope, messages, call_options, trigger)
}

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
    Map::from_array([
      ("echo", ScriptedToolOutcome::OutcomeOk(tk_ok_result("echoed"))),
    ]),
  )
  let port_runtime = @runtime.PortRuntime(
    model~,
    tools=Map::from_array([("echo", tools as &@port.ToolProvider)]),
  )
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
  let result = agent.run_turn(tk_user_msg("hi"), "session_seam_abort")
  assert_eq(result.final_session_id, "session_seam_abort")
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
    Map::from_array([
      ("echo", ScriptedToolOutcome::OutcomeOk(tk_ok_result("echoed"))),
    ]),
  )
  let port_runtime = @runtime.PortRuntime(
    model~,
    tools=Map::from_array([("echo", tools as &@port.ToolProvider)]),
  )
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
    @kernel.AssistantMessage(content~, ..) =>
      for block in content {
        match block {
          @kernel.Text(text) => result_text = text
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
      @types.TurnStarted => started = started + 1
      @types.TurnCompleted => completed = completed + 1
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
      @kernel.UserMessage(content~) =>
        for block in content {
          match block {
            @kernel.Text(text) =>
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
    is @runtime.RejectedStale(_),
  )
}

///|
/// Versioned catalog fake: the test bumps `revision` and replaces `defs`
/// wholesale to simulate dynamic tool registration.
priv struct FakeCatalogSource {
  mut revision : Int
  mut defs : Array[@kernel.ToolDef]
}

///|
fn FakeCatalogSource::FakeCatalogSource(
  defs : Array[@kernel.ToolDef],
) -> FakeCatalogSource {
  { revision: 1, defs }
}

///|
impl @runtime.CatalogSource for FakeCatalogSource with fn revision(self) -> Int {
  self.revision
}

///|
impl @runtime.CatalogSource for FakeCatalogSource with fn tools(self) -> Array[
  @kernel.ToolDef,
] {
  self.defs
}

///|
/// Names of the tool definitions the scripted model saw at its n-th call.
fn tool_names_seen(model : ScriptedModel, call : Int) -> Array[String] {
  model.received_tools[call].map(fn(def) { def.name.to_string() })
}

///|
async test "runtime seam/catalog refresh applies at the next prompt boundary" {
  let echo_def = tk_tool_def("echo", "echo tool")
  let web_def = tk_tool_def("web", "web tool")
  let model = ScriptedModel([
    Respond(tk_stop_response("turn one")),
    Respond(tk_stop_response("turn two")),
  ])
  let source = FakeCatalogSource([echo_def])
  let port_runtime = @runtime.PortRuntime(model~, tools=Map::from_array([]))
  let fake = FakeRuntime(port_runtime)
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model), sessions=[RecordingSessionStore()]),
    ],
    config=tk_config(),
    runtime=fake as &@runtime.Runtime,
    catalog_source=source as &@runtime.CatalogSource,
  )
  ignore(agent.run_turn(tk_user_msg("one"), "session_seam_catalog"))
  assert_eq(tool_names_seen(model, 0), ["echo"])
  // The host registers a new tool between turns; the revision change
  // triggers exactly one rebuild at the next prompt boundary.
  source.defs = [echo_def, web_def]
  source.revision = 2
  ignore(agent.run_turn(tk_user_msg("two"), "session_seam_catalog"))
  assert_eq(tool_names_seen(model, 1), ["echo", "web"])
}

///|
async test "runtime seam/catalog change mid-run does not disturb the active run" {
  let echo_def = tk_tool_def("echo", "echo tool")
  let web_def = tk_tool_def("web", "web tool")
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "call_1", Json::null())),
    Respond(tk_stop_response("turn one")),
    Respond(tk_stop_response("turn two")),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("echo", "echo tool")],
    Map::from_array([
      ("echo", ScriptedToolOutcome::OutcomeOk(tk_ok_result("echoed"))),
    ]),
  )
  let source = FakeCatalogSource([echo_def])
  let port_runtime = @runtime.PortRuntime(
    model~,
    tools=Map::from_array([("echo", tools as &@port.ToolProvider)]),
  )
  let fake = FakeRuntime(port_runtime)
  // The host's tool set changes while the run is executing a tool.
  fake.on_first_execute = Some(fn() {
    source.defs = [echo_def, web_def]
    source.revision = 2
  })
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model), tools=[tools], sessions=[
        RecordingSessionStore(),
      ]),
    ],
    config=tk_config(),
    runtime=fake as &@runtime.Runtime,
    catalog_source=source as &@runtime.CatalogSource,
  )
  ignore(agent.run_turn(tk_user_msg("one"), "session_seam_catalog_midrun"))
  // Both model calls of the first run — including the one AFTER the
  // mid-run change — saw the snapshot the run started with.
  assert_eq(tool_names_seen(model, 0), ["echo"])
  assert_eq(tool_names_seen(model, 1), ["echo"])
  // The next run picks up the refreshed catalog.
  ignore(agent.run_turn(tk_user_msg("two"), "session_seam_catalog_midrun"))
  assert_eq(tool_names_seen(model, 2), ["echo", "web"])
}

///|
async test "runtime seam/invalid catalog rebuild keeps the previous snapshot" {
  let echo_def = tk_tool_def("echo", "echo tool")
  let web_def = tk_tool_def("web", "web tool")
  let model = ScriptedModel([
    Respond(tk_stop_response("one")),
    Respond(tk_stop_response("two")),
    Respond(tk_stop_response("three")),
  ])
  let source = FakeCatalogSource([echo_def])
  let observer = RecordingObserver()
  let port_runtime = @runtime.PortRuntime(model~, tools=Map::from_array([]))
  let fake = FakeRuntime(port_runtime)
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(
        id="model",
        model=Some(model),
        sessions=[RecordingSessionStore()],
        observers=[observer],
      ),
    ],
    config=tk_config(),
    runtime=fake as &@runtime.Runtime,
    catalog_source=source as &@runtime.CatalogSource,
  )
  ignore(agent.run_turn(tk_user_msg("one"), "session_seam_catalog_bad"))
  assert_eq(tool_names_seen(model, 0), ["echo"])
  // A colliding definition set fails catalog validation: the previous
  // snapshot stays in effect and the turn still completes.
  source.defs = [echo_def, tk_tool_def("echo", "duplicate echo")]
  source.revision = 2
  ignore(agent.run_turn(tk_user_msg("two"), "session_seam_catalog_bad"))
  assert_eq(tool_names_seen(model, 1), ["echo"])
  let mut saw_refresh_failure = false
  for event in observer.events() {
    match event {
      @types.Custom(source=event_source, label~, data~) =>
        if event_source == "posoco.core" && label == "secondary_failure" {
          match data {
            Json::Object(fields) =>
              match fields.get("hook_point") {
                Some(Json::String(point)) if point == "catalog_refresh" =>
                  saw_refresh_failure = true
                _ => ()
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  assert_true(saw_refresh_failure)
  // The failed revision was attempted exactly once; fixing the definitions
  // under a new revision refreshes successfully.
  source.defs = [echo_def, web_def]
  source.revision = 3
  ignore(agent.run_turn(tk_user_msg("three"), "session_seam_catalog_bad"))
  assert_eq(tool_names_seen(model, 2), ["echo", "web"])
}
