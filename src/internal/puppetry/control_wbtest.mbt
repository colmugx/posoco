///|
/// Whitebox tests for control queues + idle barrier.

///|
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
    message: UserMessage(content=[Text("steer")]),
  }
}

///|
fn inbox_follow_up(mb : ControlMailbox, cmd_id : String) -> EnqueueResult {
  mb
  .message_inbox()
  .enqueue(
    CommandId::unchecked(cmd_id),
    Turn,
    UserMessage(content=[Text(cmd_id)]),
  )
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
  {
    command_id: CommandId::unchecked(cmd_id),
    target_run_id: run,
    detail: None,
  }
}

///|
fn bound_mailbox() -> ControlMailbox {
  let mb = ControlMailbox()
  mb.bind_run(mb_run_id(), mb_turn_id())
  mb
}

///|
test "puppet_control/steer_consume_drains_queue" {
  let mb = bound_mailbox()
  let _ = mb.enqueue_steer(make_steer("s1", mb_run_id(), mb_turn_id()))
  let _ = mb.enqueue_steer(make_steer("s2", mb_run_id(), mb_turn_id()))
  let cmds = mb.consume_steers()
  assert_true(cmds.length() == 2)
  // FIFO order.
  assert_true(cmds[0].command_id.to_string() == "s1")
  assert_true(cmds[1].command_id.to_string() == "s2")
  // Queue drained.
  assert_true(mb.steer_depth() == 0)
}

///|
test "puppet_control/selected steer survives release until confirmed" {
  let mb = bound_mailbox()
  assert_true(
    mb.enqueue_steer(make_steer("s1", mb_run_id(), mb_turn_id())) is Accepted(_),
  )
  assert_true(mb.consume_steers() is [_])
  mb.clear_run()
  let unsettled = mb.message_inbox().finish_operation()
  assert_eq(unsettled.length(), 1)
  assert_eq(unsettled[0].command_id.to_string(), "s1")
}

///|
test "puppet_control/resume_enqueue_and_take" {
  let mb = bound_mailbox()
  let result = mb.enqueue_resume(make_resume("r1", mb_run_id(), "susp_1"))
  assert_true(result is Accepted(_))
  let taken = mb.take_resume("susp_1")
  match taken {
    Some(cmd) => assert_true(cmd.command_id.to_string() == "r1")
    None => assert_true(false)
  }
  // Second take returns None (already taken).
  let taken2 = mb.take_resume("susp_1")
  assert_true(taken2 is None)
}

///|
test "puppet_control/resume_duplicate_suspension_rejected" {
  let mb = bound_mailbox()
  let _ = mb.enqueue_resume(make_resume("r1", mb_run_id(), "susp_1"))
  let result = mb.enqueue_resume(make_resume("r2", mb_run_id(), "susp_1"))
  assert_true(
    result
    is RejectedStale(reason="resume already pending for this suspension_id", ..),
  )
}

///|
test "puppet_control/resume_wrong_run_rejected" {
  let mb = bound_mailbox()
  let result = mb.enqueue_resume(
    make_resume("r1", RunId::unchecked("run_OTHER"), "susp_1"),
  )
  assert_true(result is RejectedStale(reason="resume targets stale run", ..))
}

///|
test "puppet_control/abort_stale_run_rejected" {
  let mb = bound_mailbox()
  let r = mb.enqueue_abort(make_abort("a1", RunId::unchecked("run_OTHER")))
  assert_true(r is RejectedStale(reason="abort targets stale run", ..))
}

///|
test "puppet_control/clear_run_retains_messages_for_agent_settlement" {
  let mb = bound_mailbox()
  let _ = mb.enqueue_steer(make_steer("s1", mb_run_id(), mb_turn_id()))
  let _ = inbox_follow_up(mb, "f1")
  let _ = mb.enqueue_resume(make_resume("r1", mb_run_id(), "susp_1"))
  mb.clear_run()
  assert_true(mb.steer_depth() == 0)
  assert_true(mb.follow_up_depth() == 1)
  let residual = mb.message_inbox().finish_operation()
  assert_eq(residual.length(), 2)
  assert_true(mb.follow_up_depth() == 0)
  // After clear, a late command targeting the old run is rejected.
  mb.bind_run(RunId::unchecked("run_new"), TurnId::unchecked("turn_new"))
  let late = mb.enqueue_steer(make_steer("s_late", mb_run_id(), mb_turn_id()))
  assert_true(late is RejectedStale(reason="steer targets stale run/turn", ..))
}

