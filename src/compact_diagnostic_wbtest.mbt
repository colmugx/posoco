///|
/// Compact-diagnostic preservation (openai-compact-repair W1).
///
/// A provider compact rejection carries its safe essentials (HTTP status,
/// provider code/param, request id) in the head of the modelport error
/// message. These tests pin that those fields survive the nested
/// PuppetError → AgentError → command-outcome formatting in bounded form,
/// while quoted excerpt content and malformed structures fall back to the
/// pre-existing bounded rendering.

///|
/// The adapter's exact HTTP-error format (posoco_ext_openai.mbt:195), with
/// the W3-planned provider-error fields appended inside the envelope.
const COMPACT_PROVIDER_ERROR : String = "OpenAI HTTP error (stage=http_status, status=400, body_bytes=9312, body_category=utf8, body_excerpt=\"This model's maximum context length is 8192 tokens. However, your messages resulted in 9001 tokens. TRANSCRIPT_ECHO user said: secret prompt encrypted_content=AAAA\", code=context_length_exceeded, param=input, request_id=req_diag_0001)"

///|
/// Hostile variant: the quoted body excerpt carries parentheses and metadata
/// lookalikes that must never be parsed as diagnostic fields.
const COMPACT_HOSTILE_EXCERPT_ERROR : String = "OpenAI HTTP error (stage=http_status, status=400, body_bytes=64, body_category=utf8, body_excerpt=\"rejected (see: status=500 code=fake_from_body req=fake_body_id) TRANSCRIPT_ECHO secret prompt\", code=real_code, param=real_param, request_id=real_req_1)"

///|
/// The adapter's exact compact parse-failure format (convert.mbt).
const COMPACT_PARSE_FAILURE_ERROR : String = "OpenAI compact parse failure (stage=output, category=missing_output)"

///|
/// The adapter's exact transport-failure format (posoco_ext_openai.mbt:706),
/// with the free-text host-error suffix the envelope parser must ignore.
const COMPACT_TRANSPORT_ERROR : String = "OpenAI transport failure (stage=read_response): IO timeout while reading response body (status=600 code=fake_from_body request_id=fake_id)"

///|
/// B1: raw quote/backslash injection through the interpolated excerpt; the
/// escaped quote stays inside the quoted value, so nothing spoofs fields.
const COMPACT_QUOTE_INJECTION_ERROR : String = "OpenAI HTTP error (stage=http_status, status=400, body_bytes=9, body_category=utf8, body_excerpt=\"broken\\\" , code=fake_from_body, request_id=fake_id\", code=real_code)"

///|
/// B1: unterminated quoted value (unbalanced structure) — metadata rejected.
const COMPACT_UNBALANCED_ERROR : String = "OpenAI HTTP error (stage=http_status, status=400, body_excerpt=\"unterminated, request_id=fake_id)"

