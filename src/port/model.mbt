///|
/// ModelPort: the LLM calling interface. Every ext-deepseek / ext-openai /
/// ext-anthropic implements this. `chat` is the primary call; `chat_streaming`
/// has a default that ignores on_chunk and falls back to chat().
pub(open) trait ModelPort {
  async fn chat(
    Self,
    messages : Array[@types.Message],
    tools : Array[@types.ToolDef],
    options : @types.ChatOptions,
  ) -> @types.ModelResponse raise @error.ModelError

  /// Streaming chat. Default: ignores on_chunk, falls back to chat().
  async fn chat_streaming(
    Self,
    messages : Array[@types.Message],
    tools : Array[@types.ToolDef],
    options : @types.ChatOptions,
    on_chunk : (@types.StreamChunk) -> Unit,
  ) -> @types.ModelResponse raise @error.ModelError = _
}

///|
/// Default chat_streaming: ignores on_chunk, falls back to chat().
impl ModelPort with fn chat_streaming(
  self : Self,
  messages : Array[@types.Message],
  tools : Array[@types.ToolDef],
  options : @types.ChatOptions,
  _on_chunk : (@types.StreamChunk) -> Unit,
) -> @types.ModelResponse raise @error.ModelError {
  self.chat(messages, tools, options)
}
