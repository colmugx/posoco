///|
/// Observer: read-only event listener. One event channel:
///
/// - **Agent-level** (`on_event`): TurnStarted / model response / tool pending
///   and result / TurnCompleted / TurnFailed. Agent projects these directly
///   from committed runtime events; it never reconstructs them by scanning a
///   terminal transcript.
///
/// The channel is read-only — never blocks or mutates. For interception or
/// abortion, implement `Hook::before_model` / `Hook::before_tool` (they
/// carry block capability via `HookAbort` / `ToolHookDecision`); for
/// real-time per-effect telemetry implement `Hook::on_post_event` — the
/// former effect-level observer channel was folded into `Hook` (D5/BR-7).
pub(open) trait Observer {
  /// Session-level turn events. Default no-op: an extension that does not
  /// care about session-level events inherits this default.
  fn on_event(Self, event : @types.TurnEvent) -> Unit = _
}

///|
/// Default implementation for `Observer::on_event`: no-op. Extensions
/// that want session-level telemetry override this; others inherit it.
impl Observer with fn on_event(_self, _event : @types.TurnEvent) -> Unit {
  ()
}
