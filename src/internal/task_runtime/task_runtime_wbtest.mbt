///|
priv struct TestObserver {
  events : Array[@types.TurnEvent]
}

///|
fn TestObserver::TestObserver() -> TestObserver {
  { events: [], }
}

///|
impl @port.Observer for TestObserver with fn on_event(
  self : TestObserver,
  _scope : @types.EventScope?,
  event : @types.TurnEvent,
) -> Unit {
  self.events.push(event)
}

///|
async test "managed_tasks/foreground_settlement_deadline_preserves_operation_owner" {
  let runtime = TaskRuntime(foreground_settle_timeout_ms=40)
  @async.with_task_group(async fn(group) {
    runtime.activate(group)
    let run_one = @kernel.RunId::unchecked("supervised-run-1")
    let turn_one = @kernel.TurnId::unchecked("supervised-turn-1")
    runtime.begin_operation("supervised-session", run_one, turn_one)

    let gate : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
    let handle = match
      runtime.submit("supervised-test", {
        session_id: "supervised-session",
        mode: @port.TaskMode::Foreground,
        label: "protected-cleanup",
        timeout_ms: None,
        run: async fn() {
          @async.protect_from_cancel(async fn() { ignore(gate.get()) })
          @kernel.Message::UserMessage(content=[
            @kernel.Content::Text("released"),
          ])
        },
      }) {
      Ok(value) => value
      Err(error) => fail("foreground task admission failed: \{repr(error)}")
    }

    let cleanup : Result[Unit, @error.AgentError] = Ok(
      runtime.finish_active_operation(),
    ) catch {
      error => Err(error)
    }
    match cleanup {
      Err(
        @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed(detail)
        )
      ) =>
        assert_true(
          detail.contains("foreground task cleanup deadline exceeded"),
        )
      _ => fail("protected foreground cleanup must hit the settlement deadline")
    }

    let blocked : Result[Unit, @error.AgentError] = Ok(
      runtime.begin_operation(
        "next-session",
        @kernel.RunId::unchecked("supervised-run-2"),
        @kernel.TurnId::unchecked("supervised-turn-2"),
      ),
    ) catch {
      error => Err(error)
    }
    match blocked {
      Err(
        @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed(detail)
        )
      ) =>
        assert_true(detail.contains("foreground task cleanup is still pending"))
      _ => fail("a stale foreground task must keep operation ownership")
    }

    gate.put(1)
    let outcome = handle.wait()
    assert_true(outcome.status is @port.TaskStatus::Cancelled(_))

    runtime.begin_operation(
      "next-session",
      @kernel.RunId::unchecked("supervised-run-3"),
      @kernel.TurnId::unchecked("supervised-turn-3"),
    )
    runtime.finish_active_operation()
    runtime.shutdown()
  })
}

///|
async test "managed_tasks/shutdown_settles_cooperative_background_work" {
  let runtime = TaskRuntime(shutdown_settle_timeout_ms=200)
  @async.with_task_group(async fn(group) {
    runtime.activate(group)
    let supervisor = match runtime.supervisor {
      Some(value) => value
      None => fail("task supervisor was not activated")
    }
    let task = match
      supervisor.spawn(
        async fn() {
          @async.pause()
          @port.TaskOutcome::{
            receipt: {
              id: "shutdown-cooperative",
              session_id: "shutdown-session",
              mode: @port.TaskMode::Background,
              label: "cooperative",
              extension_id: "shutdown-test",
            },
            status: @port.TaskStatus::Completed(
              message=@kernel.Message::UserMessage(content=[
                @kernel.Content::Text("done"),
              ]),
            ),
          }
        },
        label="cooperative",
      ) {
      Ok(value) => value
      Err(_) => fail("supervisor refused cooperative task")
    }
    runtime.tasks["shutdown-cooperative"] = {
      receipt: {
        id: "shutdown-cooperative",
        session_id: "shutdown-session",
        mode: @port.TaskMode::Background,
        label: "cooperative",
        extension_id: "shutdown-test",
      },
      task,
      operation: None,
    }
    runtime.shutdown()
    assert_true(runtime.supervisor is None)
    assert_eq(runtime.tasks.length(), 0)
  })
}

