///|
/// Whitebox tests for the root package. All fixtures use canonical kernel
/// types directly; the scripted/recording fakes come from the
/// in-package testkit (@test_support.ScriptedModel, @test_support.RecordingToolProvider,
/// @test_support.RecordingSessionPort, @test_support.RecordingObserver).

///|
struct PolicyRejectHook {}

///|
impl @port.PipelineHook for PolicyRejectHook with fn before_tool(
  _self,
  _call : @kernel.ToolCall,
) -> @port.ToolDecision {
  Reject(reason="blocked by policy")
}

///|
/// ConsentToolHook — a permission policy after the user allowed the call.
struct ConsentToolHook {
  scope : String
}

///|
impl @port.PipelineHook for ConsentToolHook with fn before_tool(
  self,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  ApproveAfterConsent(call~, consent_scope=self.scope)
}

///|
struct LogHook {
  seen : Array[@port.HookStage]
}

///|
impl @port.PipelineHook for LogHook with fn on_post_event(
  self,
  _scope,
  stage : @port.HookStage,
) -> Unit {
  self.seen.push(stage)
}

///|
fn make_config() -> AgentConfig {
  agent_config(max_tool_rounds=Some(10))
}

///|
fn user_msg(text : String) -> @kernel.Message {
  UserMessage(content=[Text(text)])
}

///|
fn stop_response(text : String) -> @kernel.ModelCallResult {
  {
    completion: Completion(
      content=[Text(text)],
      tool_calls=[],
      reasoning=None,
      finish_reason=Stop,
      usage=None,
    ),
    processed_messages: [],
  }
}

///|
fn tool_response(
  tool_calls : Array[@kernel.ToolCall],
) -> @kernel.ModelCallResult {
  let completion : @kernel.Completion = Completion(
    content=[],
    tool_calls~,
    reasoning=None,
    finish_reason=ToolCalls,
    usage=None,
  )
  { completion, processed_messages: [], }
}

///|
fn make_tool_call(id : String, name : String) -> @kernel.ToolCall {
  {
    call_id: @kernel.CallId::unchecked(id),
    name: @kernel.ToolName::unchecked(name),
    arguments: Json::object(Map::from_array([])),
  }
}

///|
/// Helper: empty tool provider (no tools, no execution)
fn empty_tools() -> @test_support.RecordingToolProvider {
  @test_support.RecordingToolProvider([], Map::from_array([]))
}

///|
async test "tool_failure_non_fatal" {
  let tc = make_tool_call("call_1", "bash")
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(tool_response([tc])),
    Respond(stop_response("error handled")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [
      ToolDef(
        name=@kernel.ToolName::unchecked("bash"),
        description="",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=Parallel,
        provenance=None,
      ),
    ],
    Map::from_array([("bash", OutcomeErr(InvocationFailed("boom")))]),
  )
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let config = make_config()

  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[tools], sessions=[store], observers=[
        observer,
      ]),
    ],
    config~,
  )
  let result = agent.run_turn(user_msg("do it"), "session_1")
  assert_eq(result.tool_results.length(), 1)
  assert_true(result.tool_results[0].is_failure())
}

///|
async test "hook_reject_skips_tool_and_feeds_back" {
  let tc = make_tool_call("call_1", "bash")
  let model = @test_support.ScriptedModel([
    Respond(tool_response([tc])),
    @test_support.ScriptedModelStep::Respond(stop_response("adjusted")),
  ])
  let tools = RecordingExecProvider::{
    tools: [
      ToolDef(
        name=@kernel.ToolName::unchecked("bash"),
        description="",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=Parallel,
        provenance=None,
      ),
    ],
    results: Map::from_array([
      ("bash", Ok(Success(content="ok", structured=None))),
    ]),
    executed: [],
  }
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let config = make_config()
  let reject_hook = PolicyRejectHook::{ }

  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        tools=[tools],
        hooks=[reject_hook],
        sessions=[store],
        observers=[observer],
      ),
    ],
    config~,
  )
  let result = agent.run_turn(user_msg("danger"), "session_1")
  // The rejected call never reached the executor...
  assert_eq(tools.executed.length(), 0)
  // ...and came back as a NotExecuted result instead of killing the turn.
  assert_eq(result.tool_results.length(), 1)
  guard result.tool_results[0]
    is NotExecuted(reason=RejectedByHook(reason~), ..) else {
    fail("expected NotExecuted(RejectedByHook) for the rejected call")
  }
  assert_true(reason.contains("blocked by policy"))
}

///|
/// GateByNameHook — rejects blocked tool names, approves everything else.
struct GateByNameHook {
  blocked : Array[String]
}

