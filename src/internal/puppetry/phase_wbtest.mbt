///|
/// Whitebox tests for M2-T02 phase gate.
///
/// Coverage:
/// - Initial state is Idle
/// - Legal transitions match ADR §4 diagram
/// - Illegal transitions raise typed PuppetError
/// - Lease exclusivity (C-LEASE-EXCLUSIVE seam)
/// - Operation class authorisation per phase
/// - Suspended retains run_id/turn_id
/// - rotate_turn only in Active
/// - enter_suspended sets suspension_id

// ──────────────────────────────────────────────────────────────────────────
// Helpers — run raise-resulting calls and capture the typed error
// ──────────────────────────────────────────────────────────────────────────

///|
/// Run a raise-resulting call and capture its typed error, if any.
fn try_acquire_prompt(
  gate : PhaseGate,
  op_id : String,
  run_id : RunId,
  turn_id : TurnId,
) -> PuppetError? {
  try {
    ignore(gate.acquire_prompt(op_id, run_id, turn_id))
    None
  } catch {
    e => Some(e)
  }
}

///|
fn try_acquire_resume(
  gate : PhaseGate,
  op_id : String,
  susp_id : String,
) -> PuppetError? {
  try {
    ignore(gate.acquire_resume(op_id, susp_id))
    None
  } catch {
    e => Some(e)
  }
}

///|
fn try_release(gate : PhaseGate, op_id : String) -> PuppetError? {
  try {
    gate.release(op_id)
    None
  } catch {
    e => Some(e)
  }
}

///|
fn try_gate_transition(gate : PhaseGate, to : PuppetPhase) -> PuppetError? {
  try {
    ignore(gate.transition(to))
    None
  } catch {
    e => Some(e)
  }
}

///|
fn try_rotate_turn(gate : PhaseGate, new_turn_id : TurnId) -> PuppetError? {
  try {
    ignore(gate.rotate_turn(new_turn_id))
    None
  } catch {
    e => Some(e)
  }
}

///|
fn try_authorise(gate : PhaseGate, op : OperationClass) -> PuppetError? {
  try {
    gate.authorise(op)
    None
  } catch {
    e => Some(e)
  }
}

///|
fn gate_run_id() -> RunId {
  RunId::unchecked("run_test")
}

///|
fn gate_turn_id() -> TurnId {
  TurnId::unchecked("turn_1")
}

///|
/// Build an Active gate bound to the given run/turn. Common fixture for
/// tests that need to start from Active.
fn active_gate(op_id : String) -> PhaseGate raise PuppetError {
  let idle = PhaseGate::idle()
  let (g, _) = idle.acquire_prompt(op_id, gate_run_id(), gate_turn_id())
  g.transition(Active)
}

// ──────────────────────────────────────────────────────────────────────────
// Initial state
// ──────────────────────────────────────────────────────────────────────────

///|
test "puppet_phase/initial_is_idle" {
  let g = PhaseGate::idle()
  assert_true(g.phase() == Idle)
  assert_true(g.is_quiescent())
  assert_true(g.lease() is None)
  assert_true(g.active_run_id() is None)
}

// ──────────────────────────────────────────────────────────────────────────
// Operation class authorisation
// ──────────────────────────────────────────────────────────────────────────

///|
test "puppet_phase/idle_accepts_prompt_and_structural" {
  let g = PhaseGate::idle()
  assert_true(try_authorise(g, Prompt) is None)
  assert_true(try_authorise(g, Structural) is None)
  // InFlight in Idle is illegal: no active run.
  let err = try_authorise(g, InFlight)
  assert_true(err is Some(OperationNotAllowedInPhase(..)))
  match err {
    Some(OperationNotAllowedInPhase(phase~, operation~, detail~)) => {
      assert_true(phase == Idle)
      assert_true(operation == InFlight)
      assert_true(detail.contains("no active run"))
    }
    _ => fail("expected OperationNotAllowedInPhase")
  }
}

///|
test "puppet_phase/active_rejects_prompt_and_structural" {
  let active = active_gate("op1")
  assert_true(try_authorise(active, InFlight) is None)
  let prompt_err = try_authorise(active, Prompt)
  assert_true(prompt_err is Some(OperationNotAllowedInPhase(..)))
  match prompt_err {
    Some(OperationNotAllowedInPhase(phase=Active, detail~, ..)) =>
      assert_true(detail.contains("already active"))
    _ => fail("expected OperationNotAllowedInPhase for Prompt")
  }
  let structural_err = try_authorise(active, Structural)
  assert_true(structural_err is Some(OperationNotAllowedInPhase(..)))
  match structural_err {
    Some(OperationNotAllowedInPhase(phase=Active, detail~, ..)) =>
      assert_true(detail.contains("structural operations require Idle"))
    _ => fail("expected OperationNotAllowedInPhase for Structural")
  }
}

