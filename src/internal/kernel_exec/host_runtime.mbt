///|
/// Host-side runtime contract for executing Kernel Effects: the reducer emits
/// Effects, the host executes them. All inputs/outputs are canonical Kernel
/// types, and the reducer never calls this async trait.

///|
/// Streaming chunk callback; interpreting `StreamChunk` stays a host concern.
pub type HostChunkCallback = (@types.StreamChunk) -> Unit

///|
impl HostRuntime with fn execute_tool_scoped(
  self,
  effect_id,
  owner_id,
  call_id,
  tool_name,
  arguments,
  _scope,
) -> @kernel.ToolOutcome {
  self.execute_tool(effect_id, owner_id, call_id, tool_name, arguments)
}

///|
/// Imperative effect scope supplied by the driver, never stored in Effects or
/// RunState. Only the driver can create real child requests.
pub(all) struct ToolExecutionScope {
  invocation : @kernel.InvocationScope
  parent_effect_id : EffectId?
  root_effect_id : EffectId
  tools : () -> Array[@kernel.ToolDef]
  invoke : async (String, Json) -> @kernel.InvocationResult
  active : () -> Bool
}

///|
pub(open) trait HostRuntime {
  /// Execute a `CallModel` effect. The pump always replaces the transcript body
  /// with the returned `processed_messages`; when the modelport initiates a
  /// compact it fills `new_thread`, and the pump starts a new thread with
  /// `processed_messages` as the new body. `scope.effect_id` is always `Some`
  /// here and hosts that propagate cancellation key in-flight model calls by
  /// it, mirroring the tool side. `messages` is an `ArrayView` borrow valid
  /// only for the duration of the call; hosts must not retain it.
  async fn call_model(
    Self,
    scope : @kernel.InvocationScope,
    messages : ArrayView[@kernel.Message],
    tool_definitions : Array[@kernel.ToolDef],
    call_options : Json,
    on_chunk : HostChunkCallback?,
  ) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure]

  /// Execute a single tool call. Missing owner / stale registration →
  /// `RuntimeFailure("MissingOwner")`; business errors → `ToolReportedError`;
  /// transport errors → `RuntimeFailure`. `effect_id` is the reducer-allocated
  /// identity of this `ExecuteTool` effect and correlates `cancel_effects`
  /// calls with in-flight executions.
  async fn execute_tool(
    Self,
    effect_id : EffectId,
    owner_id : @kernel.OwnerId,
    call_id : @kernel.CallId,
    tool_name : @kernel.ToolName,
    arguments : Json,
  ) -> @kernel.ToolOutcome

  /// Scope-aware dispatch; the default retains plain execution, while the Agent
  /// shim forwards the real scope into its public Runtime context.
  async fn execute_tool_scoped(
    Self,
    effect_id : EffectId,
    owner_id : @kernel.OwnerId,
    call_id : @kernel.CallId,
    tool_name : @kernel.ToolName,
    arguments : Json,
    scope : ToolExecutionScope?,
  ) -> @kernel.ToolOutcome = _

  /// Best-effort cancel. Fire-and-forget from the reducer's perspective.
  async fn cancel_effects(
    Self,
    effect_ids : Array[EffectId],
    reason : CancelReason,
  ) -> Array[(EffectId, CancelDisposition)]

  /// Compact the conversation. `trigger` lets the modelport pick a strategy
  /// (Auto = cheap elision, Manual = thorough). `tools` comes from the active
  /// TurnSnapshot, including standalone compact before any chat.
  /// `scope.effect_id` is always `None` here: compact is host-driven, not a
  /// reducer-allocated effect. `messages` is an `ArrayView` borrow valid only
  /// for the duration of the call; hosts must not retain it.
  async fn compact(
    Self,
    scope : @kernel.InvocationScope,
    messages : ArrayView[@kernel.Message],
    tools : Array[@kernel.ToolDef],
    call_options : Json,
    trigger : @kernel.CompactTrigger,
  ) -> Result[@kernel.CompactResult, @kernel.ModelFailure]
}
