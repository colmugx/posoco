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
/// Command ids accepted for control messages, in submission order.
fn accepted_ids(
  outcomes : Array[@runtime.EnqueueOutcome],
) -> Array[String] raise {
  outcomes.map(outcome => {
    match outcome {
      Accepted(command_id~) => command_id
      other => fail("expected an accepted message, got \{repr(other)}")
    }
  })
}

///|
test "agent control/follow_up and abort require an active run" {
  let mailbox = @puppetry.ControlMailbox()
  let control = ControlCore(mailbox as &@puppetry.Mailbox)
  assert_true(control.active_run_id() is None)
  assert_true(control.active_turn_id() is None)
  assert_true(control.current_address() is None)
  assert_true(
    control.enqueue_follow_up(control_text_message("later"))
    is @runtime.RejectedStale(_),
  )
  assert_true(
    control.enqueue_steer(control_text_message("now"))
    is @runtime.RejectedStale(_),
  )
  assert_true(control.abort_active(Some("stop")) is @runtime.RejectedStale(_))
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
test "agent control/follow_up accepted and selected FIFO" {
  let control = bound_agent_control()
  let ids = accepted_ids([
    control.enqueue_follow_up(control_text_message("first")),
    control.enqueue_follow_up(control_text_message("second")),
  ])
  assert_eq(control.pending_follow_ups(), 2)
  // The open turn is the submission target a host can pin.
  assert_true(control.current_address() is Some(_))
  match control.select_follow_up() {
    Some(command) => {
      assert_eq(command.command_id.to_string(), ids[0])
      guard command.message is UserMessage(content=[Text(text)]) else {
        fail("expected the first follow-up message")
      }
      assert_eq(text, "first")
    }
    None => fail("expected the first follow-up to be selectable")
  }
  match control.select_follow_up() {
    Some(command) => assert_eq(command.command_id.to_string(), ids[1])
    None => fail("expected the second follow-up to be selectable")
  }
  assert_true(control.select_follow_up() is None)
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
/// Lifecycle regression replacing the old internal queue-close test: a
/// selected record is retained until its commit confirms it, and an
/// operation's tail returns every leftover — queued or selected — in FIFO
/// order, closing the inbox for the next admission.
test "agent control/settles queued and selected follow-ups at operation end" {
  let control = bound_agent_control()
  let ids = accepted_ids([
    control.enqueue_follow_up(control_text_message("first")),
    control.enqueue_follow_up(control_text_message("second")),
  ])
  match control.select_follow_up() {
    Some(command) => assert_eq(command.command_id.to_string(), ids[0])
    None => fail("expected a selectable follow-up")
  }
  // Selection retires it from the waiting queue but keeps the record until
  // its turn's initial commit confirms it.
  assert_eq(control.pending_follow_ups(), 1)
  let leftovers = control.finish_operation()
  assert_eq(leftovers.length(), 2)
  assert_eq(leftovers.map(fn(c) { c.command_id.to_string() }), ids)
  assert_eq(control.pending_follow_ups(), 0)
  assert_eq(control.pending_steers(), 0)
  assert_true(control.current_address() is None)
  // The closed inbox rejects late submissions instead of silently adopting
  // the next operation's turn…
  assert_true(
    control.enqueue_follow_up(control_text_message("late"))
    is @runtime.RejectedStale(_),
  )
  // …and a fresh admission starts from an empty inbox.
  control.bind_operation("op_2", "session_1")
  assert_eq(control.pending_follow_ups(), 0)
}

///|
/// Confirmation regression: the initial-command id armed for a follow-up turn
/// projects exactly one public `MessageApplied` — through the Agent's event
/// runtime, scoped to the turn that actually committed the message — and a
/// repeated initial commit is a no-op.
test "agent control/initial confirmation projects Applied once, scoped to the committing turn" {
  let observer = @test_support.RecordingObserver()
  let events = @event_runtime.EventRuntime()
  match events.register_observers([observer]) {
    Ok(_) => ()
    Err(error) => fail("register_observers failed: \{repr(error)}")
  }
  let control = bound_agent_control()
  control.install_message_events(events)
  let scoped : Array[(String, String)] = []
  let _ = events.subscribe(fn(envelope) {
    guard envelope.event is @events.Core(MessageApplied(command_id~, ..)) else {
      return
    }
    match envelope.scope {
      Some(scope) => scoped.push((command_id, scope.run_id.to_string()))
      None => scoped.push((command_id, ""))
    }
  })
  match control.enqueue_follow_up(control_text_message("follow me")) {
    Accepted(command_id~) =>
      match control.select_follow_up() {
        Some(command) => {
          // Arming binds the committing turn and associates the receipt with
          // its initial boundary in one step.
          control.arm_follow_up(
            command.command_id,
            @kernel.RunId::unchecked("run_2"),
            @kernel.TurnId::unchecked("turn_2"),
          )
          control.inbox.confirm_initial()
          let applied = observer.events()
          assert_eq(applied.length(), 1)
          match applied[0] {
            MessageApplied(command_id=applied_id, delivery=Turn) =>
              assert_eq(applied_id, command_id)
            other => fail("expected MessageApplied(Turn), got \{repr(other)}")
          }
          assert_eq(scoped, [(command_id, "run_2")])
          // The armed id is consumed: committing again projects nothing.
          control.inbox.confirm_initial()
          assert_eq(observer.events().length(), 1)
        }
        None => fail("expected the follow-up to be selectable")
      }
    other => fail("expected an accepted follow-up, got \{repr(other)}")
  }
}

///|
/// Target regression: a `MessageTarget` pins the exact turn the host
/// observed. After the turn rolled over, submitting against the captured
/// target is stale even though a turn is still open.
test "agent control/rejects a stale message target" {
  let control = bound_agent_control()
  let fresh = match control.current_address() {
    Some(target) => target
    None => fail("expected an open turn target")
  }
  assert_true(
    control.enqueue_steer(control_text_message("pinned"), expected=Some(fresh))
    is @runtime.Accepted(_),
  )
  assert_eq(control.pending_steers(), 1)
  control.bind_turn(
    @kernel.RunId::unchecked("run_2"),
    @kernel.TurnId::unchecked("turn_2"),
  )
  let rolled = control.current_address()
  assert_true(
    match rolled {
      Some(target) => target != fresh
      None => false
    },
  )
  assert_true(
    control.enqueue_steer(control_text_message("stale"), expected=Some(fresh))
    is @runtime.RejectedStale(_),
  )
  assert_true(
    control.enqueue_steer(control_text_message("current"))
    is @runtime.Accepted(_),
  )
  // The waiting count is scoped to the open turn: the steer pinned to the
  // previous turn stays there, and only its own turn can settle it.
  assert_eq(control.pending_steers(), 1)
  assert_eq(
    control
    .finish_turn(
      @kernel.RunId::unchecked("run_1"),
      @kernel.TurnId::unchecked("turn_1"),
    )
    .length(),
    1,
  )
}

///|
test "agent control/steer requires an active run" {
  let mailbox = @puppetry.ControlMailbox()
  let control = ControlCore(mailbox as &@puppetry.Mailbox)
  assert_true(
    control.enqueue_steer(control_text_message("now"))
    is @runtime.RejectedStale(_),
  )
  assert_eq(control.pending_steers(), 0)
}

///|
/// Step records the turn boundary never confirmed are settled at that turn's
/// exit in FIFO order; the inbox closes for the next turn afterwards.
test "agent control/steer settles at the turn boundary" {
  let control = bound_agent_control()
  let ids = accepted_ids([
    control.enqueue_steer(control_text_message("first steer")),
    control.enqueue_steer(control_text_message("second steer")),
  ])
  assert_eq(control.pending_steers(), 2)
  let leftovers = control.finish_turn(
    @kernel.RunId::unchecked("run_1"),
    @kernel.TurnId::unchecked("turn_1"),
  )
  assert_eq(leftovers.map(fn(c) { c.command_id.to_string() }), ids)
  assert_eq(control.pending_steers(), 0)
  // Another turn's step window never inherits the settled records.
  let other = control.finish_turn(
    @kernel.RunId::unchecked("run_2"),
    @kernel.TurnId::unchecked("turn_2"),
  )
  assert_eq(other.length(), 0)
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
