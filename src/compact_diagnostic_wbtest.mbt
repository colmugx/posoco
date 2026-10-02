///|
/// Compact failure reporting (provider-independent).
///
/// A failed modelport compact surfaces the `ModelFailure` category plus the
/// adapter's opaque safe label through the nested PuppetError → AgentError →
/// command-outcome formatting. The label is relayed intact up to the
/// 352-character budget and every outer rendering keeps its cause under the
/// user-approved 512-character error display. Core never interprets the
/// label text: quoting, `k=v` lookalikes, and non-ASCII content stay inert
/// characters in their original order, content beyond the relay budget
/// cannot resurface, a plain reason falls back to the same rendering,
/// cancellation stays a distinct structured outcome, and a failed compact
/// commits nothing.

///|
/// A generic failure label whose head mixes quoting, parentheses, `k=v`
/// lookalikes and non-ASCII text, followed by a payload tail pushed beyond
/// the 352-character relay budget. Nothing in it may be interpreted as
/// structure, the head must reach every outcome verbatim and in order, and
/// the far tail must not survive any layer.
let compact_generic_failure : String = "adapter verdict (\"引文 (含, 逗号)\" , stage=假, status=503)" +
  " payload " +
  "m".repeat(300) +
  "FAR_TAIL_SECRET"

///|
/// A label region past the head but within the 352-character relay budget:
/// it must survive every layer even though it lies beyond the kernel's
/// 64-character display truncation.
let compact_generic_kept_region : String = " payload " + "m".repeat(80)

///|
/// A plain reason with no envelope shape at all — the fallback rendering.
const COMPACT_PLAIN_FAILURE : String = "compact endpoint unavailable"

///|
fn compact_diag_failure_agent(
  steps : Array[ScriptedModelStep],
  observer~ : RecordingObserver,
  session_id~ : String,
) -> Agent raise {
  let model = ScriptedModel(steps)
  let store = RecordingSessionStore()
  store.seed(session_id, {
    messages: [tk_user_msg("secret prompt")],
    metadata: Map::from_array([]),
  })
  Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
}

///|
fn compact_diag_builtin_compact(agent : Agent) -> &@port.CommandPort raise {
  for port in agent.commands() {
    for def in port.commands() {
      if def.id == "compact" {
        return port
      }
    }
  }
  fail("expected the builtin compact command to be declared")
}

///|
async test "compact_diag/idle_compact_command_failure_forwards_bounded_label" {
  let observer = RecordingObserver()
  let agent = compact_diag_failure_agent(
    [CompactFail(error=Transport(compact_generic_failure))],
    observer~,
    session_id="diag-cmd",
  )
  let port = compact_diag_builtin_compact(agent)
  let outcome = port.invoke(
    "compact",
    Json::object(Map::from_array([("session_id", Json::string("diag-cmd"))])),
  )
  guard outcome is Failure(reason~) else {
    fail(
      "expected the failed compact to report a failure, got \{repr(outcome)}",
    )
  }
  assert_true(reason.contains("compact failed"))
  assert_true(reason.contains("compact_session"))
  // Category plus the opaque label survive the nested formatting: the head
  // verbatim and in order, the within-budget label region intact.
  assert_true(reason.contains("ModelFailure::Transport"))
  assert_true(
    reason.contains(
      "adapter verdict (\"引文 (含, 逗号)\" , stage=假, status=503)",
    ),
  )
  assert_true(reason.contains(compact_generic_kept_region))
  // The head is inert label text, not an interpreted schema, and the tail
  // beyond the relay budget is capped out.
  assert_false(reason.contains("FAR_TAIL_SECRET"))
  assert_true(reason.contains("...(truncated)"))
  // Bounded by the user-approved 512-character outer display plus the fixed
  // command prefix and the truncation marker.
  assert_true(
    reason.length() <=
    512 + "compact failed: ".length() + "...(truncated)".length(),
  )
}

