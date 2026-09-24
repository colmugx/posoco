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
  mut model_parks : Int
  mut tool_parks : Int
  cancelled_effect_ids : Array[@kernel.EffectId]
}

///|
fn MidEffectAbortRuntime::MidEffectAbortRuntime(
  inner~ : &@runtime.Runtime,
  park_model? : Bool = false,
  park_tool_names? : Array[String] = [],
) -> MidEffectAbortRuntime {
  {
    inner,
    park_model,
    park_tool_names,
    model_parks: 0,
    tool_parks: 0,
    cancelled_effect_ids: [],
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
    park_until_cancelled()
  }
  self.inner.execute_tool(ctx)
}

///|
impl @runtime.Runtime for MidEffectAbortRuntime with fn cancel_effects(
  self,
  effect_ids : Array[@kernel.EffectId],
  _reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  for id in effect_ids {
    self.cancelled_effect_ids.push(id)
  }
  effect_ids.map(id => (id, @kernel.NotPropagated))
}

///|
impl @runtime.Runtime for MidEffectAbortRuntime with fn compact(
  self,
  scope,
  messages,
  call_options,
  trigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  self.inner.compact(scope, messages, call_options, trigger)
}

///|
async test "abort/mid-model-call: structured Cancelled, cancel_effects delivered, prefix saved, agent reusable" {
  let model = ScriptedModel([
    // The parked first call never consumes a step; this serves the turn run
    // after the abort.
    Respond(tk_stop_response("after esc")),
  ])
  let store = RecordingSessionStore()
  store.seed("abort-model", { messages: [], metadata: Map::from_array([]), })
  let port_runtime = @runtime.PortRuntime(model~, tools=Map::from_array([]))
  let probe = MidEffectAbortRuntime(
    inner=port_runtime as &@runtime.Runtime,
    park_model=true,
  )
  let agent = Agent::with_runtime(
    exts=[tk_ext(id="model", model=Some(model), sessions=[store])],
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
        agent.run_turn(tk_user_msg("long stream"), "abort-model"),
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
  guard outcome.val is Err(@error.AgentError::Cancelled(_)) else {
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
  assert_true(saved.messages[0] == tk_user_msg("long stream"))
  // Cancellation ends the operation, not the session.
  let next = agent.run_turn(tk_user_msg("next"), "abort-model")
  guard next.message is AssistantMessage(content=[Text("after esc")], ..) else {
    fail("expected the post-abort turn to complete normally")
  }
}

///|
async test "abort/mid-tool-wave: structured Cancelled, tool effect cancelled, interrupted marker saved, agent reusable" {
  let model = ScriptedModel([
    Respond(
      tk_tool_call_response(
        "slow_tool",
        "call_slow",
        Json::object(Map::from_array([])),
      ),
    ),
    Respond(tk_stop_response("after esc")),
  ])
  let tools = RecordingToolProvider(
    [tk_tool_def("slow_tool", "slow tool")],
    Map::from_array([]),
  )
  let store = RecordingSessionStore()
  store.seed("abort-tools", { messages: [], metadata: Map::from_array([]), })
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
      // The catalog must know the tool (manifest contribution); execution
      // still routes through the runtime override below.
      tk_ext(id="tools", tools=[tools]),
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
        agent.run_turn(tk_user_msg("run the slow tool"), "abort-tools"),
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
  assert_eq(probe.cancelled_effect_ids.length(), 1)
  // The saved transcript keeps the user message, the assistant's tool call,
  // and the reducer's interrupted marker for the cancelled tool — never a
  // fabricated success.
  let saved = store.store["abort-tools"]
  assert_eq(saved.messages.length(), 3)
  assert_true(saved.messages[0] == tk_user_msg("run the slow tool"))
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
  let next = agent.run_turn(tk_user_msg("next"), "abort-tools")
  guard next.message is AssistantMessage(content=[Text("after esc")], ..) else {
    fail("expected the post-abort turn to complete normally")
  }
  // A late abort for the finished run is stale, not accepted.
  assert_true(
    control.abort_active(Some("late esc")) is @runtime.RejectedStale(_),
  )
}