///|
impl @port.PipelineHook for GateByNameHook with fn before_tool(
  self,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  let name = call.name.to_string()
  if self.blocked.contains(name) {
    Reject(reason="plan mode: tool '\{name}' is disabled while planning")
  } else {
    Approve(call~)
  }
}

///|
async test "hook_reject_steers_model_to_allowed_tool" {
  let bash_call = make_tool_call("call_1", "bash")
  let read_call = make_tool_call("call_2", "read")
  let model = @test_support.ScriptedModel([
    Respond(tool_response([bash_call])),
    Respond(tool_response([read_call])),
    Respond(stop_response("done")),
  ])
  let tools = RecordingExecProvider::{
    tools: [
      @test_support.tk_tool_def("bash", "shell"),
      @test_support.tk_tool_def("read", "read files"),
    ],
    results: Map::from_array([
      ("read", Ok(Success(content="file contents", structured=None))),
    ]),
    executed: [],
  }
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()

  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        tools=[tools],
        hooks=[GateByNameHook::{ blocked: ["bash"], }],
        sessions=[store],
        observers=[observer],
      ),
    ],
    config=make_config(),
  )
  let result = agent.run_turn(user_msg("investigate"), "session_1")
  assert_eq(tools.executed, ["read"])
  assert_eq(result.tool_results.length(), 2)
  assert_true(
    result.tool_results[0] is NotExecuted(reason=RejectedByHook(..), ..),
  )
  assert_true(result.tool_results[1] is Success(..))
}

///|
/// Lattice: user consent (ApproveAfterConsent) outranks another gate's
/// Reject regardless of registration order.
async fn run_bash_with_hooks(
  hooks : Array[&@port.PipelineHook],
) -> (RecordingExecProvider, TurnResult) {
  let tc = make_tool_call("call_1", "bash")
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(tool_response([tc])),
    Respond(stop_response("done")),
  ])
  let tools = RecordingExecProvider::{
    tools: [@test_support.tk_tool_def("bash", "shell")],
    results: Map::from_array([
      ("bash", Ok(Success(content="ran", structured=None))),
    ]),
    executed: [],
  }
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[tools], hooks~, sessions=[store], observers=[]),
    ],
    config=make_config(),
  )
  let result = agent.run_turn(user_msg("investigate"), "session_1")
  (tools, result)
}

///|
async test "hook_consent_overrides_gate_reject_in_registration_order" {
  // Permission before gate (cetas order).
  let (tools, result) = run_bash_with_hooks([
    ConsentToolHook::{ scope: "bash:ego-browser", },
    GateByNameHook::{ blocked: ["bash"], },
  ])
  assert_eq(tools.executed, ["bash"])
  assert_eq(result.tool_results.length(), 1)
  assert_true(result.tool_results[0] is Success(..))
}

///|
async test "hook_consent_overrides_gate_reject_in_reverse_order" {
  // Gate before permission: Reject must not short-circuit the consent.
  let (tools, result) = run_bash_with_hooks([
    GateByNameHook::{ blocked: ["bash"], },
    ConsentToolHook::{ scope: "bash:ego-browser", },
  ])
  assert_eq(tools.executed, ["bash"])
  assert_true(result.tool_results[0] is Success(..))
}

///|
async test "hook_multiple_rejects_merge_reasons" {
  // No consent anywhere: every gate's reason reaches the model, joined.
  let (tools, result) = run_bash_with_hooks([
    GateByNameHook::{ blocked: ["bash"], },
    PolicyRejectHook::{ },
  ])
  assert_eq(tools.executed.length(), 0)
  guard result.tool_results[0]
    is NotExecuted(reason=RejectedByHook(reason~), ..) else {
    fail("expected NotExecuted(RejectedByHook)")
  }
  assert_true(reason.contains("plan mode"))
  assert_true(reason.contains("blocked by policy"))
}

///|
/// RecordingExecProvider — records executed tool names in order, so tests
/// can observe exactly when the tool wave ran relative to a suspending hook.
struct RecordingExecProvider {
  tools : Array[@kernel.ToolDef]
  results : Map[String, Result[@kernel.ToolOutcome, @error.RuntimeError]]
  executed : Array[String]
}

///|
impl @port.ToolProvider for RecordingExecProvider with fn list_tools(self) {
  self.tools
}

///|
impl @port.ToolProvider for RecordingExecProvider with fn execute(
  self,
  ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  let name = ctx.name.to_string()
  self.executed.push(name)
  match self.results.get(name) {
    Some(Ok(r)) => r
    Some(Err(e)) => raise e
    None => raise InvocationFailed("tool not found: \{name}")
  }
}

///|
/// GateHook — an async `before_tool` that suspends until the test releases
/// it; the tool wave must not start while the hook is blocked.
struct GateHook {
  entered : @aqueue.Queue[Int32]
  release : @aqueue.Queue[Int32]
}

