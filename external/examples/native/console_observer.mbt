///|
/// ConsoleObserver — colorful event logger for the REPL demo
pub(all) struct ConsoleObserver {}

///|
pub impl @posoco.Observer for ConsoleObserver with fn on_event(
  _self,
  event : @posoco.TurnEvent,
) {
  match event {
    @posoco.TurnEvent::TurnStarted => println("🔄 Turn started")
    @posoco.TurnEvent::ToolCallPending(call) =>
      println("🔧 Calling: " + call.name)
    @posoco.TurnEvent::ToolCallResult(call~, result~, is_error~) =>
      if is_error {
        println("❌ Failed: " + result.content)
      } else {
        println("✅ Done: " + call.name)
      }
    @posoco.TurnEvent::ToolCallDeferred(call~, reason~) =>
      println("⚠️  DEFERRED: " + call.name + " — " + reason)
    @posoco.TurnEvent::ModelResponseReceived(..) => ()
    @posoco.TurnEvent::StreamChunkReceived(chunk~) =>
      match chunk {
        @posoco.StreamChunk::TextDelta(token~) => () // streamed tokens
        _ => ()
      }
    @posoco.TurnEvent::TurnCompleted => println("\n✅ Turn completed")
    @posoco.TurnEvent::TurnFailed(msg) => println("💥 Turn failed: " + msg)
    @posoco.TurnEvent::SessionRedirect(from~, to~, ..) =>
      println("📦 Session redirected: " + from + " → " + to)
    @posoco.TurnEvent::Custom(source~, label~, ..) =>
      println("📢 [" + source + "] " + label)
  }
}
