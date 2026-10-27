///|
using @agent {tk_tool_def, tk_ok_result}

///|
/// Cancellable fake: registers its facet at execute start, then suspends on
/// a release queue so the effect stays in flight until the test lets it go.
pub(all) struct CancellableProbe {
  release : @aqueue.Queue[Int32]
  registered_effects : Array[Int32]
  cancelled_effects : Array[Int32]
  cancelled_runs : Array[String]
  seen_reasons : Array[@kernel.CancelReason]
}

///|
pub fn CancellableProbe::CancellableProbe() -> CancellableProbe {
  {
    release: Queue(kind=Unbounded),
    registered_effects: [],
    cancelled_effects: [],
    cancelled_runs: [],
    seen_reasons: [],
  }
}

///|
pub extend CancellableProbe with @port.ToolProvider::{list_tools, execute}

///|
pub extend CancellableProbe with @port.ToolCancellable::{cancel}

///|
pub impl @port.ToolProvider for CancellableProbe with fn list_tools(_self) {
  [tk_tool_def("probe", "cancellable probe")]
}

///|
pub impl @port.ToolProvider for CancellableProbe with fn execute(
  self,
  ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  (ctx.register_cancel)(self as &@port.ToolCancellable)
  self.registered_effects.push(ctx.effect_id.to_int())
  ignore(self.release.get() catch { _ => 0 })
  tk_ok_result("probe settled")
}

///|
pub impl @port.ToolCancellable for CancellableProbe with fn cancel(
  self,
  run_id~,
  effect_id : @kernel.EffectId,
  reason : @kernel.CancelReason,
) -> @kernel.CancelDisposition {
  self.cancelled_runs.push(run_id.to_string())
  self.cancelled_effects.push(effect_id.to_int())
  self.seen_reasons.push(reason)
  @kernel.CancelDisposition::Propagated
}

///|
pub fn probe_effect(
  effect_id : Int32,
  tool_name~ : String = "probe",
  provider~ : &@port.ToolProvider,
  run_id~ : String,
) -> @runtime.EffectContext {
  @runtime.EffectContext(
    run_id=@kernel.RunId::unchecked(run_id),
    bound_tool=provider,
    effect_id={ value: effect_id, },
    owner=@kernel.OwnerId::unchecked("probe_owner"),
    call_id=@kernel.CallId::unchecked("call_probe"),
    tool_name=@kernel.ToolName::unchecked(tool_name),
    arguments=Json::object(Map::from_array([])),
    tool_context=register_cancel => {
      @port.ToolCallContext(
        effect_id={ value: effect_id, },
        call_id=@kernel.CallId::unchecked("call_probe"),
        name=@kernel.ToolName::unchecked(tool_name),
        arguments={},
        register_cancel~,
        scope={
          session_id: @kernel.SessionId::unchecked("cancel-probe"),
          run_id: @kernel.RunId::unchecked(run_id),
          effect_id: Some({ value: effect_id, }),
          pressure: None,
        },
      )
    },
  )
}
