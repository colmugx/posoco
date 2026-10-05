///|
/// Agent operation lifecycle: one centralized admission point
/// for the existing single-operation guard, one release point that projects
/// `operation_started` / `operation_settled` exactly once per admission.
///
/// The lifecycle sits above the per-turn identity layer: one admitted
/// operation covers the initial turn plus every follow-up drained inside the
/// same call (ordinary operations drain all follow-ups before settling). The
/// projection is independent of `TurnCompleted` and the internal
/// `OperationFinalized` phase event — settled is emitted only after the
/// single-operation guard has been released, on the normal, failure, soft-,
/// and hard-cancel paths alike.

///|
/// What kind of host-visible operation holds the guard. Ordinary user input
/// is `Turn`; `Resume` replays a persisted interrupted turn; `Compact` is a
/// manual compaction; `Wakeup` is an extension-requested ordinary turn.
priv enum OperationOrigin {
  Turn
  Resume
  Compact
  Wakeup
}

///|
fn OperationOrigin::label(self : OperationOrigin) -> String {
  match self {
    Turn => "turn"
    Resume => "resume"
    Compact => "compact"
    Wakeup => "wakeup"
  }
}

///|
priv enum OperationOutcome {
  Completed
  Failed
  Cancelled
}

///|
fn OperationOutcome::label(self : OperationOutcome) -> String {
  match self {
    Completed => "completed"
    Failed => "failed"
    Cancelled => "cancelled"
  }
}

///|
/// Map a terminal `AgentError` onto the settled outcome: cancellation is a
/// first-class settled state, everything else is a failure.
fn AgentError::operation_outcome(self : @error.AgentError) -> OperationOutcome {
  match self {
    @error.AgentError::Cancelled(_) => Cancelled
    _ => Failed
  }
}

///|
/// Identity of one admitted operation. Minted at admission so even the busy
/// rejection path and the `operation_started` projection can name the
/// incumbent; `identity` is the first turn's per-turn identity and
/// `operation_id` labels that turn's Puppet request (`agent_run_turn_N`,
/// `agent_compact_session_N`, `agent_wakeup_N`).
priv struct OperationAdmission {
  operation_id : String
  origin : OperationOrigin
  identity : TurnIdentity
  session_id : String
}

///|
priv struct AgentOperations {
  mut current : OperationAdmission?
  /// Agent-owned execution record of the admitted operation. Carries the
  /// cancellation request flag plus the worker's cancellation closure, so a
  /// shutdown-side request landing between admission and the eager spawn is
  /// still delivered: the registration recheck replays the flag to the
  /// freshly spawned worker. Cleared only in `release_operation`, and only
  /// for the matching admission.
  mut execution : OperationExecution?
}

///|
fn AgentOperations::AgentOperations() -> AgentOperations {
  { current: None, execution: None, }
}

///|
/// Type-erased handle to the admitted operation's worker task. Cancellation
/// is cooperative: it unwinds the worker through its ordinary lifecycle so
/// the guard, follow-up drain and foreground task cleanup all settle for
/// real — the guard is never cleared while the worker is alive.
priv struct OperationExecution {
  operation_id : String
  mut cancel_requested : Bool
  /// Cancellation closure of the spawned worker; None until registration.
  mut cancel_worker : (() -> Unit)?
  /// Wakes bounded shutdown waits when the operation truly settles.
  settle : @async.CondVar
  mut settled : Bool
}

///|
/// Register the spawned worker under the admitted operation's execution
/// record and replay an already-requested cancellation to it (the
/// registration recheck covers the eager-spawn race where shutdown asks for
/// cancellation between admission and this registration). Runs
/// synchronously before the guarded caller's first await.
fn[X] AgentRuntime::register_operation_execution(
  self : AgentRuntime,
  admission : OperationAdmission,
  worker : @async.Task[X],
) -> Unit {
  match self.operations.execution {
    Some(execution) if execution.operation_id == admission.operation_id => {
      execution.cancel_worker = Some(fn() { worker.cancel() })
      if execution.cancel_requested {
        worker.cancel()
      }
    }
    _ => ()
  }
}

