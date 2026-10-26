///|
/// Adapter to the public Runtime seam: bound-capable chains receive the provider
/// captured at operation admission, yet execution still passes through the
/// host's Runtime instead of bypassing its policy or instrumentation.

///|
pub struct RuntimeHostShim {
  priv inner : &@runtime.Runtime
  priv bindings : Ref[Map[String, &@port.ToolProvider]]
  priv incomplete : Map[(String, Int32), @kernel.InvocationScope]
  priv on_cleanup_failure : (String) -> Unit
  priv cancel_settle_ms : Int32
}

///|
pub fn RuntimeHostShim::RuntimeHostShim(
  inner : &@runtime.Runtime,
  bindings : Ref[Map[String, &@port.ToolProvider]],
  cancel_settle_ms~ : Int32,
  on_cleanup_failure~ : (String) -> Unit = fn(_) { () },
) -> RuntimeHostShim {
  {
    inner,
    bindings,
    incomplete: Map::from_array([]),
    on_cleanup_failure,
    cancel_settle_ms,
  }
}

///|
pub impl @kernel_exec.HostRuntime for RuntimeHostShim with fn call_model(
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
pub impl @kernel_exec.HostRuntime for RuntimeHostShim with fn execute_tool(
  self,
  effect_id : @kernel.EffectId,
  owner_id : @kernel.OwnerId,
  call_id : @kernel.CallId,
  tool_name : @kernel.ToolName,
  arguments : Json,
) -> @kernel.ToolOutcome {
  @kernel_exec.HostRuntime::execute_tool_scoped(
    self,
    effect_id,
    owner_id,
    call_id,
    tool_name,
    arguments,
    None,
  )
}

///|
pub impl @kernel_exec.HostRuntime for RuntimeHostShim with fn execute_tool_scoped(
  self,
  effect_id : @kernel.EffectId,
  owner_id : @kernel.OwnerId,
  call_id : @kernel.CallId,
  tool_name : @kernel.ToolName,
  arguments : Json,
  scope : @kernel_exec.ToolExecutionScope?,
) -> @kernel.ToolOutcome {
  let factory = scope.map(scope => {
    fn(register_cancel) {
      @port.ToolCallContext(
        effect_id~,
        call_id~,
        name=tool_name,
        arguments~,
        register_cancel~,
        scope=scope.invocation,
        parent_effect_id?=scope.parent_effect_id,
        root_effect_id=scope.root_effect_id,
        tools=scope.tools,
        invoke=scope.invoke,
        active=scope.active,
      )
    }
  })
  let key = scope.map(scope => {
    (scope.invocation.run_id.to_string(), effect_id.to_int())
  })
  if key is Some(key) && scope is Some(scope) {
    self.incomplete[key] = scope.invocation
  }
  // An abnormal unwind deliberately retains this execution. Only a real
  // return or an executor-confirmed terminal cancellation releases it.
  let outcome = self.inner.execute_tool(
    @runtime.EffectContext(
      effect_id~,
      owner=owner_id,
      call_id~,
      tool_name~,
      arguments~,
      tool_context?=factory,
      bound_tool?=if self.inner.supports_bound_tools() {
        self.bindings.val
        .get(tool_name.to_string())
        .map(provider => {
          match scope {
            Some(scope) =>
              (
                ScopedBoundProvider::{
                  inner: provider,
                  before_start: scope.before_start,
                } : &@port.ToolProvider)
            None => provider
          }
        })
      } else {
        None
      },
    ),
  )
  if key is Some(key) {
    self.incomplete.remove(key)
  }
  outcome
}

///|
pub impl @kernel_exec.HostRuntime for RuntimeHostShim with fn cancel_effects(
  self,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  let attempted : Result[
    Array[(@kernel.EffectId, @kernel.CancelDisposition)],
    Error,
  ] = Ok(
    {
      let reported = @async.with_timeout(self.cancel_settle_ms, async fn() {
        self.inner.cancel_effects(effect_ids, reason)
      })
      validate_runtime_cancellations(effect_ids, reported)
      reported
    },
  ) catch {
    error => Err(error)
  }
  let reported = match attempted {
    Ok(reported) => reported
    Err(error) => {
      (self.on_cleanup_failure)(error.to_string())
      raise error
    }
  }
  for entry in reported {
    let (id, disposition) = entry
    if disposition is (Stopped | AlreadySettled) {
      for key in self.incomplete.keys().to_array() {
        if key.1 == id.to_int() {
          self.incomplete.remove(key)
        }
      }
    }
  }
  reported
}

///|
pub impl @kernel_exec.HostRuntime for RuntimeHostShim with fn compact(
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
pub extend RuntimeHostShim with @kernel_exec.HostRuntime::{
  call_model,
  execute_tool,
  execute_tool_scoped,
  cancel_effects,
  compact,
}
