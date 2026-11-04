///|
/// Opaque host-side control handle owned by one Agent.
///
/// Hosts obtain this value from `Agent::control()`. The message inbox — the
/// single FIFO behind both step and turn deliveries — and the follow-up drain
/// remain private to the root package, so a host can submit or observe control
/// state without taking ownership of Agent's loop.

///|
pub struct AgentControl {
  priv mailbox : &@puppetry.Mailbox
  priv inbox : @puppetry.MessageInbox
  priv mut seq : Int32
  priv mut abort_hook : ((@kernel.RunId) -> Unit)?
}

///|
/// Framework-only construction. Product code receives this handle from an
/// Agent and cannot bind one to an arbitrary internal mailbox.
fn AgentControl::AgentControl(mailbox : &@puppetry.Mailbox) -> AgentControl {
  { mailbox, inbox: mailbox.message_inbox(), seq: 0, abort_hook: None, }
}

///|
/// Install the Agent-owned foreground cancellation callback. The callback is
/// invoked only after the mailbox accepts an abort for a live run.
fn AgentControl::set_abort_hook(
  self : AgentControl,
  hook : (@kernel.RunId) -> Unit,
) -> Unit {
  self.abort_hook = Some(hook)
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
/// Opaque handle on the turn that currently accepts control messages. A host
/// captures it from `current_message_target()` and passes it back as
/// `target~`, so a late submit is rejected instead of silently attaching to a
/// newer turn.
#derive(Eq)
pub struct MessageTarget {
  priv address : @puppetry.MessageAddress
}

///|
pub extend MessageTarget with Eq::{equal, not_equal}

///|
/// Attribution scope for a delivered or undelivered message, taken from the
/// address the message was actually enqueued under — never the submitting
/// host's view of the active turn.
fn message_scope(address : @puppetry.MessageAddress) -> @types.EventScope {
  {
    session_id: @kernel.SessionId::unchecked(address.session_id),
    run_id: address.run_id,
    turn_id: address.turn_id,
  }
}

///|
/// Register the Agent event surface for inbox deliveries: the follow-up
/// (Turn) confirmation callback projects public `MessageApplied` through the
/// Agent's event runtime, with the scope of the turn that actually committed
/// the message. Invoked synchronously by the inbox at the initial commit.
fn AgentControl::install_message_events(
  self : AgentControl,
  events : @event_runtime.EventRuntime,
) -> Unit {
  self.inbox.set_follow_up_callback(fn(command, address) {
    events.emit_core(
      Some(message_scope(address)),
      MessageApplied(
        command_id=command.command_id.to_string(),
        delivery=command.delivery,
      ),
    )
  })
  self.inbox.set_step_delivery_callback(fn(command, reason) {
    let event : @types.TurnEvent = match reason {
      None =>
        MessageApplied(command_id=command.command_id.to_string(), delivery=Step)
      Some(reason) =>
        MessageUndelivered(
          command_id=command.command_id.to_string(),
          delivery=Step,
          reason~,
        )
    }
    events.emit_core(Some(message_scope(command.address)), event)
  })
}

///|
/// The turn that currently accepts control messages, or `None` while no turn
/// is open (idle, between turns, or during a compact operation).
pub fn AgentControl::current_message_target(
  self : AgentControl,
) -> MessageTarget? {
  self.inbox.current_address().map(fn(address) { { address, } })
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
/// Without a target, submit to the turn active at this call. With a target,
/// reject a delayed submission if the captured address is no longer active.
fn AgentControl::enqueue_message(
  self : AgentControl,
  prefix : String,
  delivery : @types.MessageDeliveryKind,
  message : @kernel.Message,
  target~ : MessageTarget? = None,
) -> @runtime.EnqueueOutcome {
  let command_id = self.next_command_id(prefix)
  match
    self.inbox.enqueue(
      command_id,
      delivery,
      message,
      expected=target.map(fn(target) { target.address }),
    ) {
    @puppetry.Accepted(command_id~) =>
      @runtime.Accepted(command_id=command_id.to_string())
    @puppetry.RejectedStale(reason~, ..) => @runtime.RejectedStale(reason~)
    @puppetry.RejectedQueueFull(depth~, ..) =>
      @runtime.RejectedQueueFull(depth~)
    @puppetry.AbortAlreadyRequested(..) =>
      @runtime.RejectedQueueFailure(
        reason="message cannot be marked abort-already-requested",
      )
  }
}

///|
/// Submit a follow-up consumed by the Agent at a turn boundary. Without a
/// target, the current turn at this call owns the submission. Pass `target~`
/// to reject a delayed task whose originally observed turn is no longer active.
pub fn AgentControl::enqueue_follow_up(
  self : AgentControl,
  message : @kernel.Message,
  target~ : MessageTarget? = None,
) -> @runtime.EnqueueOutcome {
  self.enqueue_message(
    "follow_up",
    @types.MessageDeliveryKind::Turn,
    message,
    target~,
  )
}

///|
/// Submit a steering message consumed at the next step boundary of the active
/// turn. Without a target, submit to the current turn at this call. Pass
/// `target~` to reject a delayed submission for an older turn.
pub fn AgentControl::enqueue_steer(
  self : AgentControl,
  message : @kernel.Message,
  target~ : MessageTarget? = None,
) -> @runtime.EnqueueOutcome {
  self.enqueue_message(
    "steer",
    @types.MessageDeliveryKind::Step,
    message,
    target~,
  )
}

///|
/// Number of steers waiting for the active turn's next step boundary.
pub fn AgentControl::pending_steers(self : AgentControl) -> Int32 {
  self.inbox.steer_depth()
}

///|
/// Number of follow-ups waiting for the Agent's next turn boundary.
pub fn AgentControl::pending_follow_ups(self : AgentControl) -> Int32 {
  self.inbox.follow_up_depth()
}

///|
/// Bind the inbox to the admitted operation: one inbox operation per guard
/// operation, cleared by `finish_operation` before the guard releases.
fn AgentControl::bind_operation(
  self : AgentControl,
  operation_id : String,
  session_id : String,
) -> Unit {
  self.inbox.begin_operation(operation_id, session_id)
}

///|
/// Bind the per-turn identity before the turn executes, opening the step
/// window under the admitted operation.
fn AgentControl::bind_turn(
  self : AgentControl,
  run_id : @kernel.RunId,
  turn_id : @kernel.TurnId,
) -> Unit {
  self.inbox.bind_turn(run_id, turn_id)
}

///|
/// Associate a drained follow-up with the turn that will first commit it: the
/// pump confirms the id at that turn's initial boundary, which projects the
/// public `MessageApplied` and retires the record.
fn AgentControl::arm_follow_up(
  self : AgentControl,
  command_id : @puppetry.CommandId,
  run_id : @kernel.RunId,
  turn_id : @kernel.TurnId,
) -> Unit {
  self.inbox.bind_turn(run_id, turn_id)
  self.inbox.set_initial_command(command_id.to_string())
}

///|
/// Take the oldest queued follow-up for this operation. The record stays in
/// the inbox (selected) until its turn's initial commit confirms it.
fn AgentControl::select_follow_up(
  self : AgentControl,
) -> @puppetry.QueuedMessage? {
  self.inbox.select_follow_up()
}

///|
/// Settle the step window at one per-turn exit: every step message still
/// unconfirmed for this turn is returned for `MessageUndelivered` reporting.
fn AgentControl::finish_turn(
  self : AgentControl,
  run_id : @kernel.RunId,
  turn_id : @kernel.TurnId,
) -> Array[@puppetry.QueuedMessage] {
  self.inbox.finish_turn(run_id, turn_id)
}

///|
/// Settle the whole operation before the guard releases: every remaining
/// record — step and turn, queued or selected — is returned for
/// `MessageUndelivered` reporting, and the inbox is closed so the next
/// admission starts from an empty inbox.
fn AgentControl::finish_operation(
  self : AgentControl,
) -> Array[@puppetry.QueuedMessage] {
  self.inbox.finish_operation()
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
    @puppetry.Accepted(command_id~) => {
      match self.abort_hook {
        Some(hook) => hook(cmd.target_run_id)
        None => ()
      }
      @runtime.Accepted(command_id=command_id.to_string())
    }
    @puppetry.RejectedStale(reason~, ..) => @runtime.RejectedStale(reason~)
    @puppetry.RejectedQueueFull(depth~, ..) =>
      @runtime.RejectedQueueFull(depth~)
    @puppetry.AbortAlreadyRequested(..) => @runtime.AbortAlreadyRequested
  }
}
