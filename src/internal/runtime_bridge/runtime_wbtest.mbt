///|
/// Whitebox tests for the runtime shim's admission bookkeeping: a cancelled
/// execution with no cancellable facet must not wedge every later admission.

///|
struct SilentModel {
  mut calls : Int32
}

///|
fn SilentModel::SilentModel() -> SilentModel {
  { calls: 0, }
}

///|
pub impl @port.ModelPort for SilentModel with fn chat(
  self : SilentModel,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  self.calls = self.calls + 1
  raise @error.ModelError::ResponseParse("silent model")
}

///|
pub extend SilentModel with @port.ModelPort::{chat, compact, provider_config}

///|
pub impl @port.ModelPort for SilentModel with fn compact(
  _self : SilentModel,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  raise @error.ModelError::ResponseParse("silent model")
}

///|
pub impl @port.ModelPort for SilentModel with fn provider_config(
  _self : SilentModel,
) -> @port.ProviderConfig {
  {
    reasoning_effort_values: [],
    context_window: None,
    compact_threshold: None,
  }
}

///|

///|
/// A provider that parks in a cancellable point. `register` decides whether it
/// hands the runtime a `ToolCancellable` before parking.
struct ParkingTool {
  register : Bool
  park : Bool
}

///|
fn ParkingTool::ParkingTool(register~ : Bool, park~ : Bool) -> ParkingTool {
  { register, park, }
}

///|
pub extend ParkingTool with @port.ToolCancellable::{cancel}

///|
pub impl @port.ToolCancellable for ParkingTool with fn cancel(
  self : ParkingTool,
  run_id~ : @kernel.RunId,
  effect_id : @kernel.EffectId,
  reason : @kernel.CancelReason,
) -> @kernel.CancelDisposition {
  ignore((self, run_id, effect_id, reason))
  AlreadySettled
}

///|
pub extend ParkingTool with @port.ToolProvider::{execute, list_tools}

///|
pub impl @port.ToolProvider for ParkingTool with fn list_tools(
  _self : ParkingTool,
) -> Array[@kernel.ToolDef] {
  []
}

///|
pub impl @port.ToolProvider for ParkingTool with fn execute(
  self : ParkingTool,
  ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  if self.register {
    (ctx.register_cancel)(self as &@port.ToolCancellable)
  }
  if self.park {
    @async.sleep(5_000)
  }
  Success(content="parked", structured=None)
}

///|
/// A runtime whose `execute_tool` raises instead of running the tool, so the
/// shim unwinds without any cancellation signal.
struct RaisingRuntime {
  inner : &@runtime.Runtime
}

///|
fn RaisingRuntime::RaisingRuntime(inner~ : &@runtime.Runtime) -> RaisingRuntime {
  { inner, }
}

///|
pub extend RaisingRuntime with @runtime.Runtime::{
  call_model,
  execute_tool,
  cancel_effects,
  compact,
}

///|
pub impl @runtime.Runtime for RaisingRuntime with fn call_model(
  self : RaisingRuntime,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tool_definitions : Array[@kernel.ToolDef],
  call_options : Json,
  on_chunk : ((@types.StreamChunk) -> Unit)?,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  @runtime.Runtime::call_model(
    self.inner,
    scope,
    messages,
    tool_definitions,
    call_options,
    on_chunk,
  )
}

///|
pub impl @runtime.Runtime for RaisingRuntime with fn execute_tool(
  self : RaisingRuntime,
  ctx : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  ignore((self, ctx))
  raise @error.RuntimeError::InvocationFailed("adapter blew up")
}

///|
pub impl @runtime.Runtime for RaisingRuntime with fn cancel_effects(
  self : RaisingRuntime,
  run_id~ : @kernel.RunId,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  @runtime.Runtime::cancel_effects(self.inner, effect_ids, reason, run_id~)
}

///|
pub impl @runtime.Runtime for RaisingRuntime with fn compact(
  self : RaisingRuntime,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  call_options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  @runtime.Runtime::compact(
    self.inner,
    scope,
    messages,
    tools,
    call_options,
    trigger,
  )
}

///|
struct ShimFixture {
  shim : RuntimeHostShim
  diagnostics : Array[String]
}

///|
fn shim_fixture(register~ : Bool, park~ : Bool) -> ShimFixture {
  shim_over(@runtime.PortRuntime(model=SilentModel()), register~, park~)
}

