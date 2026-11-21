///|
/// Opaque host-side control handle owned by one Agent.
pub struct AgentControl {
  priv core : @agent_runtime.ControlCore
}

///|
/// Opaque handle on the turn that currently accepts control messages.
#derive(Eq)
pub struct MessageTarget {
  priv address : @puppetry.MessageAddress
}

///|
pub extend MessageTarget with Eq::{equal, not_equal}

///|
pub fn AgentControl::current_message_target(
  self : AgentControl,
) -> MessageTarget? {
  self.core.current_address().map(fn(address) { { address, } })
}

///|
pub fn AgentControl::active_run_id(self : AgentControl) -> @kernel.RunId? {
  self.core.active_run_id()
}

///|
pub fn AgentControl::active_turn_id(self : AgentControl) -> @kernel.TurnId? {
  self.core.active_turn_id()
}

///|
pub fn AgentControl::enqueue_follow_up(
  self : AgentControl,
  message : @kernel.Message,
  target~ : MessageTarget? = None,
) -> @runtime.EnqueueOutcome {
  self.core.enqueue_follow_up(
    message,
    expected=target.map(fn(target) { target.address }),
  )
}

///|
pub fn AgentControl::enqueue_steer(
  self : AgentControl,
  message : @kernel.Message,
  target~ : MessageTarget? = None,
) -> @runtime.EnqueueOutcome {
  self.core.enqueue_steer(
    message,
    expected=target.map(fn(target) { target.address }),
  )
}

///|
pub fn AgentControl::pending_steers(self : AgentControl) -> Int32 {
  self.core.pending_steers()
}

///|
pub fn AgentControl::pending_follow_ups(self : AgentControl) -> Int32 {
  self.core.pending_follow_ups()
}

///|
pub fn AgentControl::abort_active(
  self : AgentControl,
  detail : String?,
) -> @runtime.EnqueueOutcome {
  self.core.abort_active(detail)
}
