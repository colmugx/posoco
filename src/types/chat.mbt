///|
/// Provider-agnostic chat options. Trimmed in R3 M3.7 to just the two fields
/// every provider accepts. Provider-specific tuning (tool_choice, reasoning
/// effort, top_p, frequency_penalty, ...) belongs on the modelport's own
/// config struct, not on this shared bag — that way adding a new provider
/// never bloats the common type.
pub(all) struct ChatOptions {
  temperature : Double?
  max_output_tokens : Int?
} derive(Eq, Debug)

///|
/// Streaming mode for `ModelPort::chat`. See trait doc.
///
/// `NoStream` lets the modelport skip chunk wire-format work entirely (no SSE
/// parsing, no callback construction). `Stream(cb)` asks it to emit each chunk
/// to `cb` as a `StreamChunk`. The ADR §2.11 rationale still holds — streaming
/// is a host/telemetry concern, not a transcript fact — but the chunk contract
/// is now the canonical `StreamChunk` type, not a private JSON shape.
pub(all) enum StreamMode {
  NoStream
  Stream((StreamChunk) -> Unit)
} derive(Debug)

///|
pub impl Show for StreamMode with fn to_string(self : StreamMode) -> String {
  match self {
    NoStream => "NoStream"
    Stream(_) => "Stream(<callback>)"
  }
}
