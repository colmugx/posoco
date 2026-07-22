///|
/// Lifecycle: resource cleanup hook. Called once on agent shutdown to release
/// connections, flush buffers, etc. async to allow IO during cleanup.
pub(open) trait Lifecycle {
  async fn on_shutdown(Self) -> Unit
}
