///|
/// Whitebox tests for M2-T02 phase gate.
///
/// Coverage:
/// - Initial state is Idle
/// - Legal transitions match ADR §4 diagram
/// - Illegal transitions raise typed HarnessError
/// - Lease exclusivity (C-LEASE-EXCLUSIVE seam)
/// - Operation class authorisation per phase
/// - Suspended retains run_id/turn_id
/// - rotate_turn only in Active
/// - enter_suspended sets suspension_id

// ──────────────────────────────────────────────────────────────────────────
// Helpers — wrap raise-resulting calls into Result for assertion
// ──────────────────────────────────────────────────────────────────────────

///|
/// Run a raise-resulting closure and capture the result or error.
fn try_acquire_prompt(
  gate : PhaseGate,
  op_id : String,
  run_id : RunId,
  turn_id : TurnId,
) -> Result[(PhaseGate, OperationLease), HarnessError] {
  Ok(gate.acquire_prompt(op_id, run_id, turn_id)) catch {
    e => Err(e)
  }
}

///|
fn try_acquire_resume(
  gate : PhaseGate,
  op_id : String,
  susp_id : String,
) -> Result[(PhaseGate, OperationLease), HarnessError] {
  Ok(gate.acquire_resume(op_id, susp_id)) catch {
    e => Err(e)
  }
}

///|
fn try_release(gate : PhaseGate, op_id : String) -> Result[Unit, HarnessError] {
  try {
    gate.release(op_id)
    Ok(())
  } catch {
    e => Err(e)
  }
}

///|
fn try_gate_transition(
  gate : PhaseGate,
  to : HarnessPhase,
) -> Result[PhaseGate, HarnessError] {
  Ok(gate.transition(to)) catch {
    e => Err(e)
  }
}

