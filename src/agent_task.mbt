///|
let task_outcomes_applied_metadata_key : String = "posoco.task.applied_ids"

///|
/// Applied task ids may survive a session-store restart, so a process-local
/// counter alone cannot identify a new runtime. Use the platform entropy
/// source and fail activation if it is unavailable.
fn next_task_runtime_identity() -> String raise @error.AgentError {
  let bytes = match @getrandom.getrandom(16) {
    Ok(value) => value
    Err(reason) =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "task runtime nonce unavailable: " + reason,
        ),
      )
  }
  let hex : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
  ]
  let out = StringBuilder()
  for i in 0..<bytes.length() {
    let byte = bytes[i].to_int()
    out.write_char(hex[(byte >> 4) & 0x0f])
    out.write_char(hex[byte & 0x0f])
  }
  out.to_string()
}

///|
priv struct AgentTaskOperation {
  session_id : String
  run_id : @kernel.RunId
  turn_id : @kernel.TurnId
}

///|
priv struct AgentTaskRecord {
  receipt : @port.TaskReceipt
  task : @async.Task[@port.TaskOutcome]
  operation : AgentTaskOperation?
}

///|
/// Agent-owned task execution. The group itself is represented only by
/// the private spawn callback installed for one run_scoped lifetime.
priv struct AgentTaskRuntime {
  mut spawn : ((async () -> @port.TaskOutcome) -> @async.Task[@port.TaskOutcome])?
  mut scope_active : Bool
  mut closed : Bool
  mut runtime_id : String?
  mut next_id : Int
  mut active_operation : AgentTaskOperation?
  tasks : Map[String, AgentTaskRecord]
  outcomes : Map[String, Array[@port.TaskOutcome]]
  inflight : Map[String, Array[String]]
}

///|
fn AgentTaskRuntime::AgentTaskRuntime() -> AgentTaskRuntime {
  {
    spawn: None,
    scope_active: false,
    closed: false,
    runtime_id: None,
    next_id: 1,
    active_operation: None,
    tasks: Map::from_array([]),
    outcomes: Map::from_array([]),
    inflight: Map::from_array([]),
  }
}

///|
/// Each composed lifecycle contributor receives a closure that captures its
/// manifest id. That keeps attribution with the capability instead of asking
/// extensions to copy an id into every task specification.
fn AgentTaskRuntime::capability(
  self : AgentTaskRuntime,
  extension_id : String,
) -> @port.Tasks {
  @port.Tasks::from_submit(submit=fn(spec) { self.submit(extension_id, spec) })
}

///|
fn AgentTaskRuntime::activate(
  self : AgentTaskRuntime,
  spawn : (async () -> @port.TaskOutcome) -> @async.Task[@port.TaskOutcome],
) -> Unit raise @error.AgentError {
  if self.closed {
    raise @error.AgentError::Runtime(
      @error.RuntimeError::InvocationFailed("task runtime is closed"),
    )
  }
  if self.scope_active {
    raise @error.AgentError::Runtime(
      @error.RuntimeError::InvocationFailed("task scope is already active"),
    )
  }
  self.runtime_id = Some(next_task_runtime_identity())
  self.spawn = Some(spawn)
  self.scope_active = true
}

///|
fn AgentTaskRuntime::scope_available(self : AgentTaskRuntime) -> Bool {
  !self.closed && !self.scope_active
}

///|
fn AgentTaskRuntime::begin_operation(
  self : AgentTaskRuntime,
  session_id : String,
  run_id : @kernel.RunId,
  turn_id : @kernel.TurnId,
) -> Unit {
  self.active_operation = Some({ session_id, run_id, turn_id, })
}

///|
fn AgentTaskRuntime::end_operation(self : AgentTaskRuntime) -> Unit {
  self.active_operation = None
}

///|
fn AgentTaskRuntime::next_receipt(
  self : AgentTaskRuntime,
  extension_id : String,
  spec : @port.TaskSpec,
) -> @port.TaskReceipt {
  let runtime_id = match self.runtime_id {
    Some(value) => value
    None => abort("task runtime nonce missing while scope is active")
  }
  let id = "agent_task_\{runtime_id}_\{self.next_id}"
  self.next_id = self.next_id + 1
  {
    id,
    session_id: spec.session_id,
    mode: spec.mode,
    label: spec.label,
    extension_id,
  }
}