///|
impl @port.PipelineHook for GateHook with fn before_tool(
  self : GateHook,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  self.entered.put(1)
  ignore(self.release.get())
  Approve(call~)
}

///|
async test "async_before_tool_gates_tool_wave" {
  let tc = make_tool_call("call_1", "echo")
  let model = @test_support.ScriptedModel([
    Respond(tool_response([tc])),
    Respond(stop_response("done")),
  ])
  let tools = RecordingExecProvider::{
    tools: [
      ToolDef(
        name=@kernel.ToolName::unchecked("echo"),
        description="",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=Parallel,
        provenance=None,
      ),
    ],
    results: Map::from_array([
      ("echo", Ok(Success(content="echoed", structured=None))),
    ]),
    executed: [],
  }
  let store = @test_support.RecordingSessionPort()
  let entered : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let release : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let gate_hook = GateHook::{ entered, release, }
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[tools], hooks=[gate_hook], sessions=[
        store,
      ]),
    ],
    config=make_config(),
  )
  @async.with_task_group(group => {
    let task = group.spawn(async fn() {
      agent.run_turn(user_msg("hello"), "session_1")
    })
    // Wait until the hook is inside `before_tool`. At this point the hook is
    // suspended, so the tool wave must NOT have executed anything yet.
    ignore(entered.get())
    assert_eq(tools.executed.length(), 0)
    release.put(1)
    let result = task.wait()
    assert_eq(result.final_session_id, "session_1")
  })
  assert_eq(tools.executed, ["echo"])
}

///|
/// Marker error for the raising-hook test.
suberror ApprovalPromptFailed {
  ApprovalPromptFailed
}

///|
/// RaisingToolHook — an async `before_tool` that fails instead of deciding
/// (e.g. the approval UI errored). The pump converts the raise into a
/// terminal HookRejected, surfaced to the caller as AgentError::PipelineAborted.
struct RaisingToolHook {}

///|
impl @port.PipelineHook for RaisingToolHook with fn before_tool(
  _self : RaisingToolHook,
  _call : @kernel.ToolCall,
) -> @port.ToolDecision {
  raise ApprovalPromptFailed::ApprovalPromptFailed
}

///|
async test "hook_before_tool_raise_aborts_run" {
  let tc = make_tool_call("call_1", "bash")
  let model = @test_support.ScriptedModel([
    Respond(tool_response([tc])),
    Respond(stop_response("should not reach")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [
      ToolDef(
        name=@kernel.ToolName::unchecked("bash"),
        description="",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=Parallel,
        provenance=None,
      ),
    ],
    Map::from_array([
      ("bash", OutcomeOk(Success(content="ok", structured=None))),
    ]),
  )
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        tools=[tools],
        hooks=[RaisingToolHook::{ }],
        sessions=[store],
      ),
    ],
    config=make_config(),
  )
  match
    (Ok(agent.run_turn(user_msg("danger"), "session_1")) catch { e => Err(e) }) {
    Err(PipelineAborted(msg)) =>
      assert_true(msg.contains("pre_tool_hook raised"))
    _ => fail("expected PipelineAborted from raising before_tool")
  }
}

///|
/// Canonical-type contract: `Reasoning.raw` is an opaque provider replay
/// payload (OpenAI Responses API reasoning items). The kernel never
/// interprets it, but it MUST store and replay it verbatim — provider
/// adapters and session stores rely on that guarantee.
async test "reasoning_raw_replayed_verbatim_into_saved_session" {
  let raw_items = Json::array([
    Json::object(
      Map::from_array([
        ("type", Json::string("reasoning")),
        ("id", Json::string("rs_1")),
      ]),
    ),
  ])
  let model = @test_support.ScriptedModel([
    Respond({
      completion: Completion(
        content=[Text("done")],
        tool_calls=[],
        reasoning=Some({ content: "thinking", raw: Some(raw_items), }),
        finish_reason=Stop,
        usage=None,
      ),
      processed_messages: [],
    }),
  ])
  let store = @test_support.RecordingSessionPort()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=make_config(),
  )
  let result = agent.run_turn(user_msg("hi"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  let session = store.store["session_1"]
  let mut found = false
  for msg in session.messages {
    match msg {
      AssistantMessage(reasoning=Some(r), ..) => {
        found = true
        assert_eq(r.raw, Some(raw_items))
      }
      _ => ()
    }
  }
  assert_true(found)
}

///|
/// With `max_tool_rounds=None` the turn is unbounded: a 40-round single-call
/// turn must complete.
async test "unbounded_tool_rounds_complete_long_turn" {
  let rounds = 40
  let steps : Array[@test_support.ScriptedModelStep] = []
  for i in 0..<rounds {
    steps.push(
      Respond(
        @test_support.tk_tool_call_response(
          "probe",
          "unbounded_\{i}",
          Json::null(),
        ),
      ),
    )
  }
  steps.push(Respond(@test_support.tk_stop_response("done")))
  let model = @test_support.ScriptedModel(steps)
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("probe", "")],
    Map::from_array([("probe", OutcomeOk(@test_support.tk_ok_result("ok")))]),
  )
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[tools], sessions=[store], observers=[
        observer,
      ]),
    ],
    config=agent_config(max_tool_rounds=None),
  )
  // Any raise (ToolLoopExceeded or otherwise) fails the test with the error.
  let _ = agent.run_turn(
    @test_support.tk_user_msg("long loop"),
    "session_unbounded",
  )
  assert_eq(model.call_count(), rounds + 1)
  assert_eq(tools.exec_records().length(), rounds)
  let mut completions = 0
  for event in observer.events() {
    if event is TurnCompleted {
      completions = completions + 1
    }
  }
  assert_eq(completions, 1)
}

