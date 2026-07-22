///|
/// Control queues + idle barrier (M2-T03, ADR §6).
///
/// Three control mailboxes:
/// - **Steer mailbox**: FIFO queue of `SteerCommand`. Consumed at the safe
///   point after a complete tool batch commits and before the next
///   model_step_id is allocated.
/// - **Follow-up mailbox**: FIFO queue of `FollowUpCommand`. Consumed at a
///   turn boundary (same run_id, new turn_id).
/// - **Resume mailbox**: addressed by `(target_run_id, suspension_id)`.
///   Only one resume per suspension; payload must satisfy the suspension
///   requirement.
///
/// Plus an **idle barrier**: a `@cond_var.Cond` that `wait_idle` waits on,
/// woken when the Harness reaches a quiescent phase (Idle / Suspended /
/// Shutdown).
///
/// IDs (ADR §6.1): every command carries the IDs required for safe-point
/// correlation. Stale IDs are rejected at enqueue time, not at consume time.

// ──────────────────────────────────────────────────────────────────────────
// CommandId — typed wrapper
// ──────────────────────────────────────────────────────────────────────────

///|
/// Stable identifier for a control command. Used in diagnostics and in
/// the queue's FIFO ordering (frozen at enqueue, consumed in command_id
/// order within a safe point).
pub(all) struct CommandId {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn CommandId::new(value : String) -> Result[CommandId, String] {
  if value == "" {
    Err("CommandId must be non-empty")
  } else {
    Ok(CommandId::{ value, })
  }
}

///|
pub fn CommandId::unchecked(value : String) -> CommandId {
  CommandId::{ value, }
}

///|
pub fn CommandId::to_string(self : CommandId) -> String {
  self.value
}

///|
pub impl Show for CommandId with fn to_string(self : CommandId) -> String {
  self.value
}

// ──────────────────────────────────────────────────────────────────────────
// QueuePolicy — ADR §6.4/§6.5
// ──────────────────────────────────────────────────────────────────────────

///|
/// How a mailbox consumes its queue at a single safe point.
pub(all) enum QueuePolicy {
  /// Consume all queued commands at once (e.g. all pending steers at one
  /// tool-batch boundary).
  All
  /// Consume exactly one command per safe point (e.g. one follow-up per
  /// turn boundary).
  OneAtATime
} derive(Eq, Debug)

///|
pub impl Show for QueuePolicy with fn to_string(self : QueuePolicy) -> String {
  match self {
    All => "All"
    OneAtATime => "OneAtATime"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Command types
// ──────────────────────────────────────────────────────────────────────────

///|
/// A steer command. Carries run/turn/batch/model-step IDs observed at
/// enqueue; consumed only if they match the active run's state at the
/// safe point.
pub(all) struct SteerCommand {
  command_id : CommandId
  target_run_id : RunId
  target_turn_id : TurnId
  /// Observed tool_batch_id when the steer was enqueued. Must match the
  /// batch that just completed at the consume point.
  observed_tool_batch_id : String
  /// Observed model_step_id when the steer was enqueued.
  observed_model_step_id : ModelStepId
  /// Opaque steer payload (e.g. additional system message). The Kernel
  /// does not interpret this; the Harness converts it to a RunInput at
  /// consume time.
  payload : Json
} derive(Eq, Debug)

///|
pub fn SteerCommand::command_id(self : SteerCommand) -> CommandId {
  self.command_id
}

///|
pub fn SteerCommand::target_run_id(self : SteerCommand) -> RunId {
  self.target_run_id
}

///|
pub fn SteerCommand::target_turn_id(self : SteerCommand) -> TurnId {
  self.target_turn_id
}

///|
pub fn SteerCommand::observed_tool_batch_id(self : SteerCommand) -> String {
  self.observed_tool_batch_id
}

///|
pub fn SteerCommand::observed_model_step_id(self : SteerCommand) -> ModelStepId {
  self.observed_model_step_id
}

///|
pub fn SteerCommand::payload(self : SteerCommand) -> Json {
  self.payload
}

///|
/// A follow-up command. Creates a new turn under the same run_id at a
/// turn boundary.
pub(all) struct FollowUpCommand {
  command_id : CommandId
  target_run_id : RunId
  source_turn_id : TurnId
  payload : Json
} derive(Eq, Debug)

///|
pub fn FollowUpCommand::command_id(self : FollowUpCommand) -> CommandId {
  self.command_id
}

///|
pub fn FollowUpCommand::target_run_id(self : FollowUpCommand) -> RunId {
  self.target_run_id
}

///|
pub fn FollowUpCommand::source_turn_id(self : FollowUpCommand) -> TurnId {
  self.source_turn_id
}

///|
pub fn FollowUpCommand::payload(self : FollowUpCommand) -> Json {
  self.payload
}

///|
/// A resume command. Targets a specific suspension under a specific run.
pub(all) struct ResumeCommand {
  command_id : CommandId
  target_run_id : RunId
  suspension_id : String
  /// Payload that must satisfy the SuspensionRequirement's `kind`.
  payload : Json
} derive(Eq, Debug)

///|
pub fn ResumeCommand::command_id(self : ResumeCommand) -> CommandId {
  self.command_id
}

///|
pub fn ResumeCommand::target_run_id(self : ResumeCommand) -> RunId {
  self.target_run_id
}

///|
pub fn ResumeCommand::suspension_id(self : ResumeCommand) -> String {
  self.suspension_id
}

///|
pub fn ResumeCommand::payload(self : ResumeCommand) -> Json {
  self.payload
}

///|
/// An abort command. Idempotent: the first call converts to
/// `RunInput::CancelRequested`; subsequent calls return
/// `AbortAlreadyRequested`.
pub(all) struct AbortCommand {
  command_id : CommandId
  target_run_id : RunId
  detail : String?
} derive(Eq, Debug)

///|
pub fn AbortCommand::command_id(self : AbortCommand) -> CommandId {
  self.command_id
}

///|
pub fn AbortCommand::target_run_id(self : AbortCommand) -> RunId {
  self.target_run_id
}

///|
pub fn AbortCommand::detail(self : AbortCommand) -> String? {
  self.detail
}

// ──────────────────────────────────────────────────────────────────────────
// EnqueueResult — what enqueue returns
// ──────────────────────────────────────────────────────────────────────────

///|
/// Result of enqueuing a control command.
pub(all) enum EnqueueResult {
  /// Command accepted; carries the command_id for correlation.
  Accepted(command_id~ : CommandId)
  /// Command rejected because the target id is stale (run/turn/batch/etc.
  /// does not match any active run).
  RejectedStale(command_id~ : CommandId, reason~ : String)
  /// Command rejected because the queue is full.
  RejectedQueueFull(command_id~ : CommandId, depth~ : Int)
  /// Abort command that arrived after the run was already terminal OR
  /// after a previous abort already fired.
  AbortAlreadyRequested(command_id~ : CommandId)
} derive(Eq, Debug)

///|
pub impl Show for EnqueueResult with fn to_string(self : EnqueueResult) -> String {
  match self {
    Accepted(command_id~) => "Accepted(\{command_id.to_string()})"
    RejectedStale(command_id~, reason~) =>
      "RejectedStale(\{command_id.to_string()}, \{reason})"
    RejectedQueueFull(command_id~, depth~) =>
      "RejectedQueueFull(\{command_id.to_string()}, depth=\{depth})"
    AbortAlreadyRequested(command_id~) =>
      "AbortAlreadyRequested(\{command_id.to_string()})"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// ControlMailbox — holds the three queues + abort flag + idle barrier
// ──────────────────────────────────────────────────────────────────────────

///|
/// Default max queue depth per mailbox. Beyond this, enqueue returns
/// `RejectedQueueFull`. M2 picks a conservative bound; M4/M5 may tune.
let default_max_queue_depth : Int = 64

///|
/// The control mailbox bundle. One instance per Harness; tracks the
/// currently-active run_id (so stale commands targeting an old run are
/// rejected at enqueue time without needing to consult the phase gate).
///
/// The steer and follow-up queues are `@aqueue.Queue` (MPMC, async-safe)
/// so that a sibling task in the same `TaskGroup` can enqueue commands
/// while the pump is mid-run (e.g. blocked on a model HTTP call). The
/// pump drains them at safe points via `try_get` (non-blocking).
/// `resume_pending` stays a `Map` because resume is addressed by
/// `suspension_id`, not FIFO.
pub struct ControlMailbox {
  mut steer_queue : @aqueue.Queue[SteerCommand]
  mut follow_up_queue : @aqueue.Queue[FollowUpCommand]
  /// Manual depth counters (`@aqueue.Queue` exposes no `length()`). The
  /// enqueue path increments; the consume path decrements. Tests assert
  /// on these to verify drain behaviour.
  mut steer_depth : Int
  mut follow_up_depth : Int
  /// Resume commands keyed by suspension_id. At most one per suspension.
  resume_pending : Map[String, ResumeCommand]
  /// Set if abort has been issued for the active run. Subsequent aborts
  /// return `AbortAlreadyRequested`.
  mut abort_requested : Bool
  /// Currently-active run_id. None when Idle.
  mut active_run_id : RunId?
  /// Currently-active turn_id. None when Idle.
  mut active_turn_id : TurnId?
  /// Condition variable for the idle barrier. `wait_idle` waits on this;
  /// the Harness signals it when reaching a quiescent phase.
  idle_cond : @cond_var.Cond
  /// Current quiescent status — set by the Harness when it reaches Idle /
  /// Suspended / Shutdown. `wait_idle` reads this upon wake.
  mut quiescent_status : QuiescentStatus
  max_depth : Int
}

///|
/// Typed quiescent status returned by `wait_idle`. Distinct from
/// `HarnessPhase` because it carries suspension details and the terminal
/// outcome (ADR §6.7).
pub(all) enum QuiescentStatus {
  /// No run was active.
  Idle
  /// Run is suspended; carries the details needed to resume.
  Suspended(
    run_id~ : RunId,
    suspension_id~ : String,
    requirement_kind~ : String
  )
  /// Run reached terminal outcome; carries the outcome for the caller.
  Terminal(outcome~ : RunOutcome)
  /// Harness has shut down. No further commands will be accepted.
  Shutdown
} derive(Eq, Debug)

///|
pub impl Show for QuiescentStatus with fn to_string(self : QuiescentStatus) -> String {
  match self {
    Idle => "Idle"
    Suspended(run_id~, suspension_id~, requirement_kind~) =>
      "Suspended(run=\{run_id.to_string()}, susp=\{suspension_id}, kind=\{requirement_kind})"
    Terminal(outcome~) => "Terminal(\{outcome.to_string()})"
    Shutdown => "Shutdown"
  }
}

///|
pub fn ControlMailbox::new() -> ControlMailbox {
  {
    steer_queue: @aqueue.Queue::Queue(kind=Unbounded),
    follow_up_queue: @aqueue.Queue::Queue(kind=Unbounded),
    steer_depth: 0,
    follow_up_depth: 0,
    resume_pending: Map::from_array([]),
    abort_requested: false,
    active_run_id: None,
    active_turn_id: None,
    idle_cond: @cond_var.Cond::Cond(),
    quiescent_status: Idle,
    max_depth: default_max_queue_depth,
  }
}

///|
/// Bind the mailbox to a new active run/turn. Called by the Harness when
/// acquiring a prompt lease. Clears any leftover state from the previous
/// run.
pub fn ControlMailbox::bind_run(
  self : ControlMailbox,
  run_id : RunId,
  turn_id : TurnId,
) -> Unit {
  self.active_run_id = Some(run_id)
  self.active_turn_id = Some(turn_id)
  self.abort_requested = false
  // `@aqueue.Queue` has no `clear()`: rebuild fresh instances. Old queued
  // commands targeting the previous run are dropped (their command_ids
  // were already Accepted; callers correlate via wait_idle).
  self.steer_queue = @aqueue.Queue::Queue(kind=Unbounded)
  self.follow_up_queue = @aqueue.Queue::Queue(kind=Unbounded)
  self.steer_depth = 0
  self.follow_up_depth = 0
  self.resume_pending.clear()
}

///|
/// Clear the active run binding. Called by the Harness when the run
/// reaches terminal. Any queued commands targeting the now-terminal run
/// are dropped.
pub fn ControlMailbox::clear_run(self : ControlMailbox) -> Unit {
  self.active_run_id = None
  self.active_turn_id = None
  self.abort_requested = false
  self.steer_queue = @aqueue.Queue::Queue(kind=Unbounded)
  self.follow_up_queue = @aqueue.Queue::Queue(kind=Unbounded)
  self.steer_depth = 0
  self.follow_up_depth = 0
  self.resume_pending.clear()
}

///|
pub fn ControlMailbox::active_run_id(self : ControlMailbox) -> RunId? {
  self.active_run_id
}

///|
pub fn ControlMailbox::active_turn_id(self : ControlMailbox) -> TurnId? {
  self.active_turn_id
}

///|
pub fn ControlMailbox::abort_requested(self : ControlMailbox) -> Bool {
  self.abort_requested
}

///|
pub fn ControlMailbox::steer_depth(self : ControlMailbox) -> Int {
  self.steer_depth
}

///|
pub fn ControlMailbox::follow_up_depth(self : ControlMailbox) -> Int {
  self.follow_up_depth
}

// ──────────────────────────────────────────────────────────────────────────
// Enqueue — steer / follow_up / resume / abort
// ──────────────────────────────────────────────────────────────────────────

///|
/// Enqueue a steer command. Rejects if:
/// - no active run (RejectedStale)
/// - target_run_id / target_turn_id don't match active
/// - queue full
///
/// Uses `try_put` (non-blocking) on the underlying `@aqueue.Queue`. The
/// queue is `Unbounded`, so we enforce `max_depth` manually via the
/// `steer_depth` counter to preserve `RejectedQueueFull` semantics.
pub fn ControlMailbox::enqueue_steer(
  self : ControlMailbox,
  cmd : SteerCommand,
) -> EnqueueResult {
  match (self.active_run_id, self.active_turn_id) {
    (Some(run), Some(turn)) => {
      if run != cmd.target_run_id || turn != cmd.target_turn_id {
        return RejectedStale(
          command_id=cmd.command_id,
          reason="steer targets stale run/turn",
        )
      }
      if self.steer_depth >= self.max_depth {
        return RejectedQueueFull(
          command_id=cmd.command_id,
          depth=self.steer_depth,
        )
      }
      let put_ok : Bool = self.steer_queue.try_put(cmd) catch {
        _ => false // queue closed — treat as full for caller simplicity
      }
      if not(put_ok) {
        return RejectedQueueFull(
          command_id=cmd.command_id,
          depth=self.steer_depth,
        )
      }
      self.steer_depth = self.steer_depth + 1
      Accepted(command_id=cmd.command_id)
    }
    _ => RejectedStale(command_id=cmd.command_id, reason="no active run")
  }
}

///|
/// Enqueue a follow-up command. Rejects if no active run or stale ids.
pub fn ControlMailbox::enqueue_follow_up(
  self : ControlMailbox,
  cmd : FollowUpCommand,
) -> EnqueueResult {
  match (self.active_run_id, self.active_turn_id) {
    (Some(run), Some(turn)) => {
      if run != cmd.target_run_id || turn != cmd.source_turn_id {
        return RejectedStale(
          command_id=cmd.command_id,
          reason="follow_up targets stale run/turn",
        )
      }
      if self.follow_up_depth >= self.max_depth {
        return RejectedQueueFull(
          command_id=cmd.command_id,
          depth=self.follow_up_depth,
        )
      }
      let put_ok : Bool = self.follow_up_queue.try_put(cmd) catch { _ => false }
      if not(put_ok) {
        return RejectedQueueFull(
          command_id=cmd.command_id,
          depth=self.follow_up_depth,
        )
      }
      self.follow_up_depth = self.follow_up_depth + 1
      Accepted(command_id=cmd.command_id)
    }
    _ => RejectedStale(command_id=cmd.command_id, reason="no active run")
  }
}

///|
/// Enqueue a resume command. Rejects if no active run or run id mismatch.
/// Multiple resumes for the same suspension_id: the first wins, subsequent
/// are rejected as stale.
pub fn ControlMailbox::enqueue_resume(
  self : ControlMailbox,
  cmd : ResumeCommand,
) -> EnqueueResult {
  match self.active_run_id {
    Some(run) => {
      if run != cmd.target_run_id {
        return RejectedStale(
          command_id=cmd.command_id,
          reason="resume targets stale run",
        )
      }
      if self.resume_pending.contains(cmd.suspension_id) {
        return RejectedStale(
          command_id=cmd.command_id,
          reason="resume already pending for this suspension_id",
        )
      }
      self.resume_pending[cmd.suspension_id] = cmd
      Accepted(command_id=cmd.command_id)
    }
    None => RejectedStale(command_id=cmd.command_id, reason="no active run")
  }
}

///|
/// Enqueue an abort. Idempotent: the first call sets `abort_requested`
/// and returns Accepted; subsequent calls return `AbortAlreadyRequested`.
/// Rejects if no active run.
pub fn ControlMailbox::enqueue_abort(
  self : ControlMailbox,
  cmd : AbortCommand,
) -> EnqueueResult {
  match self.active_run_id {
    None =>
      RejectedStale(command_id=cmd.command_id, reason="no active run to abort")
    Some(run) => {
      if run != cmd.target_run_id {
        return RejectedStale(
          command_id=cmd.command_id,
          reason="abort targets stale run",
        )
      }
      if self.abort_requested {
        return AbortAlreadyRequested(command_id=cmd.command_id)
      }
      self.abort_requested = true
      // Signal the idle barrier so a wait_idle blocked on this run wakes
      // up (the pump will observe abort_requested on its next tick).
      self.idle_cond.broadcast()
      Accepted(command_id=cmd.command_id)
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Consume — called by the Harness at safe points
// ──────────────────────────────────────────────────────────────────────────

///|
/// Consume all steer commands at one safe point. The Harness calls this
/// after a complete tool batch commits and before allocating the next
/// model_step_id. Returns the commands in FIFO order; the queue is
/// drained.
///
/// Uses `try_get` (non-blocking) in a loop until the queue is empty.
pub fn ControlMailbox::consume_steers(
  self : ControlMailbox,
) -> Array[SteerCommand] {
  let out : Array[SteerCommand] = []
  while true {
    let next : SteerCommand? = self.steer_queue.try_get() catch {
      _ => None // closed — treat as drained
    }
    match next {
      Some(cmd) => {
        out.push(cmd)
        self.steer_depth = self.steer_depth - 1
      }
      None => break
    }
  }
  out
}

///|
/// Consume one follow-up command (OneAtATime policy). Returns the oldest
/// if any, else None. The Harness calls this at a turn boundary.
pub fn ControlMailbox::consume_one_follow_up(
  self : ControlMailbox,
) -> FollowUpCommand? {
  let next : FollowUpCommand? = self.follow_up_queue.try_get() catch {
    _ => None
  }
  match next {
    Some(cmd) => {
      self.follow_up_depth = self.follow_up_depth - 1
      Some(cmd)
    }
    None => None
  }
}

///|
/// Take the resume command for a given suspension_id. Returns None if no
/// resume is pending for this suspension (the run stays suspended).
pub fn ControlMailbox::take_resume(
  self : ControlMailbox,
  suspension_id : String,
) -> ResumeCommand? {
  match self.resume_pending.get(suspension_id) {
    Some(cmd) => {
      let c = cmd
      self.resume_pending.remove(suspension_id)
      Some(c)
    }
    None => None
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Idle barrier — wait_idle / notify
// ──────────────────────────────────────────────────────────────────────────

///|
/// Current quiescent status. Set by the Harness via `set_quiescent`.
pub fn ControlMailbox::quiescent_status(
  self : ControlMailbox,
) -> QuiescentStatus {
  self.quiescent_status
}

///|
/// Update the quiescent status and wake all waiters. Called by the Harness
/// when it reaches Idle / Suspended / Terminal / Shutdown. The status is
/// read by `wait_idle` upon wake.
pub fn ControlMailbox::set_quiescent(
  self : ControlMailbox,
  status : QuiescentStatus,
) -> Unit {
  self.quiescent_status = status
  self.idle_cond.broadcast()
}

///|
/// Wait until the mailbox reaches a quiescent status. Implemented via
/// `@cond_var.Cond::wait` — NOT polling, NOT sleep. Multiple waiters all
/// wake on `set_quiescent`.
///
/// Returns the quiescent status (never `Idle`-but-still-active — the
/// Harness only sets quiescent when truly quiescent).
pub async fn ControlMailbox::wait_idle(
  self : ControlMailbox,
) -> QuiescentStatus {
  // Loop because @cond_var may have spurious wakeups; we re-check the
  // status each time. The status starts as Idle (the initial state) so
  // a wait_idle call when already quiescent returns immediately.
  while true {
    match self.quiescent_status {
      Idle =>
        // Idle is quiescent — return immediately.
        return Idle
      Suspended(..) => return self.quiescent_status
      Terminal(..) => return self.quiescent_status
      Shutdown => return Shutdown
    }
    // Active state: wait for the Harness to signal.
    self.idle_cond.wait()
  }
  // Unreachable; MoonBit needs a return at the end.
  Idle
}
