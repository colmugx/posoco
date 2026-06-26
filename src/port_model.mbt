///|
/// ModelPort: the LLM calling interface. Every ext-deepseek / ext-openai /
/// ext-anthropic implements this. `chat` is the primary call; `chat_streaming`
/// has a default that ignores on_chunk and falls back to chat().
pub(open) trait ModelPort {
  async fn chat(
    Self,
    messages : Array[Message],
    tools : Array[ToolDef],
    options : ChatOptions,
  ) -> ModelResponse raise ModelError

  /// Streaming chat. Default: ignores on_chunk, falls back to chat().
  async fn chat_streaming(
    Self,
    messages : Array[Message],
    tools : Array[ToolDef],
    options : ChatOptions,
    on_chunk : (StreamChunk) -> Unit,
  ) -> ModelResponse raise ModelError = _
}