///|
/// Bounded semantics: `Some(n)` allows exactly n full tool rounds; the
/// (n+1)-th batch is rejected atomically (never executed) and the error
/// reports consumed/limit.
async test "bounded_tool_rounds_allows_exactly_n_rounds" {
  let steps : Array[@test_support.ScriptedModelStep] = []
  for i in 0..<10 {
    steps.push(
      Respond(
        @test_support.tk_tool_call_response(
          "probe",
          "bounded_\{i}",
          Json::null(),
        ),
      ),
    )
  }
  let model = @test_support.ScriptedModel(steps)
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("probe", "")],
    Map::from_array([("probe", OutcomeOk(@test_support.tk_ok_result("ok")))]),
  )
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[tools], sessions=[store], observers=[
        observer,
      ]),
    ],
    config=agent_config(max_tool_rounds=Some(2)),
  )
  match
    (Ok(agent.run_turn(@test_support.tk_user_msg("loop"), "session_bounded")) catch {
      e => Err(e)
    }) {
    Err(ToolLoopExceeded(consumed~, limit~)) => {
      assert_eq(consumed, 3)
      assert_eq(limit, 2)
    }
    _ => fail("expected ToolLoopExceeded(consumed=3, limit=2)")
  }
  // Two full rounds executed; the third batch was rejected before execution.
  assert_eq(tools.exec_records().length(), 2)
  assert_eq(model.call_count(), 3)
}

///|
/// Test: one PipelineHook implementor receives every interception point through a
/// single trait impl — before_model, before_tool and on_post_event all land
/// on the same @test_support.RecordingHook instance in one turn.
async test "hook_single_impl_receives_all_points" {
  let tc = make_tool_call("call_1", "echo")
  let model = @test_support.ScriptedModel([
    Respond(tool_response([tc])),
    Respond(stop_response("done")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [
      ToolDef(
        name=@kernel.ToolName::unchecked("echo"),
        description="",
        input_schema=Json::null(),
        owner=@kernel.OwnerId::unchecked("legacy_provider"),
        policy=Parallel,
        provenance=None,
      ),
    ],
    Map::from_array([
      ("echo", OutcomeOk(Success(content="echoed", structured=None))),
    ]),
  )
  let hook = @test_support.RecordingHook()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[tools], hooks=[hook], sessions=[
        @test_support.RecordingSessionPort(),
      ]),
    ],
    config=make_config(),
  )
  let result = agent.run_turn(user_msg("hi"), "session_1")
  assert_eq(result.final_session_id, "session_1")
  let labels = hook.records().map(fn(record) { record.label })
  assert_true(labels.contains("before_model"))
  assert_true(labels.contains("before_tool"))
  assert_true(labels.contains("on_post_event"))
}

///|
/// Test: Multiple session stores all receive writes
async test "multiple_session_stores_write_all" {
  let model = @test_support.ScriptedModel([
    Respond(stop_response("multi-store")),
  ])
  let store1 = @test_support.RecordingSessionPort()
  let store2 = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let config = make_config()

  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        tools=[empty_tools()],
        sessions=[store1, store2],
        observers=[observer],
      ),
    ],
    config~,
  )
  let _ = agent.run_turn(user_msg("persist"), "session_1")

  assert_true(store1.store.contains("session_1"))
  assert_true(store2.store.contains("session_1"))
}

///|
/// Helper: build a minimal CommandParam for tests.
fn make_param(
  name : String,
  ptype~ : @port.ParamType,
  required~ : Bool,
  default~ : Json? = None,
) -> @port.CommandParam {
  {
    name,
    label: name,
    description: "",
    ptype,
    required,
    default,
    choices: None,
    positional: false,
  }
}

