///|
/// Lifecycle: the extension-facing agent lifecycle, three phases.
///
/// - `on_compose`: called once, synchronously, after every composition gate
///   has passed (catalog atomic snapshot, model cardinality, collision
///   checks) and before the Agent is ready. This is where the composed
///   capabilities declared in the manifest's `requires` are delivered via
///   `CompositionView`. Sync on purpose: `ModelPort::chat` and
///   `UiPort::request` are async, so a sync composition point cannot *use*
///   what it wires — the type system enforces "wire, don't act". Raise
///   `CompositionError::ExtensionComposeFailed` to fail the composition
///   loudly; no partial Agent is produced.
/// - `on_start`: called once per Agent lifetime, inside the first
///   `run_turn` (an async context), before the first `TurnStarted` is
///   projected. This is the legitimate birth point for loading persisted
///   state or spawning background loops — construction time has no async
///   root. Not re-fired after `Suspended` resumes. Like other async slots
///   the body may raise; the Agent wraps a raised error loudly and the
///   first turn fails before any terminal event is emitted.
/// - `on_shutdown`: resource cleanup hook, called once on agent shutdown in
///   reverse registration order; cleanup failure propagates (loud).
///
/// All methods have defaults: an extension overrides only the phases it
/// cares about, and adding a phase is non-breaking (same pattern as `PipelineHook`).
pub(open) trait Lifecycle {
  fn on_compose(Self, ctx : CompositionView) -> Unit raise @error.CompositionError = _
  async fn on_start(Self) -> Unit = _
  async fn on_shutdown(Self) -> Unit
}

///|
/// Default `on_compose`: no wiring needed.
impl Lifecycle with fn on_compose(_self, _ctx : CompositionView) -> Unit {
  ()
}

///|
/// Default `on_start`: nothing to boot. Sync body satisfies the async slot.
impl Lifecycle with fn on_start(_self) -> Unit {
  ()
}
