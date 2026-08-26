///|
/// ModelPort: LLM calling interface. Decides HOW to compact; posoco decides
/// WHEN. `chat` returns `ModelCallResult` with `processed_messages`.
///
/// Both model-side entry points receive an `InvocationScope` identifying the
/// session/run the call serves (`chat` additionally carries the reducer-
/// allocated effect id). Adapters that key behaviour on session identity —
/// continuity, telemetry, cost attribution, per-session policy — read it from
/// `scope`; scope-agnostic adapters ignore it. Treat it as read-only.
pub(open) trait ModelPort {
  /// One chat call. `Stream(cb)` emits chunks; `NoStream` skips chunk work.
  /// `messages` is an `ArrayView` borrow valid only for the duration of the
  /// call; adapters must not retain it.
  async fn chat(
    Self,
    scope : @kernel.InvocationScope,
    messages : ArrayView[@kernel.Message],
    tools : Array[@kernel.ToolDef],
    options : @types.ChatOptions,
    stream : @types.StreamMode,
  ) -> @kernel.ModelCallResult raise @error.ModelError

  /// Compact the conversation. `trigger` (Auto/Manual) is advisory — the
  /// modelport MAY use a cheaper strategy for Auto. Modelports that do not
  /// support compact should raise `ModelError::ResponseParse`.
  /// `scope.effect_id` is always `None` here: compact is host-driven, not a
  /// reducer-allocated effect. `messages` is an `ArrayView` borrow valid only
  /// for the duration of the call; adapters must not retain it.
  async fn compact(
    Self,
    scope : @kernel.InvocationScope,
    messages : ArrayView[@kernel.Message],
    options : @types.ChatOptions,
    trigger : @kernel.CompactTrigger,
  ) -> @kernel.CompactResult raise @error.ModelError

  /// Self-description: which config values this modelport accepts. A mismatch
  /// is not fatal — posoco emits a warning and resets. Pure function.
  fn provider_config(Self) -> ProviderConfig
}