///|
async test "compact_diag/standalone_compact_failure_detail_and_no_commit" {
  let model = ScriptedModel([
    CompactFail(error=Transport(compact_generic_failure)),
  ])
  let store = RecordingSessionStore()
  store.seed("diag-detail", {
    messages: [tk_user_msg("seeded")],
    metadata: Map::from_array([]),
  })
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model), sessions=[store], observers=[
        observer,
      ]),
    ],
    config=tk_config(),
  )
  let outcome : Result[@types.CompactOutcome, @error.AgentError] = Ok(
    agent.compact_session("diag-detail"),
  ) catch {
    e => Err(e)
  }
  guard outcome is Err(Runtime(InvocationFailed(detail))) else {
    let why = match outcome {
      Err(e) => e.to_string()
      Ok(_) => "compact succeeded"
    }
    fail("expected a typed Runtime failure, got \{why}")
  }
  assert_true(detail.contains("puppet rejected the compact"))
  assert_true(detail.contains("compact_session"))
  assert_true(detail.contains("ModelFailure::Transport"))
  assert_true(detail.contains("stage=假"))
  assert_true(detail.contains("m".repeat(80)))
  assert_false(detail.contains("FAR_TAIL_SECRET"))
  // Bounded by the user-approved 512-character outer display plus its fixed
  // prefix.
  assert_true(detail.length() <= 512 + "puppet rejected the compact: ".length())
  let mut failed_detail = ""
  for event in observer.events() {
    match event {
      OperationFinalized(operation~, outcome~, detail=d) =>
        if operation == "compact" && outcome == "failed" {
          failed_detail = d
        }
      _ => ()
    }
  }
  assert_true(failed_detail.contains("ModelFailure::Transport"))
  assert_true(failed_detail.contains(compact_generic_kept_region))
  assert_false(failed_detail.contains("FAR_TAIL_SECRET"))
  // A failed compact commits nothing: the stored window is untouched.
  assert_eq(store.store["diag-detail"].messages.length(), 1)
  assert_true(store.store["diag-detail"].messages[0] == tk_user_msg("seeded"))
}

///|
async test "compact_diag/plain_failure_fallback_renders_verbatim" {
  let observer = RecordingObserver()
  let agent = compact_diag_failure_agent(
    [CompactFail(error=Transport(COMPACT_PLAIN_FAILURE))],
    observer~,
    session_id="diag-fallback",
  )
  let port = compact_diag_builtin_compact(agent)
  let outcome = port.invoke(
    "compact",
    Json::object(
      Map::from_array([("session_id", Json::string("diag-fallback"))]),
    ),
  )
  guard outcome is Failure(reason~) else {
    fail("expected the failed compact to report a failure")
  }
  // A short plain reason passes every layer without truncation or
  // restructuring: the fallback rendering is the display rendering.
  assert_true(
    reason.contains("ModelFailure::Transport(compact endpoint unavailable)"),
  )
  assert_false(reason.contains("...(truncated)"))
}

///|
/// Model fake that reports a fixed context window (so auto-compact fires on
/// the usage reading) and fails every compaction with a generic failure.
struct AutoCompactFailModel {
  scripted : ScriptedModel
  reported : @port.ProviderConfig
}

///|
fn AutoCompactFailModel::make(
  steps : Array[ScriptedModelStep],
) -> AutoCompactFailModel {
  {
    scripted: ScriptedModel(steps),
    reported: policy_reported(
      context_window=Some(100),
      compact_threshold=Some(0.9),
    ),
  }
}

///|
impl @port.ModelPort for AutoCompactFailModel with fn chat(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : @types.ChatOptions,
  stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  (self.scripted as &@port.ModelPort).chat(
    scope, messages, tools, options, stream,
  )
}

///|
impl @port.ModelPort for AutoCompactFailModel with fn compact(
  _self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  raise Transport(compact_generic_failure)
}

///|
impl @port.ModelPort for AutoCompactFailModel with fn provider_config(self) -> @port.ProviderConfig {
  self.reported
}

///|
async test "compact_diag/auto_compact_failure_forwards_bounded_label" {
  let model = AutoCompactFailModel::make([
    Respond(scope_test_tool_call_with_usage(95)),
  ])
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[policy_tools()]),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let result : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(tk_user_msg("hi"), "diag-auto"),
  ) catch {
    e => Err(e)
  }
  guard result is Err(AutoCompactFailed(cause)) else {
    let why = match result {
      Err(e) => e.to_string()
      Ok(_) => "turn completed"
    }
    fail("expected a typed AutoCompactFailed outcome, got \{why}")
  }
  assert_true(cause.contains("phase=compact"))
  assert_true(cause.contains("ModelFailure::Transport"))
  assert_true(cause.contains("stage=假"))
  assert_true(cause.contains(compact_generic_kept_region))
  assert_false(cause.contains("FAR_TAIL_SECRET"))
}

///|
/// Runtime decorator that parks the first model call until released, so the
/// test can enqueue a manual compact while the run is active.
struct MidRunCompactRuntime {
  inner : &@runtime.Runtime
  mut model_calls : Int
  mut release : Bool
}