///|
/// After stages run hooks in reverse order: hooks[1] runs before hooks[0].
async test "hook_turn_error_fires_on_model_error" {
  let model = @test_support.ScriptedModel([])
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let log_hook = LogHook::{ seen: [], }
  let config = make_config()

  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        tools=[empty_tools()],
        hooks=[log_hook],
        sessions=[store],
        observers=[observer],
      ),
    ],
    config~,
  )
  // Model has no responses → raises; run_turn catches and fires TurnFailed.
  let _ = Ok(agent.run_turn(user_msg("boom"), "session_1")) catch {
    e => Err(e)
  }
  // LogHook (PostEventHook) should have seen ModelFailed
  let saw_model_failed = log_hook.seen.iter().any(fn(s) { s is ModelFailed(_) })
  assert_true(saw_model_failed)
}

///|
/// Finally semantics: when BeforeTool aborts (raise PipelineAborted), the
/// TurnError hook still fires before the error propagates.

///|
/// Tool-event trace from a recorded observer: "pending:<id>" /
/// "result:<id>" entries in arrival order, used to assert the
/// pending→terminal pairing contract for a call. Any of the four terminal
/// tool events counts as the result side of the pair.
fn tool_event_trace(events : Array[@types.TurnEvent]) -> Array[String] {
  let trace : Array[String] = []
  for event in events {
    match event {
      ToolCallPending(call) => trace.push("pending:\{call.call_id.to_string()}")
      ToolCallSucceeded(call~, ..)
      | ToolCallFailed(call~, ..)
      | ToolCallRejected(call~, ..)
      | ToolCallAbandoned(call~, ..) =>
        trace.push("result:\{call.call_id.to_string()}")
      _ => ()
    }
  }
  trace
}

///|
/// The executed call must see ToolCallPending strictly before its terminal
/// event, and both must be present.
fn assert_pending_before_result(
  trace : Array[String],
  call_id : String,
) -> Unit raise {
  let mut seen_pending = false
  for entry in trace {
    if entry == "pending:\{call_id}" {
      seen_pending = true
    } else if entry == "result:\{call_id}" {
      if !seen_pending {
        fail("terminal tool event before ToolCallPending for \{call_id}")
      }
      return
    }
  }
  fail("missing pending/result pair for \{call_id}")
}

///|
/// Pre-pass rejects never enter the pipeline: the rejection must surface
/// directly, with no pending marker.
fn assert_rejected_without_pending(
  trace : Array[String],
  call_id : String,
) -> Unit raise {
  for entry in trace {
    if entry == "pending:\{call_id}" {
      fail("unexpected ToolCallPending for pre-pass-rejected \{call_id}")
    }
    if entry == "result:\{call_id}" {
      return
    }
  }
  fail("missing rejection for \{call_id}")
}

///|
/// Regression: a wave whose ONLY call is rejected pre-execution (unknown
/// tool name) must complete the turn. The rejection surfaces as a dedicated
/// `ToolCallRejected` event — the call never entered the pipeline, so no
/// `ToolCallPending` precedes it.
async test "all_rejected_wave_unknown_tool_completes_with_rejection_event" {
  let model = @test_support.ScriptedModel([
    Respond(
      @test_support.tk_tool_call_response("ghost_tool", "c_rej", Json::null()),
    ),
    Respond(@test_support.tk_stop_response("recovered")),
  ])
  let tools = @test_support.RecordingToolProvider([], Map::from_array([]))
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[tools], sessions=[store], observers=[
        observer,
      ]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let turn = agent.run_turn(
    @test_support.tk_user_msg("typo tool"),
    "session_reject",
  )
  // The model's rejected call is in the transcript as a NotExecuted result.
  assert_eq(turn.tool_results.length(), 1)
  match turn.tool_results[0] {
    NotExecuted(reason=UnknownTool, ..) => ()
    _ => fail("expected NotExecuted(UnknownTool) in turn tool_results")
  }
  assert_eq(tools.exec_records().length(), 0)
  assert_rejected_without_pending(tool_event_trace(observer.events()), "c_rej")
}

