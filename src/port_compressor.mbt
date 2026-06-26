///|
/// Context passed to Compressor::compress.
pub(all) struct CompressContext {
  session_id : String
  model_context_window : Int?
} derive(Eq, Debug)

///|
/// Action returned by a Compressor. None = no compression; Replace =
/// substitute the message list; NewThread = start a fresh session with a
/// summary carried over.
pub(all) enum CompressAction {
  None
  Replace(Array[Message])
  NewThread(
    messages~ : Array[Message],
    new_session_id~ : String,
    messages_before~ : Int,
    messages_after~ : Int
  )
} derive(Eq, Debug)

///|
/// Compressor: pure function that decides how to shrink the message context.
/// Returns instructions (None/Replace/NewThread) — never saves sessions or
/// emits events directly; the Agent and Observer handle side effects.
pub(open) trait Compressor {
  fn compress(Self, messages : Array[Message], ctx : CompressContext) -> CompressAction
}