///|
fn make_fork(
  cmd_id : String,
  run : RunId,
  turn : TurnId,
  fork_index : Int32,
) -> ForkCommand {
  {
    command_id: CommandId::unchecked(cmd_id),
    target_run_id: run,
    target_turn_id: turn,
    fork_index,
  }
}

///|
test "puppet_control/fork_enqueue_stale_run_rejected" {
  let mb = bound_mailbox()
  let result = mb.enqueue_fork(
    make_fork("fk1", RunId::unchecked("run_OTHER"), mb_turn_id(), 0),
  )
  assert_true(result is RejectedStale(reason="fork targets stale run/turn", ..))
  assert_true(mb.fork_depth() == 0)
}

///|
fn make_compact(
  cmd_id : String,
  run : RunId,
  turn : TurnId,
  trigger : @kernel.CompactTrigger,
) -> CompactCommand {
  {
    command_id: CommandId::unchecked(cmd_id),
    target_run_id: run,
    target_turn_id: turn,
    trigger,
  }
}

///|
test "puppet_control/compact_enqueue_stale_rejected" {
  let mb = bound_mailbox()
  let result = mb.enqueue_compact(
    make_compact("cm1", RunId::unchecked("run_OTHER"), mb_turn_id(), Manual),
  )
  assert_true(
    result is RejectedStale(reason="compact targets stale run/turn", ..),
  )
  assert_true(mb.compact_depth() == 0)
}

///|
fn mb_terminal_status() -> QuiescentStatus {
  Terminal(outcome=Cancelled(reason=HostRequested(detail=Some("test"))))
}

///|
async test "puppet_control/wait_idle_blocks_while_run_is_active" {
  let mb = bound_mailbox()
  let seen : Ref[QuiescentStatus?] = Ref(None)
  let timed_out : Ref[Bool] = Ref(false)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() {
      let waited : Result[QuiescentStatus, Error] = Ok(
        @async.with_timeout(60, () => mb.wait_idle()),
      ) catch {
        error => Err(error)
      }
      match waited {
        Ok(status) => seen.val = Some(status)
        Err(_) => timed_out.val = true
      }
    })
    @async.sleep(20)
    // The run is still in flight: nothing may satisfy the barrier yet.
    assert_true(seen.val is None)
    assert_true(timed_out.val == false)
    mb.set_quiescent(mb_terminal_status())
  })
  assert_true(timed_out.val == false)
  match seen.val {
    Some(status) => assert_true(status is Terminal(_))
    None => fail("wait_idle never returned the terminal status")
  }
}

///|
async test "puppet_control/wait_idle_waits_through_non_quiescent_wakeups" {
  let mb = bound_mailbox()
  let seen : Ref[QuiescentStatus?] = Ref(None)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() { seen.val = Some(mb.wait_idle()) })
    @async.sleep(20)
    ignore(mb.enqueue_abort(make_abort("a1", mb_run_id())))
    mb.set_quiescent(Active)
    @async.sleep(20)
    assert_true(seen.val is None)
    mb.set_quiescent(mb_terminal_status())
  })
  match seen.val {
    Some(status) => assert_true(status is Terminal(_))
    None => fail("wait_idle never returned the terminal status")
  }
}

///|
test "puppet_control/second_run_starts_active_not_stale_terminal" {
  let mb = bound_mailbox()
  mb.set_quiescent(mb_terminal_status())
  assert_true(mb.quiescent_status() is Terminal(_))
  mb.clear_run()
  // The ended run's terminal stays observable until the next run binds.
  assert_true(mb.quiescent_status() is Terminal(_))
  mb.bind_run(RunId::unchecked("run_second"), TurnId::unchecked("turn_second"))
  assert_true(mb.quiescent_status() is Active)
}