///|
/// Execute the admitted operation body on a dedicated worker task so the
/// Agent owns a cancellation handle for it. The typed `AgentError` outcome
/// travels as data through the worker boundary. The whole group/join boundary
/// runs under `handle_cancellation`: a caller cancellation first unwinds the
/// worker through its ordinary lifecycle (the spawned-body errdefer), the
/// group joins every child, and only then is the intercepted signal mapped
/// to `AgentError::Cancelled` — so callers observe a typed, catchable error
/// instead of a raw signal. An explicit agent-owned worker cancellation
/// surfaces from the joined `wait` as `@async.WaitedTaskAlreadyCancelled`
/// and is reported as `AgentError::Cancelled` the same way, only after the
/// worker fully unwound.
async fn[X] AgentRuntime::execute_operation(
  self : AgentRuntime,
  admission : OperationAdmission,
  body : async () -> Result[X, @error.AgentError],
) -> X raise @error.AgentError {
  // Typed outcome the worker body produced, captured synchronously the moment
  // body() returns (before any await), so a caller cancellation landing at the
  // outer task-group boundary cannot discard the body's own typed reason.
  let body_outcome : Ref[Result[X, @error.AgentError]?] = Ref(None)
  let outcome : Result[X, @error.AgentError]? = @async.handle_cancellation(async fn() {
    @async.with_task_group(async fn(group) {
      let worker = group.spawn(async fn() -> Result[X, @error.AgentError] {
        // Unconditional-on-unwind cleanup: whether the body settles typed or
        // unwinds on a raw cancellation, the protected foreground task
        // cleanup and the pending-call drain run here, before the guard
        // releases. finish_active_operation is idempotent (None clears), so
        // the typed catch paths cannot double-run terminal cleanup, and the
        // raw cancellation signal keeps propagating after this errdefer.
        errdefer {
          let cleanup : Result[Unit, @error.AgentError] = Ok(
            self.task_runtime.finish_active_operation(),
          ) catch {
            cleanup_error => Err(cleanup_error)
          }
          match cleanup {
            Ok(_) => ()
            Err(cleanup_error) =>
              emit_secondary_failure(
                self.observers,
                "operation_worker_cleanup",
                cleanup_error.to_string(),
              )
          }
          self.event_subscriber.drain_pending(
            Some(admission.identity.scope()),
            "operation execution cancelled",
          )
        }
        let result = body()
        body_outcome.val = Some(result)
        result
      })
      self.register_operation_execution(admission, worker)
      worker.wait() catch {
        error =>
          if error is @async.WaitedTaskAlreadyCancelled {
            // The worker already performed its protected cleanup on unwind
            // (see the spawned-body errdefer); map the joined cancellation to
            // the typed cancelled outcome only, with the origin's own detail:
            // compact names its cancellation, everything else stays generic.
            Err(
              @error.AgentError::Cancelled(
                match admission.origin {
                  Compact => "compact cancelled"
                  _ => "operation execution cancelled"
                },
              ),
            )
          } else {
            Err(
              @error.AgentError::Runtime(
                @error.RuntimeError::InvocationFailed(
                  "operation worker: " + safe_error_label(error.to_string()),
                ),
              ),
            )
          }
      }
    }) catch {
      // Ordinary group failures become the contextualized runtime error. A
      // caller cancellation bypasses this catch too, but the surrounding
      // handle_cancellation intercepts it only after the group has fully
      // joined, mapping it to the typed Cancelled outcome below.
      error =>
        Err(
          @error.AgentError::Runtime(
            @error.RuntimeError::InvocationFailed(
              "operation group: " + safe_error_label(error.to_string()),
            ),
          ),
        )
    }
  }) catch {
    // `handle_cancellation` itself is typed to raise the wide `Error`; only
    // a genuine non-cancellation defect from the fully joined group reaches
    // this arm at runtime. It is preserved as a typed failure (never
    // confused with the mapped Cancelled outcome below).
    error =>
      Some(
        Err(
          @error.AgentError::Runtime(
            @error.RuntimeError::InvocationFailed(
              "operation boundary: " + safe_error_label(error.to_string()),
            ),
          ),
        ),
      )
  }
  match outcome {
    Some(Ok(value)) => value
    Some(Err(error)) => raise error
    None =>
      // The outer boundary was cancelled and has fully joined. If the worker
      // body completed before that, its captured typed error is raised
      // unchanged; a captured success or non-cancellation failure is never
      // rewritten into cancellation detail.
      match body_outcome.val {
        Some(Err(error)) => raise error
        _ =>
          raise @error.AgentError::Cancelled(
            match admission.origin {
              Compact => "compact cancelled"
              _ => "operation execution cancelled"
            },
          )
      }
  }
}

