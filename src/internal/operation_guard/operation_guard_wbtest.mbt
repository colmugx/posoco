///|
test "operation_guard/busy_and_matching_release" {
  let g = OperationGuard::OperationGuard()
  g.try_admit("a", "session-a", "turn")
  let busy : Result[Unit, OperationBusy] = Ok(
    g.try_admit("b", "session-b", "turn"),
  ) catch {
    error => Err(error)
  }
  match busy {
    Err(Busy(operation_id~, session~)) => {
      assert_eq(operation_id, "a")
      assert_eq(session, "session-a")
    }
    Ok(_) => fail("expected busy")
  }
  assert_true(g.clear_current("a"))
  assert_false(g.has_current())
  assert_false(g.clear_current("a"))
  g.try_admit("b", "session-b", "turn")
  assert_true(g.has_current())
  assert_false(g.clear_current("a"))
  assert_true(g.clear_current("b"))
}

///|
async test "operation_guard/cancel_replay_and_settled" {
  let g = OperationGuard::OperationGuard()
  g.try_admit("a", "session-a", "turn")
  g.begin_execution("a")
  g.request_cancel()
  let cancelled = Ref(false)
  let cancel : () -> Unit = fn() { cancelled.val = true }
  g.register_cancel("a", cancel)
  assert_true(cancelled.val)
  g.request_cancel()
  assert_true(cancelled.val)
  assert_true(g.clear_current("a"))
  g.settle_execution("a")
  assert_false(g.has_execution())
}

///|
async test "operation_guard/settled_timeout_and_stale_release" {
  let g = OperationGuard::OperationGuard()
  let no_exec : Result[Bool, Error] = Ok(g.wait_settled(1)) catch {
    error => Err(error)
  }
  assert_true(no_exec is Ok(true))
  g.try_admit("a", "session-a", "turn")
  g.begin_execution("a")
  let timed_out : Result[Bool, Error] = Ok(g.wait_settled(1)) catch {
    error => Err(error)
  }
  assert_true(timed_out is Ok(false))
  assert_true(g.clear_current("a"))
  g.settle_execution("a")
  let settled : Result[Bool, Error] = Ok(g.wait_settled(1)) catch {
    error => Err(error)
  }
  assert_true(settled is Ok(true))
  // A stale release cannot clear the next operation's execution.
  g.try_admit("b", "session-b", "turn")
  g.begin_execution("b")
  assert_false(g.clear_current("a"))
  assert_true(g.has_current())
  assert_true(g.has_execution())
  assert_true(g.clear_current("b"))
  g.settle_execution("b")
}
