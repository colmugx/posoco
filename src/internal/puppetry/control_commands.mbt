///|
/// Control commands + idle barrier (ADR §6).
///
/// Step and turn messages share the Agent-owned `MessageInbox`. The pump
/// selects step messages at safe boundaries; Agent selects turn messages
/// when starting a new turn with a new run/turn identity. Resume commands are
/// separately addressed by `(target_run_id, suspension_id)` and must satisfy
/// the suspension requirement.
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
#derive(Eq, Hash, Debug)
pub(all) struct CommandId {
  value : String
}

///|
pub extend CommandId with Eq::{not_equal, equal}

///|
pub extend CommandId with Hash::{hash, hash_combine}

///|
pub extend CommandId with Debug::{to_repr}

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
pub extend CommandId with Show::{output}

///|
pub impl Show for CommandId with fn to_string(self : CommandId) -> String {
  self.value
}

// ──────────────────────────────────────────────────────────────────────────
// QueuePolicy — ADR §6.4/§6.5
// ──────────────────────────────────────────────────────────────────────────

///|
/// How a mailbox consumes its queue at a single safe point.
#derive(Eq, Debug)
pub(all) enum QueuePolicy {
  /// Consume all queued commands at once (e.g. all pending steers at one
  /// tool-batch boundary).
  All
  /// Consume exactly one command per safe point (e.g. one follow-up per
  /// turn boundary).
  OneAtATime
}

///|
pub extend QueuePolicy with Eq::{not_equal, equal}

///|
pub extend QueuePolicy with Debug::{to_repr}

///|
pub extend QueuePolicy with Show::{to_string, output}

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
/// A steer command: a message appended to the transcript at the next step
/// boundary. Identity is validated against the active run/turn at enqueue
/// time only — a steer is never stale at consume time, it is delivered at the
/// next safe point or reported undelivered.
#derive(Eq, Debug)
pub(all) struct SteerCommand {
  command_id : CommandId
  target_run_id : RunId
  target_turn_id : TurnId
  /// The user message to append. The Puppet converts it to a
  /// `RunInput::SteerAppended` at consume time.
  message : @kernel.Message
}

///|
pub extend SteerCommand with Eq::{not_equal, equal}

///|
pub extend SteerCommand with Debug::{to_repr}

///|
/// A resume command. Targets a specific suspension under a specific run.
#derive(Eq, Debug)
pub(all) struct ResumeCommand {
  command_id : CommandId
  target_run_id : RunId
  suspension_id : String
  /// Payload that must satisfy the SuspensionRequirement's `kind`.
  payload : Json
}

///|
pub extend ResumeCommand with Eq::{not_equal, equal}

///|
pub extend ResumeCommand with Debug::{to_repr}

///|
/// An abort command. Idempotent: the first call converts to
/// `RunInput::CancelRequested`; subsequent calls return
/// `AbortAlreadyRequested`.
#derive(Eq, Debug)
pub(all) struct AbortCommand {
  command_id : CommandId
  target_run_id : RunId
  detail : String?
}

///|
pub extend AbortCommand with Eq::{not_equal, equal}

///|
pub extend AbortCommand with Debug::{to_repr}

// ──────────────────────────────────────────────────────────────────────────
// Fork / Compact commands
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
#derive(Eq, Debug)
pub(all) struct ForkCommand {
  command_id : CommandId
  target_run_id : RunId
  target_turn_id : TurnId
  fork_index : Int32
}

///|
pub extend ForkCommand with Eq::{not_equal, equal}

///|
pub extend ForkCommand with Debug::{to_repr}

///|
pub fn ForkCommand::command_id(self : ForkCommand) -> CommandId {
  self.command_id
}

///|
pub fn ForkCommand::fork_index(self : ForkCommand) -> Int32 {
  self.fork_index
}

///|
/// User-or-pump request to compact the current thread. `trigger` tells the
/// modelport whether this is an automatic (context-window pressure) or
/// manual (`/compact`) compact, so the modelport can pick a strategy.
#derive(Eq, Debug)
pub(all) struct CompactCommand {
  command_id : CommandId
  target_run_id : RunId
  target_turn_id : TurnId
  trigger : @kernel.CompactTrigger
}

///|
pub extend CompactCommand with Eq::{not_equal, equal}

///|
pub extend CompactCommand with Debug::{to_repr}

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
#derive(Eq, Debug)
pub(all) enum EnqueueResult {
  /// Command accepted; carries the command_id for correlation.
  Accepted(command_id~ : CommandId)
  /// Command rejected because the target id is stale (run/turn/batch/etc.
  /// does not match any active run).
  RejectedStale(command_id~ : CommandId, reason~ : String)
  /// Command rejected because the queue is full.
  RejectedQueueFull(command_id~ : CommandId, depth~ : Int32)
  /// Abort command that arrived after the run was already terminal OR
  /// after a previous abort already fired.
  AbortAlreadyRequested(command_id~ : CommandId)
}

///|
pub extend EnqueueResult with Eq::{not_equal, equal}

///|
pub extend EnqueueResult with Debug::{to_repr}

///|
pub extend EnqueueResult with Show::{to_string, output}

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
  fn message_inbox(Self) -> MessageInbox
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
  fn steer_depth(Self) -> Int32
  fn follow_up_depth(Self) -> Int32
  fn fork_depth(Self) -> Int32
  fn compact_depth(Self) -> Int32

  // ── Enqueue (product / sibling-task side; non-blocking) ──
  fn enqueue_steer(Self, cmd : SteerCommand) -> EnqueueResult
  fn enqueue_resume(Self, cmd : ResumeCommand) -> EnqueueResult
  fn enqueue_abort(Self, cmd : AbortCommand) -> EnqueueResult
  fn enqueue_fork(Self, cmd : ForkCommand) -> EnqueueResult
  fn enqueue_compact(Self, cmd : CompactCommand) -> EnqueueResult

  // ── Consume (pump side; called at safe points) ──
  /// Select all queued step messages in FIFO order, retaining commit receipts.
  fn consume_steers(Self) -> Array[SteerCommand]
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
