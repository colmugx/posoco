///|
impl @wakeup.WakeupHost for AgentRuntime with fn wakeup_idle(
  self : AgentRuntime,
) -> Bool {
  !self.turn_active
}

///|
impl @wakeup.WakeupHost for AgentRuntime with fn run_wakeup_turn(
  self : AgentRuntime,
  input : @kernel.Message,
  session_id : String,
  operation_id : String,
  on_admitted : () -> Unit,
) -> Unit raise @error.AgentError {
  ignore(
    self.run_turn_with_mode(
      input,
      session_id,
      false,
      origin=Wakeup,
      operation_label=Some(operation_id),
      on_admitted=Some(fn(admission) {
        ignore(admission)
        on_admitted()
      }),
    ),
  )
}

///|
fn AgentRuntime::snapshot_step_wakeup(
  self : AgentRuntime,
  session_id : String,
  metadata : Map[String, Json],
  applied_task_ids : Array[String],
) -> @puppetry.StepContext? {
  guard self.wakeup.snapshot_step(session_id) is Some(step) else { return None }
  let outcomes = self.task_runtime.snapshot_outcomes(
    session_id,
    excluding=applied_task_ids,
  )
  let messages = outcomes.map(@task.task_outcome_message)
  messages.append(step.messages)
  let ids = outcomes.map(fn(outcome) { outcome.receipt.id })
  let updated = @message_snapshot.snapshot_metadata(metadata)
  if !ids.is_empty() {
    let updated_ids = applied_task_ids.copy()
    updated_ids.append(ids)
    @task.write_applied_task_ids(updated, updated_ids)
  }
  Some({
    messages,
    metadata: updated,
    metadata_changed: !ids.is_empty(),
    is_current: fn() { step.is_current() },
    confirm: fn(scope, operation_id) {
      if !ids.is_empty() {
        applied_task_ids.append(ids)
        @task.write_applied_task_ids(metadata, applied_task_ids)
        self.task_runtime.include_inflight(session_id, ids)
      }
      self.wakeup.confirm_step(step, scope, operation_id)
    },
  })
}
