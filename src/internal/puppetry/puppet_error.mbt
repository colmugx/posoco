///|
/// Puppet phase gate (M2-T02).
///
/// ADR §4: the Puppet maintains a macro-level phase machine ON TOP OF the
/// reducer's `Phase`. The reducer phase describes one Run's micro-state; the
/// Puppet phase describes the product-level macro-state that gates which
/// host commands are accepted.
///
/// Invariants:
/// - At most one structural `OperationLease` is held at any time.
/// - `release` validates the owner; releasing a lease you don't own is a
///   typed error (never a silent success).
/// - `Suspended` retains the original `run_id` / `turn_id` so resume can
///   continue with monotonic sequence.
/// - Transitions out of `ShuttingDown` / `Shutdown` are illegal except the
///   final shutdown transition.

// ──────────────────────────────────────────────────────────────────────────
// PuppetPhase (ADR §4 — Q7.1 recommendation: `PuppetPhase`)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Product-level macro phase. Distinct from M1 `Phase` (which is per-Run
/// micro-state owned by the reducer).
///
/// Allowed transitions (ADR §4 diagram):
/// - Idle → Active            (prompt / continue accepted)
/// - Active → Suspended       (reducer enters Suspended)
/// - Suspended → Active       (resume)
/// - Active → Terminalizing   (terminal outcome committed)
/// - Suspended → Terminalizing (abort)
/// - Terminalizing → Idle     (terminal event dispatched + cleanup)
/// - Idle/Suspended/Active → ShuttingDown  (host shutdown call; Active defers)
/// - ShuttingDown → Shutdown  (lifecycle rollback complete)
pub(all) enum PuppetPhase {
  Idle
  Active
  Suspended
  Terminalizing
  ShuttingDown
  Shutdown
} derive(Eq, Debug)

///|
pub impl Show for PuppetPhase with fn to_string(self : PuppetPhase) -> String {
  match self {
    Idle => "Idle"
    Active => "Active"
    Suspended => "Suspended"
    Terminalizing => "Terminalizing"
    ShuttingDown => "ShuttingDown"
    Shutdown => "Shutdown"
  }
}

///|
/// Whether this phase is quiescent — the union of Idle, Suspended and
/// Shutdown per ADR §4. `wait_idle` wakes when the Puppet reaches any of
/// these (with distinct typed status, never conflating Suspended with a
/// terminal outcome).
pub fn PuppetPhase::is_quiescent(self : PuppetPhase) -> Bool {
  match self {
    Idle => true
    Suspended => true
    Shutdown => true
    _ => false
  }
}

///|
/// Whether the Puppet will accept ANY new host command. Once `Shutdown`
/// is reached, all commands fail with `PuppetError::AfterShutdown`.
pub fn PuppetPhase::is_accepting(self : PuppetPhase) -> Bool {
  match self {
    Shutdown => false
    _ => true
  }
}

// ──────────────────────────────────────────────────────────────────────────
// OperationClass
// ──────────────────────────────────────────────────────────────────────────

///|
/// Class of operation the phase gate is asked to authorise. ADR §6.8
/// reserves a `Structural` slot for M5 (branch/compact/retry); M2 implements
/// zero structural operations but the gate already knows how to reject them
/// outside `Idle`.
pub(all) enum OperationClass {
  /// `prompt`, `continue`, `resume` — start or continue a Run.
  Prompt
  /// `steer`, `follow_up`, `abort` — modify an active Run.
  InFlight
  /// Reserved for M5: branch, compact, retry. Always rejected outside Idle.
  Structural
} derive(Eq, Debug)

