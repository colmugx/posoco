///|
let task_outcomes_applied_metadata_key : String = "posoco.task.applied_ids"

///|
let foreground_task_settle_timeout_ms : Int32 = 5_000

///|
let managed_task_shutdown_settle_timeout_ms : Int32 = 5_000

///|
let hex_digits : ReadOnlyArray[Char] = [
  '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
]

///|
fn next_task_runtime_identity() -> String raise @error.AgentError {
  let bytes = match @env.rand(16) {
    Some(value) => value
    None =>
      raise Runtime(
        InvocationFailed(
          "task runtime nonce unavailable: platform entropy source returned no bytes",
        ),
      )
  }
  let out = StringBuilder()
  for i in 0..<bytes.length() {
    let byte = bytes[i].to_int()
    out.write_char(hex_digits[(byte >> 4) & 0x0f])
    out.write_char(hex_digits[byte & 0x0f])
  }
  out.to_string()
}

///|
priv struct TaskOperation {
  session_id : String
  run_id : @kernel.RunId
  turn_id : @kernel.TurnId
}

///|
priv struct TaskRecord {
  receipt : @port.TaskReceipt
  task : @fuwaroid.SupervisedTask[@port.TaskOutcome]
  operation : TaskOperation?
}

///|
pub struct TaskRuntime {
  priv mut supervisor : @fuwaroid.Supervisor[@port.TaskOutcome]?
  priv mut scope_active : Bool
  priv mut closed : Bool
  priv mut runtime_id : String?
  priv mut next_id : Int32
  priv mut active_operation : TaskOperation?
  /// Core-owned `background_outcome_ready` projection, installed at
  /// composition. Called only after a background outcome is successfully
  /// enqueued into its session inbox; carries no outcome payload.
  priv mut ready_notifier : ((@port.TaskOutcome) -> Unit)?
  priv foreground_settle_timeout_ms : Int32
  priv shutdown_settle_timeout_ms : Int32
  priv tasks : Map[String, TaskRecord]
  priv outcomes : Map[String, Array[@port.TaskOutcome]]
  priv inflight : Map[String, Array[String]]
}

///|
pub fn TaskRuntime::set_ready_notifier(
  self : TaskRuntime,
  notifier : (@port.TaskOutcome) -> Unit,
) -> Unit {
  self.ready_notifier = Some(notifier)
}

///|
pub fn TaskRuntime::TaskRuntime(
  foreground_settle_timeout_ms~ : Int32 = foreground_task_settle_timeout_ms,
  shutdown_settle_timeout_ms~ : Int32 = managed_task_shutdown_settle_timeout_ms,
) -> TaskRuntime {
  {
    supervisor: None,
    scope_active: false,
    closed: false,
    runtime_id: None,
    next_id: 1,
    active_operation: None,
    ready_notifier: None,
    foreground_settle_timeout_ms,
    shutdown_settle_timeout_ms,
    tasks: Map::from_array([]),
    outcomes: Map::from_array([]),
    inflight: Map::from_array([]),
  }
}

///|
pub fn TaskRuntime::capability(
  self : TaskRuntime,
  extension_id : String,
) -> @port.Tasks {
  @port.Tasks::from_submit(submit=fn(spec) { self.submit(extension_id, spec) })
}

///|
pub fn TaskRuntime::activate(
  self : TaskRuntime,
  group : @async.TaskGroup,
) -> Unit raise @error.AgentError {
  if self.closed {
    raise Runtime(InvocationFailed("task runtime is closed"))
  }
  if self.scope_active {
    raise Runtime(InvocationFailed("task scope is already active"))
  }
  self.runtime_id = Some(next_task_runtime_identity())
  self.supervisor = Some(Supervisor(group~))
  self.scope_active = true
}

///|
pub fn TaskRuntime::scope_available(self : TaskRuntime) -> Bool {
  !self.closed && !self.scope_active
}

///|
fn agent_task_operation_equal(
  left : TaskOperation,
  right : TaskOperation,
) -> Bool {
  left.session_id == right.session_id &&
  left.run_id == right.run_id &&
  left.turn_id == right.turn_id
}

///|
fn TaskRuntime::record_matches_operation(
  _self : TaskRuntime,
  record : TaskRecord,
  operation : TaskOperation,
) -> Bool {
  match record.receipt.mode {
    Foreground =>
      match record.operation {
        Some(owner) => agent_task_operation_equal(owner, operation)
        None => false
      }
    Background => false
  }
}

///|
fn supervised_task_terminal(status : @fuwaroid.SupervisedTaskStatus) -> Bool {
  match status {
    Completed | Cancelled | Failed => true
    Running | Cancelling => false
  }
}