///|
/// Regression: same rejection-node contract for the schema-mismatch path.
async test "all_rejected_wave_schema_mismatch_completes_with_rejection_event" {
  let strict_def : @kernel.ToolDef = {
    ..@test_support.tk_tool_def("strict", "requires an object"),
    input_schema: Json::object(
      Map::from_array([("type", Json::string("object"))]),
    ),
  }
  let model = @test_support.ScriptedModel([
    Respond(
      @test_support.tk_tool_call_response(
        "strict",
        "c_schema",
        Json::string("nope"),
      ),
    ),
    Respond(@test_support.tk_stop_response("recovered")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [strict_def],
    Map::from_array([]),
  )
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[tools], sessions=[store], observers=[
        observer,
      ]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let turn = agent.run_turn(
    @test_support.tk_user_msg("bad args"),
    "session_schema",
  )
  assert_eq(turn.tool_results.length(), 1)
  match turn.tool_results[0] {
    NotExecuted(reason=SchemaMismatch(..), ..) => ()
    _ => fail("expected NotExecuted(SchemaMismatch) in turn tool_results")
  }
  assert_eq(tools.exec_records().length(), 0)
  assert_rejected_without_pending(
    tool_event_trace(observer.events()),
    "c_schema",
  )
}

///|
/// Regression: a MIXED wave (one valid call + one unknown-name call) must
/// complete; the executed call keeps the full pending→terminal pairing while
/// the unknown-name call surfaces as a rejection without a pending marker.
async test "mixed_wave_pairs_executed_call_and_rejects_unknown_without_pending" {
  let probe_call = make_tool_call("c_probe", "probe")
  let ghost_call = make_tool_call("c_ghost", "ghost_tool")
  let model = @test_support.ScriptedModel([
    Respond(tool_response([probe_call, ghost_call])),
    Respond(@test_support.tk_stop_response("done")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("probe", "")],
    Map::from_array([("probe", OutcomeOk(@test_support.tk_ok_result("ok")))]),
  )
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[tools], sessions=[store], observers=[
        observer,
      ]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let turn = agent.run_turn(@test_support.tk_user_msg("mixed"), "session_mixed")
  // The valid call executed once; the rejected call never reached a provider.
  assert_eq(tools.exec_records().length(), 1)
  // Exactly one tool result per call (no duplicated transcript entries).
  assert_eq(turn.tool_results.length(), 2)
  let mut saw_success = false
  let mut saw_not_executed = false
  for outcome in turn.tool_results {
    match outcome {
      Success(..) => saw_success = true
      NotExecuted(reason=UnknownTool, ..) => saw_not_executed = true
      _ => ()
    }
  }
  assert_true(saw_success)
  assert_true(saw_not_executed)
  let trace = tool_event_trace(observer.events())
  assert_pending_before_result(trace, "c_probe")
  assert_rejected_without_pending(trace, "c_ghost")
}

///|
fn wave3_stop_with_usage(
  text : String,
  total : Int32,
) -> @kernel.ModelCallResult {
  let completion : @kernel.Completion = Completion(
    content=[Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
    usage=Some({
      input_tokens: Some(total),
      output_tokens: Some(0),
      total_tokens: Some(total),
      cached_input_tokens: None,
      uncached_input_tokens: None,
    }),
  )
  { completion, processed_messages: [], }
}

///|
async test "wave3/compact_session/pending tools fixated as interrupted" {
  let dangling_call : @kernel.ToolCall = {
    call_id: @kernel.CallId::unchecked("call_fix"),
    name: @kernel.ToolName::unchecked("echo"),
    arguments: Json::null(),
  }
  let model = @test_support.ScriptedModel([
    Compact(result={
      compacted_messages: [@test_support.tk_user_msg("summary")],
      mode: Replace,
    }),
  ])
  let store = @test_support.RecordingSessionPort()
  store.seed("wave3-fixate", {
    messages: [
      @test_support.tk_user_msg("do the thing"),
      AssistantMessage(
        content=[Text("working on it")],
        tool_calls=[dangling_call],
        reasoning=None,
        finish_reason=ToolCalls,
      ),
    ],
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let outcome = agent.compact_session("wave3-fixate")
  guard outcome.mode is Replace else { fail("expected Replace mode") }
  let compact_input = model.received_compacts()[0].0
  assert_eq(compact_input.length(), 3)
  guard compact_input[1] is AssistantMessage(tool_calls=[owner, ..], ..) else {
    fail("expected the owning assistant message directly before its output")
  }
  guard compact_input[2]
    is ToolMessage(
      call_id=synthesized_id,
      outcome=RuntimeFailure(error_category~, ..),
      ..
    ) else {
    fail("expected an interrupted marker for the pending tool call")
  }
  assert_eq(synthesized_id, owner.call_id)
  assert_eq(error_category, "Interrupted")
  assert_eq(store.store["wave3-fixate"].messages.length(), 1)
}

///|
async test "wave3/context_state/retrievable at initial load and not cleared by TurnStarted" {
  let store = @test_support.RecordingSessionPort()
  store.seed("wave3-ctx", {
    messages: [@test_support.tk_user_msg("earlier")],
    metadata: policy_context_metadata(
      session_id="wave3-ctx",
      measured=50,
      window=100,
      reading_count=1,
    ),
  })
  let observer = @test_support.RecordingObserver()
  let model = @test_support.ScriptedModel([
    Respond(wave3_stop_with_usage("done", 30)),
  ])
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(
      max_tool_rounds=Some(10),
      model_context_window=Some(100),
    ),
  )
  let initial = agent.context_state("wave3-ctx")
  guard initial is Some(loaded) else {
    fail("expected the persisted context state at initial load")
  }
  assert_eq(loaded.last_measured_tokens, Some(50))
  assert_eq(loaded.source, Measured)
  ignore(agent.run_turn(@test_support.tk_user_msg("hi there"), "wave3-ctx"))
  let events = observer.events()
  let mut turn_started_at = -1
  for i, event in events {
    match event {
      TurnStarted => turn_started_at = i
      _ => ()
    }
  }
  assert_true(turn_started_at >= 0)
  let mut after_start = None
  for i in turn_started_at..<events.length() {
    match events[i] {
      ContextStateUpdated(state~) => {
        after_start = Some(state)
        break
      }
      _ => ()
    }
  }
  guard after_start is Some(projected) else {
    fail("expected a context-state update after TurnStarted")
  }
  assert_eq(projected.last_measured_tokens, Some(50))
  let latest = agent.context_state("wave3-ctx")
  guard latest is Some(current) else {
    fail("expected the live context state after the turn")
  }
  assert_eq(current.last_measured_tokens, Some(30))
  assert_eq(current.source, Measured)
  let metadata = store.store["wave3-ctx"].metadata
  assert_true(metadata.contains(@types.CONTEXT_STATE_METADATA_KEY))
}

///|
/// Agent-level guarantee for formerly-rejected schema keywords: a tool
/// declaring `oneOf` composes through the full Agent path, conforming calls
/// execute, and XOR violations die in the pre-pass as
/// `NotExecuted(SchemaMismatch)` — no execution, turn survives. This is the
/// contract extension-side schema debts (ptc run_code code/source XOR)
/// rely on.

///|
fn oneof_tool_def() -> @kernel.ToolDef {
  ToolDef(
    name=@kernel.ToolName::unchecked("write_thing"),
    description="Provide exactly one of code or source.",
    input_schema={
      "type": "object",
      "properties": {
        "code": { "type": "string" },
        "source": { "type": "string" },
      },
      "oneOf": [{ "required": ["code"] }, { "required": ["source"] }],
      "additionalProperties": false,
    },
    owner=@kernel.OwnerId::unchecked("schema_turn_test"),
    policy=Parallel,
    provenance=Some("schema-turn-test"),
  )
}

///|
fn schema_call(id : String, arguments : Json) -> @kernel.ToolCall {
  {
    call_id: @kernel.CallId::unchecked(id),
    name: @kernel.ToolName::unchecked("write_thing"),
    arguments,
  }
}

///|
async test "oneOf tool composes through Agent and executes conforming call" {
  let tc = schema_call("call_1", { "code": "fn main { }" })
  let model = @test_support.ScriptedModel([
    Respond(tool_response([tc])),
    Respond(stop_response("done")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [oneof_tool_def()],
    Map::from_array([
      ("write_thing", OutcomeOk(Success(content="ok", structured=None))),
    ]),
  )
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[tools], sessions=[store], observers=[
        observer,
      ]),
    ],
    config=make_config(),
  )
  let result = agent.run_turn(user_msg("write it"), "session_oneof")
  assert_eq(result.tool_results.length(), 1)
  guard result.tool_results[0] is Success(content~, ..) else {
    fail("conforming oneOf call must execute")
  }
  assert_eq(content, "ok")
}

///|
async test "oneOf XOR violations are pre-pass rejected without execution" {
  let both = schema_call("call_both", { "code": "a", "source": "b" })
  let neither = schema_call("call_neither", { "description": "nope" })
  let model = @test_support.ScriptedModel([
    Respond(tool_response([both])),
    Respond(tool_response([neither])),
    Respond(stop_response("done")),
  ])
  let tools = @test_support.RecordingToolProvider(
    [oneof_tool_def()],
    Map::from_array([]),
  )
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", tools=[tools], sessions=[store], observers=[
        observer,
      ]),
    ],
    config=make_config(),
  )
  let result = agent.run_turn(user_msg("write it"), "session_xor")
  assert_eq(result.tool_results.length(), 2)
  guard result.tool_results[0]
    is NotExecuted(reason=SchemaMismatch(json_path~, ..), ..) else {
    fail("both-branch call must be pre-pass rejected")
  }
  assert_eq(json_path, "$")
  guard result.tool_results[1] is NotExecuted(reason=SchemaMismatch(..), ..) else {
    fail("zero-branch call must be pre-pass rejected")
  }
  // The provider never executed anything; the turn still completed.
  assert_eq(tools.exec_records().length(), 0)
  assert_eq(result.final_session_id, "session_xor")
}

