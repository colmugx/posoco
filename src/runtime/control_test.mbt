///|
/// Unit contract tests for `RuntimeControl`: identity-guarded enqueue,
/// OneAtATime follow-up drain, queue bound, and abort idempotence.

///|
/// A control handle whose mailbox is bound to an active run/turn.
fn bound_control() -> @runtime.RuntimeControl {
  let mailbox = @puppetry.ControlMailbox::ControlMailbox()
  mailbox.bind_run(
    @kernel.RunId::unchecked("run_1"),
    @kernel.TurnId::unchecked("turn_1"),
  )
  @runtime.RuntimeControl(mailbox as &@puppetry.Mailbox)
}

///|
fn text_message(text : String) -> @kernel.Message {
  @kernel.UserMessage(content=[@kernel.Text(text)])
}

///|
test "runtime control/follow_up and abort require an active run" {
  let mailbox = @puppetry.ControlMailbox::ControlMailbox()
  let control = @runtime.RuntimeControl(mailbox as &@puppetry.Mailbox)
  assert_true(control.active_run_id() is None)
  assert_true(control.active_turn_id() is None)
  assert_true(
    control.enqueue_follow_up(text_message("later")) is RejectedStale(_),
  )
  assert_true(control.abort_active(Some("stop")) is RejectedStale(_))
}

///|
test "runtime control/follow_up accepted and drained FIFO" {
  let control = bound_control()
  assert_true(control.active_run_id() is Some(_))
  assert_true(control.enqueue_follow_up(text_message("first")) is Accepted(_))
  assert_true(control.enqueue_follow_up(text_message("second")) is Accepted(_))
  assert_eq(control.pending_follow_ups(), 2)
  match control.take_follow_up() {
    Some(@kernel.UserMessage(content=[@kernel.Text(text)])) =>
      assert_eq(text, "first")
    other => fail("expected first follow-up, got \{repr(other)}")
  }
  match control.take_follow_up() {
    Some(@kernel.UserMessage(content=[@kernel.Text(text)])) =>
      assert_eq(text, "second")
    other => fail("expected second follow-up, got \{repr(other)}")
  }
  assert_true(control.take_follow_up() is None)
  assert_eq(control.pending_follow_ups(), 0)
}

///|
test "runtime control/follow_up rejects beyond queue depth" {
  let control = bound_control()
  for i in 0..<64 {
    assert_true(
      control.enqueue_follow_up(text_message("msg_\{i}")) is Accepted(_),
    )
  }
  assert_eq(control.pending_follow_ups(), 64)
  assert_true(
    control.enqueue_follow_up(text_message("overflow"))
    is RejectedQueueFull(depth=64),
  )
}

///|
test "runtime control/abort is idempotent per active run" {
  let control = bound_control()
  assert_true(control.abort_active(Some("stop")) is Accepted(_))
  assert_true(control.abort_active(None) is AbortAlreadyRequested)
}
