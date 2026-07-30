///|
/// Native-only regression: shutdown cleanup failures must propagate.
///
/// The JS async test runner treats an uncaught panic as a process-level
/// failure, so this test belongs to the native target where the test harness
/// can report the expected panic without terminating unrelated tests.
struct FailingLifecycle {}

///|
pub impl @port.Lifecycle for FailingLifecycle with fn on_shutdown(_self) -> Unit {
  abort("shutdown cleanup failed")
}

///|
async test "panic t07_shutdown_failure_is_not_swallowed" {
  let model = @posoco.ScriptedModel([])
  let store = @posoco.RecordingSessionStore()
  let lifecycle = FailingLifecycle::{  }
  let agent = @posoco.Agent(
    exts=[
      @posoco.tk_ext(id="model", model=Some(model)),
      @posoco.tk_ext(id="io", sessions=[store], lifecycle=[lifecycle]),
    ],
    config=err_config(),
  )
  agent.shutdown()
}
