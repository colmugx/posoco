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
  // mutates the gate. The Puppet (T06) holds a PhaseGate and calls its
  // methods; it never reaches into fields.
  phase : PuppetPhase
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
pub fn PhaseGate::phase(self : PhaseGate) -> PuppetPhase {
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
/// Whether the gate is in a quiescent phase (delegates to PuppetPhase).
pub fn PhaseGate::is_quiescent(self : PhaseGate) -> Bool {
  self.phase.is_quiescent()
}

// ──────────────────────────────────────────────────────────────────────────
// Authorisation — which operation classes are allowed in each phase
// ──────────────────────────────────────────────────────────────────────────

///|
/// Decide whether an operation class is allowed in the current phase.
/// Returns `Ok` if allowed, or a typed `PuppetError` describing the
/// rejection (never a bare bool — the rejection reason is part of the
/// contract).
pub fn PhaseGate::authorise(
  self : PhaseGate,
  operation : OperationClass,
) -> Result[Unit, PuppetError] {
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
) -> (PhaseGate, OperationLease) raise PuppetError {
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
) -> (PhaseGate, OperationLease) raise PuppetError {
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
) -> Unit raise PuppetError {
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
// Internal mutators (used by the Puppet pump in T06)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Apply a transition. Internal — the Puppet (T06) is the only caller and
/// it has already acquired/released the lease as appropriate. Raises typed
/// error on illegal transitions.
///
/// The legal edges are encoded here once; everything else is rejected.
pub fn PhaseGate::transition(
  self : PhaseGate,
  to : PuppetPhase,
) -> PhaseGate raise PuppetError {
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
      // From Idle: run_id/turn_id set by `bind_run` (called by the puppet
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
      // is released by the puppet on the final terminal dispatch.
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
/// Legal-edge table for PuppetPhase transitions. Single source of truth
/// for what transitions are allowed; `transition` and tests both consult it.
fn check_transition(from : PuppetPhase, to : PuppetPhase) -> Bool {
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
/// Enter Suspended phase with a suspension id. Called by the Puppet when
/// the reducer transitions to Suspended. Keeps run/turn identity.
pub fn PhaseGate::enter_suspended(
  self : PhaseGate,
  suspension_id : String,
) -> PhaseGate raise PuppetError {
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
) -> PhaseGate raise PuppetError {
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