///|
test "puppet_phase/shutdown_rejects_all" {
  let g = PhaseGate::idle()
  let g = g.transition(ShuttingDown)
  let g = g.transition(Shutdown)
  assert_true(try_authorise(g, Prompt) is Some(AfterShutdown(..)))
  assert_true(try_authorise(g, InFlight) is Some(AfterShutdown(..)))
  assert_true(try_authorise(g, Structural) is Some(AfterShutdown(..)))
  // All commands surface as AfterShutdown carrying the command name.
  match try_authorise(g, Prompt) {
    Some(AfterShutdown(command~)) => assert_true(command == "Prompt")
    _ => fail("expected AfterShutdown")
  }
  match try_authorise(g, InFlight) {
    Some(AfterShutdown(command~)) => assert_true(command == "InFlight")
    _ => fail("expected AfterShutdown for InFlight")
  }
  match try_authorise(g, Structural) {
    Some(AfterShutdown(command~)) => assert_true(command == "Structural")
    _ => fail("expected AfterShutdown for Structural")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Legal transitions (ADR §4 diagram)
// ──────────────────────────────────────────────────────────────────────────

///|
test "puppet_phase/legal_transition_idle_to_active" {
  let idle = PhaseGate::idle()
  let (g, _lease) = idle.acquire_prompt("op1", gate_run_id(), gate_turn_id())
  assert_true(g.active_run_id() == Some(gate_run_id()))
  let g = g.transition(Active)
  assert_true(g.phase() == Active)
}

///|
test "puppet_phase/legal_transition_active_to_suspended" {
  let active = active_gate("op1")
  let g = active.enter_suspended("susp_1")
  assert_true(g.phase() == Suspended)
  // Run id preserved across suspension.
  assert_true(g.active_run_id() == Some(gate_run_id()))
  assert_true(g.active_turn_id() == Some(gate_turn_id()))
  assert_true(g.active_suspension_id() == Some("susp_1"))
}

///|
test "puppet_phase/legal_transition_suspended_to_active_resume" {
  let active = active_gate("op1")
  let g = active.enter_suspended("susp_1")
  // Resume: acquire_resume checks suspension_id match and rotates lease.
  let (g, resume_lease) = g.acquire_resume("op2", "susp_1")
  assert_true(resume_lease.operation_id() == "op2")
  let g = g.transition(Active)
  assert_true(g.phase() == Active)
  assert_true(g.active_suspension_id() is None)
  // Run id still preserved.
  assert_true(g.active_run_id() == Some(gate_run_id()))
}

///|
test "puppet_phase/legal_transition_active_to_terminalizing_to_idle" {
  let mut g = active_gate("op1")
  g = g.transition(Terminalizing)
  assert_true(g.phase() == Terminalizing)
  g = g.transition(Idle)
  assert_true(g.phase() == Idle)
  assert_true(g.lease() is None)
  assert_true(g.active_run_id() is None)
}

///|
test "puppet_phase/legal_shutdown_path" {
  let g = PhaseGate::idle()
  let g = g.transition(ShuttingDown)
  assert_true(g.phase() == ShuttingDown)
  let g = g.transition(Shutdown)
  assert_true(g.phase() == Shutdown)
}

// ──────────────────────────────────────────────────────────────────────────
// Illegal transitions
// ──────────────────────────────────────────────────────────────────────────

///|
test "puppet_phase/illegal_idle_to_suspended" {
  let g = PhaseGate::idle()
  let result = try_gate_transition(g, Suspended)
  assert_true(result is Some(IllegalPhaseTransition(..)))
  match result {
    Some(IllegalPhaseTransition(from~, to~, detail~, ..)) => {
      assert_true(from == Idle)
      assert_true(to == Suspended)
      assert_true(detail.contains("no legal edge"))
    }
    _ => fail("expected IllegalPhaseTransition")
  }
}

///|
test "puppet_phase/illegal_active_to_idle_directly" {
  let active = active_gate("op1")
  // Active→Idle is NOT legal (must go through Terminalizing).
  let result = try_gate_transition(active, Idle)
  assert_true(result is Some(IllegalPhaseTransition(..)))
  match result {
    Some(IllegalPhaseTransition(from=Active, to=Idle, detail~, ..)) =>
      assert_true(detail.contains("no legal edge"))
    _ => fail("expected IllegalPhaseTransition(Active→Idle)")
  }
}

///|
test "puppet_phase/shutdown_is_sink" {
  let g = PhaseGate::idle()
  let g = g.transition(ShuttingDown)
  let g = g.transition(Shutdown)
  // No legal edge out of Shutdown.
  let targets : Array[PuppetPhase] = [
    Idle,
    Active,
    Suspended,
    Terminalizing,
    ShuttingDown,
  ]
  for target in targets {
    let result = try_gate_transition(g, target)
    assert_true(result is Some(IllegalPhaseTransition(from=Shutdown, ..)))
    match result {
      Some(IllegalPhaseTransition(detail~, ..)) =>
        assert_true(detail.contains("no legal edge"))
      _ => fail("expected IllegalPhaseTransition out of Shutdown")
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Lease exclusivity (C-LEASE-EXCLUSIVE seam)
// ──────────────────────────────────────────────────────────────────────────

///|
test "puppet_phase/lease_held_rejects_second_prompt" {
  let idle = PhaseGate::idle()
  let (g, _lease) = idle.acquire_prompt("op1", gate_run_id(), gate_turn_id())
  // A second prompt on the same gate must fail.
  let result = try_acquire_prompt(
    g,
    "op2",
    RunId::unchecked("run_other"),
    gate_turn_id(),
  )
  assert_true(result is Some(LeaseHeld(..)))
  match result {
    Some(LeaseHeld(operation_id~, held_by~)) => {
      assert_true(operation_id == "op2")
      assert_true(held_by == "op1")
    }
    _ => fail("expected LeaseHeld")
  }
}

///|
test "puppet_phase/release_validates_owner" {
  let idle = PhaseGate::idle()
  let (g, _lease) = idle.acquire_prompt("op1", gate_run_id(), gate_turn_id())
  // Releasing with the wrong owner is a typed error.
  let result = try_release(g, "op_other")
  assert_true(result is Some(LeaseNotHeld(..)))
  match result {
    Some(LeaseNotHeld(operation_id~, detail~)) => {
      assert_true(operation_id == "op_other")
      assert_true(detail.contains("lease held by 'op1'"))
    }
    _ => fail("expected LeaseNotHeld")
  }
}

///|
test "puppet_phase/release_when_no_lease" {
  let g = PhaseGate::idle()
  let result = try_release(g, "op1")
  assert_true(
    result is Some(LeaseNotHeld(detail="no lease currently held", ..)),
  )
}

// ──────────────────────────────────────────────────────────────────────────
// resume with wrong suspension id
// ──────────────────────────────────────────────────────────────────────────

///|
test "puppet_phase/resume_wrong_suspension_id" {
  let active = active_gate("op1")
  let g = active.enter_suspended("susp_actual")
  let result = try_acquire_resume(g, "op2", "susp_wrong")
  assert_true(result is Some(SuspensionIdMismatch(..)))
  match result {
    Some(SuspensionIdMismatch(target_run_id~, expected~, actual~)) => {
      assert_true(target_run_id == gate_run_id())
      assert_true(expected == "susp_wrong")
      assert_true(actual == "susp_actual")
    }
    _ => fail("expected SuspensionIdMismatch")
  }
}

///|
test "puppet_phase/resume_when_not_suspended" {
  let g = PhaseGate::idle()
  // Idle gate cannot accept resume.
  let result = try_acquire_resume(g, "op1", "susp_1")
  assert_true(
    result
    // authorise(InFlight) rejects before the resume phase check: an
    // Idle gate has no active run for InFlight operations.
    is Some(
      OperationNotAllowedInPhase(
        phase=Idle,
        operation=InFlight,
        detail="no active run; InFlight operations require Active or Suspended"
      )
    ),
  )
}

// ──────────────────────────────────────────────────────────────────────────
// rotate_turn (follow-up seam)
// ──────────────────────────────────────────────────────────────────────────

///|
test "puppet_phase/rotate_turn_in_active" {
  let active = active_gate("op1")
  let g = active.rotate_turn(TurnId::unchecked("turn_2"))
  assert_true(g.active_turn_id() == Some(TurnId::unchecked("turn_2")))
  // Run id unchanged.
  assert_true(g.active_run_id() == Some(gate_run_id()))
}

///|
test "puppet_phase/rotate_turn_rejected_in_idle" {
  let g = PhaseGate::idle()
  let result = try_rotate_turn(g, TurnId::unchecked("turn_2"))
  assert_true(
    result
    is Some(
      IllegalPhaseTransition(
        from=Idle,
        to=Idle,
        detail="rotate_turn requires Active phase with a bound run",
        ..
      )
    ),
  )
}

// ──────────────────────────────────────────────────────────────────────────
// Quiescent status union
// ──────────────────────────────────────────────────────────────────────────

///|
test "puppet_phase/quiescent_phases" {
  // Type annotation disambiguates from M1 `Phase::Suspended`/`Phase::Idle`.
  let idle : PuppetPhase = Idle
  let suspended : PuppetPhase = Suspended
  let shutdown : PuppetPhase = Shutdown
  let active : PuppetPhase = Active
  let terminalizing : PuppetPhase = Terminalizing
  let shutting_down : PuppetPhase = ShuttingDown
  assert_true(idle.is_quiescent())
  assert_true(suspended.is_quiescent())
  assert_true(shutdown.is_quiescent())
  assert_true(!active.is_quiescent())
  assert_true(!terminalizing.is_quiescent())
  assert_true(!shutting_down.is_quiescent())
}
