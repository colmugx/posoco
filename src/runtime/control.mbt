///|
/// `RuntimeControl` — the host-side control handle. A narrow, identity-guarded
/// facade over the run's control plane: follow-up submission and abort,
/// consumed by Posoco at safe boundaries. Stale targets are rejected at
/// enqueue time; abort is idempotent. The run loop itself stays internal —
/// this handle never exposes phases, journals, or the mailbox.

///|
/// Default max follow-up queue depth, aligned with the internal control
/// mailbox bound. Beyond this, enqueue returns `RejectedQueueFull`.
let default_max_follow_up_depth : Int = 64

///|
/// Result of a `RuntimeControl` submission.
pub(all) enum EnqueueOutcome {
  /// Command accepted; carries the command id for diagnostics/correlation.
  Accepted(command_id~ : String)
  /// Rejected because there is no active run, or the target went stale.
  RejectedStale(reason~ : String)
  /// Rejected because the follow-up queue is full.
  RejectedQueueFull(depth~ : Int)
  /// Abort arrived after a previous abort already fired for the active run.
  AbortAlreadyRequested
} derive(Eq, Debug)

///|
pub impl Show for EnqueueOutcome with fn to_string(self : EnqueueOutcome) -> String {
  match self {
    Accepted(command_id~) => "Accepted(\{command_id})"
    RejectedStale(reason~) => "RejectedStale(\{reason})"
    RejectedQueueFull(depth~) => "RejectedQueueFull(depth=\{depth})"
    AbortAlreadyRequested => "AbortAlreadyRequested"
  }
}

///|
/// The control handle. One instance per Agent; obtained via
/// `Agent::control()`. Holds a borrowed internal mailbox for identity
/// checks and abort signalling, plus its own follow-up queue drained by the
/// Agent at turn boundaries.
pub struct RuntimeControl {
  priv mailbox : &@puppetry.Mailbox
  priv follow_ups : @aqueue.Queue[@kernel.Message]
  priv mut follow_up_depth : Int
  /// Monotonic counter for command ids, so submissions correlate in
  /// diagnostics without wall-clock time.
  priv mut seq : Int
  priv max_depth : Int
}

///|
/// Construct the control handle over the Agent's shared mailbox. Framework
/// entry point — hosts obtain the handle from `Agent::control()`, they do
/// not construct it.
pub fn RuntimeControl::RuntimeControl(mailbox : &@puppetry.Mailbox) -> RuntimeControl {
  {
    mailbox,
    follow_ups: @aqueue.Queue::Queue(kind=Unbounded),
    follow_up_depth: 0,
    seq: 0,
    max_depth: default_max_follow_up_depth,
  }
}

///|
fn RuntimeControl::next_command_id(
  self : RuntimeControl,
  prefix : String,
) -> @puppetry.CommandId {
  self.seq = self.seq + 1
  @puppetry.CommandId::unchecked("\{prefix}_\{self.seq}")
}

///|
/// Currently-active run id, `None` when the Agent is idle. Hosts use this
/// (with `active_turn_id`) to target submissions and to detect staleness.
pub fn RuntimeControl::active_run_id(self : RuntimeControl) -> @kernel.RunId? {
  self.mailbox.active_run_id()
}

///|
/// Currently-active turn id, `None` when the Agent is idle.
pub fn RuntimeControl::active_turn_id(self : RuntimeControl) -> @kernel.TurnId? {
  self.mailbox.active_turn_id()
}

///|
/// Submit a follow-up message. The Agent consumes queued follow-ups one at
/// a time at turn boundaries (OneAtATime, matching the internal follow-up
/// mailbox policy) and drives a subsequent turn with each as a new user
/// message. Rejected with `RejectedStale` when no run is active — a
/// background task that finishes after its turn ended cannot sneak a
/// message into a later run.
pub fn RuntimeControl::enqueue_follow_up(
  self : RuntimeControl,
  message : @kernel.Message,
) -> EnqueueOutcome {
  let command_id = self.next_command_id("follow_up")
  match (self.mailbox.active_run_id(), self.mailbox.active_turn_id()) {
    (Some(_), Some(_)) => {
      if self.follow_up_depth >= self.max_depth {
        return RejectedQueueFull(depth=self.follow_up_depth)
      }
      let put_ok : Bool = self.follow_ups.try_put(message) catch { _ => false }
      if !put_ok {
        return RejectedQueueFull(depth=self.follow_up_depth)
      }
      self.follow_up_depth = self.follow_up_depth + 1
      Accepted(command_id=command_id.to_string())
    }
    _ => RejectedStale(reason="follow_up requires an active run")
  }
}

///|
/// Take the oldest queued follow-up (OneAtATime). Consumed by the Agent at
/// turn boundaries; hosts observe depth via `pending_follow_ups` instead.
pub fn RuntimeControl::take_follow_up(
  self : RuntimeControl,
) -> @kernel.Message? {
  let next : @kernel.Message? = self.follow_ups.try_get() catch { _ => None }
  match next {
    Some(message) => {
      self.follow_up_depth = self.follow_up_depth - 1
      Some(message)
    }
    None => None
  }
}

///|
/// Number of follow-ups currently queued.
pub fn RuntimeControl::pending_follow_ups(self : RuntimeControl) -> Int {
  self.follow_up_depth
}

///|
/// Abort the active run. Idempotent: the first call is accepted and the
/// loop observes it at its next safe point (in-flight effects receive a
/// best-effort `cancel_effects`); subsequent calls return
/// `AbortAlreadyRequested`. Rejected with `RejectedStale` when no run is
/// active.
pub fn RuntimeControl::abort_active(
  self : RuntimeControl,
  detail : String?,
) -> EnqueueOutcome {
  let command_id = self.next_command_id("abort")
  let cmd : @puppetry.AbortCommand = {
    command_id,
    target_run_id: match self.mailbox.active_run_id() {
      Some(run) => run
      None => return RejectedStale(reason="no active run to abort")
    },
    detail,
  }
  match self.mailbox.enqueue_abort(cmd) {
    @puppetry.Accepted(command_id~) =>
      Accepted(command_id=command_id.to_string())
    @puppetry.RejectedStale(reason~, ..) => RejectedStale(reason~)
    @puppetry.RejectedQueueFull(depth~, ..) => RejectedQueueFull(depth~)
    @puppetry.AbortAlreadyRequested(..) => AbortAlreadyRequested
  }
}