///|
async test "managed_tasks/shutdown_deadline_reports_straggler_and_can_retry" {
  let runtime = TaskRuntime(shutdown_settle_timeout_ms=40)
  @async.with_task_group(async fn(group) {
    runtime.activate(group)
    let supervisor = match runtime.supervisor {
      Some(value) => value
      None => fail("task supervisor was not activated")
    }
    let gate : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let started : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
    let receipt : @port.TaskReceipt = {
      id: "shutdown-stuck",
      session_id: "shutdown-session",
      mode: @port.TaskMode::Background,
      label: "stuck-worker",
      extension_id: "shutdown-test",
    }
    let task = match
      supervisor.spawn(
        async fn() {
          started.put(())
          @async.protect_from_cancel(async fn() { ignore(gate.get()) })
          @port.TaskOutcome::{
            receipt,
            status: @port.TaskStatus::Cancelled(reason="released"),
          }
        },
        label="stuck-worker",
      ) {
      Ok(value) => value
      Err(_) => fail("supervisor refused stuck task")
    }
    runtime.tasks[receipt.id] = { receipt, task, operation: None, }
    ignore(started.get())

    let first : Result[Unit, @error.AgentError] = Ok(runtime.shutdown()) catch {
      error => Err(error)
    }
    match first {
      Err(
        @error.AgentError::Runtime(
          @error.RuntimeError::InvocationFailed(detail)
        )
      ) => {
        assert_true(detail.contains("managed task shutdown deadline exceeded"))
        assert_true(detail.contains("extension=shutdown-test"))
        assert_true(detail.contains("label=stuck-worker"))
        assert_true(detail.contains("status=Cancelling"))
      }
      _ => fail("stuck background task must exceed shutdown deadline")
    }

    assert_true(runtime.closed)
    assert_true(runtime.supervisor is Some(_))
    assert_eq(runtime.tasks.length(), 1)

    // The observer path is the only Posoco-level diagnostic that can become
    // visible before the owning TaskGroup eventually exits. Keep the complete
    // task identity/status detail instead of truncating its tail.
    let stragglers = runtime.shutdown_straggler_detail()
    let observer = TestObserver::TestObserver()
    let event_runtime = @event_runtime.EventRuntime()
    match event_runtime.register_observers([observer as &@port.Observer]) {
      Ok(_) => ()
      Err(error) => fail("register_observers failed: \{repr(error)}")
    }
    emit_managed_task_shutdown_failure(
      event_runtime, "managed task shutdown deadline exceeded", stragglers,
    )
    let events = observer.events
    assert_eq(events.length(), 1)
    match events[0] {
      Custom(source~, label~, data~) => {
        assert_eq(source, "posoco.core")
        assert_eq(label, "secondary_failure")
        match data {
          Object(fields) => {
            match fields.get("hook_point") {
              Some(String(value)) => assert_eq(value, "managed_task_shutdown")
              _ => fail("shutdown diagnostic missing hook_point")
            }
            let observed = match fields.get("stragglers") {
              Some(String(value)) => value
              _ => fail("shutdown diagnostic missing stragglers")
            }
            assert_eq(observed, stragglers)
            assert_true(observed.contains("extension=shutdown-test"))
            assert_true(observed.contains("label=stuck-worker"))
            assert_true(observed.contains("receipt=shutdown-stuck"))
            assert_true(observed.contains("status=Cancelling"))
          }
          _ => fail("shutdown diagnostic data must be a JSON object")
        }
      }
      _ => fail("expected managed-task secondary_failure diagnostic")
    }

    gate.put(())
    runtime.shutdown()
    assert_true(runtime.supervisor is None)
    assert_eq(runtime.tasks.length(), 0)
  })
}

///|
test "managed_tasks/commit_outcomes_clears_committed_and_keeps_the_rest" {
  let runtime = TaskRuntime()
  let outcome = fn(id) {
    @port.TaskOutcome::{
      receipt: {
        id,
        session_id: "commit-session",
        mode: @port.TaskMode::Background,
        label: id,
        extension_id: "commit-test",
      },
      status: @port.TaskStatus::Cancelled(reason="settled"),
    }
  }
  runtime.enqueue_outcome(outcome("committed-one"))
  runtime.enqueue_outcome(outcome("committed-two"))
  let peeked = runtime.peek_outcomes("commit-session")
  assert_eq(peeked.length(), 2)
  runtime.enqueue_outcome(outcome("late-arrival"))
  runtime.commit_outcomes("commit-session")
  assert_false(runtime.inflight.contains("commit-session"))
  match runtime.outcomes.get("commit-session") {
    Some(remaining) => {
      assert_eq(remaining.length(), 1)
      assert_eq(remaining[0].receipt.id, "late-arrival")
    }
    None => fail("uncommitted outcome must stay in the inbox")
  }
  assert_eq(runtime.peek_outcomes("commit-session").length(), 1)
  runtime.commit_outcomes("commit-session")
  assert_false(runtime.outcomes.contains("commit-session"))
  assert_false(runtime.inflight.contains("commit-session"))
}