///|
fn TaskRuntime::refresh_active_operation(self : TaskRuntime) -> Unit {
  match self.active_operation {
    None => ()
    Some(operation) => {
      let stale : Array[String] = []
      let mut unresolved = false
      for record in self.tasks.values() {
        if self.record_matches_operation(record, operation) {
          if supervised_task_terminal(record.task.snapshot().status) {
            stale.push(record.receipt.id)
          } else {
            unresolved = true
          }
        }
      }
      for id in stale {
        self.reap(id)
      }
      if !unresolved {
        self.active_operation = None
      }
    }
  }
}

///|
pub fn TaskRuntime::begin_operation(
  self : TaskRuntime,
  session_id : String,
  run_id : @kernel.RunId,
  turn_id : @kernel.TurnId,
) -> Unit raise @error.AgentError {
  self.refresh_active_operation()
  if self.active_operation is Some(_) {
    raise Runtime(InvocationFailed("foreground task cleanup is still pending"))
  }
  self.active_operation = Some({ session_id, run_id, turn_id, })
}

///|
fn TaskRuntime::next_receipt(
  self : TaskRuntime,
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
fn TaskRuntime::submit(
  self : TaskRuntime,
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
    Foreground =>
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
    Background => ()
  }

  let supervisor = match self.supervisor {
    Some(value) => value
    None => return Err(Unavailable)
  }
  let receipt = self.next_receipt(extension_id, spec)
  let runtime = self
  let task = match
    supervisor.spawn(
      async fn() { runtime.execute(spec, receipt, operation) },
      label=receipt.label,
    ) {
    Ok(value) => value
    Err(_) => return Err(Closed)
  }
  self.tasks[receipt.id] = { receipt, task, operation, }
  let handle_task = task
  Ok(
    @port.TaskHandle::from_callbacks(
      receipt~,
      wait=async fn(_target) {
        let waited : Result[@port.TaskOutcome, Error] = Ok(handle_task.wait()) catch {
          error => Err(error)
        }
        let outcome = match waited {
          Ok(value) => value
          Err(error) if error is @async.WaitedTaskAlreadyCancelled =>
            { receipt, status: Cancelled(reason="task cancelled"), }
          Err(error) => { receipt, status: Failed(reason=error.to_string()), }
        }
        runtime.reap(receipt.id)
        snapshot_task_outcome(outcome)
      },
      cancel=fn(_target) { handle_task.cancel() },
    ),
  )
}

///|
/// Authoritative status word for the ready projection: completed / failed /
/// timed_out / cancelled. Observers schedule work from it; the outcome body
/// stays in the session inbox only.
pub fn task_outcome_status_label(status : @port.TaskStatus) -> String {
  match status {
    Completed(..) => "completed"
    Failed(..) => "failed"
    TimedOut => "timed_out"
    Cancelled(..) => "cancelled"
  }
}

///|
fn TaskRuntime::notify_background_outcome_ready(
  self : TaskRuntime,
  outcome : @port.TaskOutcome,
) -> Unit {
  match self.ready_notifier {
    Some(emit) => emit(outcome)
    None => ()
  }
}

///|
#warnings("-fragile_catch_all")
async fn TaskRuntime::execute(
  self : TaskRuntime,
  spec : @port.TaskSpec,
  receipt : @port.TaskReceipt,
  _operation : TaskOperation?,
) -> @port.TaskOutcome {
  let guarded : async () -> @kernel.Message = async fn() {
    let message = (spec.run)() catch {
      error => {
        @async.pause()
        raise error
      }
    }
    @async.pause()
    message
  }
  let status : @port.TaskStatus = match spec.timeout_ms {
    Some(timeout_ms) => {
      let result : Result[@kernel.Message?, Error] = Ok(
        @async.handle_cancellation(async fn() {
          @async.with_timeout(timeout_ms, () => guarded())
        }),
      ) catch {
        error => Err(error)
      }
      match result {
        Ok(Some(message)) =>
          Completed(message=@message_snapshot.snapshot_message(message))
        Ok(None) => Cancelled(reason="task cancelled")
        Err(error) if error is @async.TimeoutError => TimedOut
        Err(error) => Failed(reason=error.to_string())
      }
    }
    None => {
      let result : Result[@kernel.Message?, Error] = Ok(
        @async.handle_cancellation(guarded),
      ) catch {
        error => Err(error)
      }
      match result {
        Ok(Some(message)) =>
          Completed(message=@message_snapshot.snapshot_message(message))
        Ok(None) => Cancelled(reason="task cancelled")
        Err(error) => Failed(reason=error.to_string())
      }
    }
  }
  let outcome : @port.TaskOutcome = { receipt, status, }
  match receipt.mode {
    Background => {
      let stored = snapshot_task_outcome(outcome)
      self.enqueue_outcome(stored)
      // Inbox write succeeded first: the ready projection is never ahead of
      // the delivery it announces.
      self.notify_background_outcome_ready(stored)
    }
    Foreground => ()
  }
  outcome
}

