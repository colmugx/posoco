///|
/// Opaque host-side control handle owned by one Agent.
///
/// Hosts obtain this value from `Agent::control()`. The internal mailbox and
/// the follow-up drain remain private to the root package, so a host can
/// submit or observe control state without taking ownership of Agent's loop.

///|
let default_max_follow_up_depth : Int = 64

///|
pub struct AgentControl {
  priv mailbox : &@puppetry.Mailbox
  priv follow_ups : @aqueue.Queue[@kernel.Message]
  priv mut follow_up_depth : Int
  priv mut seq : Int
  priv max_depth : Int
}

///|
/// Framework-only construction. Product code receives this handle from an
/// Agent and cannot bind one to an arbitrary internal mailbox.
fn AgentControl::AgentControl(mailbox : &@puppetry.Mailbox) -> AgentControl {
  {
    mailbox,
    follow_ups: Queue(kind=Unbounded),
    follow_up_depth: 0,
    seq: 0,
    max_depth: default_max_follow_up_depth,
  }
}

///|
fn AgentControl::next_command_id(
  self : AgentControl,
  prefix : String,
) -> @puppetry.CommandId {
  self.seq = self.seq + 1
  @puppetry.CommandId::unchecked("\{prefix}_\{self.seq}")
}

///|
/// Currently-active run id, or `None` while the Agent is idle.
pub fn AgentControl::active_run_id(self : AgentControl) -> @kernel.RunId? {
  self.mailbox.active_run_id()
}

///|
/// Currently-active turn id, or `None` while the Agent is idle.
pub fn AgentControl::active_turn_id(self : AgentControl) -> @kernel.TurnId? {
  self.mailbox.active_turn_id()
}

///|
/// Submit a follow-up consumed by the Agent at a turn boundary. A stale or
/// absent run is rejected so a late task cannot target a later run.
pub fn AgentControl::enqueue_follow_up(
  self : AgentControl,
  message : @kernel.Message,
) -> @runtime.EnqueueOutcome {
  let command_id = self.next_command_id("follow_up")
  match (self.mailbox.active_run_id(), self.mailbox.active_turn_id()) {
    (Some(_), Some(_)) => {
      if self.follow_up_depth >= self.max_depth {
        return @runtime.RejectedQueueFull(depth=self.follow_up_depth)
      }
      let put_result : Result[Bool, Error] = Ok(
        self.follow_ups.try_put(message),
      ) catch {
        error => Err(error)
      }
      match put_result {
        Err(error) =>
          return @runtime.RejectedQueueFailure(
            reason="follow_up queue write failed: " +
              safe_error_label(error.to_string()),
          )
        Ok(false) =>
          return @runtime.RejectedQueueFull(depth=self.follow_up_depth)
        Ok(true) => ()
      }
      self.follow_up_depth = self.follow_up_depth + 1
      @runtime.Accepted(command_id=command_id.to_string())
    }
    _ => @runtime.RejectedStale(reason="follow_up requires an active run")
  }
}

///|
/// Agent-internal drain at the boundary between full turns.
fn AgentControl::take_follow_up(
  self : AgentControl,
) -> @kernel.Message? raise @error.AgentError {
  let next : @kernel.Message? = self.follow_ups.try_get() catch {
    error =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "follow_up queue read failed: " + safe_error_label(error.to_string()),
        ),
      )
  }
  match next {
    Some(message) => {
      self.follow_up_depth = self.follow_up_depth - 1
      Some(message)
    }
    None => None
  }
}

///|
/// Number of follow-ups waiting for the Agent's next turn boundary.
pub fn AgentControl::pending_follow_ups(self : AgentControl) -> Int {
  self.follow_up_depth
}

///|
/// Request cancellation of the active run. Repeated requests return the
/// displayable `AbortAlreadyRequested` outcome.
pub fn AgentControl::abort_active(
  self : AgentControl,
  detail : String?,
) -> @runtime.EnqueueOutcome {
  let command_id = self.next_command_id("abort")
  let cmd : @puppetry.AbortCommand = {
    command_id,
    target_run_id: match self.mailbox.active_run_id() {
      Some(run) => run
      None => return @runtime.RejectedStale(reason="no active run to abort")
    },
    detail,
  }
  match self.mailbox.enqueue_abort(cmd) {
    @puppetry.Accepted(command_id~) =>
      @runtime.Accepted(command_id=command_id.to_string())
    @puppetry.RejectedStale(reason~, ..) => @runtime.RejectedStale(reason~)
    @puppetry.RejectedQueueFull(depth~, ..) =>
      @runtime.RejectedQueueFull(depth~)
    @puppetry.AbortAlreadyRequested(..) => @runtime.AbortAlreadyRequested
  }
}
