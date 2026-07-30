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
    messages : Array[Message],
    tool_definitions : Array[ToolDef],
    call_options : Json,
    on_chunk : HostChunkCallback?,
  ) -> Result[ModelCallResult, ModelFailure]

  /// Execute a single tool call. Looks up the owner, invokes the provider,
  /// and maps the result to a canonical `ToolOutcome`. Missing owner /
  /// stale registration → `RuntimeFailure("MissingOwner")`; business errors
  /// → `ToolReportedError`; transport errors → `RuntimeFailure`.
  async fn execute_tool(
    Self,
    owner_id : OwnerId,
    call_id : CallId,
    tool_name : ToolName,
    arguments : Json,
  ) -> ToolOutcome

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
    messages : Array[Message],
    call_options : Json,
    trigger : CompactTrigger,
  ) -> Result[CompactResult, ModelFailure]
}
