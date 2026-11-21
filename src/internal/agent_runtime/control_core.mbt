///|
pub struct ControlCore {
  priv mailbox : &@puppetry.Mailbox
  priv inbox : @puppetry.MessageInbox
  priv mut seq : Int32
  priv mut abort_hook : ((@kernel.RunId) -> Unit)?
}

///|
fn ControlCore::ControlCore(mailbox : &@puppetry.Mailbox) -> ControlCore {
  { mailbox, inbox: mailbox.message_inbox(), seq: 0, abort_hook: None, }
}

///|
fn ControlCore::set_abort_hook(
  self : ControlCore,
  hook : (@kernel.RunId) -> Unit,
) -> Unit {
  self.abort_hook = Some(hook)
}

///|
fn ControlCore::next_command_id(
  self : ControlCore,
  prefix : String,
) -> @puppetry.CommandId {
  self.seq = self.seq + 1
  @puppetry.CommandId::unchecked("\{prefix}_\{self.seq}")
}

///|
fn message_scope(address : @puppetry.MessageAddress) -> @types.EventScope {
  {
    session_id: @kernel.SessionId::unchecked(address.session_id),
    run_id: address.run_id,
    turn_id: address.turn_id,
  }
}

///|
fn ControlCore::install_message_events(
  self : ControlCore,
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
pub fn ControlCore::current_address(
  self : ControlCore,
) -> @puppetry.MessageAddress? {
  self.inbox.current_address()
}

///|
pub fn ControlCore::active_run_id(self : ControlCore) -> @kernel.RunId? {
  self.mailbox.active_run_id()
}

///|
pub fn ControlCore::active_turn_id(self : ControlCore) -> @kernel.TurnId? {
  self.mailbox.active_turn_id()
}

///|
fn ControlCore::enqueue_message(
  self : ControlCore,
  prefix : String,
  delivery : @types.MessageDeliveryKind,
  message : @kernel.Message,
  expected : @puppetry.MessageAddress?,
) -> @runtime.EnqueueOutcome {
  let command_id = self.next_command_id(prefix)
  match self.inbox.enqueue(command_id, delivery, message, expected~) {
    Accepted(command_id~) => Accepted(command_id=command_id.to_string())
    RejectedStale(reason~, ..) => RejectedStale(reason~)
    RejectedQueueFull(depth~, ..) => RejectedQueueFull(depth~)
    AbortAlreadyRequested(..) =>
      RejectedQueueFailure(
        reason="message cannot be marked abort-already-requested",
      )
  }
}

///|
pub fn ControlCore::enqueue_follow_up(
  self : ControlCore,
  message : @kernel.Message,
  expected~ : @puppetry.MessageAddress? = None,
) -> @runtime.EnqueueOutcome {
  self.enqueue_message("follow_up", Turn, message, expected)
}

///|
pub fn ControlCore::enqueue_steer(
  self : ControlCore,
  message : @kernel.Message,
  expected~ : @puppetry.MessageAddress? = None,
) -> @runtime.EnqueueOutcome {
  self.enqueue_message("steer", Step, message, expected)
}

///|
pub fn ControlCore::pending_steers(self : ControlCore) -> Int32 {
  self.inbox.steer_depth()
}

///|
pub fn ControlCore::pending_follow_ups(self : ControlCore) -> Int32 {
  self.inbox.follow_up_depth()
}

///|
fn ControlCore::bind_operation(
  self : ControlCore,
  operation_id : String,
  session_id : String,
) -> Unit {
  self.inbox.begin_operation(operation_id, session_id)
}

///|
fn ControlCore::bind_turn(
  self : ControlCore,
  run_id : @kernel.RunId,
  turn_id : @kernel.TurnId,
) -> Unit {
  self.inbox.bind_turn(run_id, turn_id)
}

///|
fn ControlCore::arm_follow_up(
  self : ControlCore,
  command_id : @puppetry.CommandId,
  run_id : @kernel.RunId,
  turn_id : @kernel.TurnId,
) -> Unit {
  self.inbox.bind_turn(run_id, turn_id)
  self.inbox.set_initial_command(command_id.to_string())
}

///|
fn ControlCore::select_follow_up(
  self : ControlCore,
) -> @puppetry.QueuedMessage? {
  self.inbox.select_follow_up()
}

///|
fn ControlCore::finish_turn(
  self : ControlCore,
  run_id : @kernel.RunId,
  turn_id : @kernel.TurnId,
) -> Array[@puppetry.QueuedMessage] {
  self.inbox.finish_turn(run_id, turn_id)
}

///|
fn ControlCore::finish_operation(
  self : ControlCore,
) -> Array[@puppetry.QueuedMessage] {
  self.inbox.finish_operation()
}

///|
pub fn ControlCore::abort_active(
  self : ControlCore,
  detail : String?,
) -> @runtime.EnqueueOutcome {
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
    Accepted(command_id~) => {
      match self.abort_hook {
        Some(hook) => hook(cmd.target_run_id)
        None => ()
      }
      Accepted(command_id=command_id.to_string())
    }
    RejectedStale(reason~, ..) => RejectedStale(reason~)
    RejectedQueueFull(depth~, ..) => RejectedQueueFull(depth~)
    AbortAlreadyRequested(..) => AbortAlreadyRequested
  }
}