///|
pub impl Show for OperationClass with fn to_string(self : OperationClass) -> String {
  match self {
    Prompt => "Prompt"
    InFlight => "InFlight"
    Structural => "Structural"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// OperationLease
// ──────────────────────────────────────────────────────────────────────────

///|
/// A structural lease. At most one is held at any time (ADR §4 rule 1).
/// Acquired by `prompt`/`continue`/`resume`; released on terminal outcome,
/// abort, or shutdown. Records the owner operation id and the phase at which
/// the lease was acquired so release can validate provenance.
pub(all) struct OperationLease {
  /// Stable identifier for the operation that acquired the lease. Typically
  /// the `command_id` of the prompt/resume.
  operation_id : String
  /// Phase at acquisition. Used by release to detect misuse (e.g. releasing
  /// a Prompt lease during a Structural operation).
  acquired_phase : PuppetPhase
  /// Run id the lease is bound to. Set for Prompt/InFlight; empty for
  /// Structural reservations.
  run_id : RunId
  /// Turn id the lease is bound to. Empty for non-Prompt leases.
  turn_id : TurnId
} derive(Eq, Debug)

///|
pub impl Show for OperationLease with fn to_string(self : OperationLease) -> String {
  "OperationLease(op=\{self.operation_id}, phase=\{self.acquired_phase.to_string()}, run=\{self.run_id.to_string()}, turn=\{self.turn_id.to_string()})"
}

///|
pub fn OperationLease::operation_id(self : OperationLease) -> String {
  self.operation_id
}

///|
pub fn OperationLease::run_id(self : OperationLease) -> RunId {
  self.run_id
}

///|
pub fn OperationLease::turn_id(self : OperationLease) -> TurnId {
  self.turn_id
}

///|
pub fn OperationLease::acquired_phase(self : OperationLease) -> PuppetPhase {
  self.acquired_phase
}

// ──────────────────────────────────────────────────────────────────────────
// TurnId — canonical definition lives in `@kernel` (`domain_run.mbt`);
// this package aliases it via `imports.mbt`.
// ──────────────────────────────────────────────────────────────────────────

// ──────────────────────────────────────────────────────────────────────────
// PuppetError (phase gate subset; extended by T04/T05)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Typed errors raised by the Puppet. Single suberror type because MoonBit
/// can raise only one error type per function — all Puppet subsystems
/// contribute variants here (phase/journal/lifecycle/event/control).
///
/// Variants are grouped by subsystem; new subsystems append, they do not
/// rename existing variants.
pub(all) suberror PuppetError {
  // ── Phase gate (T02) ──
  /// Operation requested in a phase that does not accept it.
  IllegalPhaseTransition(
    from~ : PuppetPhase,
    to~ : PuppetPhase,
    operation~ : OperationClass,
    detail~ : String
  )
  /// Operation class not allowed in this phase (e.g. Structural while Active).
  OperationNotAllowedInPhase(
    phase~ : PuppetPhase,
    operation~ : OperationClass,
    detail~ : String
  )
  /// A structural lease is already held; second concurrent prompt rejected.
  LeaseHeld(operation_id~ : String, held_by~ : String)
  /// Release called with the wrong owner or after the lease was already
  /// released.
  LeaseNotHeld(operation_id~ : String, detail~ : String)
  /// Host command issued after Puppet reached Shutdown.
  AfterShutdown(command~ : String)
  /// Snapshot capture failed (empty model, invalid budget, etc.).
  SnapshotInvalid(detail~ : String)
  // ── Control queues (T03) ──
  /// Steer/follow-up/resume target id does not match the active run/turn.
  StaleIdentity(kind~ : String, expected~ : String, actual~ : String)
  /// Queue is full; enqueue rejected.
  QueueFull(kind~ : String, depth~ : Int)
  /// Resume payload does not satisfy the suspension requirement.
  SuspensionPayloadMismatch(suspension_id~ : String, expected_kind~ : String)
  /// Resume targeted a suspension that does not exist or was already resumed.
  SuspensionIdMismatch(
    target_run_id~ : RunId,
    expected~ : String,
    actual~ : String
  )
  /// Abort called on a run that is already terminal.
  AbortNoActiveRun(run_id~ : RunId)
  // ── Journal / contribution (T04) ──
  /// Savepoint validation or commit failed; the frozen batch is retained.
  SavepointFailed(kind~ : String, cause~ : SavepointFailureCause)
  /// Contributor returned an invalid entry (wrong kind, stale identity).
  ContributionInvalid(contributor_id~ : String, detail~ : String)
  /// Post-commit subscriber attempted to mutate the journal (contract
  /// violation; subscribers never receive the writer).
  SubscriberJournalMutation(subscriber_id~ : String)
  // ── Lifecycle / events (T05) ──
  /// Lifecycle node failed to start; initial failure preserved, rollback
  /// failures aggregated.
  LifecycleStartupFailed(
    node_id~ : String,
    cause~ : String,
    rollback_failures~ : Array[(String, String)]
  )
  /// Lifecycle node failed to shut down cleanly.
  LifecycleShutdownFailed(
    node_id~ : String,
    cause~ : String,
    other_failures~ : Array[(String, String)]
  )
  /// Duplicate lifecycle node id or double registration.
  LifecycleDuplicate(node_id~ : String)
  /// Post-commit subscriber raised; journal entry already durable.
  SubscriberFailed(
    subscriber_id~ : String,
    cause~ : String,
    committed_revision~ : Int
  )
  // ── Pump / orchestration (T06) ──
  /// Driver exceeded its iteration safety bound.
  PumpLoopExceeded(iterations~ : Int)
  /// Effect completion arrived for an unknown or already-terminal effect.
  DuplicateOrLateCompletion(effect_id~ : EffectId, detail~ : String)
  /// A host/executor task raised instead of returning its typed canonical
  /// completion. This is never converted into a normal tool outcome.
  EffectExecutionFailed(phase~ : String, cause~ : String)
  /// The async runtime cancelled a model or tool wave. Kept distinct from a
  /// host failure so callers can diagnose interruption without guessing from
  /// a generic error string.
  EffectExecutionCancelled(phase~ : String)
  /// Reducer raised KernelError (host-fatal; aborts the product lifecycle).
  ReducerInvariantViolation(category~ : InvariantCategory)
  /// A pre-model or pre-tool hook aborted the run.
  HookRejected(reason~ : String)
}

///|
/// Why a savepoint failed (ADR §5 failure handling).
pub(all) enum SavepointFailureCause {
  /// Contributor raised or returned Err.
  ContributorRaised(contributor_id~ : String, detail~ : String)
  /// Puppet validation rejected an entry (wrong kind, stale id, etc.).
  ValidationFailed(detail~ : String)
  /// Journal append or durability barrier failed.
  BarrierFailed(detail~ : String)
} derive(Eq, Debug)

///|
pub impl Show for SavepointFailureCause with fn to_string(
  self : SavepointFailureCause,
) -> String {
  match self {
    ContributorRaised(contributor_id~, detail~) =>
      "ContributorRaised(\{contributor_id}: \{safe_label(detail)})"
    ValidationFailed(detail~) => "ValidationFailed(\{safe_label(detail)})"
    BarrierFailed(detail~) => "BarrierFailed(\{safe_label(detail)})"
  }
}

///|
pub impl Show for PuppetError with fn to_string(self : PuppetError) -> String {
  match self {
    IllegalPhaseTransition(from~, to~, operation~, detail~) =>
      "IllegalPhaseTransition(\{from.to_string()}→\{to.to_string()}, op=\{operation.to_string()}, \{safe_label(detail)})"
    OperationNotAllowedInPhase(phase~, operation~, detail~) =>
      "OperationNotAllowedInPhase(\{phase.to_string()}, op=\{operation.to_string()}, \{safe_label(detail)})"
    LeaseHeld(operation_id~, held_by~) =>
      "LeaseHeld(op=\{safe_label(operation_id)}, held_by=\{safe_label(held_by)})"
    LeaseNotHeld(operation_id~, detail~) =>
      "LeaseNotHeld(op=\{safe_label(operation_id)}, \{safe_label(detail)})"
    AfterShutdown(command~) => "AfterShutdown(cmd=\{safe_label(command)})"
    SnapshotInvalid(detail~) => "SnapshotInvalid(\{safe_label(detail)})"
    StaleIdentity(kind~, expected~, actual~) =>
      "StaleIdentity(\{kind}, expected=\{safe_label(expected)}, actual=\{safe_label(actual)})"
    QueueFull(kind~, depth~) => "QueueFull(\{kind}, depth=\{depth})"
    SuspensionPayloadMismatch(suspension_id~, expected_kind~) =>
      "SuspensionPayloadMismatch(susp=\{safe_label(suspension_id)}, kind=\{safe_label(expected_kind)})"
    SuspensionIdMismatch(target_run_id~, expected~, actual~) =>
      "SuspensionIdMismatch(run=\{target_run_id.to_string()}, expected=\{safe_label(expected)}, actual=\{safe_label(actual)})"
    AbortNoActiveRun(run_id~) => "AbortNoActiveRun(run=\{run_id.to_string()})"
    SavepointFailed(kind~, cause~) =>
      "SavepointFailed(\{kind}, \{cause.to_string()})"
    ContributionInvalid(contributor_id~, detail~) =>
      "ContributionInvalid(\{safe_label(contributor_id)}, \{safe_label(detail)})"
    SubscriberJournalMutation(subscriber_id~) =>
      "SubscriberJournalMutation(\{safe_label(subscriber_id)})"
    LifecycleStartupFailed(node_id~, cause~, rollback_failures~) =>
      "LifecycleStartupFailed(node=\{safe_label(node_id)}, cause=\{safe_label(cause)}, rollback=[\{rollback_failures.length()} failures])"
    LifecycleShutdownFailed(node_id~, cause~, other_failures~) =>
      "LifecycleShutdownFailed(node=\{safe_label(node_id)}, cause=\{safe_label(cause)}, other=[\{other_failures.length()} failures])"
    LifecycleDuplicate(node_id~) =>
      "LifecycleDuplicate(node=\{safe_label(node_id)})"
    SubscriberFailed(subscriber_id~, cause~, committed_revision~) =>
      "SubscriberFailed(\{safe_label(subscriber_id)}, rev=\{committed_revision}, \{safe_label(cause)})"
    PumpLoopExceeded(iterations~) => "PumpLoopExceeded(\{iterations})"
    DuplicateOrLateCompletion(effect_id~, detail~) =>
      "DuplicateOrLateCompletion(effect=\{effect_id.to_int()}, \{safe_label(detail)})"
    EffectExecutionFailed(phase~, cause~) =>
      "EffectExecutionFailed(phase=\{safe_label(phase)}, \{safe_label(cause)})"
    EffectExecutionCancelled(phase~) =>
      "EffectExecutionCancelled(phase=\{safe_label(phase)})"
    ReducerInvariantViolation(category~) =>
      "ReducerInvariantViolation(\{category.to_string()})"
    HookRejected(reason~) => "HookRejected(\{safe_label(reason)})"
  }
}

///|
/// Bounded single-line label helper. Mirrors `safe_event_label` so the error
/// file has no cross-file dependency.
fn safe_label(value : String) -> String {
  let chars : Array[Char] = []
  let mut truncated = false
  for char in value {
    if chars.length() >= 64 {
      truncated = true
      break
    }
    match char {
      '\n' | '\r' => chars.push(' ')
      other => chars.push(other)
    }
  }
  let label = String::from_array(chars)
  if truncated {
    label + "...(truncated)"
  } else {
    label
  }
}
