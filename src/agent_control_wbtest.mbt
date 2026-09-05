///|
/// Root-package control contract tests. The constructor and follow-up drain
/// are intentionally private here; hosts only receive the opaque handle from
/// `Agent::control()` and use its public submission/inspection methods.

///|
fn bound_agent_control() -> AgentControl {
  let mailbox = @puppetry.ControlMailbox()
  mailbox.bind_run(
    @kernel.RunId::unchecked("run_1"),
    @kernel.TurnId::unchecked("turn_1"),
  )
  AgentControl(mailbox as &@puppetry.Mailbox)
}

///|
fn control_text_message(text : String) -> @kernel.Message {
  UserMessage(content=[Text(text)])
}

///|
test "agent control/follow_up and abort require an active run" {
  let mailbox = @puppetry.ControlMailbox()
  let control = AgentControl(mailbox as &@puppetry.Mailbox)
  assert_true(control.active_run_id() is None)
  assert_true(control.active_turn_id() is None)
  assert_true(
    control.enqueue_follow_up(control_text_message("later"))
    is @runtime.RejectedStale(_),
  )
  assert_true(control.abort_active(Some("stop")) is @runtime.RejectedStale(_))
}

///|
test "agent control/follow_up accepted and drained FIFO" {
  let control = bound_agent_control()
  assert_true(control.active_run_id() is Some(_))
  assert_true(
    control.enqueue_follow_up(control_text_message("first"))
    is @runtime.Accepted(_),
  )
  assert_true(
    control.enqueue_follow_up(control_text_message("second"))
    is @runtime.Accepted(_),
  )
  assert_eq(control.pending_follow_ups(), 2)
  match control.take_follow_up() {
    Some(UserMessage(content=[Text(text)])) => assert_eq(text, "first")
    other => fail("expected first follow-up, got \{repr(other)}")
  }
  match control.take_follow_up() {
    Some(UserMessage(content=[Text(text)])) => assert_eq(text, "second")
    other => fail("expected second follow-up, got \{repr(other)}")
  }
  assert_true(control.take_follow_up() is None)
  assert_eq(control.pending_follow_ups(), 0)
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
test "agent control/follow_up reports queue write failure" {
  let control = bound_agent_control()
  control.follow_ups.close()
  match control.enqueue_follow_up(control_text_message("closed")) {
    @runtime.RejectedQueueFailure(reason~) => {
      assert_true(reason.contains("follow_up queue write failed"))
      assert_true(reason.contains("QueueAlreadyClosed"))
    }
    other => fail("expected queue failure, got \{repr(other)}")
  }
  assert_eq(control.pending_follow_ups(), 0)
}

///|
test "agent control/follow_up drain reports queue read failure" {
  let control = bound_agent_control()
  control.follow_ups.close()
  let result : Result[@kernel.Message?, @error.AgentError] = Ok(
    control.take_follow_up(),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(
      @error.AgentError::Runtime(@error.RuntimeError::InvocationFailed(detail))
    ) => {
      assert_true(detail.contains("follow_up queue read failed"))
      assert_true(detail.contains("QueueAlreadyClosed"))
    }
    other => fail("expected typed queue read failure, got \{repr(other)}")
  }
}

///|
async test "agent run_turn exposes follow-up drain failure as Runtime error" {
  let model = ScriptedModel([Respond(tk_stop_response("done"))])
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let control = agent.control()
  control.follow_ups.close()
  let result : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(tk_user_msg("hello"), "queue-read-fail"),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(
      @error.AgentError::Runtime(@error.RuntimeError::InvocationFailed(detail))
    ) => {
      assert_true(detail.contains("follow_up queue read failed"))
      assert_true(detail.contains("QueueAlreadyClosed"))
    }
    other => fail("expected Agent runtime queue failure, got \{repr(other)}")
  }
}

///|
test "agent control/abort is idempotent per active run" {
  let control = bound_agent_control()
  assert_true(control.abort_active(Some("stop")) is @runtime.Accepted(_))
  assert_true(control.abort_active(None) is @runtime.AbortAlreadyRequested)
}