///|
/// Request cancellation of the tracked operation execution: the flag feeds
/// the registration recheck for a not-yet-registered worker, the closure
/// reaches an already-registered one. This never clears `current` and never
/// fakes a settled outcome — the worker's own unwind performs the release.
fn AgentRuntime::cancel_operation_execution(self : AgentRuntime) -> Unit {
  match self.operations.execution {
    Some(execution) => {
      execution.cancel_requested = true
      match execution.cancel_worker {
        Some(cancel_worker) => cancel_worker()
        None => ()
      }
    }
    None => ()
  }
}

///|
/// Bounded graceful window before shutdown actively cancels an in-flight
/// operation.
let operation_shutdown_grace_ms : Int = 5_000

///|
/// Bounded settle budget after an active cancellation: the unwind (catch
/// paths, foreground task cleanup, guard release) must finish here or
/// shutdown fails loudly instead of closing the Puppet under live work.
let operation_cancel_settle_ms : Int = 5_000

///|
/// Wait bounded for the operation to settle; False when the deadline
/// expires first. The `release_operation` broadcast ends the wait early on
/// real settlement.
async fn OperationExecution::wait_settled(
  self : OperationExecution,
  timeout_ms : Int,
) -> Bool raise @error.AgentError {
  let waited = @async.with_timeout_opt(timeout_ms, async fn() {
    while !self.settled {
      self.settle.wait()
    }
  }) catch {
    // Ordinary observation errors become the contextual runtime error; a
    // raw cancellation of the waiter bypasses this catch and stays raw.
    error =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "operation settle observation: " + safe_error_label(error.to_string()),
        ),
      )
  }
  waited is Some(_)
}

///|
/// Straggler detail for the bounded-shutdown diagnostic: names the
/// operation that outlived its cancellation budget.
fn AgentRuntime::operation_straggler_detail(self : AgentRuntime) -> String {
  match self.operations.current {
    Some(active) =>
      "operation_id=\{active.operation_id} session=\{active.session_id} origin=\{active.origin.label()}"
    None => "no active operation"
  }
}

///|
/// Settle the in-flight operation during shutdown: a finite graceful window
/// lets an admitted operation finish its ordinary lifecycle; if it is still
/// alive, the tracked execution is actively cancelled and its unwind must
/// finish within the bounded budget. A worker that outlives cancellation
/// (a noncooperative shielded child cannot be force-joined) fails shutdown
/// loudly with the straggler detail, and the Puppet is never closed under
/// live work.
async fn AgentRuntime::settle_operation_for_shutdown(
  self : AgentRuntime,
) -> Unit raise @error.AgentError {
  match self.operations.execution {
    None => ()
    Some(execution) => {
      let graceful = execution.wait_settled(operation_shutdown_grace_ms)
      if !graceful {
        self.cancel_operation_execution()
        let settled = execution.wait_settled(operation_cancel_settle_ms)
        if !settled {
          raise @error.AgentError::Runtime(
            @error.RuntimeError::InvocationFailed(
              "operation shutdown deadline exceeded: " +
              self.operation_straggler_detail(),
            ),
          )
        }
      }
    }
  }
}

