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
/// woken when the Puppet reaches a quiescent phase (Idle / Suspended /
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
pub fn CommandId::checked(value : String) -> Result[CommandId, String] {
  if value == "" {
    Err("CommandId must be non-empty")
  } else {
    Ok({ value, })
  }
}

///|
pub fn CommandId::unchecked(value : String) -> CommandId {
  { value, }
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
  /// does not interpret this; the Puppet converts it to a RunInput at
  /// consume time.
  payload : Json
} derive(Eq, Debug)

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
/// A resume command. Targets a specific suspension under a specific run.
pub(all) struct ResumeCommand {
  command_id : CommandId
  target_run_id : RunId
  suspension_id : String
  /// Payload that must satisfy the SuspensionRequirement's `kind`.
  payload : Json
} derive(Eq, Debug)

///|
/// An abort command. Idempotent: the first call converts to
/// `RunInput::CancelRequested`; subsequent calls return
/// `AbortAlreadyRequested`.
pub(all) struct AbortCommand {
  command_id : CommandId
  target_run_id : RunId
  detail : String?
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// Fork / Compact commands (M3.5)
// ──────────────────────────────────────────────────────────────────────────

///|
/// User request to fork the current thread at a message index. Carries the
/// run/turn IDs observed at enqueue so the pump can correlate at the consume
/// safe point. `fork_index` is the position in the transcript at which the
/// new thread splits from the current one (clamped to `[0, length]`).
///
/// Fork is copy-on-write: the original thread is never mutated. The pump
/// snapshots the transcript's first `fork_index` messages, writes them as a
/// new session (carrying `parent_thread_id` lineage), and returns
/// `PromptResult::ForkCompleted`. The current turn then continues on the
/// original thread.
pub(all) struct ForkCommand {
  command_id : CommandId
  target_run_id : RunId
  target_turn_id : TurnId
  fork_index : Int
} derive(Eq, Debug)

///|
pub fn ForkCommand::command_id(self : ForkCommand) -> CommandId {
  self.command_id
}

///|
pub fn ForkCommand::fork_index(self : ForkCommand) -> Int {
  self.fork_index
}

///|
/// User-or-pump request to compact the current thread. `trigger` tells the
/// modelport whether this is an automatic (context-window pressure) or
/// manual (`/compact`) compact, so the modelport can pick a strategy.
pub(all) struct CompactCommand {
  command_id : CommandId
  target_run_id : RunId
  target_turn_id : TurnId
  trigger : @kernel.CompactTrigger
} derive(Eq, Debug)

///|
pub fn CompactCommand::command_id(self : CompactCommand) -> CommandId {
  self.command_id
}

///|
pub fn CompactCommand::trigger(self : CompactCommand) -> @kernel.CompactTrigger {
  self.trigger
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
// Mailbox trait — lets the long-lived Puppet and product command ports share
// one `ControlMailbox`. `pub(open)` so alternative implementations (recorded
// replay, clustered) can substitute without touching the pump.
// ──────────────────────────────────────────────────────────────────────────

///|
/// Control-plane abstraction over the run's command queues and idle
/// barrier.
pub(open) trait Mailbox {
  // ── Run binding (pump owns; called at prompt / terminal boundaries) ──
  /// Bind the mailbox to a new active run/turn. Clears leftover state.
  fn bind_run(Self, run_id : RunId, turn_id : TurnId) -> Unit
  /// Clear the active run binding. Called when the run reaches terminal.
  fn clear_run(Self) -> Unit
  /// Currently-active run_id. `None` when Idle.
  fn active_run_id(Self) -> RunId?
  /// Currently-active turn_id. `None` when Idle.
  fn active_turn_id(Self) -> TurnId?
  /// Whether an abort has been issued for the active run.
  fn abort_requested(Self) -> Bool

  // ── Queue depth accessors (read-only diagnostics for tests / hosts) ──
  fn steer_depth(Self) -> Int
  fn follow_up_depth(Self) -> Int
  fn fork_depth(Self) -> Int
  fn compact_depth(Self) -> Int

  // ── Enqueue (product / sibling-task side; non-blocking) ──
  fn enqueue_steer(Self, cmd : SteerCommand) -> EnqueueResult
  fn enqueue_follow_up(Self, cmd : FollowUpCommand) -> EnqueueResult
  fn enqueue_resume(Self, cmd : ResumeCommand) -> EnqueueResult
  fn enqueue_abort(Self, cmd : AbortCommand) -> EnqueueResult
  fn enqueue_fork(Self, cmd : ForkCommand) -> EnqueueResult
  fn enqueue_compact(Self, cmd : CompactCommand) -> EnqueueResult

  // ── Consume (pump side; called at safe points) ──
  /// Consume all queued steer commands (All policy). FIFO order.
  fn consume_steers(Self) -> Array[SteerCommand]
  /// Consume one follow-up (OneAtATime). `None` if empty.
  fn consume_one_follow_up(Self) -> FollowUpCommand?
  /// Consume one fork (OneAtATime). `None` if empty.
  fn consume_one_fork(Self) -> ForkCommand?
  /// Consume one compact (OneAtATime). `None` if empty.
  fn consume_one_compact(Self) -> CompactCommand?
  /// Take the resume for a suspension_id. `None` if none pending.
  fn take_resume(Self, suspension_id : String) -> ResumeCommand?

  // ── Idle barrier (pump signals; callers wait) ──
  fn quiescent_status(Self) -> QuiescentStatus
  fn set_quiescent(Self, status : QuiescentStatus) -> Unit
  /// Wait until the mailbox reaches a quiescent status. Implementations
  /// MUST use a cond-var / event (not polling).
  async fn wait_idle(Self) -> QuiescentStatus
}