///|
fn TaskRuntime::reap(self : TaskRuntime, receipt_id : String) -> Unit {
  self.tasks.remove(receipt_id)
}

///|
fn TaskRuntime::cancel_foreground(
  self : TaskRuntime,
  operation : TaskOperation,
) -> Unit {
  for record in self.tasks.values() {
    if self.record_matches_operation(record, operation) {
      record.task.cancel()
    }
  }
}

///|
pub fn TaskRuntime::cancel_foreground_for_run(
  self : TaskRuntime,
  run_id : @kernel.RunId,
) -> Unit {
  match self.active_operation {
    Some(operation) if operation.run_id == run_id =>
      self.cancel_foreground(operation)
    _ => ()
  }
}

///|
/// Settle the operation's foreground tasks within the bounded settlement
/// budget. `nocancel` keeps cleanup that follows in a `defer`/`errdefer` from
/// being skipped by cancellation.
pub async fn TaskRuntime::finish_active_operation(
  self : TaskRuntime,
) -> Unit raise @error.AgentError + nocancel {
  let operation = match self.active_operation {
    None => return
    Some(value) => value
  }
  let records = Array::from_iter(self.tasks.values()).filter(fn(record) {
    self.record_matches_operation(record, operation)
  })
  if records.is_empty() {
    self.active_operation = None
    return
  }
  let supervisor = match self.supervisor {
    Some(value) => value
    None =>
      raise Runtime(
        InvocationFailed(
          "task supervisor is unavailable during foreground cleanup",
        ),
      )
  }
  let tasks = records.map(fn(record) { record.task })
  let settled : Result[@fuwaroid.SettleOutcome, Error] = Ok(
    @async.protect_from_cancel(async fn() {
      supervisor.cancel_and_wait(
        tasks=tasks.clamped_view(),
        timeout_ms=self.foreground_settle_timeout_ms,
      )
    }),
  ) catch {
    error => Err(error)
  }
  let outcome = match settled {
    Ok(value) => value
    Err(error) =>
      raise Runtime(
        InvocationFailed(
          "foreground task settlement failed: " + error.to_string(),
        ),
      )
  }
  match outcome {
    Settled => {
      for record in records {
        self.reap(record.receipt.id)
      }
      self.active_operation = None
    }
    DeadlineExceeded(snapshots) => {
      self.refresh_active_operation()
      let detail = snapshots
        .map(fn(snapshot) {
          let label = if snapshot.label == "" {
            "<unlabelled>"
          } else {
            snapshot.label
          }
          "\{label}:\{repr(snapshot.status)}"
        })
        .join(", ")
      raise Runtime(
        InvocationFailed("foreground task cleanup deadline exceeded: " + detail),
      )
    }
  }
}

///|
fn TaskRuntime::enqueue_outcome(
  self : TaskRuntime,
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
pub fn TaskRuntime::has_inflight(
  self : TaskRuntime,
  session_id : String,
) -> Bool {
  match self.inflight.get(session_id) {
    Some(ids) => !ids.is_empty()
    None => false
  }
}

///|
pub fn TaskRuntime::metadata_with_applied_outcomes(
  self : TaskRuntime,
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
  write_applied_task_ids(metadata, ids)
  metadata
}

///|
pub fn write_applied_task_ids(
  metadata : Map[String, Json],
  ids : Array[String],
) -> Unit {
  if !ids.is_empty() {
    metadata[task_outcomes_applied_metadata_key] = Json::array(
      ids.map(fn(id) { Json::string(id) }),
    )
  }
}

///|
/// Parse the Agent-owned applied-outcome metadata once at each session
/// admission. Any malformed value is a runtime error before the turn can
/// perform model, memory, or task-outcome side effects.
pub fn parse_task_applied_ids(
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
            raise Runtime(
              InvocationFailed(
                "malformed posoco.task.applied_ids metadata entry",
              ),
            )
        }
      }
      ids
    }
    Some(_) =>
      raise Runtime(
        InvocationFailed("malformed posoco.task.applied_ids metadata value"),
      )
  }
}

///|
pub fn task_outcome_is_applied(
  applied_ids : Array[String],
  outcome : @port.TaskOutcome,
) -> Bool {
  applied_ids.contains(outcome.receipt.id)
}

///|
pub fn TaskRuntime::peek_outcomes(
  self : TaskRuntime,
  session_id : String,
) -> Array[@port.TaskOutcome] {
  let pending = self.snapshot_outcomes(session_id, excluding=[])
  self.inflight[session_id] = pending.map(fn(outcome) { outcome.receipt.id })
  pending
}