///|

///|
/// Emit a core-owned `Custom` projection to every observer. Operation-level
/// and wakeup-level events hold no per-turn identity, so `scope` is `None`
/// by design (session attribution travels in the event data).
fn emit_custom_event(
  observers : Array[&@port.Observer],
  scope : @types.EventScope?,
  source : String,
  label : String,
  fields : Array[(String, Json)],
) -> Unit {
  let event : @types.TurnEvent = Custom(
    source~,
    label~,
    data=Json::object(Map::from_array(fields)),
  )
  for observer in observers {
    observer.on_event_at(scope, snapshot_turn_event(event))
  }
}

///|
/// Admit the next single operation or reject the caller with the structured
/// `AgentError::Busy`. Sets the single-operation guard before the first
/// await, so a rejected concurrent call cannot mutate turn-scoped state.
/// The wakeup label override lets the wakeup pump name its operations
/// without reaching into the turn identity counter.
fn AgentRuntime::admit_operation(
  self : AgentRuntime,
  session_id : String,
  origin : OperationOrigin,
  operation_label? : String? = None,
) -> OperationAdmission raise @error.AgentError {
  match self.operations.current {
    Some(active) =>
      raise @error.AgentError::Busy(
        operation_id=active.operation_id,
        session=active.session_id,
      )
    None => ()
  }
  let identity = self.mint_turn_identity(session_id)
  let operation_id = match operation_label {
    Some(label) => label
    None =>
      match origin {
        Turn | Resume => "agent_run_turn_\{identity.seq}"
        Compact => "agent_compact_session_\{identity.seq}"
        Wakeup => "agent_wakeup_\{identity.seq}"
      }
  }
  let admission : OperationAdmission = {
    operation_id,
    origin,
    identity,
    session_id,
  }
  self.operations.current = Some(admission)
  self.turn_active = true
  self.operations.execution = Some({
    operation_id: admission.operation_id,
    settle: @async.CondVar::Cond(),
    settled: false,
    cancel_requested: false,
    cancel_worker: None,
  })
  emit_custom_event(
    self.observers,
    None,
    "posoco.operation",
    "operation_started",
    [
      ("operation_id", Json::string(admission.operation_id)),
      ("session", Json::string(session_id)),
      ("origin", Json::string(origin.label())),
    ],
  )
  admission
}

///|
/// Release the guard and project `operation_settled` exactly once. The
/// settled event fires after `turn_active` is already cleared, so observers
/// that react to it (the wakeup pump, hosts) can admit the next operation
/// immediately. Idempotent: a hard-cancel unwind racing the normal release
/// never duplicates the projection.
fn AgentRuntime::release_operation(
  self : AgentRuntime,
  admission : OperationAdmission,
  outcome : OperationOutcome,
) -> Unit {
  match self.operations.current {
    Some(active) if active.operation_id == admission.operation_id => {
      self.turn_active = false
      self.operations.current = None
      match self.operations.execution {
        Some(execution) if execution.operation_id == admission.operation_id => {
          // The worker fully unwound before this release ran; mark settled
          // and wake any bounded shutdown wait before dropping the record.
          execution.settled = true
          execution.settle.broadcast()
          self.operations.execution = None
        }
        _ => ()
      }
      emit_custom_event(
        self.observers,
        None,
        "posoco.operation",
        "operation_settled",
        [
          ("operation_id", Json::string(admission.operation_id)),
          ("session", Json::string(admission.session_id)),
          ("origin", Json::string(admission.origin.label())),
          ("outcome", Json::string(outcome.label())),
        ],
      )
      // The wakeup pump waits for this notification when a host operation
      // holds the guard; wake it so a deferred wakeup ticket re-arms.
      self.wakeup.notify_operation_settled()
    }
    _ => ()
  }
}