///|
fn try_rotate_turn(
  gate : PhaseGate,
  new_turn_id : TurnId,
) -> Result[PhaseGate, HarnessError] {
  Ok(gate.rotate_turn(new_turn_id)) catch {
    e => Err(e)
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
fn active_gate(op_id : String) -> PhaseGate raise HarnessError {
  let idle = PhaseGate::idle()
  let (g, _) = idle.acquire_prompt(op_id, gate_run_id(), gate_turn_id())
  g.transition(Active)
}

// ──────────────────────────────────────────────────────────────────────────
// Initial state
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_phase/initial_is_idle" {
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
test "harness_phase/idle_accepts_prompt_and_structural" {
  let g = PhaseGate::idle()
  assert_true(g.authorise(Prompt) is Ok(_))
  assert_true(g.authorise(Structural) is Ok(_))
  // InFlight in Idle is illegal: no active run.
  let err = g.authorise(InFlight)
  assert_true(err is Err(_))
  match err {
    Err(OperationNotAllowedInPhase(phase~, operation~, ..)) => {
      assert_true(phase == Idle)
      assert_true(operation == InFlight)
    }
    _ => fail("expected OperationNotAllowedInPhase")
  }
}

///|
test "harness_phase/active_rejects_prompt_and_structural" {
  let active = active_gate("op1")
  assert_true(active.authorise(InFlight) is Ok(_))
  assert_true(active.authorise(Prompt) is Err(_))
  assert_true(active.authorise(Structural) is Err(_))
}

///|
test "harness_phase/shutdown_rejects_all" {
  let g = PhaseGate::idle()
  let g = g.transition(ShuttingDown)
  let g = g.transition(Shutdown)
  assert_true(g.authorise(Prompt) is Err(_))
  assert_true(g.authorise(InFlight) is Err(_))
  assert_true(g.authorise(Structural) is Err(_))
  // All commands surface as AfterShutdown.
  match g.authorise(Prompt) {
    Err(AfterShutdown(command~)) => assert_true(command == "Prompt")
    _ => fail("expected AfterShutdown")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Legal transitions (ADR §4 diagram)
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_phase/legal_transition_idle_to_active" {
  let idle = PhaseGate::idle()
  let (g, _lease) = idle.acquire_prompt("op1", gate_run_id(), gate_turn_id())
  assert_true(g.active_run_id() == Some(gate_run_id()))
  let g = g.transition(Active)
  assert_true(g.phase() == Active)
}

///|
test "harness_phase/legal_transition_active_to_suspended" {
  let active = active_gate("op1")
  let g = active.enter_suspended("susp_1")
  assert_true(g.phase() == Suspended)
  // Run id preserved across suspension.
  assert_true(g.active_run_id() == Some(gate_run_id()))
  assert_true(g.active_turn_id() == Some(gate_turn_id()))
  assert_true(g.active_suspension_id() == Some("susp_1"))
}

///|
test "harness_phase/legal_transition_suspended_to_active_resume" {
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
test "harness_phase/legal_transition_active_to_terminalizing_to_idle" {
  let mut g = active_gate("op1")
  g = g.transition(Terminalizing)
  assert_true(g.phase() == Terminalizing)
  g = g.transition(Idle)
  assert_true(g.phase() == Idle)
  assert_true(g.lease() is None)
  assert_true(g.active_run_id() is None)
}

///|
test "harness_phase/legal_shutdown_path" {
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
test "harness_phase/illegal_idle_to_suspended" {
  let g = PhaseGate::idle()
  let result = try_gate_transition(g, Suspended)
  assert_true(result is Err(_))
  match result {
    Err(IllegalPhaseTransition(from~, to~, ..)) => {
      assert_true(from == Idle)
      assert_true(to == Suspended)
    }
    _ => fail("expected IllegalPhaseTransition")
  }
}

///|
test "harness_phase/illegal_active_to_idle_directly" {
  let active = active_gate("op1")
  // Active→Idle is NOT legal (must go through Terminalizing).
  let result = try_gate_transition(active, Idle)
  assert_true(result is Err(_))
}

///|
test "harness_phase/shutdown_is_sink" {
  let g = PhaseGate::idle()
  let g = g.transition(ShuttingDown)
  let g = g.transition(Shutdown)
  // No legal edge out of Shutdown.
  let targets : Array[HarnessPhase] = [
    Idle,
    Active,
    Suspended,
    Terminalizing,
    ShuttingDown,
  ]
  for target in targets {
    let result = try_gate_transition(g, target)
    assert_true(result is Err(_))
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Lease exclusivity (C-LEASE-EXCLUSIVE seam)
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_phase/lease_held_rejects_second_prompt" {
  let idle = PhaseGate::idle()
  let (g, _lease) = idle.acquire_prompt("op1", gate_run_id(), gate_turn_id())
  // A second prompt on the same gate must fail.
  let result = try_acquire_prompt(
    g,
    "op2",
    RunId::unchecked("run_other"),
    gate_turn_id(),
  )
  assert_true(result is Err(_))
  match result {
    Err(LeaseHeld(operation_id~, held_by~)) => {
      assert_true(operation_id == "op2")
      assert_true(held_by == "op1")
    }
    _ => fail("expected LeaseHeld")
  }
}

///|
test "harness_phase/release_validates_owner" {
  let idle = PhaseGate::idle()
  let (g, _lease) = idle.acquire_prompt("op1", gate_run_id(), gate_turn_id())
  // Releasing with the wrong owner is a typed error.
  let result = try_release(g, "op_other")
  assert_true(result is Err(_))
  match result {
    Err(LeaseNotHeld(operation_id~, ..)) =>
      assert_true(operation_id == "op_other")
    _ => fail("expected LeaseNotHeld")
  }
}

///|
test "harness_phase/release_when_no_lease" {
  let g = PhaseGate::idle()
  let result = try_release(g, "op1")
  assert_true(result is Err(_))
}

// ──────────────────────────────────────────────────────────────────────────
// resume with wrong suspension id
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_phase/resume_wrong_suspension_id" {
  let active = active_gate("op1")
  let g = active.enter_suspended("susp_actual")
  let result = try_acquire_resume(g, "op2", "susp_wrong")
  assert_true(result is Err(_))
  match result {
    Err(SuspensionIdMismatch(target_run_id~, expected~, actual~)) => {
      assert_true(target_run_id == gate_run_id())
      assert_true(expected == "susp_wrong")
      assert_true(actual == "susp_actual")
    }
    _ => fail("expected SuspensionIdMismatch")
  }
}

///|
test "harness_phase/resume_when_not_suspended" {
  let g = PhaseGate::idle()
  // Idle gate cannot accept resume.
  let result = try_acquire_resume(g, "op1", "susp_1")
  assert_true(result is Err(_))
}

// ──────────────────────────────────────────────────────────────────────────
// rotate_turn (follow-up seam)
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_phase/rotate_turn_in_active" {
  let active = active_gate("op1")
  let g = active.rotate_turn(TurnId::unchecked("turn_2"))
  assert_true(g.active_turn_id() == Some(TurnId::unchecked("turn_2")))
  // Run id unchanged.
  assert_true(g.active_run_id() == Some(gate_run_id()))
}

///|
test "harness_phase/rotate_turn_rejected_in_idle" {
  let g = PhaseGate::idle()
  let result = try_rotate_turn(g, TurnId::unchecked("turn_2"))
  assert_true(result is Err(_))
}

// ──────────────────────────────────────────────────────────────────────────
// Quiescent status union
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_phase/quiescent_phases" {
  // Type annotation disambiguates from M1 `Phase::Suspended`/`Phase::Idle`.
  let idle : HarnessPhase = Idle
  let suspended : HarnessPhase = Suspended
  let shutdown : HarnessPhase = Shutdown
  let active : HarnessPhase = Active
  let terminalizing : HarnessPhase = Terminalizing
  let shutting_down : HarnessPhase = ShuttingDown
  assert_true(idle.is_quiescent())
  assert_true(suspended.is_quiescent())
  assert_true(shutdown.is_quiescent())
  assert_true(!active.is_quiescent())
  assert_true(!terminalizing.is_quiescent())
  assert_true(!shutting_down.is_quiescent())
}
