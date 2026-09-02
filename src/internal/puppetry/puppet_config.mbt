// ──────────────────────────────────────────────────────────────────────────
// PuppetConfig — composition root
// ──────────────────────────────────────────────────────────────────────────

///|
/// Inputs to build a Puppet. All fields are required; the Puppet owns
/// the lifetime of every reference.
///
/// The host is an `&HostRuntime` — any implementation (port adapter, direct
/// fixture, external host) that satisfies the canonical effect-execution
/// contract. Catalog-composition validation is the caller's responsibility.
pub(all) struct PuppetConfig {
  host : &@kernel_exec.HostRuntime
  /// Mutable so the Agent can swap in a refreshed snapshot at prompt
  /// boundaries via `Puppet::replace_catalog`. An in-flight run is
  /// unaffected: its RunState pinned the catalog version it started with.
  mut catalog : @kernel_exec.ToolCatalogSnapshot
  journal : &RunJournal
  contributors : Array[&JournalContributor]
  subscribers : Array[&EventSubscriber]
  /// Optional live chunk sink. `None` is the default product path and tells
  /// the HostRuntime to avoid chunk JSON conversion altogether.
  stream_chunks : @kernel_exec.HostChunkCallback?
  /// Pipeline interception hooks, in registration order. `before_tool`
  /// decisions merge per `ToolDecision`'s contract (consent beats
  /// Reject; Reject feeds back to the model as `NotExecuted`).
  hooks : Array[&PipelineHook]
  /// Livelock backstop only: max pump iterations before the pump declares
  /// PumpLoopExceeded. `None` disables the backstop. The kernel budget is
  /// the sole semantic limit; when a budget is configured this is derived
  /// generously from it (2 iterations per round + terminal iteration) so the
  /// budget always fires first.
  max_iterations : Int?
  /// Slash command processors. The pump does NOT invoke these —
  /// `BuiltinCommandPort` is registered here so product code can reach it
  /// through `puppet.commands()`. The BuiltinCommandPort holds a reference
  /// to the Puppet's ControlMailbox so its `/compact` and `/fork-here`
  /// enqueue fork/compact signals for the pump's safe points.
  commands : Array[&CommandPort]
  /// Session store used by fork (and by compact::NewThread) to write the
  /// new session carrying `parent_thread_id` lineage. `None` means the
  /// product did not configure persistence — fork still works in-memory
  /// (the new session id is returned via `PromptResult::ForkCompleted`),
  /// but nothing is durably saved.
  session_store : &SessionStore?
  /// The shared control mailbox. Product composition owns the concrete
  /// `ControlMailbox` instance and lends the same mailbox to the Puppet,
  /// command ports, and any product-layer controllers. Signals enqueued by
  /// those callers reach the pump's safe points.
  mailbox : &Mailbox
}

// ──────────────────────────────────────────────────────────────────────────
// Puppet — the assembled pump
// ──────────────────────────────────────────────────────────────────────────

///|
/// The Puppet. Construct once via `Puppet::new`; call `startup` once
/// before any prompt; call `shutdown` once at product exit.
///
/// The Puppet owns:
/// - PhaseGate (mutable)
/// - &Mailbox (borrowed from `PuppetConfig`; product composition owns the
///   concrete mailbox)
///
/// The Puppet borrows:
/// - &HostRuntime (from config)
/// - &RunJournal (from config)
/// - &JournalContributor[] (from config)
/// - &EventSubscriber[] (from config)
/// - ToolCatalogSnapshot (owned copy; snapshot immutable after capture)
pub struct Puppet {
  config : PuppetConfig
  mut phase_gate : PhaseGate
  /// Borrowed from `PuppetConfig.mailbox` so the Puppet, command ports, and
  /// product layer all share the SAME `ControlMailbox` instance.
  mailbox : &Mailbox
  /// Last terminal transcript. The Kernel owns the live transcript while a
  /// run is active; after a terminal commit the Puppet exposes this immutable
  /// snapshot so products can materialize their canonical session state.
  mut last_completed_transcript : Transcript?
  /// Last terminal outcome captured by the Puppet. `None` means no run has
  /// completed or the current run is suspended.
  mut last_outcome : RunOutcome?
  /// Run that already consumed its single auto-compact attempt (fired
  /// regardless of outcome, so a failed compact cannot become a retry loop).
  mut auto_compact_fired_run : RunId?
  /// Why the current/last run's auto-compact attempt was skipped, if it was.
  /// Drained by the Agent facade after each prompt and surfaced to observers
  /// as a secondary failure; the Puppet itself owns no observer channel.
  mut last_auto_compact_failure : String?
}

