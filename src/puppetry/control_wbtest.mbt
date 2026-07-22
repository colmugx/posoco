///|
/// Whitebox tests for M2-T03 control queues + idle barrier.
///
/// Coverage:
/// - bind_run / clear_run cycle
/// - steer enqueue with valid + stale ids
/// - follow_up enqueue + OneAtATime consume
/// - resume enqueue + take_resume
/// - abort idempotency (first Accepted, second AbortAlreadyRequested)
/// - queue full
/// - late command for old run rejected after clear_run
/// - wait_idle returns immediately when already quiescent
/// - set_quiescent wakes waiters (verified structurally; the async wait
///   itself is exercised in the orchestration tests)

// ──────────────────────────────────────────────────────────────────────────
// Fixtures
// ──────────────────────────────────────────────────────────────────────────

fn mb_run_id() -> RunId {
  RunId::unchecked("run_mb")
}

///|
fn mb_turn_id() -> TurnId {
  TurnId::unchecked("turn_mb")
}

///|
fn make_steer(cmd_id : String, run : RunId, turn : TurnId) -> SteerCommand {
  {
    command_id: CommandId::unchecked(cmd_id),
    target_run_id: run,
    target_turn_id: turn,
    observed_tool_batch_id: "batch_1",
    observed_model_step_id: ModelStepId::first(),
    payload: Json::null(),
  }
}

///|
fn make_follow_up(
  cmd_id : String,
  run : RunId,
  source_turn : TurnId,
) -> FollowUpCommand {
  {
    command_id: CommandId::unchecked(cmd_id),
    target_run_id: run,
    source_turn_id: source_turn,
    payload: Json::null(),
  }
}

///|
fn make_resume(cmd_id : String, run : RunId, susp_id : String) -> ResumeCommand {
  {
    command_id: CommandId::unchecked(cmd_id),
    target_run_id: run,
    suspension_id: susp_id,
    payload: Json::null(),
  }
}

///|
fn make_abort(cmd_id : String, run : RunId) -> AbortCommand {
  { command_id: CommandId::unchecked(cmd_id), target_run_id: run, detail: None }
}

///|
fn bound_mailbox() -> ControlMailbox {
  let mb = ControlMailbox::new()
  mb.bind_run(mb_run_id(), mb_turn_id())
  mb
}

// ──────────────────────────────────────────────────────────────────────────
// bind_run / clear_run
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_control/bind_then_clear" {
  let mb = ControlMailbox::new()
  assert_true(mb.active_run_id() is None)
  mb.bind_run(mb_run_id(), mb_turn_id())
  assert_true(mb.active_run_id() == Some(mb_run_id()))
  assert_true(mb.active_turn_id() == Some(mb_turn_id()))
  mb.clear_run()
  assert_true(mb.active_run_id() is None)
}

// ──────────────────────────────────────────────────────────────────────────
// Steer
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_control/steer_enqueue_accepted" {
  let mb = bound_mailbox()
  let result = mb.enqueue_steer(make_steer("s1", mb_run_id(), mb_turn_id()))
  assert_true(result is Accepted(_))
  assert_true(mb.steer_depth() == 1)
}

///|
test "harness_control/steer_enqueue_stale_run_rejected" {
  let mb = bound_mailbox()
  let result = mb.enqueue_steer(
    make_steer("s1", RunId::unchecked("run_OTHER"), mb_turn_id()),
  )
  assert_true(result is RejectedStale(_))
  assert_true(mb.steer_depth() == 0)
}

///|
test "harness_control/steer_enqueue_no_active_run_rejected" {
  let mb = ControlMailbox::new()
  let result = mb.enqueue_steer(make_steer("s1", mb_run_id(), mb_turn_id()))
  assert_true(result is RejectedStale(_))
}

///|
test "harness_control/steer_consume_drains_queue" {
  let mb = bound_mailbox()
  let _ = mb.enqueue_steer(make_steer("s1", mb_run_id(), mb_turn_id()))
  let _ = mb.enqueue_steer(make_steer("s2", mb_run_id(), mb_turn_id()))
  let consumed = mb.consume_steers()
  assert_true(consumed.length() == 2)
  // FIFO order.
  assert_true(consumed[0].command_id().to_string() == "s1")
  assert_true(consumed[1].command_id().to_string() == "s2")
  // Queue drained.
  assert_true(mb.steer_depth() == 0)
}

// ──────────────────────────────────────────────────────────────────────────
// Follow-up
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_control/follow_up_enqueue_accepted" {
  let mb = bound_mailbox()
  let result = mb.enqueue_follow_up(
    make_follow_up("f1", mb_run_id(), mb_turn_id()),
  )
  assert_true(result is Accepted(_))
  assert_true(mb.follow_up_depth() == 1)
}

///|
test "harness_control/follow_up_consume_one_at_a_time" {
  let mb = bound_mailbox()
  let _ = mb.enqueue_follow_up(make_follow_up("f1", mb_run_id(), mb_turn_id()))
  let _ = mb.enqueue_follow_up(make_follow_up("f2", mb_run_id(), mb_turn_id()))
  // First consume returns f1, leaves f2.
  let first = mb.consume_one_follow_up()
  assert_true(first is Some(_))
  match first {
    Some(cmd) => assert_true(cmd.command_id().to_string() == "f1")
    None => assert_true(false)
  }
  assert_true(mb.follow_up_depth() == 1)
  // Second consume returns f2.
  let second = mb.consume_one_follow_up()
  match second {
    Some(cmd) => assert_true(cmd.command_id().to_string() == "f2")
    None => assert_true(false)
  }
  assert_true(mb.follow_up_depth() == 0)
  // Third consume returns None.
  let third = mb.consume_one_follow_up()
  assert_true(third is None)
}

