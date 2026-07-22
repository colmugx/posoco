///|
/// Harness phase gate (M2-T02).
///
/// ADR §4: the Harness maintains a macro-level phase machine ON TOP OF the
/// reducer's `Phase`. The reducer phase describes one Run's micro-state; the
/// Harness phase describes the product-level macro-state that gates which
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
// HarnessPhase (ADR §4 — Q7.1 recommendation: `HarnessPhase`)
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
pub(all) enum HarnessPhase {
  Idle
  Active
  Suspended
  Terminalizing
  ShuttingDown
  Shutdown
} derive(Eq, Debug)

///|
pub impl Show for HarnessPhase with fn to_string(self : HarnessPhase) -> String {
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
/// Shutdown per ADR §4. `wait_idle` wakes when the Harness reaches any of
/// these (with distinct typed status, never conflating Suspended with a
/// terminal outcome).
pub fn HarnessPhase::is_quiescent(self : HarnessPhase) -> Bool {
  match self {
    Idle => true
    Suspended => true
    Shutdown => true
    _ => false
  }
}

///|
/// Whether the Harness will accept ANY new host command. Once `Shutdown`
/// is reached, all commands fail with `HarnessError::AfterShutdown`.
pub fn HarnessPhase::is_accepting(self : HarnessPhase) -> Bool {
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
  acquired_phase : HarnessPhase
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
pub fn OperationLease::acquired_phase(self : OperationLease) -> HarnessPhase {
  self.acquired_phase
}

// ──────────────────────────────────────────────────────────────────────────
// TurnId — typed wrapper (sibling of RunId)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Identifier for a single turn within a Run. A Run may contain multiple
/// turns (initial prompt + follow-ups); turns never outlive their Run.
/// follow_up allocates a new TurnId under the same RunId.
pub(all) struct TurnId {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn TurnId::new(value : String) -> Result[TurnId, String] {
  if value == "" {
    Err("TurnId must be non-empty")
  } else {
    Ok(TurnId::{ value, })
  }
}

///|
pub fn TurnId::unchecked(value : String) -> TurnId {
  TurnId::{ value, }
}

///|
pub fn TurnId::to_string(self : TurnId) -> String {
  self.value
}

///|
pub impl Show for TurnId with fn to_string(self : TurnId) -> String {
  self.value
}

// ──────────────────────────────────────────────────────────────────────────
// HarnessError (phase gate subset; extended by T04/T05)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Typed errors raised by the Harness. Single suberror type because MoonBit
/// can raise only one error type per function — all Harness subsystems
/// contribute variants here (phase/journal/lifecycle/event/control).
///
/// Variants are grouped by subsystem; new subsystems append, they do not
/// rename existing variants.
pub(all) suberror HarnessError {
  // ── Phase gate (T02) ──
  /// Operation requested in a phase that does not accept it.
  IllegalPhaseTransition(
    from~ : HarnessPhase,
    to~ : HarnessPhase,
    operation~ : OperationClass,
    detail~ : String
  )
  /// Operation class not allowed in this phase (e.g. Structural while Active).
  OperationNotAllowedInPhase(
    phase~ : HarnessPhase,
    operation~ : OperationClass,
    detail~ : String
  )
  /// A structural lease is already held; second concurrent prompt rejected.
  LeaseHeld(operation_id~ : String, held_by~ : String)
  /// Release called with the wrong owner or after the lease was already
  /// released.
  LeaseNotHeld(operation_id~ : String, detail~ : String)
  /// Host command issued after Harness reached Shutdown.
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
  /// Reducer raised KernelError (host-fatal; aborts the product lifecycle).
  ReducerInvariantViolation(category~ : InvariantCategory)
}

///|
/// Why a savepoint failed (ADR §5 failure handling).
pub(all) enum SavepointFailureCause {
  /// Contributor raised or returned Err.
  ContributorRaised(contributor_id~ : String, detail~ : String)
  /// Harness validation rejected an entry (wrong kind, stale id, etc.).
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
pub impl Show for HarnessError with fn to_string(self : HarnessError) -> String {
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
    ReducerInvariantViolation(category~) =>
      "ReducerInvariantViolation(\{category.to_string()})"
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

// ──────────────────────────────────────────────────────────────────────────
// PhaseGate — the state machine + lease tracker
// ──────────────────────────────────────────────────────────────────────────

///|
/// The phase gate. Holds the current macro-phase and (optionally) the
/// outstanding lease. All transitions go through `transition` / `acquire`
/// / `release`, which validate and raise typed errors on misuse.
///
/// Construction: `PhaseGate::idle()` is the only public constructor.
pub struct PhaseGate {
  // Field visibility is package-private: only this file constructs or
  // mutates the gate. The Harness (T06) holds a PhaseGate and calls its
  // methods; it never reaches into fields.
  phase : HarnessPhase
  lease : OperationLease?
  /// Run id currently bound to the gate (None when Idle). Survives
  /// Active→Suspended→Active.
  active_run_id : RunId?
  /// Turn id currently bound to the gate. Replaced on follow_up.
  active_turn_id : TurnId?
  /// Suspension id when in Suspended phase. None otherwise.
  active_suspension_id : String?
}

///|
pub fn PhaseGate::idle() -> PhaseGate {
  {
    phase: Idle,
    lease: None,
    active_run_id: None,
    active_turn_id: None,
    active_suspension_id: None,
  }
}

///|
/// Current macro-phase. Read-only accessor.
pub fn PhaseGate::phase(self : PhaseGate) -> HarnessPhase {
  self.phase
}

///|
/// Currently-held lease, if any.
pub fn PhaseGate::lease(self : PhaseGate) -> OperationLease? {
  self.lease
}

///|
/// Run id currently bound to the gate. None when Idle.
pub fn PhaseGate::active_run_id(self : PhaseGate) -> RunId? {
  self.active_run_id
}

///|
/// Turn id currently bound to the gate.
pub fn PhaseGate::active_turn_id(self : PhaseGate) -> TurnId? {
  self.active_turn_id
}

///|
/// Suspension id when Suspended; None otherwise.
pub fn PhaseGate::active_suspension_id(self : PhaseGate) -> String? {
  self.active_suspension_id
}

///|
/// Whether the gate is in a quiescent phase (delegates to HarnessPhase).
pub fn PhaseGate::is_quiescent(self : PhaseGate) -> Bool {
  self.phase.is_quiescent()
}

// ──────────────────────────────────────────────────────────────────────────
// Authorisation — which operation classes are allowed in each phase
// ──────────────────────────────────────────────────────────────────────────

///|
/// Decide whether an operation class is allowed in the current phase.
/// Returns `Ok` if allowed, or a typed `HarnessError` describing the
/// rejection (never a bare bool — the rejection reason is part of the
/// contract).
pub fn PhaseGate::authorise(
  self : PhaseGate,
  operation : OperationClass,
) -> Result[Unit, HarnessError] {
  match (self.phase, operation) {
    // Idle accepts Prompt (prompt/continue/resume is a new Run start in this
    // state) and Structural (M5 reservation). It rejects InFlight (no active
    // Run to modify).
    (Idle, Prompt) => Ok(())
    (Idle, Structural) => Ok(())
    (Idle, InFlight) =>
      Err(
        OperationNotAllowedInPhase(
          phase=Idle,
          operation~,
          detail="no active run; InFlight operations require Active or Suspended",
        ),
      )
    // Active accepts InFlight (steer/follow_up/abort). It rejects Prompt
    // (one Run at a time) and Structural (compaction during a Run corrupts).
    (Active, InFlight) => Ok(())
    (Active, Prompt) =>
      Err(
        OperationNotAllowedInPhase(
          phase=Active,
          operation~,
          detail="a run is already active; second prompt rejected",
        ),
      )
    (Active, Structural) =>
      Err(
        OperationNotAllowedInPhase(
          phase=Active,
          operation~,
          detail="structural operations require Idle phase",
        ),
      )
    // Suspended accepts resume (InFlight, since it operates on the suspended
    // Run) and abort. It rejects Prompt (no new Run while suspended) and
    // Structural.
    (Suspended, InFlight) => Ok(())
    (Suspended, Prompt) =>
      Err(
        OperationNotAllowedInPhase(
          phase=Suspended,
          operation~,
          detail="a run is suspended; resume or abort it first",
        ),
      )
    (Suspended, Structural) =>
      Err(
        OperationNotAllowedInPhase(
          phase=Suspended,
          operation~,
          detail="structural operations require Idle phase",
        ),
      )
    // Terminalizing / ShuttingDown / Shutdown reject everything.
    (Terminalizing, _) =>
      Err(
        OperationNotAllowedInPhase(
          phase=Terminalizing,
          operation~,
          detail="terminalization in progress",
        ),
      )
    (ShuttingDown, _) =>
      Err(
        OperationNotAllowedInPhase(
          phase=ShuttingDown,
          operation~,
          detail="shutdown in progress",
        ),
      )
    (Shutdown, _) => Err(AfterShutdown(command=operation.to_string()))
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Lease acquire / release
// ──────────────────────────────────────────────────────────────────────────

///|
/// Acquire a structural lease for a new prompt/continue. Returns the updated
/// gate and the lease on success. Raises typed errors for:
/// - lease already held (LeaseHeld)
/// - phase does not accept Prompt (OperationNotAllowedInPhase)
///
/// The lease binds the gate to the given run_id / turn_id; subsequent
/// InFlight commands must target these IDs. The gate's `lease` / `active_run_id`
/// / `active_turn_id` fields are updated atomically with the lease creation.
pub fn PhaseGate::acquire_prompt(
  self : PhaseGate,
  operation_id : String,
  run_id : RunId,
  turn_id : TurnId,
) -> (PhaseGate, OperationLease) raise HarnessError {
  match self.authorise(Prompt) {
    Err(e) => raise e
    Ok(_) => ()
  }
  match self.lease {
    Some(existing) =>
      raise LeaseHeld(operation_id~, held_by=existing.operation_id)
    None => ()
  }
  let lease : OperationLease = {
    operation_id,
    acquired_phase: self.phase,
    run_id,
    turn_id,
  }
  let next : PhaseGate = {
    phase: self.phase,
    lease: Some(lease),
    active_run_id: Some(run_id),
    active_turn_id: Some(turn_id),
    active_suspension_id: None,
  }
  (next, lease)
}

///|
/// Acquire a lease for resume from Suspended. The run_id must match the
/// suspended run; the turn_id is inherited (resume does not allocate a new
/// turn). Returns the updated gate and the lease.
///
/// The lease replaces the previous prompt lease (the original prompt's
/// operation_id is no longer the holder). This is correct because resume
/// is a new authorisation point: subsequent abort/release must use the
/// resume operation_id, not the prompt's.
pub fn PhaseGate::acquire_resume(
  self : PhaseGate,
  operation_id : String,
  expected_suspension_id : String,
) -> (PhaseGate, OperationLease) raise HarnessError {
  match self.authorise(InFlight) {
    Err(e) => raise e
    Ok(_) => ()
  }
  match (self.phase, self.active_suspension_id, self.active_run_id) {
    (Suspended, Some(actual), Some(run)) => {
      if actual != expected_suspension_id {
        raise SuspensionIdMismatch(
          target_run_id=run,
          expected=expected_suspension_id,
          actual~,
        )
      }
      // Resume does NOT allocate a new turn; we re-use the active turn id.
      let turn = match self.active_turn_id {
        Some(t) => t
        None => TurnId::unchecked("__missing__")
      }
      let lease : OperationLease = {
        operation_id,
        acquired_phase: self.phase,
        run_id: run,
        turn_id: turn,
      }
      let next : PhaseGate = {
        phase: self.phase,
        lease: Some(lease),
        active_run_id: self.active_run_id,
        active_turn_id: self.active_turn_id,
        active_suspension_id: self.active_suspension_id,
      }
      (next, lease)
    }
    (_, _, _) =>
      raise OperationNotAllowedInPhase(
        phase=self.phase,
        operation=InFlight,
        detail="resume requires Suspended phase with an active suspension",
      )
  }
}

///|
/// Release the lease. Validates that the caller is the owner; releasing a
/// lease you don't own (or one that's already released) raises a typed
/// error. Idempotent release is the caller's responsibility, not the gate's.
pub fn PhaseGate::release(
  self : PhaseGate,
  operation_id : String,
) -> Unit raise HarnessError {
  match self.lease {
    None => raise LeaseNotHeld(operation_id~, detail="no lease currently held")
    Some(existing) => {
      if existing.operation_id != operation_id {
        raise LeaseNotHeld(
          operation_id~,
          detail="lease held by '\{existing.operation_id}', not '\{operation_id}'",
        )
      }
      ()
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Internal mutators (used by the Harness pump in T06)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Apply a transition. Internal — the Harness (T06) is the only caller and
/// it has already acquired/released the lease as appropriate. Raises typed
/// error on illegal transitions.
///
/// The legal edges are encoded here once; everything else is rejected.
pub fn PhaseGate::transition(
  self : PhaseGate,
  to : HarnessPhase,
) -> PhaseGate raise HarnessError {
  let legal = check_transition(self.phase, to)
  if !legal {
    raise IllegalPhaseTransition(
      from=self.phase,
      to~,
      operation=Prompt, // operation context is supplied by callers via separate methods
      detail="no legal edge between these phases",
    )
  }
  // Side-effects of specific transitions:
  // - Active→Suspended: keep run_id/turn_id/lease, set suspension_id (caller
  //   passes it via `transition_to_suspended`).
  // - Suspended→Active: clear suspension_id, keep run_id/turn_id/lease.
  // - →Idle: clear lease, run_id, turn_id, suspension_id.
  // - →ShuttingDown or →Shutdown: keep nothing relevant.
  match to {
    Idle =>
      {
        phase: Idle,
        lease: None,
        active_run_id: None,
        active_turn_id: None,
        active_suspension_id: None,
      }
    Active =>
      // From Suspended: clear suspension_id.
      // From Idle: run_id/turn_id set by `bind_run` (called by the harness
      // before transition).
      {
        phase: Active,
        lease: self.lease,
        active_run_id: self.active_run_id,
        active_turn_id: self.active_turn_id,
        active_suspension_id: None,
      }
    Suspended =>
      // Active→Suspended: everything preserved; suspension_id set by
      // `transition_to_suspended`.
      {
        phase: Suspended,
        lease: self.lease,
        active_run_id: self.active_run_id,
        active_turn_id: self.active_turn_id,
        active_suspension_id: self.active_suspension_id,
      }
    Terminalizing =>
      // Active/Suspended→Terminalizing: keep run id for diagnostics; lease
      // is released by the harness on the final terminal dispatch.
      {
        phase: Terminalizing,
        lease: self.lease,
        active_run_id: self.active_run_id,
        active_turn_id: self.active_turn_id,
        active_suspension_id: None,
      }
    ShuttingDown =>
      {
        phase: ShuttingDown,
        lease: None,
        active_run_id: None,
        active_turn_id: None,
        active_suspension_id: None,
      }
    Shutdown =>
      {
        phase: Shutdown,
        lease: None,
        active_run_id: None,
        active_turn_id: None,
        active_suspension_id: None,
      }
  }
}

///|
/// Legal-edge table for HarnessPhase transitions. Single source of truth
/// for what transitions are allowed; `transition` and tests both consult it.
fn check_transition(from : HarnessPhase, to : HarnessPhase) -> Bool {
  match (from, to) {
    // From Idle: only to Active (prompt) or ShuttingDown.
    (Idle, Active) => true
    (Idle, ShuttingDown) => true
    (Idle, _) => false
    // From Active: to Suspended, Terminalizing, or ShuttingDown.
    (Active, Suspended) => true
    (Active, Terminalizing) => true
    (Active, ShuttingDown) => true
    (Active, _) => false
    // From Suspended: to Active (resume), Terminalizing (abort), ShuttingDown.
    (Suspended, Active) => true
    (Suspended, Terminalizing) => true
    (Suspended, ShuttingDown) => true
    (Suspended, _) => false
    // From Terminalizing: only to Idle.
    (Terminalizing, Idle) => true
    (Terminalizing, _) => false
    // From ShuttingDown: only to Shutdown.
    (ShuttingDown, Shutdown) => true
    (ShuttingDown, _) => false
    // From Shutdown: nowhere.
    (Shutdown, _) => false
  }
}

///|
/// Enter Suspended phase with a suspension id. Called by the Harness when
/// the reducer transitions to Suspended. Keeps run/turn identity.
pub fn PhaseGate::enter_suspended(
  self : PhaseGate,
  suspension_id : String,
) -> PhaseGate raise HarnessError {
  let next = self.transition(Suspended)
  {
    phase: next.phase,
    lease: next.lease,
    active_run_id: next.active_run_id,
    active_turn_id: next.active_turn_id,
    active_suspension_id: Some(suspension_id),
  }
}

///|
/// Replace the active turn id. Used by follow_up at turn boundary to
/// allocate a new turn under the same run.
pub fn PhaseGate::rotate_turn(
  self : PhaseGate,
  new_turn_id : TurnId,
) -> PhaseGate raise HarnessError {
  match (self.phase, self.active_run_id) {
    (Active, Some(_)) =>
      {
        phase: self.phase,
        lease: self.lease,
        active_run_id: self.active_run_id,
        active_turn_id: Some(new_turn_id),
        active_suspension_id: None,
      }
    (_, _) =>
      raise IllegalPhaseTransition(
        from=self.phase,
        to=self.phase,
        operation=InFlight,
        detail="rotate_turn requires Active phase with a bound run",
      )
  }
}