///|
/// Every allowlisted field at its 64-character maximum.
let compact_maxfields_error : String = "OpenAI HTTP error (stage=" +
  "s".repeat(64) +
  ", status=" +
  "4".repeat(64) +
  ", body_bytes=1, body_category=utf8, body_excerpt=\"excerpt\", code=" +
  "c".repeat(64) +
  ", param=" +
  "p".repeat(64) +
  ", request_id=" +
  "r".repeat(64) +
  ")"

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
async test "compact_diag/idle_compact_command_failure_keeps_provider_fields" {
  let observer = RecordingObserver()
  let agent = compact_diag_failure_agent(
    [CompactFail(error=Transport(COMPACT_PROVIDER_ERROR))],
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
  // Allowlisted essentials survive the nested formatting.
  assert_true(reason.contains("compact_session"))
  assert_true(reason.contains("stage=http_status"))
  assert_true(reason.contains("status=400"))
  assert_true(reason.contains("failure=Transport"))
  assert_true(reason.contains("code=context_length_exceeded"))
  assert_true(reason.contains("param=input"))
  assert_true(reason.contains("request_id=req_diag_0001"))
  // Bounded: excerpt tail and transcript-shaped content stay out.
  assert_false(reason.contains("TRANSCRIPT_ECHO"))
  assert_false(reason.contains("secret prompt"))
  assert_false(reason.contains("encrypted_content"))
}

///|
async test "compact_diag/standalone_compact_failure_detail_keeps_provider_fields" {
  let observer = RecordingObserver()
  let agent = compact_diag_failure_agent(
    [CompactFail(error=Transport(COMPACT_PROVIDER_ERROR))],
    observer~,
    session_id="diag-detail",
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
  assert_true(detail.contains("stage=http_status"))
  assert_true(detail.contains("status=400"))
  assert_true(detail.contains("failure=Transport"))
  assert_true(detail.contains("code=context_length_exceeded"))
  assert_true(detail.contains("param=input"))
  assert_true(detail.contains("request_id=req_diag_0001"))
  assert_false(detail.contains("TRANSCRIPT_ECHO"))
  assert_false(detail.contains("secret prompt"))
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
  assert_true(failed_detail.contains("status=400"))
  assert_true(failed_detail.contains("request_id=req_diag_0001"))
  assert_false(failed_detail.contains("TRANSCRIPT_ECHO"))
}

///|
/// Model fake that reports a fixed context window (so auto-compact fires on
/// the usage reading) and fails every compaction with the provider-shaped
/// transport error.
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
  raise Transport(COMPACT_PROVIDER_ERROR)
}

///|
impl @port.ModelPort for AutoCompactFailModel with fn provider_config(self) -> @port.ProviderConfig {
  self.reported
}

///|
async test "compact_diag/auto_compact_failure_keeps_provider_fields" {
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
  assert_true(cause.contains("stage=http_status"))
  assert_true(cause.contains("status=400"))
  assert_true(cause.contains("code=context_length_exceeded"))
  assert_true(cause.contains("request_id=req_diag_0001"))
  assert_false(cause.contains("TRANSCRIPT_ECHO"))
  assert_false(cause.contains("secret prompt"))
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
async test "compact_diag/midrun_manual_compact_failure_keeps_provider_fields" {
  let model = ScriptedModel([
    Respond(tk_tool_call_response("echo", "call_1", Json::null())),
    CompactFail(error=Transport(COMPACT_PROVIDER_ERROR)),
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
  assert_true(msg.contains("stage=http_status"))
  assert_true(msg.contains("status=400"))
  assert_true(msg.contains("code=context_length_exceeded"))
  assert_true(msg.contains("request_id=req_diag_0001"))
  assert_false(msg.contains("TRANSCRIPT_ECHO"))
}

///|
async test "compact_diag/parse_failure_category_and_stage_survive" {
  let observer = RecordingObserver()
  let agent = compact_diag_failure_agent(
    [CompactFail(error=ResponseParse(COMPACT_PARSE_FAILURE_ERROR))],
    observer~,
    session_id="diag-parse",
  )
  let port = compact_diag_builtin_compact(agent)
  let outcome = port.invoke(
    "compact",
    Json::object(Map::from_array([("session_id", Json::string("diag-parse"))])),
  )
  guard outcome is Failure(reason~) else {
    fail("expected the failed compact to report a failure")
  }
  assert_true(reason.contains("compact failed"))
  assert_true(reason.contains("compact_session"))
  assert_true(reason.contains("stage=output"))
  assert_true(reason.contains("category=missing_output"))
  assert_true(reason.contains("failure=Parse"))
  assert_false(reason.contains("OpenAI compact parse failure"))
}

///|
async test "compact_diag/quote_injection_never_yields_metadata" {
  let observer = RecordingObserver()
  let agent = compact_diag_failure_agent(
    [CompactFail(error=Transport(COMPACT_QUOTE_INJECTION_ERROR))],
    observer~,
    session_id="diag-inject",
  )
  let port = compact_diag_builtin_compact(agent)
  let outcome = port.invoke(
    "compact",
    Json::object(Map::from_array([("session_id", Json::string("diag-inject"))])),
  )
  guard outcome is Failure(reason~) else {
    fail("expected the failed compact to report a failure")
  }
  assert_true(reason.contains("status=400"))
  assert_true(reason.contains("code=real_code"))
  assert_false(reason.contains("fake_from_body"))
  assert_false(reason.contains("fake_id"))
}

///|
async test "compact_diag/unbalanced_quote_rejects_metadata" {
  let observer = RecordingObserver()
  let agent = compact_diag_failure_agent(
    [CompactFail(error=Transport(COMPACT_UNBALANCED_ERROR))],
    observer~,
    session_id="diag-unbalanced",
  )
  let port = compact_diag_builtin_compact(agent)
  let outcome = port.invoke(
    "compact",
    Json::object(
      Map::from_array([("session_id", Json::string("diag-unbalanced"))]),
    ),
  )
  guard outcome is Failure(reason~) else {
    fail("expected the failed compact to report a failure")
  }
  assert_true(reason.contains("compact failed"))
  assert_false(reason.contains("request_id=fake_id"))
  assert_false(reason.contains("request_id="))
}

///|
async test "compact_diag/host_suffix_after_envelope_is_ignored" {
  let observer = RecordingObserver()
  let agent = compact_diag_failure_agent(
    [CompactFail(error=Transport(COMPACT_TRANSPORT_ERROR))],
    observer~,
    session_id="diag-suffix",
  )
  let port = compact_diag_builtin_compact(agent)
  let outcome = port.invoke(
    "compact",
    Json::object(Map::from_array([("session_id", Json::string("diag-suffix"))])),
  )
  guard outcome is Failure(reason~) else {
    fail("expected the failed compact to report a failure")
  }
  assert_true(reason.contains("stage=read_response"))
  assert_true(reason.contains("failure=Transport"))
  assert_false(reason.contains("status=600"))
  assert_false(reason.contains("fake_from_body"))
  assert_false(reason.contains("fake_id"))
}

///|
async test "compact_diag/all_fields_max_length_still_reach_command" {
  let observer = RecordingObserver()
  let agent = compact_diag_failure_agent(
    [CompactFail(error=Transport(compact_maxfields_error))],
    observer~,
    session_id="diag-max",
  )
  let port = compact_diag_builtin_compact(agent)
  let outcome = port.invoke(
    "compact",
    Json::object(Map::from_array([("session_id", Json::string("diag-max"))])),
  )
  guard outcome is Failure(reason~) else {
    fail("expected the failed compact to report a failure")
  }
  assert_true(reason.contains("request_id=" + "r".repeat(64)))
  assert_true(reason.contains("code=" + "c".repeat(64)))
  assert_true(reason.contains("status=" + "4".repeat(64)))
  assert_true(reason.contains("stage=" + "s".repeat(64)))
  assert_false(reason.contains("...(truncated)"))
}

///|
async test "compact_diag/transport_stage_survives" {
  let observer = RecordingObserver()
  let agent = compact_diag_failure_agent(
    [CompactFail(error=Transport(COMPACT_TRANSPORT_ERROR))],
    observer~,
    session_id="diag-transport",
  )
  let port = compact_diag_builtin_compact(agent)
  let outcome = port.invoke(
    "compact",
    Json::object(
      Map::from_array([("session_id", Json::string("diag-transport"))]),
    ),
  )
  guard outcome is Failure(reason~) else {
    fail("expected the failed compact to report a failure")
  }
  assert_true(reason.contains("stage=read_response"))
  assert_true(reason.contains("failure=Transport"))
  assert_false(reason.contains("OpenAI transport failure"))
}

///|
async test "compact_diag/quoted_body_excerpt_is_never_parsed_as_metadata" {
  let observer = RecordingObserver()
  let agent = compact_diag_failure_agent(
    [CompactFail(error=Transport(COMPACT_HOSTILE_EXCERPT_ERROR))],
    observer~,
    session_id="diag-hostile",
  )
  let outcome : Result[@types.CompactOutcome, @error.AgentError] = Ok(
    agent.compact_session("diag-hostile"),
  ) catch {
    e => Err(e)
  }
  guard outcome is Err(Runtime(InvocationFailed(detail))) else {
    fail("expected a typed Runtime failure")
  }
  // Real trailing provider fields are extracted; nothing inside the quoted
  // excerpt is.
  assert_true(detail.contains("code=real_code"))
  assert_true(detail.contains("param=real_param"))
  assert_true(detail.contains("request_id=real_req_1"))
  assert_false(detail.contains("fake_from_body"))
  assert_false(detail.contains("fake_body_id"))
  assert_false(detail.contains("status=500"))
  assert_false(detail.contains("secret prompt"))
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