///|
pub fn Puppet::Puppet(config : PuppetConfig) -> Puppet {
  {
    config,
    phase_gate: PhaseGate::idle(),
    mailbox: config.mailbox,
    last_completed_transcript: None,
    last_outcome: None,
    auto_compact_fired_run: None,
    last_auto_compact_failure: None,
  }
}

///|
/// Drain the recorded auto-compact skip reason, if any. Resets the slot so
/// the next run starts clean.
pub fn Puppet::take_last_auto_compact_failure(self : Puppet) -> String? {
  let value = self.last_auto_compact_failure
  self.last_auto_compact_failure = None
  value
}

///|
/// Return the last terminal transcript captured by the Puppet. `None` means
/// no run has completed since construction or the current run is suspended.
pub fn Puppet::last_completed_transcript(self : Puppet) -> Transcript? {
  self.last_completed_transcript
}

///|
/// Return the last terminal outcome captured by the Puppet. `None` means no
/// run has completed since construction or the current run is suspended.
pub fn Puppet::last_terminal_outcome(self : Puppet) -> RunOutcome? {
  self.last_outcome
}

///|
/// Swap the tool catalog snapshot between runs. Returns `false` without
/// swapping when a run is active — an in-flight run always keeps the
/// snapshot (and catalog version) its RunState started with. Callers are
/// expected to swap only at prompt boundaries; the active-run guard is
/// defence in depth.
pub fn Puppet::replace_catalog(
  self : Puppet,
  catalog : @kernel_exec.ToolCatalogSnapshot,
) -> Bool {
  match self.mailbox.active_run_id() {
    Some(_) => false
    None => {
      self.config.catalog = catalog
      true
    }
  }
}

///|
pub fn Puppet::phase(self : Puppet) -> PuppetPhase {
  self.phase_gate.phase()
}

///|
/// Borrow the Puppet's mailbox. Product code (BuiltinCommandPort, test
/// harness) uses this to enqueue fork/compact/steer/abort commands that
/// the pump consumes at its safe points. Returns `&Mailbox` so the caller
/// and the pump observe the same underlying `ControlMailbox` instance —
/// mutation through the returned reference is visible to the pump.
pub fn Puppet::mailbox(self : Puppet) -> &Mailbox {
  self.mailbox
}

///|
pub fn Puppet::is_quiescent(self : Puppet) -> Bool {
  self.phase_gate.is_quiescent()
}

// ──────────────────────────────────────────────────────────────────────────
// Shutdown — phase gate + idle barrier wake
// ──────────────────────────────────────────────────────────────────────────

///|
/// Shut the pump down. Idempotent.
pub fn Puppet::shutdown(self : Puppet) -> Unit raise PuppetError {
  // Transition the phase gate to ShuttingDown so any in-flight command
  // is rejected. Active runs are not forcibly aborted (M2 single-threaded
  // means there is no in-flight run when shutdown is called).
  self.phase_gate = self.phase_gate.transition(ShuttingDown)
  self.phase_gate = self.phase_gate.transition(Shutdown)
  // Wake any wait_idle callers so they observe Shutdown.
  self.mailbox.set_quiescent(Shutdown)
}
