///|
/// Observer: read-only event listener. One event channel:
///
/// - **Agent-level** (`on_event` / `on_event_at`): TurnStarted / model
///   response / tool pending and result / TurnCompleted / TurnFailed. Agent
///   projects these directly from committed runtime events; it never
///   reconstructs them by scanning a terminal transcript. `on_event_at`
///   additionally carries the `EventScope` attribution (session/run/turn);
///   the core dispatches only the scoped variant and its default delegates
///   here.
///
/// The channel is read-only — never blocks or mutates. For interception or
/// abortion, implement `PipelineHook::before_model` / `PipelineHook::before_tool` (they
/// carry block capability via `HookAbort` / `ToolDecision`); for
/// real-time per-effect telemetry implement `PipelineHook::on_post_event` — the
/// former effect-level observer channel was folded into `PipelineHook` (D5/BR-7).
pub(open) trait Observer {
  /// Session-level turn events. Default no-op: an extension that does not
  /// care about session-level events inherits this default.
  fn on_event(Self, event : @types.TurnEvent) -> Unit = _
  /// Scoped variant: the core dispatches ONLY this method; the default
  /// delegates to `on_event`, so pre-scope observers keep working unchanged.
  /// `scope` is `Some` for run-bound events (turn lifecycle, tool and model
  /// events projected from committed envelopes); out-of-run diagnostics
  /// (`StreamChunkReceived`, `Custom` secondary failures) may carry `None`.
  fn on_event_at(Self, scope : @types.EventScope?, event : @types.TurnEvent) -> Unit = _
}

///|
/// Default implementation for `Observer::on_event`: no-op. Extensions
/// that want session-level telemetry override this; others inherit it.
impl Observer with fn on_event(_self, _event : @types.TurnEvent) -> Unit {
  ()
}

///|
/// Default `Observer::on_event_at`: drop the scope and delegate to
/// `on_event`. Override this instead when attribution (session/run/turn
/// identity) matters.
impl Observer with fn on_event_at(
  self,
  _scope : @types.EventScope?,
  event : @types.TurnEvent,
) -> Unit {
  self.on_event(event)
}
