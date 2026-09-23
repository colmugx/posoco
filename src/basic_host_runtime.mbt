///|
/// Host-runtime decorator for the composition seam: core basic tools (the
/// built-in memory surface) execute through their own providers ahead of the
/// host's runtime chain, so a host that wires `Agent::with_runtime` without
/// knowing the basic names still runs them. Everything else — model calls,
/// cancellation, compact, and every non-basic tool — forwards to the host
/// runtime untouched.

///|
priv struct BasicFirstHostRuntime {
  inner : &@kernel_exec.HostRuntime
  basic : Map[String, &@port.ToolProvider]
}

///|
impl @kernel_exec.HostRuntime for BasicFirstHostRuntime with fn call_model(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tool_definitions : Array[@kernel.ToolDef],
  call_options : Json,
  on_chunk : @kernel_exec.HostChunkCallback?,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  self.inner.call_model(
    scope, messages, tool_definitions, call_options, on_chunk,
  )
}

///|
impl @kernel_exec.HostRuntime for BasicFirstHostRuntime with fn execute_tool(
  self,
  effect_id : @kernel.EffectId,
  owner_id : @kernel.OwnerId,
  call_id : @kernel.CallId,
  tool_name : @kernel.ToolName,
  arguments : Json,
) -> @kernel.ToolOutcome {
  let name = tool_name.to_string()
  match self.basic.get(name) {
    Some(provider) => {
      let call : @kernel.ToolCall = { call_id, name: tool_name, arguments, }
      provider.execute(name, call) catch {
        error =>
          RuntimeFailure(
            error_category="ToolProviderError",
            message=error.to_string(),
          )
      }
    }
    None =>
      self.inner.execute_tool(
        effect_id, owner_id, call_id, tool_name, arguments,
      )
  }
}

///|
impl @kernel_exec.HostRuntime for BasicFirstHostRuntime with fn cancel_effects(
  self,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  self.inner.cancel_effects(effect_ids, reason)
}

///|
impl @kernel_exec.HostRuntime for BasicFirstHostRuntime with fn compact(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  call_options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  self.inner.compact(scope, messages, call_options, trigger)
}
