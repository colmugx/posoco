///|
/// Root-package control contract tests. The constructor, the inbox lifecycle
/// seam and the follow-up drain are intentionally private here; hosts only
/// receive the opaque handle from `Agent::control()` and use its public
/// submission/inspection methods.

///|
/// Bind a bare control handle the way an admitted operation would: one inbox
/// operation, one open turn, and the mailbox run binding the abort path reads.
fn bound_agent_control() -> ControlCore {
  let mailbox = @puppetry.ControlMailbox()
  mailbox.bind_run(
    @kernel.RunId::unchecked("run_1"),
    @kernel.TurnId::unchecked("turn_1"),
  )
  let control = ControlCore(mailbox as &@puppetry.Mailbox)
  control.bind_operation("op_1", "session_1")
  control.bind_turn(
    @kernel.RunId::unchecked("run_1"),
    @kernel.TurnId::unchecked("turn_1"),
  )
  control
}

///|
fn control_text_message(text : String) -> @kernel.Message {
  UserMessage(content=[Text(text)])
}

///|
test "agent control/targets cannot cross Agents with identical run identities" {
  let first = bound_agent_control()
  let second = bound_agent_control()
  let target = first.current_address()
  assert_true(target is Some(_))
  assert_true(first.active_run_id() == second.active_run_id())
  assert_true(
    second.enqueue_steer(control_text_message("foreign step"), expected=target)
    is RejectedStale(_),
  )
  assert_true(
    second.enqueue_follow_up(
      control_text_message("foreign turn"),
      expected=target,
    )
    is RejectedStale(_),
  )
  assert_eq(second.pending_steers(), 0)
  assert_eq(second.pending_follow_ups(), 0)
}

///|
test "agent control/follow_up rejects beyond queue depth" {
  let control = bound_agent_control()
  for i in 0..<64 {
    assert_true(
      control.enqueue_follow_up(control_text_message("msg_\{i}"))
      is @runtime.Accepted(_),
    )
  }
  assert_eq(control.pending_follow_ups(), 64)
  assert_true(
    control.enqueue_follow_up(control_text_message("overflow"))
    is @runtime.RejectedQueueFull(depth=64),
  )
}

///|
test "agent control/steer rejects beyond queue depth" {
  let control = bound_agent_control()
  for i in 0..<64 {
    assert_true(
      control.enqueue_steer(control_text_message("steer_\{i}"))
      is @runtime.Accepted(_),
    )
  }
  assert_eq(control.pending_steers(), 64)
  assert_true(
    control.enqueue_steer(control_text_message("overflow"))
    is @runtime.RejectedQueueFull(depth=64),
  )
}

///|
test "agent control/abort is idempotent per active run" {
  let control = bound_agent_control()
  assert_true(control.abort_active(Some("stop")) is @runtime.Accepted(_))
  assert_true(control.abort_active(None) is @runtime.AbortAlreadyRequested)
}