///|
fn AgentTaskRuntime::submit(
  self : AgentTaskRuntime,
  extension_id : String,
  spec : @port.TaskSpec,
) -> Result[@port.TaskHandle, @port.TaskSubmitError] {
  if spec.session_id == "" {
    return Err(InvalidSession(reason="session_id must not be empty"))
  }
  match spec.timeout_ms {
    Some(timeout_ms) if timeout_ms <= 0 =>
      return Err(InvalidSession(reason="timeout_ms must be positive"))
    _ => ()
  }
  if self.closed {
    return Err(Closed)
  }
  let operation = self.active_operation
  match spec.mode {
    @port.TaskMode::Foreground =>
      match operation {
        None => return Err(Unavailable)
        Some(owner) if owner.session_id != spec.session_id =>
          return Err(
            InvalidSession(
              reason="foreground task session does not match the active operation",
            ),
          )
        Some(_) => ()
      }
    @port.TaskMode::Background => ()
  }
  match self.spawn {
    None => return Err(Unavailable)
    Some(spawn) => {
      let receipt = self.next_receipt(extension_id, spec)
      let runtime = self
      let task = spawn(async fn() { runtime.execute(spec, receipt, operation) })
      self.tasks[receipt.id] = { receipt, task, operation, }
      let handle_task = task
      Ok(
        @port.TaskHandle::from_callbacks(
          receipt~,
          wait=async fn(_target) {
            let outcome = handle_task.wait()
            runtime.reap(receipt.id)
            snapshot_task_outcome(outcome)
          },
          cancel=fn(_target) { handle_task.cancel() },
        ),
      )
    }
  }
}

///|
async fn AgentTaskRuntime::execute(
  self : AgentTaskRuntime,
  spec : @port.TaskSpec,
  receipt : @port.TaskReceipt,
  _operation : AgentTaskOperation?,
) -> @port.TaskOutcome {
  let status : @port.TaskStatus = match spec.timeout_ms {
    Some(timeout_ms) => {
      let result : Result[@kernel.Message, Error] = Ok(
        @async.with_timeout(timeout_ms, () => (spec.run)()),
      ) catch {
        error => Err(error)
      }
      match result {
        Ok(message) =>
          @port.TaskStatus::Completed(message=snapshot_message(message))
        Err(error) if error is @async.TimeoutError => @port.TaskStatus::TimedOut
        Err(error) if @async.is_cancellation_error(error) =>
          @port.TaskStatus::Cancelled(reason="task cancelled")
        Err(error) => @port.TaskStatus::Failed(reason=error.to_string())
      }
    }
    None => {
      let result : Result[@kernel.Message, Error] = Ok((spec.run)()) catch {
        error => Err(error)
      }
      match result {
        Ok(message) =>
          @port.TaskStatus::Completed(message=snapshot_message(message))
        Err(error) if @async.is_cancellation_error(error) =>
          @port.TaskStatus::Cancelled(reason="task cancelled")
        Err(error) => @port.TaskStatus::Failed(reason=error.to_string())
      }
    }
  }
  let outcome : @port.TaskOutcome = { receipt, status, }
  match receipt.mode {
    @port.TaskMode::Background =>
      self.enqueue_outcome(snapshot_task_outcome(outcome))
    @port.TaskMode::Foreground => ()
  }
  outcome
}

///|
fn AgentTaskRuntime::reap(self : AgentTaskRuntime, receipt_id : String) -> Unit {
  self.tasks.remove(receipt_id)
}

///|
fn AgentTaskRuntime::cancel_foreground(
  self : AgentTaskRuntime,
  operation : AgentTaskOperation,
) -> Unit {
  for record in self.tasks.values() {
    match record.receipt.mode {
      @port.TaskMode::Foreground =>
        match record.operation {
          Some(owner) if owner.session_id == operation.session_id &&
            owner.run_id == operation.run_id &&
            owner.turn_id == operation.turn_id => record.task.cancel()
          _ => ()
        }
      @port.TaskMode::Background => ()
    }
  }
}

