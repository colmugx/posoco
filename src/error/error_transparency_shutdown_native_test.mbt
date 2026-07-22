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
  let model = @posoco.ScriptedModel::new([])
  let store = @posoco.RecordingSessionStore::new()
  let lifecycle = FailingLifecycle::{  }
  let agent = @posoco.Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[@posoco.NoopCompressor::{  }],
    observers=[],
    sessions=[store],
    lifecycle=Some(lifecycle),
    config=err_config(),
  )
  agent.shutdown()
}