///|
impl @runtime.Runtime for MidRunCompactRuntime with fn call_model(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tool_definitions : Array[@kernel.ToolDef],
  call_options : Json,
  on_chunk : ((@types.StreamChunk) -> Unit)?,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  self.model_calls = self.model_calls + 1
  while !self.release {
    @async.pause()
  }
  self.inner.call_model(
    scope, messages, tool_definitions, call_options, on_chunk,
  )
}

///|
impl @runtime.Runtime for MidRunCompactRuntime with fn execute_tool(
  self,
  ctx : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  self.inner.execute_tool(ctx)
}

///|
impl @runtime.Runtime for MidRunCompactRuntime with fn cancel_effects(
  self,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  self.inner.cancel_effects(effect_ids, reason)
}

///|
impl @runtime.Runtime for MidRunCompactRuntime with fn compact(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  call_options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  self.inner.compact(scope, messages, tools, call_options, trigger)
}

///|
async test "compact_diag/midrun_manual_compact_failure_forwards_bounded_label" {
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "call_1", Json::null())),
    CompactFail(error=Transport(compact_generic_failure)),
    Respond(tk_stop_response("done")),
  ])
  let tools = policy_tools()
  let store = RecordingSessionStore()
  let port_runtime = @runtime.PortRuntime(
    model~,
    tools=Map::from_array([("echo", tools as &@port.ToolProvider)]),
  )
  let probe = MidRunCompactRuntime::{
    inner: port_runtime as &@runtime.Runtime,
    model_calls: 0,
    release: false,
  }
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tools]),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
    runtime=probe as &@runtime.Runtime,
  )
  let outcome : Ref[Result[@types.TurnResult, @error.AgentError]] = Ref(
    Err(Runtime(InvocationFailed("unset"))),
  )
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      let r : Result[@types.TurnResult, @error.AgentError] = Ok(
        agent.run_turn(tk_user_msg("hi"), "diag-midrun"),
      ) catch {
        e => Err(e)
      }
      outcome.val = r
    })
    // Once the model call is parked the run is active, so `/compact` takes
    // the in-run enqueue path instead of the idle compact path.
    while probe.model_calls == 0 {
      @async.pause()
    }
    let port = compact_diag_builtin_compact(agent)
    let queued = port.invoke("compact", Json::null())
    assert_true(queued is Success(..))
    probe.release = true
    ignore(task.wait())
  })
  guard outcome.val is Err(Runtime(InvocationFailed(msg))) else {
    let why = match outcome.val {
      Err(e) => e.to_string()
      Ok(_) => "turn completed"
    }
    fail("expected the failed in-run compact to fail the turn, got \{why}")
  }
  assert_true(msg.contains("compact"))
  assert_true(msg.contains("ModelFailure::Transport"))
  assert_true(msg.contains("stage=假"))
  assert_true(msg.contains(compact_generic_kept_region))
  assert_false(msg.contains("FAR_TAIL_SECRET"))
}

///|
/// Runtime decorator whose compact parks until the enclosing task is
/// cancelled, mirroring a hung provider compact connection.
struct CompactParkingRuntime {
  inner : &@runtime.Runtime
  mut compact_calls : Int
}

///|
impl @runtime.Runtime for CompactParkingRuntime with fn call_model(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tool_definitions : Array[@kernel.ToolDef],
  call_options : Json,
  on_chunk : ((@types.StreamChunk) -> Unit)?,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  self.inner.call_model(
    scope, messages, tool_definitions, call_options, on_chunk,
  )
}

///|
impl @runtime.Runtime for CompactParkingRuntime with fn execute_tool(
  self,
  ctx : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  self.inner.execute_tool(ctx)
}

///|
impl @runtime.Runtime for CompactParkingRuntime with fn cancel_effects(
  self,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  self.inner.cancel_effects(effect_ids, reason)
}

///|
impl @runtime.Runtime for CompactParkingRuntime with fn compact(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  call_options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  self.compact_calls = self.compact_calls + 1
  if self.compact_calls == 1 {
    while !@async.is_being_cancelled() {
      @async.pause()
    }
    raise @error.ModelError::Transport(
      "parked compact resumed without cancellation",
    )
  }
  self.inner.compact(scope, messages, tools, call_options, trigger)
}

