///|
/// ConsoleObserver — colorful event logger for the REPL demo
pub(all) struct ConsoleObserver {}

///|
pub impl @posoco.Observer for ConsoleObserver with on_event(
  _self,
  event : @posoco.TurnEvent,
) {
  match event {
    @posoco.TurnStarted => println("🔄 Turn started")
    @posoco.ToolCallPending(call) => println("🔧 Pending: " + call.name)
    @posoco.ToolCallResult(call~, result~, is_error~) =>
      if is_error {
        println("❌ Failed: " + result.content)
      } else {
        println("✅ Done: " + result.content)
      }
    @posoco.ToolCallDeferred(call~, reason~) =>
      println("⚠️  DEFERRED: " + call.name + " — " + reason)
    @posoco.ModelResponseReceived(..) => ()
    @posoco.TurnCompleted => println("✅ Turn completed")
    @posoco.TurnFailed(msg) => println("💥 Turn failed: " + msg)
    @posoco.SessionRedirect(from~, to~, ..) =>
      println("📦 Session redirected: " + from + " → " + to)
    @posoco.Custom(source~, label~, ..) =>
      println("📢 [" + source + "] " + label)
  }
}
