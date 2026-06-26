///|
/// Observer: read-only event listener. Never blocks or mutates — use
/// PipelineHook for interception/abortion. Receives TurnEvent for every
/// significant turn lifecycle event.
pub(open) trait Observer {
  fn on_event(Self, event : TurnEvent) -> Unit
}