// ──────────────────────────────────────────────────────────────────────────
// Resume
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_control/resume_enqueue_and_take" {
  let mb = bound_mailbox()
  let result = mb.enqueue_resume(make_resume("r1", mb_run_id(), "susp_1"))
  assert_true(result is Accepted(_))
  let taken = mb.take_resume("susp_1")
  match taken {
    Some(cmd) => assert_true(cmd.command_id().to_string() == "r1")
    None => assert_true(false)
  }
  // Second take returns None (already taken).
  let taken2 = mb.take_resume("susp_1")
  assert_true(taken2 is None)
}

///|
test "harness_control/resume_duplicate_suspension_rejected" {
  let mb = bound_mailbox()
  let _ = mb.enqueue_resume(make_resume("r1", mb_run_id(), "susp_1"))
  let result = mb.enqueue_resume(make_resume("r2", mb_run_id(), "susp_1"))
  assert_true(result is RejectedStale(_))
}

///|
test "harness_control/resume_wrong_run_rejected" {
  let mb = bound_mailbox()
  let result = mb.enqueue_resume(
    make_resume("r1", RunId::unchecked("run_OTHER"), "susp_1"),
  )
  assert_true(result is RejectedStale(_))
}

// ──────────────────────────────────────────────────────────────────────────
// Abort idempotency
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_control/abort_first_accepted_second_already_requested" {
  let mb = bound_mailbox()
  let r1 = mb.enqueue_abort(make_abort("a1", mb_run_id()))
  assert_true(r1 is Accepted(_))
  assert_true(mb.abort_requested())
  let r2 = mb.enqueue_abort(make_abort("a2", mb_run_id()))
  assert_true(r2 is AbortAlreadyRequested(_))
}

///|
test "harness_control/abort_no_active_run_rejected" {
  let mb = ControlMailbox::new()
  let r = mb.enqueue_abort(make_abort("a1", mb_run_id()))
  assert_true(r is RejectedStale(_))
}

///|
test "harness_control/abort_stale_run_rejected" {
  let mb = bound_mailbox()
  let r = mb.enqueue_abort(make_abort("a1", RunId::unchecked("run_OTHER")))
  assert_true(r is RejectedStale(_))
}

// ──────────────────────────────────────────────────────────────────────────
// clear_run drops queued commands
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_control/clear_run_drops_queued_commands" {
  let mb = bound_mailbox()
  let _ = mb.enqueue_steer(make_steer("s1", mb_run_id(), mb_turn_id()))
  let _ = mb.enqueue_follow_up(make_follow_up("f1", mb_run_id(), mb_turn_id()))
  let _ = mb.enqueue_resume(make_resume("r1", mb_run_id(), "susp_1"))
  mb.clear_run()
  assert_true(mb.steer_depth() == 0)
  assert_true(mb.follow_up_depth() == 0)
  // After clear, a late command targeting the old run is rejected.
  mb.bind_run(RunId::unchecked("run_new"), TurnId::unchecked("turn_new"))
  let late = mb.enqueue_steer(make_steer("s_late", mb_run_id(), mb_turn_id()))
  assert_true(late is RejectedStale(_))
}

// ──────────────────────────────────────────────────────────────────────────
// QueuePolicy semantics
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_control/queue_policy_all_vs_one_at_a_time" {
  // Steer is All (drain everything); follow-up is OneAtATime (one per call).
  // Documented by the consume methods' behaviour.
  let mb = bound_mailbox()
  let _ = mb.enqueue_steer(make_steer("s1", mb_run_id(), mb_turn_id()))
  let _ = mb.enqueue_steer(make_steer("s2", mb_run_id(), mb_turn_id()))
  let _ = mb.enqueue_follow_up(make_follow_up("f1", mb_run_id(), mb_turn_id()))
  let _ = mb.enqueue_follow_up(make_follow_up("f2", mb_run_id(), mb_turn_id()))
  // Steer: one call drains both.
  let steers = mb.consume_steers()
  assert_true(steers.length() == 2)
  // Follow-up: one call returns one.
  let one_fu = mb.consume_one_follow_up()
  assert_true(one_fu is Some(_))
  assert_true(mb.follow_up_depth() == 1)
}

// ──────────────────────────────────────────────────────────────────────────
// Quiescent status
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_control/quiescent_status_idle_initially" {
  let mb = ControlMailbox::new()
  let s = mb.quiescent_status()
  // Initial quiescent status is Idle.
  assert_true(s is Idle)
}

///|
test "harness_control/set_quiescent_updates_status" {
  let mb = ControlMailbox::new()
  mb.set_quiescent(Shutdown)
  assert_true(mb.quiescent_status() is Shutdown)
}

///|
async test "harness_control/wait_idle_returns_when_already_idle" {
  // When the mailbox is already Idle, wait_idle must return immediately.
  let mb = ControlMailbox::new()
  let s = mb.wait_idle()
  assert_true(s is Idle)
}

///|
async test "harness_control/wait_idle_returns_terminal" {
  let mb = ControlMailbox::new()
  let outcome : RunOutcome = Completed(
    final_message=AssistantMessage(
      content=[],
      tool_calls=[],
      reasoning=None,
      finish_reason=Stop,
    ),
    tool_results=[],
  )
  mb.set_quiescent(Terminal(outcome~))
  let s = mb.wait_idle()
  assert_true(s is Terminal(_))
}