///|
/// Run-bound callbacks carry the identity minted for their turn;
/// out-of-run notifications may carry None.

///|
/// Observer double recording (tag, scope) for every scoped dispatch.
struct ScopedObserver {
  records : Array[(String, @types.EventScope?)]
}

///|
/// Tag just the variants these tests drive; everything else is "other".
fn scope_projection_event_tag(event : @types.TurnEvent) -> String {
  match event {
    TurnStarted => "turn_started"
    ModelResponseReceived(..) => "model_response"
    ToolCallPending(_) => "tool_pending"
    ToolCallApproved(..) => "tool_approved"
    ToolCallStarted(..) => "tool_started"
    ToolCallSucceeded(..)
    | ToolCallFailed(..)
    | ToolCallRejected(..)
    | ToolCallAbandoned(..) => "tool_result"
    TurnCompleted => "turn_completed"
    TurnFailed(_) => "turn_failed"
    _ => "other"
  }
}

///|
pub extend ScopedObserver with @port.Observer::{on_event}

///|
pub impl @port.Observer for ScopedObserver with fn on_event(
  self,
  scope,
  event : @types.TurnEvent,
) -> Unit {
  self.records.push((scope_projection_event_tag(event), scope))
}

///|
/// PipelineHook double recording (tag, scope) for every scoped post-event dispatch.
struct ScopedHook {
  stages : Array[(String, @types.EventScope?)]
}

