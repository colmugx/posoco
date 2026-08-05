///|
/// Host-side runtime contract for executing Kernel Effects. The reducer emits
/// Effects; the host executes them. All inputs/outputs are canonical Kernel types.
/// This trait is async (hosts use async I/O); the Kernel reducer never calls it.

///|
/// Streaming chunk callback. The host delivers raw provider chunks to the
/// observer/telemetry surface without interpretation (ADR §2.11).
pub type HostChunkCallback = (Json) -> Unit

///|
/// Host runtime contract. Implementations live outside the Kernel package.
pub(open) trait HostRuntime {
  /// Execute a `CallModel` effect. Converts messages + tool_definitions to
  /// provider wire format, calls the model (optionally streaming), and returns
  /// `ModelCallResult` with both the completion and `processed_messages`.
  /// The pump always replaces the transcript body with the returned value.
  /// When the modelport initiates a compact, it fills `new_thread` and the
  /// pump starts a new thread using `processed_messages` as the new body.
  async fn call_model(
    Self,
    messages : Array[@kernel.Message],
    tool_definitions : Array[@kernel.ToolDef],
    call_options : Json,
    on_chunk : HostChunkCallback?,
  ) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure]

  /// Execute a single tool call. Looks up the owner, invokes the provider,
  /// and maps the result to a canonical `ToolOutcome`. Missing owner /
  /// stale registration → `RuntimeFailure("MissingOwner")`; business errors
  /// → `ToolReportedError`; transport errors → `RuntimeFailure`.
  /// `effect_id` is the reducer-allocated identity of this `ExecuteTool`
  /// effect; hosts that propagate cancellation use it to correlate
  /// `cancel_effects` calls with in-flight executions.
  async fn execute_tool(
    Self,
    effect_id : EffectId,
    owner_id : @kernel.OwnerId,
    call_id : @kernel.CallId,
    tool_name : @kernel.ToolName,
    arguments : Json,
  ) -> @kernel.ToolOutcome

  /// Best-effort cancel. Fire-and-forget from the reducer's perspective.
  async fn cancel_effects(
    Self,
    effect_ids : Array[EffectId],
    reason : CancelReason,
  ) -> Array[(EffectId, CancelDisposition)]

  /// Compact the conversation. Forwards to `ModelPort::compact` and returns
  /// the compacted message body plus a `CompactMode`. `trigger` lets the
  /// modelport pick a strategy (Auto = cheap elision, Manual = thorough).
  async fn compact(
    Self,
    messages : Array[@kernel.Message],
    call_options : Json,
    trigger : @kernel.CompactTrigger,
  ) -> Result[@kernel.CompactResult, @kernel.ModelFailure]
}
