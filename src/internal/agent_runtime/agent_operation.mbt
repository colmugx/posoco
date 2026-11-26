///|

///|
priv enum OperationOrigin {
  Turn
  Resume
  Compact
  Fork
  Rewind
  Wakeup
}

///|
fn OperationOrigin::label(self : OperationOrigin) -> String {
  match self {
    Turn => "turn"
    Resume => "resume"
    Compact => "compact"
    Fork => "fork"
    Rewind => "rewind"
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
fn agent_error_operation_outcome(error : @error.AgentError) -> OperationOutcome {
  match error {
    Cancelled(_) => Cancelled
    _ => Failed
  }
}

///|
priv struct OperationAdmission {
  operation_id : String
  origin : OperationOrigin
  identity : TurnIdentity
  session_id : String
}

///|
fn[X] AgentRuntime::register_operation_execution(
  self : AgentRuntime,
  admission : OperationAdmission,
  worker : @async.Task[X],
) -> Unit {
  self.operations.register_cancel(admission.operation_id, fn() {
    worker.cancel()
  })
}

///|
async fn[X] AgentRuntime::execute_operation(
  self : AgentRuntime,
  admission : OperationAdmission,
  body : async () -> Result[X, @error.AgentError],
) -> X raise @error.AgentError {
  let body_outcome : Ref[Result[X, @error.AgentError]?] = Ref(None)
  // `with_task_group` is `Unit`-valued: the joined outcome crosses in a cell.
  let joined_outcome : Ref[Result[X, @error.AgentError]?] = Ref(None)
  let outcome : Result[X, @error.AgentError]? = @async.handle_cancellation(async fn() {
    @async.with_task_group(async fn(group) {
      let worker = group.spawn(async fn() -> Result[X, @error.AgentError] {
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
                self.events,
                "operation_worker_cleanup",
                cleanup_error.to_string(),
              )
          }
          self.event_subscriber.drain_pending(
            Some(admission.identity.scope()),
            "operation execution cancelled",
          )
        }
        let startup : Result[Unit, @error.AgentError] = Ok(
          if !self.start_notified {
            self.notify_start_if_first()
            self.capture_tool_contributions(operation_id=admission.operation_id)
            self.acquire_operation_versions()
          },
        ) catch {
          error => Err(error)
        }
        let result = match startup {
          Ok(_) => {
            self.retire_pending_versions()
            let body_drained : Result[Unit, @error.AgentError] = Ok(
              self.drain_body_recovery_outputs(admission.session_id),
            ) catch {
              error => Err(error)
            }
            let drained : Result[Unit, @error.AgentError] = match body_drained {
              Ok(_) =>
                Ok(self.drain_pending_new_thread_outputs()) catch {
                  error => Err(error)
                }
              Err(error) => Err(error)
            }
            match drained {
              Ok(_) => body()
              Err(error) => Err(error)
            }
          }
          Err(error) => Err(error)
        }
        body_outcome.val = Some(result)
        result
      })
      self.register_operation_execution(admission, worker)
      let joined : Result[X, @error.AgentError] = worker.wait() catch {
        error =>
          if error is @async.WaitedTaskAlreadyCancelled {
            Err(
              Cancelled(
                match admission.origin {
                  Compact => "compact cancelled"
                  Fork => "fork cancelled"
                  Rewind => "rewind cancelled"
                  _ => "operation execution cancelled"
                },
              ),
            )
          } else {
            Err(
              Runtime(
                InvocationFailed(
                  "operation worker: " +
                  @diagnostic.safe_error_label(error.to_string()),
                ),
              ),
            )
          }
      }
      joined_outcome.val = Some(joined)
    }) catch {
      error =>
        joined_outcome.val = Some(
          Err(
            Runtime(
              InvocationFailed(
                "operation group: " +
                @diagnostic.safe_error_label(error.to_string()),
              ),
            ),
          ),
        )
    }
    match joined_outcome.val {
      Some(joined) => joined
      None =>
        raise @error.AgentError::Runtime(
          InvocationFailed("operation group: no outcome"),
        )
    }
  }) catch {
    error =>
      Some(
        Err(
          Runtime(
            InvocationFailed(
              "operation boundary: " +
              @diagnostic.safe_error_label(error.to_string()),
            ),
          ),
        ),
      )
  }
  match outcome {
    Some(Ok(value)) => value
    Some(Err(error)) => raise error
    None =>
      match body_outcome.val {
        Some(Err(error)) => raise error
        _ =>
          raise Cancelled(
            match admission.origin {
              Compact => "compact cancelled"
              Fork => "fork cancelled"
              Rewind => "rewind cancelled"
              _ => "operation execution cancelled"
            },
          )
      }
  }
}