///|
pub extend ScopedHook with @port.PipelineHook::{
  tool_exposure,
  on_turn_begin,
  on_post_event,
  before_model,
  before_tool,
  on_turn_end,
}

///|
pub impl @port.PipelineHook for ScopedHook with fn on_post_event(
  self,
  scope,
  stage : @port.HookStage,
) -> Unit {
  let tag = match stage {
    ModelCompleted(..) => "model_completed"
    ModelFailed(..) => "model_failed"
    ToolCompleted(..) => "tool_completed"
    ToolFailed(..) => "tool_failed"
  }
  self.stages.push((tag, scope))
}

///|
/// A plain stop turn emits TurnStarted → ModelResponseReceived →
/// TurnCompleted, all carrying the SAME Some(scope), and the scope names the
/// session the product passed to `run_turn`.
async test "scope_projection/turn_events_carry_one_run_identity" {
  let observer = ScopedObserver::{ records: [], }
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            Respond(@test_support.tk_stop_response("hi")),
          ]),
        ),
      ),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("hello"), "s_scope"))
  // The operation projection is deliberately out-of-run (scope None, session
  // in the payload); the run-bound invariants below cover the TURN events.
  let turn_records = observer.records.filter(fn(r) { r.0 != "other" })
  let tags = turn_records.map(fn(r) { r.0 })
  assert_eq(tags, ["turn_started", "model_response", "turn_completed"])
  guard turn_records[0].1 is Some(first) else {
    fail("TurnStarted must carry Some(scope)")
  }
  for record in turn_records {
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
  let observer = ScopedObserver::{ records: [], }
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("a"),
    ),
    Respond(@test_support.tk_stop_response("b")),
  ])
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("one"), "s_scope"))
  ignore(agent.run_turn(@test_support.tk_user_msg("two"), "s_scope"))
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
  let observer = ScopedObserver::{ records: [], }
  let hook = ScopedHook::{ stages: [], }
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_tool_call_response("echo", "call_1", Json::null()),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("echo", "echo tool")],
    Map::from_array([("echo", OutcomeOk(@test_support.tk_ok_result("echoed")))]),
  )
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="tools",
        tools=[tools],
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
        hooks=[hook],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("hi"), "s_loop"))
  let tags = observer.records
    .filter(fn(r) { r.0 != "other" })
    .map(fn(r) { r.0 })
  assert_eq(tags, [
    "turn_started", "model_response", "tool_pending", "tool_approved", "tool_started",
    "tool_result", "model_response", "turn_completed",
  ])
  let turn_records = observer.records.filter(fn(r) { r.0 != "other" })
  guard turn_records[0].1 is Some(turn_scope) else {
    fail("TurnStarted must carry Some(scope)")
  }
  for record in turn_records {
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
fn scope_test_tool_call_with_usage(total : Int32) -> @kernel.ModelCallResult {
  let base = @test_support.tk_tool_call_response("echo", "call_1", Json::null())
  let completion : @kernel.Completion = Completion(
    content=[],
    tool_calls=base.completion.tool_calls(),
    reasoning=None,
    finish_reason=ToolCalls,
    usage=Some({
      input_tokens: Some(total),
      output_tokens: Some(0),
      total_tokens: Some(total),
      cached_input_tokens: None,
      uncached_input_tokens: None,
    }),
  )
  { completion, processed_messages: [], }
}
