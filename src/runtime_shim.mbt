///|
/// Mechanical adapter from the public `@runtime.Runtime` seam to the
/// internal `HostRuntime` boundary. The shim only packs/unpacks
/// `EffectContext` — it adds no semantics of its own, so the public trait
/// and the internal contract cannot drift apart silently.

///|
priv struct RuntimeHostShim {
  inner : &@runtime.Runtime
}

///|
fn RuntimeHostShim::new(inner : &@runtime.Runtime) -> RuntimeHostShim {
  { inner, }
}

///|
impl @kernel_exec.HostRuntime for RuntimeHostShim with fn call_model(
  self,
  messages : Array[@kernel.Message],
  tool_definitions : Array[@kernel.ToolDef],
  call_options : Json,
  on_chunk : @kernel_exec.HostChunkCallback?,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  self.inner.call_model(messages, tool_definitions, call_options, on_chunk)
}

///|
impl @kernel_exec.HostRuntime for RuntimeHostShim with fn execute_tool(
  self,
  effect_id : @kernel.EffectId,
  owner_id : @kernel.OwnerId,
  call_id : @kernel.CallId,
  tool_name : @kernel.ToolName,
  arguments : Json,
) -> @kernel.ToolOutcome {
  self.inner.execute_tool(@runtime.EffectContext::{
    effect_id,
    owner: owner_id,
    call_id,
    tool_name,
    arguments,
  })
}

///|
impl @kernel_exec.HostRuntime for RuntimeHostShim with fn cancel_effects(
  self,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  self.inner.cancel_effects(effect_ids, reason)
}

///|
impl @kernel_exec.HostRuntime for RuntimeHostShim with fn compact(
  self,
  messages : Array[@kernel.Message],
  call_options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  self.inner.compact(messages, call_options, trigger)
}