///|
fn AgentRuntime::cancel_operation_execution(self : AgentRuntime) -> Unit {
  self.operations.request_cancel()
}

///|
let operation_shutdown_grace_ms : Int32 = 5_000

///|
let operation_cancel_settle_ms : Int32 = 5_000

///|
fn AgentRuntime::operation_straggler_detail(self : AgentRuntime) -> String {
  self.operations.straggler_detail()
}

///|
async fn AgentRuntime::settle_operation_for_shutdown(
  self : AgentRuntime,
) -> Unit raise @error.AgentError {
  if !self.operations.has_execution() {
    return
  }
  let graceful = self.operations.wait_settled(operation_shutdown_grace_ms) catch {
    error =>
      raise Runtime(
        InvocationFailed(
          "operation settle observation: " +
          @diagnostic.safe_error_label(error.to_string()),
        ),
      )
  }
  if !graceful {
    self.cancel_operation_execution()
    let settled = self.operations.wait_settled(operation_cancel_settle_ms) catch {
      error =>
        raise Runtime(
          InvocationFailed(
            "operation settle observation: " +
            @diagnostic.safe_error_label(error.to_string()),
          ),
        )
    }
    if !settled {
      raise Runtime(
        InvocationFailed(
          "operation shutdown deadline exceeded: " +
          self.operation_straggler_detail(),
        ),
      )
    }
  }
}

///|
fn emit_custom_event(
  events : @event_runtime.EventRuntime,
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
  events.emit_core(scope, event)
}

