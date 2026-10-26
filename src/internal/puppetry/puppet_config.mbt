// ──────────────────────────────────────────────────────────────────────────
// PuppetConfig — composition root
// ──────────────────────────────────────────────────────────────────────────

///|
/// Inputs to build a Puppet. The host is any `&HostRuntime` satisfying the
/// canonical effect-execution contract; catalog-composition validation stays
/// the caller's responsibility.
pub(all) struct PuppetConfig {
  host : &@kernel_exec.HostRuntime
  /// Mutable so the Agent can swap in a refreshed snapshot at prompt
  /// boundaries via `Puppet::replace_catalog`. An in-flight run is
  /// unaffected: its RunState pinned the catalog version it started with.
  mut catalog : @kernel_exec.ToolCatalogSnapshot
  journal : &RunJournal
  contributors : Array[&JournalContributor]
  subscribers : Array[&EventSubscriber]
  /// Optional live chunk sink. `None` (the default product path) tells the
  /// HostRuntime to skip chunk JSON conversion altogether.
  stream_chunks : @kernel_exec.HostChunkCallback?
  /// Pipeline interception hooks, in registration order. `before_tool`
  /// decisions merge per `ToolDecision`'s contract (consent beats Reject;
  /// Reject feeds back to the model as `NotExecuted`).
  hooks : Array[&PipelineHook]
  tool_call_owners : Map[String, Array[String]]
  max_tool_depth : Int32?
  bound_tool_names : () -> Array[String]
  /// Livelock backstop only: max pump iterations before the pump declares
  /// PumpLoopExceeded. `None` disables the backstop. The kernel budget is
  /// the sole semantic limit; when a budget is configured this is derived
  /// generously from it (2 iterations per round + terminal iteration) so the
  /// budget always fires first.
  max_iterations : Int32?
  /// Slash command processors. The pump does NOT invoke these — they are
  /// registered so product code can reach them. They share the Puppet's
  /// mailbox, so `/compact` and `/fork-here` only enqueue signals the pump
  /// consumes at its safe points.
  commands : Array[&CommandPort]
  /// Session store used by fork (and by compact::NewThread) to write the new
  /// session carrying `parent_thread_id` lineage. `None` still forks
  /// in-memory (the id comes back via `PromptResult::ForkCompleted`) but saves
  /// nothing durably.
  session_store : &SessionStore?
  /// The shared control mailbox. Product composition owns the concrete
  /// `ControlMailbox` and lends this same instance to the Puppet, command
  /// ports and product-layer controllers.
  mailbox : &Mailbox
}

// ──────────────────────────────────────────────────────────────────────────
// Puppet — the assembled pump
// ──────────────────────────────────────────────────────────────────────────

///|
/// The assembled pump: construct once via `Puppet::new`, call `startup` once
/// before any prompt and `shutdown` once at product exit.
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
  mut auto_compact_attempt_version : Int32?
  context_states : Map[String, @types.ContextState]
}

///|
pub fn Puppet::Puppet(config : PuppetConfig) -> Puppet {
  {
    config,
    phase_gate: PhaseGate::idle(),
    mailbox: config.mailbox,
    last_completed_transcript: None,
    last_outcome: None,
    auto_compact_attempt_version: None,
    context_states: Map::from_array([]),
  }
}

///|
pub fn Puppet::session_context_state(
  self : Puppet,
  session_id : String,
) -> @types.ContextState? {
  self.context_states.get(session_id)
}

///|
pub fn Puppet::adopt_context_state(
  self : Puppet,
  session_id : String,
  state : @types.ContextState,
) -> Unit {
  self.context_states[session_id] = state
}

///|
pub fn Puppet::last_completed_transcript(self : Puppet) -> Transcript? {
  self.last_completed_transcript
}

///|
pub fn Puppet::last_terminal_outcome(self : Puppet) -> RunOutcome? {
  self.last_outcome
}

///|
/// Swap the tool catalog snapshot between runs. Returns `false` without
/// swapping while a run is active: an in-flight run keeps the snapshot and
/// catalog version its RunState started with.
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
/// Borrow the Puppet's mailbox so callers can enqueue
/// fork/compact/steer/abort commands for the pump's safe points.
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
  // ShuttingDown rejects further commands; active runs are not forcibly
  // aborted.
  self.phase_gate = self.phase_gate.transition(ShuttingDown)
  self.phase_gate = self.phase_gate.transition(Shutdown)
  // Wakes any wait_idle caller so it observes Shutdown.
  self.mailbox.set_quiescent(Shutdown)
}