///|
pub fn TaskRuntime::snapshot_outcomes(
  self : TaskRuntime,
  session_id : String,
  excluding~ : Array[String],
) -> Array[@port.TaskOutcome] {
  match self.outcomes.get(session_id) {
    Some(values) =>
      values.filter_map(fn(outcome) {
        if excluding.contains(outcome.receipt.id) {
          None
        } else {
          Some(snapshot_task_outcome(outcome))
        }
      })
    None => []
  }
}

///|
pub fn TaskRuntime::include_inflight(
  self : TaskRuntime,
  session_id : String,
  ids : Array[String],
) -> Unit {
  let inflight = self.inflight.get(session_id).unwrap_or([])
  inflight.append(ids)
  self.inflight[session_id] = inflight
}

///|
fn snapshot_task_outcome(outcome : @port.TaskOutcome) -> @port.TaskOutcome {
  let status = match outcome.status {
    Completed(message~) =>
      @port.TaskStatus::Completed(
        message=@message_snapshot.snapshot_message(message),
      )
    Failed(reason~) => Failed(reason~)
    TimedOut => TimedOut
    Cancelled(reason~) => Cancelled(reason~)
  }
  { receipt: outcome.receipt, status, }
}

///|
pub fn TaskRuntime::commit_outcomes(
  self : TaskRuntime,
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
      Text(text) => text
      Image(media_type~, ..) => "[image=\{media_type}]"
    }
  }
  match message {
    SystemMessage(content~) => content.map(content_text).join("")
    UserMessage(content~) => content.map(content_text).join("")
    AssistantMessage(content~, ..) => content.map(content_text).join("")
    ToolMessage(outcome~, ..) => outcome.summary()
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
pub fn task_outcome_message(outcome : @port.TaskOutcome) -> @kernel.Message {
  let marker = task_outcome_marker(outcome)
  let detail = match outcome.status {
    Completed(message~) => task_message_text(message)
    Failed(reason~) => "failed: \{reason}"
    TimedOut => "timed out"
    Cancelled(reason~) => "cancelled: \{reason}"
  }
  UserMessage(content=[
    Text(
      "\{marker} extension=\{outcome.receipt.extension_id} label=\{outcome.receipt.label}: \{detail}",
    ),
  ])
}

///|
pub fn TaskRuntime::shutdown_straggler_detail(self : TaskRuntime) -> String {
  let details : Array[String] = []
  for record in self.tasks.values() {
    let snapshot = record.task.snapshot()
    if !supervised_task_terminal(snapshot.status) {
      let label = if record.receipt.label == "" {
        "<unlabelled>"
      } else {
        record.receipt.label
      }
      details.push(
        "extension=\{record.receipt.extension_id} label=\{label} receipt=\{record.receipt.id} status=\{repr(snapshot.status)}",
      )
    }
  }
  if details.is_empty() {
    "<unknown managed task>"
  } else {
    details.join(", ")
  }
}

///|
/// Close task admission and bounded-settle all live managed work.
pub async fn TaskRuntime::shutdown(
  self : TaskRuntime,
) -> Unit raise @error.AgentError {
  if !self.closed {
    self.closed = true
    self.scope_active = false
  }
  let supervisor = match self.supervisor {
    Some(value) => value
    None => {
      self.active_operation = None
      return
    }
  }
  let settled : Result[@fuwaroid.SettleOutcome, Error] = Ok(
    @async.protect_from_cancel(async fn() {
      supervisor.shutdown(timeout_ms=self.shutdown_settle_timeout_ms)
    }),
  ) catch {
    error => Err(error)
  }
  let outcome = match settled {
    Ok(value) => value
    Err(error) =>
      raise Runtime(
        InvocationFailed(
          "managed task shutdown settlement failed: " + error.to_string(),
        ),
      )
  }
  match outcome {
    Settled => {
      let records : Array[TaskRecord] = Array::from_iter(self.tasks.values())
      for record in records {
        self.reap(record.receipt.id)
      }
      self.supervisor = None
      self.active_operation = None
    }
    DeadlineExceeded(_) =>
      raise Runtime(
        InvocationFailed(
          "managed task shutdown deadline exceeded: " +
          self.shutdown_straggler_detail(),
        ),
      )
  }
}

///|
pub fn emit_managed_task_shutdown_failure(
  events : @event_runtime.EventRuntime,
  error : String,
  stragglers : String,
) -> Unit {
  let event : @types.TurnEvent = Custom(
    source="posoco.core",
    label="secondary_failure",
    data={
      "hook_point": "managed_task_shutdown",
      "error": @diagnostic.safe_error_label(error),
      "stragglers": stragglers,
    },
  )
  events.emit_core(None, event)
}
