///|
/// Observer: read-only event listener. Two event channels:
///
/// - **Session-level** (`on_event`): TurnStarted / TurnCompleted / TurnFailed
///   etc. Fired at turn boundaries. Projection is currently batched at
///   turn end (see `LegacyEventProjector`); a future revision may deliver
///   these in real time.
///
/// - **Effect-level** (`on_kernel_event`): ModelCompleted / ToolCompleted /
///   ToolFailed / ModelFailed. Fired by the pump immediately after each
///   effect commits, right after `PostEventHook` handlers. This is the
///   real-time channel. Default impl is no-op so existing Observer
///   implementations are unaffected.
///
/// Both channels are read-only — never blocks or mutates. For interception
/// or abortion, implement `PreModelHook` / `PreToolHook` (they carry block
/// capability via `HookAbort` / `ToolHookDecision`).
pub(open) trait Observer {
  /// Session-level turn events. Default no-op: an extension that only
  /// cares about real-time effect events can implement just
  /// `on_kernel_event` and inherit this default.
  fn on_event(Self, event : @types.TurnEvent) -> Unit = _

  /// Effect-level events, fired in real time after each effect commits.
  /// Default no-op: existing Observer implementations that only care
  /// about session-level events are unaffected. Implement this to get
  /// per-effect telemetry without registering a separate PostEventHook.
  fn on_kernel_event(Self, event : PostStage) -> Unit = _
}

///|
/// Default implementation for `Observer::on_event`: no-op. Extensions
/// that want session-level telemetry override this; others inherit it.
impl Observer with fn on_event(_self, _event : @types.TurnEvent) -> Unit {
  ()
}

///|
/// Default implementation for `Observer::on_kernel_event`: no-op.
/// Existing Observer implementations that only override `on_event` are
/// unaffected — they automatically inherit this no-op default.
impl Observer with fn on_kernel_event(_self, _event : PostStage) -> Unit {
  ()
}