///|
async test "compact_diag/cancelled_compact_stays_a_cancelled_outcome" {
  let model = ScriptedModel([
    Compact(result={
      compacted_messages: [tk_user_msg("summary")],
      mode: Replace,
    }),
    Respond(tk_stop_response("after retry")),
  ])
  let store = RecordingSessionStore()
  store.seed("diag-cancel", {
    messages: [tk_user_msg("seeded")],
    metadata: Map::from_array([]),
  })
  let observer = RecordingObserver()
  let port_runtime = @runtime.PortRuntime(model~, tools=Map::from_array([]))
  let probe = CompactParkingRuntime::{
    inner: port_runtime as &@runtime.Runtime,
    compact_calls: 0,
  }
  let agent = Agent::with_runtime(
    exts=[
      tk_ext(id="model", model=Some(model), sessions=[store], observers=[
        observer,
      ]),
    ],
    config=tk_config(),
    runtime=probe as &@runtime.Runtime,
  )
  let outcome : Ref[Result[@types.CompactOutcome, @error.AgentError]] = Ref(
    Err(Runtime(InvocationFailed("unset"))),
  )
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      let r : Result[@types.CompactOutcome, @error.AgentError] = Ok(
        agent.compact_session("diag-cancel"),
      ) catch {
        e => Err(e)
      }
      outcome.val = r
    })
    while probe.compact_calls == 0 {
      @async.pause()
    }
    task.cancel()
  })
  guard outcome.val is Err(Cancelled(msg)) else {
    let why = match outcome.val {
      Err(e) => e.to_string()
      Ok(_) => "compact completed"
    }
    fail("expected a structured Cancelled outcome, got \{why}")
  }
  assert_eq(msg, "compact cancelled")
  for event in observer.events() {
    match event {
      OperationFinalized(operation~, outcome~, ..) =>
        if operation == "compact" && outcome == "failed" {
          fail("a cancelled compact must not be reported as failed")
        }
      _ => ()
    }
  }
  // The committed window is untouched by the cancelled compact.
  assert_eq(store.store["diag-cancel"].messages.length(), 1)
  assert_true(store.store["diag-cancel"].messages[0] == tk_user_msg("seeded"))
  // W4: cancellation ends the operation, not the session — the same Agent
  // and session accept a retry compact immediately.
  let retried = agent.compact_session("diag-cancel")
  assert_true(retried.mode is Replace)
  assert_eq(retried.messages_after, 1)
  assert_true(store.store["diag-cancel"].messages[0] == tk_user_msg("summary"))
  // …and an ordinary turn still runs on the same session afterwards.
  let turn = agent.run_turn(tk_user_msg("next"), "diag-cancel")
  guard turn.message is AssistantMessage(content=[Text("after retry")], ..) else {
    fail("expected the post-retry turn to complete normally")
  }
}

///|
async test "compact_diag/busy_agent_rejects_compact_and_stays_usable" {
  let model = ScriptedModel([
    Respond(tk_stop_response("done")),
    Compact(result={
      compacted_messages: [tk_user_msg("summary")],
      mode: Replace,
    }),
  ])
  let store = RecordingSessionStore()
  store.seed("diag-busy", {
    messages: [tk_user_msg("seeded")],
    metadata: Map::from_array([]),
  })
  let port_runtime = @runtime.PortRuntime(model~, tools=Map::from_array([]))
  let probe = MidRunCompactRuntime::{
    inner: port_runtime as &@runtime.Runtime,
    model_calls: 0,
    release: false,
  }
  let agent = Agent::with_runtime(
    exts=[tk_ext(id="model", model=Some(model), sessions=[store])],
    config=tk_config(),
    runtime=probe as &@runtime.Runtime,
  )
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      agent.run_turn(tk_user_msg("hi"), "diag-busy")
    })
    while probe.model_calls == 0 {
      @async.pause()
    }
    let attempted : Result[@types.CompactOutcome, @error.AgentError] = Ok(
      agent.compact_session("diag-busy"),
    ) catch {
      e => Err(e)
    }
    guard attempted is Err(Runtime(InvocationFailed(reason))) else {
      let why = match attempted {
        Err(e) => e.to_string()
        Ok(_) => "compact succeeded"
      }
      fail("expected the busy compact to be rejected, got \{why}")
    }
    assert_true(reason.contains("agent turn busy"))
    probe.release = true
    ignore(task.wait())
  })
  // After the run ends the same session accepts a compact.
  let retried = agent.compact_session("diag-busy")
  assert_true(retried.mode is Replace)
}
