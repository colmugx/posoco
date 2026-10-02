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
  /// Same registration semantics as `PortRuntime`: populated only by basic
  /// providers that call `ToolCallContext.register_cancel`; dropped at
  /// settle. Memory tools are instantaneous and never register.
  cancels : Map[Int, &@port.ToolCancellable]
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
      let key = effect_id.to_int()
      let runtime = self
      let call_ctx : @port.ToolCallContext = {
        effect_id,
        call_id,
        name: tool_name,
        arguments,
        register_cancel: fn(c : &@port.ToolCancellable) {
          runtime.cancels[key] = c
        },
      }
      let outcome = provider.execute(call_ctx) catch {
        error =>
          RuntimeFailure(
            error_category="ToolProviderError",
            message=error.to_string(),
          )
      }
      self.cancels.remove(key)
      outcome
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
  let dispositions : Array[(@kernel.EffectId, @kernel.CancelDisposition)] = []
  let delegated : Array[@kernel.EffectId] = []
  for id in effect_ids {
    match self.cancels.get(id.to_int()) {
      Some(handler) => {
        let disposition = handler.cancel(id, reason) catch {
          _ => NotPropagated
        }
        dispositions.push((id, disposition))
      }
      None => delegated.push(id)
    }
  }
  if !delegated.is_empty() {
    for pair in self.inner.cancel_effects(delegated, reason) {
      dispositions.push(pair)
    }
  }
  dispositions
}

///|
impl @kernel_exec.HostRuntime for BasicFirstHostRuntime with fn compact(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  call_options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  self.inner.compact(scope, messages, tools, call_options, trigger)
}