///|
fn AgentRuntime::admit_operation(
  self : AgentRuntime,
  session_id : String,
  origin : OperationOrigin,
  operation_label~ : String? = None,
) -> OperationAdmission raise @error.AgentError {
  self.ensure_agent_running()
  match self.operations.busy() {
    Some(busy) =>
      raise Busy(
        operation_id=match busy {
          Busy(operation_id~, ..) => operation_id
        },
        session=match busy {
          Busy(session~, ..) => session
        },
      )
    None => ()
  }
  self.tool_runtime.require_settled()
  let identity = self.mint_turn_identity(session_id)
  let operation_id = match operation_label {
    Some(label) => label
    None =>
      match origin {
        Turn | Resume => "agent_run_turn_\{identity.seq}"
        Compact => "agent_compact_session_\{identity.seq}"
        Fork => "agent_fork_session_\{identity.seq}"
        Rewind => "agent_rewind_session_\{identity.seq}"
        Wakeup => "agent_wakeup_\{identity.seq}"
      }
  }
  let admission : OperationAdmission = {
    operation_id,
    origin,
    identity,
    session_id,
  }
  self.operations.try_admit(operation_id, session_id, origin.label()) catch {
    error =>
      raise Busy(
        operation_id=match error {
          Busy(operation_id~, ..) => operation_id
        },
        session=match error {
          Busy(session~, ..) => session
        },
      )
  }
  errdefer self.operations.abort_admit(operation_id)
  // The UI operation window opens and closes with this guard; a second live
  // window is a broken invariant, reported as a typed runtime failure.
  match self.ui_runtime.begin_operation(operation_id) {
    Ok(_) => ()
    Err(error) =>
      raise Runtime(
        InvocationFailed("ui operation window: " + error.to_string()),
      )
  }
  errdefer self.ui_runtime.settle_operation(operation_id)
  self.tool_revocations.reset()
  if self.start_notified {
    self.capture_tool_contributions(operation_id=admission.operation_id)
  }
  self.acquire_operation_versions()
  self.control.bind_operation(admission.operation_id, session_id)
  self.turn_active = true
  self.operations.begin_execution(admission.operation_id)
  emit_custom_event(
    self.events,
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
fn AgentRuntime::settle_turn_messages(
  self : AgentRuntime,
  identity : TurnIdentity,
) -> Unit {
  for command in self.control.finish_turn(identity.run_id, identity.turn_id) {
    self.emit_message_undelivered(command, "turn ended before delivery")
  }
}

///|
fn AgentRuntime::settle_operation_messages(self : AgentRuntime) -> Unit {
  for command in self.control.finish_operation() {
    self.emit_message_undelivered(command, "operation ended before delivery")
  }
}

///|
fn AgentRuntime::emit_message_undelivered(
  self : AgentRuntime,
  command : @puppetry.QueuedMessage,
  reason : String,
) -> Unit {
  self.emit_turn_event(
    Some(message_scope(command.address)),
    MessageUndelivered(
      command_id=command.command_id.to_string(),
      delivery=command.delivery,
      reason~,
    ),
  )
}

///|
fn AgentRuntime::release_operation(
  self : AgentRuntime,
  admission : OperationAdmission,
  outcome : OperationOutcome,
) -> Unit {
  if self.operations.current_id() == Some(admission.operation_id) {
    // Keep the guard held while settlement callbacks run. The inbox is
    // already closed, and no new operation may acquire this one's leases.
    self.settle_operation_messages()
    // Fallback for unwind paths that never reached the managed settle step:
    // the lease is always given back (or retained for unknown executions).
    self.release_operation_versions()
    // Reclaim transient presentation resources while the guard is still
    // held; idempotent across all release paths.
    self.ui_runtime.settle_operation(admission.operation_id)
    self.operations.settle_execution(admission.operation_id)
    self.turn_active = false
    if !self.operations.clear_current(admission.operation_id) {
      return
    }
    emit_custom_event(
      self.events,
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
}

///|
async fn[X] AgentRuntime::run_admitted_operation(
  self : AgentRuntime,
  session_id : String,
  origin : OperationOrigin,
  body : async (OperationAdmission) -> X raise @error.AgentError,
) -> X raise @error.AgentError {
  let admission = self.admit_operation(session_id, origin)
  errdefer (if self.operations.current_id() == Some(admission.operation_id) {
    self.retire_released_versions()
    self.release_operation(admission, Cancelled)
  })
  let result : Result[X, @error.AgentError] = Ok(
    self.execute_operation(admission, async fn() -> Result[X, @error.AgentError] {
      let typed : Result[X, @error.AgentError] = Ok(body(admission)) catch {
        error => Err(error)
      }
      typed
    }),
  ) catch {
    error => Err(error)
  }
  let cleanup : Result[Unit, @error.AgentError] = Ok(
    self.task_runtime.finish_active_operation(),
  ) catch {
    error => Err(error)
  }
  let outcome = match result {
    Ok(_) => Completed
    Err(error) => agent_error_operation_outcome(error)
  }
  self.retire_released_versions()
  self.release_operation(admission, outcome)
  match result {
    Ok(value) =>
      match cleanup {
        Ok(_) => value
        Err(error) => {
          emit_secondary_failure(
            self.events,
            "foreground_task_cleanup",
            error.to_string(),
          )
          raise error
        }
      }
    Err(error) => {
      match cleanup {
        Err(cleanup_error) =>
          emit_secondary_failure(
            self.events,
            "foreground_task_cleanup",
            cleanup_error.to_string(),
          )
        Ok(_) => ()
      }
      raise error
    }
  }
}