///|
/// Cancel foreground tasks belonging to the run named by an accepted abort.
/// The mailbox remains the source of run validity; this hook closes the task
/// side immediately while the Puppet observes the same abort at its safe
/// point.
fn AgentTaskRuntime::cancel_foreground_for_run(
  self : AgentTaskRuntime,
  run_id : @kernel.RunId,
) -> Unit {
  match self.active_operation {
    Some(operation) if operation.run_id == run_id =>
      self.cancel_foreground(operation)
    _ => ()
  }
}

///|
async fn AgentTaskRuntime::finish_active_operation(
  self : AgentTaskRuntime,
) -> Unit raise @error.AgentError {
  match self.active_operation {
    None => ()
    Some(operation) => {
      self.cancel_foreground(operation)
      let reaped : Array[String] = []
      let mut first_error : @error.AgentError? = None
      for record in self.tasks.values() {
        match record.receipt.mode {
          @port.TaskMode::Foreground =>
            match record.operation {
              Some(owner) if owner.session_id == operation.session_id &&
                owner.run_id == operation.run_id &&
                owner.turn_id == operation.turn_id => {
                let task = record.task
                let waited : Result[@port.TaskOutcome, Error] = Ok(
                  @async.protect_from_cancel(async fn() { task.wait() }),
                ) catch {
                  error => Err(error)
                }
                match waited {
                  Ok(_) => reaped.push(record.receipt.id)
                  Err(error) if @async.is_cancellation_error(error) =>
                    reaped.push(record.receipt.id)
                  Err(error) => {
                    reaped.push(record.receipt.id)
                    if first_error is None {
                      first_error = Some(
                        @error.AgentError::Runtime(
                          @error.RuntimeError::InvocationFailed(
                            "foreground task wait: " + error.to_string(),
                          ),
                        ),
                      )
                    }
                  }
                }
              }
              _ => ()
            }
          @port.TaskMode::Background => ()
        }
      }
      for id in reaped {
        self.reap(id)
      }
      self.active_operation = None
      match first_error {
        Some(error) => raise error
        None => ()
      }
    }
  }
}

///|
fn AgentTaskRuntime::enqueue_outcome(
  self : AgentTaskRuntime,
  outcome : @port.TaskOutcome,
) -> Unit {
  let session_id = outcome.receipt.session_id
  if self.outcomes.contains(session_id) {
    let existing = self.outcomes[session_id]
    if !existing.iter().any(fn(item) { item.receipt.id == outcome.receipt.id }) {
      existing.push(outcome)
    }
  } else {
    self.outcomes[session_id] = [outcome]
  }
}

///|
fn AgentTaskRuntime::has_inflight(
  self : AgentTaskRuntime,
  session_id : String,
) -> Bool {
  match self.inflight.get(session_id) {
    Some(ids) => !ids.is_empty()
    None => false
  }
}

///|
fn AgentTaskRuntime::metadata_with_applied_outcomes(
  self : AgentTaskRuntime,
  session_id : String,
  metadata : Map[String, Json],
) -> Map[String, Json] raise @error.AgentError {
  let ids = parse_task_applied_ids(metadata)
  match self.inflight.get(session_id) {
    Some(inflight) =>
      for id in inflight {
        if !ids.contains(id) {
          ids.push(id)
        }
      }
    None => ()
  }
  if !ids.is_empty() {
    metadata[task_outcomes_applied_metadata_key] = Json::array(
      ids.map(fn(id) { Json::string(id) }),
    )
  }
  metadata
}

///|
/// Parse the Agent-owned applied-outcome metadata once at each session
/// admission. Any malformed value is a runtime error before the turn can
/// perform model, memory, or task-outcome side effects.
fn parse_task_applied_ids(
  metadata : Map[String, Json],
) -> Array[String] raise @error.AgentError {
  match metadata.get(task_outcomes_applied_metadata_key) {
    None => []
    Some(Array(values)) => {
      let ids : Array[String] = []
      for value in values {
        match value {
          String(id) => ids.push(id)
          _ =>
            raise @error.AgentError::Runtime(
              @error.RuntimeError::InvocationFailed(
                "malformed posoco.task.applied_ids metadata entry",
              ),
            )
        }
      }
      ids
    }
    Some(_) =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "malformed posoco.task.applied_ids metadata value",
        ),
      )
  }
}