///|
fn shim_over(
  runtime : &@runtime.Runtime,
  register~ : Bool,
  park~ : Bool,
) -> ShimFixture {
  let tool : &@port.ToolProvider = ParkingTool(register~, park~)
  let bindings : Ref[Map[String, &@port.ToolProvider]] = Ref(
    Map::from_array([("parking", tool)]),
  )
  let diagnostics : Array[String] = []
  let shim = RuntimeHostShim(runtime, bindings, cancel_settle_ms=100, on_cleanup_failure=fn(
    reason,
  ) {
    diagnostics.push(reason)
  })
  { shim, diagnostics, }
}

///|
/// Run one effect and, when the provider parks, cancel it mid-flight so
/// `execute_tool` unwinds through raw cancellation.
async fn cancelled_effect(shim : RuntimeHostShim) -> Unit {
  ignore(run_effect(shim))
}

///|
async fn run_effect(shim : RuntimeHostShim) -> @kernel.ToolOutcome {
  let outcome : Ref[@kernel.ToolOutcome?] = Ref(None)
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      outcome.val = Some(
        @kernel_exec.HostRuntime::execute_tool(
          shim,
          @kernel.EffectId::first(),
          @kernel.OwnerId::unchecked("owner"),
          @kernel.CallId::unchecked("call_1"),
          @kernel.ToolName::unchecked("parking"),
          Json::null(),
          {
            invocation: {
              session_id: @kernel.SessionId::unchecked("session"),
              run_id: @kernel.RunId::unchecked("run"),
              effect_id: Some(@kernel.EffectId::first()),
              pressure: None,
            },
            parent_effect_id: None,
            root_effect_id: @kernel.EffectId::first(),
            tools: fn() { [] },
            invoke: fn(_name, _arguments) {
              Interrupted(
                reason="child invocation unavailable",
                cancellation=NotPropagated,
                side_effects_possible=false,
              )
            },
            active: fn() { true },
            before_start: fn() { None },
          },
        ),
      )
    })
    @async.sleep(50)
    task.cancel()
    ignore(task.try_wait())
  })
  match outcome.val {
    Some(value) => value
    None => RuntimeFailure(error_category="Cancelled", message="cancelled")
  }
}

///|
async test "runtime_bridge/non_cancellable_cancel_unwind_keeps_admission_open" {
  let fixture = shim_fixture(register=false, park=true)
  cancelled_effect(fixture.shim)
  let settled : Result[Unit, Error] = Ok(fixture.shim.require_settled()) catch {
    error => Err(error)
  }
  assert_true(settled is Ok(_))
  assert_false(fixture.shim.has_unconfirmed())
  // A cancelled execution is settled silently: it is not a cleanup defect and
  // must not add a secondary-failure event to the turn.
  assert_eq(fixture.diagnostics.length(), 0)
}

///|
async test "runtime_bridge/dispatch_failure_keeps_the_conservative_ledger" {
  let inner : &@runtime.Runtime = @runtime.PortRuntime(model=SilentModel())
  let fixture = shim_over(RaisingRuntime(inner~), register=false, park=false)
  let outcome : Result[@kernel.ToolOutcome, Error] = Ok(
    run_effect(fixture.shim),
  ) catch {
    error => Err(error)
  }
  assert_true(outcome is Err(_))
  // An ordinary dispatch failure leaves the effect unconfirmed on purpose: a
  // trusted decorator's explicit terminal receipt is what settles it.
  assert_true(fixture.shim.has_unconfirmed())
  let settled : Result[Unit, Error] = Ok(fixture.shim.require_settled()) catch {
    error => Err(error)
  }
  assert_true(settled is Err(_))
  assert_eq(fixture.diagnostics.length(), 0)
}

///|
async test "runtime_bridge/cancellable_cancel_unwind_stays_unconfirmed" {
  let fixture = shim_fixture(register=true, park=true)
  cancelled_effect(fixture.shim)
  // The execution still has a cancellable facet, so it stays pending until a
  // later `cancel_effects` confirms a terminal disposition.
  assert_true(fixture.shim.has_unconfirmed())
  let settled : Result[Unit, Error] = Ok(fixture.shim.require_settled()) catch {
    error => Err(error)
  }
  assert_true(settled is Err(_))
  assert_eq(fixture.diagnostics.length(), 0)
}

///|
async test "runtime_bridge/completed_effect_releases_admission" {
  let fixture = shim_fixture(register=false, park=false)
  let outcome = run_effect(fixture.shim)
  assert_true(outcome is Success(_))
  assert_false(fixture.shim.has_unconfirmed())
  assert_eq(fixture.diagnostics.length(), 0)
}
