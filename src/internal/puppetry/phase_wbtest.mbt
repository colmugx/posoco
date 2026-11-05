///|
/// Whitebox tests for the Puppet phase gate.

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