///|
fn task_outcome_is_applied(
  applied_ids : Array[String],
  outcome : @port.TaskOutcome,
) -> Bool {
  applied_ids.contains(outcome.receipt.id)
}

///|
fn AgentTaskRuntime::peek_outcomes(
  self : AgentTaskRuntime,
  session_id : String,
) -> Array[@port.TaskOutcome] {
  let pending : Array[@port.TaskOutcome] = match self.outcomes.get(session_id) {
    Some(values) => values.map(snapshot_task_outcome)
    None => []
  }
  self.inflight[session_id] = pending.map(fn(outcome) { outcome.receipt.id })
  pending
}

///|
/// Copy the message payload carried by a task terminal so queued delivery and
/// repeated handle waits cannot share mutable content with the worker result.
fn snapshot_task_outcome(outcome : @port.TaskOutcome) -> @port.TaskOutcome {
  let status = match outcome.status {
    @port.TaskStatus::Completed(message~) =>
      @port.TaskStatus::Completed(message=snapshot_message(message))
    @port.TaskStatus::Failed(reason~) => @port.TaskStatus::Failed(reason~)
    @port.TaskStatus::TimedOut => @port.TaskStatus::TimedOut
    @port.TaskStatus::Cancelled(reason~) => @port.TaskStatus::Cancelled(reason~)
  }
  { receipt: outcome.receipt, status, }
}

///|
fn AgentTaskRuntime::commit_outcomes(
  self : AgentTaskRuntime,
  session_id : String,
) -> Unit {
  let committed : Array[String] = match self.inflight.get(session_id) {
    Some(ids) => ids
    None => return
  }
  match self.outcomes.get(session_id) {
    Some(values) => {
      let remaining = values.filter(fn(outcome) {
        !committed.contains(outcome.receipt.id)
      })
      if remaining.is_empty() {
        self.outcomes.remove(session_id)
      } else {
        self.outcomes[session_id] = remaining
      }
      for id in committed {
        self.reap(id)
      }
    }
    None => ()
  }
  self.inflight.remove(session_id)
}

///|
fn task_message_text(message : @kernel.Message) -> String {
  let content_text = fn(content : @kernel.Content) -> String {
    match content {
      @kernel.Content::Text(text) => text
      @kernel.Content::Image(media_type~, ..) => "[image=\{media_type}]"
    }
  }
  match message {
    @kernel.Message::SystemMessage(content~) =>
      content.map(content_text).join("")
    @kernel.Message::UserMessage(content~) => content.map(content_text).join("")
    @kernel.Message::AssistantMessage(content~, ..) =>
      content.map(content_text).join("")
    @kernel.Message::ToolMessage(outcome~, ..) => outcome.summary()
  }
}

///|
fn task_outcome_marker(outcome : @port.TaskOutcome) -> String {
  "[posoco-task-outcome id=\{outcome.receipt.id}]"
}

///|
/// Outcomes enter the transcript as user/context data. This prevents a task
/// completion from gaining system or tool authority merely because it came
/// from an Agent-owned worker.
fn task_outcome_message(outcome : @port.TaskOutcome) -> @kernel.Message {
  let marker = task_outcome_marker(outcome)
  let detail = match outcome.status {
    @port.TaskStatus::Completed(message~) => task_message_text(message)
    @port.TaskStatus::Failed(reason~) => "failed: \{reason}"
    @port.TaskStatus::TimedOut => "timed out"
    @port.TaskStatus::Cancelled(reason~) => "cancelled: \{reason}"
  }
  @kernel.Message::UserMessage(content=[
    @kernel.Content::Text(
      "\{marker} extension=\{outcome.receipt.extension_id} label=\{outcome.receipt.label}: \{detail}",
    ),
  ])
}

///|
async fn AgentTaskRuntime::shutdown(self : AgentTaskRuntime) -> Unit {
  if !self.closed {
    self.closed = true
    self.scope_active = false
    self.spawn = None
    for record in self.tasks.values() {
      record.task.cancel()
    }
  }
  let reaped : Array[String] = []
  for record in self.tasks.values() {
    let task = record.task
    ignore(task.wait())
    reaped.push(record.receipt.id)
  }
  for id in reaped {
    self.reap(id)
  }
}
