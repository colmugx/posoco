///|
/// ModelPort: LLM calling interface. Decides HOW to compact; posoco decides
/// WHEN. `chat` returns `ModelCallResult` with `processed_messages`.
pub(open) trait ModelPort {
  /// One chat call. `Stream(cb)` emits chunks; `NoStream` skips chunk work.
  async fn chat(
    Self,
    messages : Array[@kernel.Message],
    tools : Array[@kernel.ToolDef],
    options : @types.ChatOptions,
    stream : @types.StreamMode,
  ) -> @kernel.ModelCallResult raise @error.ModelError

  /// Compact the conversation. `trigger` (Auto/Manual) is advisory — the
  /// modelport MAY use a cheaper strategy for Auto. Modelports that do not
  /// support compact should raise `ModelError::ResponseParse`.
  async fn compact(
    Self,
    messages : Array[@kernel.Message],
    options : @types.ChatOptions,
    trigger : @kernel.CompactTrigger,
  ) -> @kernel.CompactResult raise @error.ModelError

  /// Self-description: which config values this modelport accepts. A mismatch
  /// is not fatal — posoco emits a warning and resets. Pure function.
  fn provider_config(Self) -> ProviderConfig
}
