///|
let next_message_inbox_id : Ref[Int32] = Ref(0)

///|
#derive(Eq, Debug)
pub(all) struct MessageAddress {
  owner_id : Int32
  operation_id : String
  session_id : String
  run_id : RunId
  turn_id : TurnId
}

///|
pub extend MessageAddress with Eq::{equal, not_equal}

///|
pub extend MessageAddress with Debug::{to_repr}

///|
pub(all) struct QueuedMessage {
  command_id : CommandId
  address : MessageAddress
  delivery : @types.MessageDeliveryKind
  message : Message
}

///|
priv struct PendingMessage {
  command : QueuedMessage
  mut selected : Bool
}

///|
priv struct CommittedStepDelivery {
  command : QueuedMessage
  reason : String?
}

///|
/// Agent owns admission and settlement; the pump only selects and confirms
/// messages. Selected entries stay here until their boundary commits.
pub struct MessageInbox {
  priv owner_id : Int32
  priv mut operation_id : String?
  priv mut session_id : String
  priv mut address : MessageAddress?
  priv mut step_open : Bool
  priv pending : Array[PendingMessage]
  priv mut initial_command_id : String?
  priv mut on_follow_up_applied : ((QueuedMessage, MessageAddress) -> Unit)?
  priv committed_steps : Array[CommittedStepDelivery]
  priv mut on_step_delivery : ((QueuedMessage, String?) -> Unit)?
}

///|
pub fn MessageInbox::MessageInbox() -> MessageInbox {
  let owner_id = next_message_inbox_id.val
  next_message_inbox_id.val = owner_id + 1
  {
    owner_id,
    operation_id: None,
    session_id: "",
    address: None,
    step_open: false,
    pending: [],
    initial_command_id: None,
    on_follow_up_applied: None,
    committed_steps: [],
    on_step_delivery: None,
  }
}

///|
pub fn MessageInbox::begin_operation(
  self : MessageInbox,
  operation_id : String,
  session_id : String,
) -> Unit {
  if !self.pending.is_empty() || !self.committed_steps.is_empty() {
    abort("message inbox: previous operation has unsettled messages")
  }
  self.operation_id = Some(operation_id)
  self.session_id = session_id
  self.address = None
  self.step_open = false
}

///|
pub fn MessageInbox::bind_turn(
  self : MessageInbox,
  run_id : RunId,
  turn_id : TurnId,
) -> Unit {
  // Standalone Puppet tests have no Agent operation admission.
  let operation_id = match self.operation_id {
    Some(id) => id
    None => {
      let id = run_id.to_string()
      self.operation_id = Some(id)
      id
    }
  }
  self.address = Some({
    owner_id: self.owner_id,
    operation_id,
    session_id: self.session_id,
    run_id,
    turn_id,
  })
  self.step_open = true
}

///|
pub fn MessageInbox::current_address(self : MessageInbox) -> MessageAddress? {
  if self.step_open {
    self.address
  } else {
    None
  }
}

///|
pub fn MessageInbox::close_step(self : MessageInbox) -> Unit {
  self.step_open = false
}

///|
pub fn MessageInbox::close_turn(self : MessageInbox) -> Unit {
  self.step_open = false
  self.address = None
  self.initial_command_id = None
}

///|
pub fn MessageInbox::enqueue(
  self : MessageInbox,
  command_id : CommandId,
  delivery : @types.MessageDeliveryKind,
  message : Message,
  expected~ : MessageAddress? = None,
) -> EnqueueResult {
  let address = match self.address {
    Some(address) => address
    None => return RejectedStale(command_id~, reason="no active turn")
  }
  if delivery is Step && !self.step_open {
    return RejectedStale(command_id~, reason="turn input is closed")
  }
  match expected {
    Some(expected) if expected != address =>
      return RejectedStale(command_id~, reason="message target is stale")
    _ => ()
  }
  let depth = self.pending
    .filter(fn(entry) { entry.command.delivery == delivery })
    .length()
  if depth >= default_max_queue_depth {
    return RejectedQueueFull(command_id~, depth~)
  }
  self.pending.push({
    command: {
      command_id,
      address,
      delivery,
      message: @message_snapshot.snapshot_message(message),
    },
    selected: false,
  })
  Accepted(command_id~)
}

///|
pub fn MessageInbox::steer_depth(self : MessageInbox) -> Int32 {
  self.pending
  .filter(fn(entry) {
    !entry.selected &&
    entry.command.delivery is Step &&
    self.address == Some(entry.command.address)
  })
  .length()
}

///|
pub fn MessageInbox::follow_up_depth(self : MessageInbox) -> Int32 {
  self.pending
  .filter(fn(entry) { !entry.selected && entry.command.delivery is Turn })
  .length()
}

///|
pub fn MessageInbox::pending_steer_messages(
  self : MessageInbox,
) -> Array[Message] {
  self.pending
  .filter(fn(entry) {
    !entry.selected &&
    entry.command.delivery is Step &&
    self.address == Some(entry.command.address)
  })
  .map(fn(entry) { @message_snapshot.snapshot_message(entry.command.message) })
}

///|
pub fn MessageInbox::select_steers(self : MessageInbox) -> Array[QueuedMessage] {
  let selected : Array[QueuedMessage] = []
  for entry in self.pending {
    if !entry.selected &&
      entry.command.delivery is Step &&
      self.address == Some(entry.command.address) {
      entry.selected = true
      selected.push(entry.command)
    }
  }
  selected
}

///|
pub fn MessageInbox::select_follow_up(self : MessageInbox) -> QueuedMessage? {
  for entry in self.pending {
    if !entry.selected &&
      entry.command.delivery is Turn &&
      self.operation_id == Some(entry.command.address.operation_id) {
      entry.selected = true
      return Some(entry.command)
    }
  }
  None
}

///|
pub fn MessageInbox::set_initial_command(
  self : MessageInbox,
  command_id : String,
) -> Unit {
  self.initial_command_id = Some(command_id)
}

///|
pub fn MessageInbox::set_follow_up_callback(
  self : MessageInbox,
  callback : (QueuedMessage, MessageAddress) -> Unit,
) -> Unit {
  self.on_follow_up_applied = Some(callback)
}

///|
pub fn MessageInbox::confirm(self : MessageInbox, command_id : String) -> Unit {
  for index, entry in self.pending {
    if entry.command.command_id.to_string() == command_id {
      ignore(self.pending.remove(index))
      if entry.command.delivery is Turn {
        match (self.on_follow_up_applied, self.address) {
          (Some(callback), Some(address)) => callback(entry.command, address)
          _ => ()
        }
      } else {
        self.committed_steps.push({ command: entry.command, reason: None, })
      }
      return
    }
  }
}

///|
pub fn MessageInbox::initial_command(self : MessageInbox) -> String? {
  self.initial_command_id
}

///|
pub fn MessageInbox::confirm_initial(self : MessageInbox) -> Unit {
  match self.initial_command_id {
    Some(command_id) => {
      self.initial_command_id = None
      self.confirm(command_id)
    }
    None => ()
  }
}

///|
pub fn MessageInbox::discard(
  self : MessageInbox,
  command_id : String,
  reason : String,
) -> Unit {
  for index, entry in self.pending {
    if entry.command.command_id.to_string() == command_id {
      ignore(self.pending.remove(index))
      self.committed_steps.push({
        command: entry.command,
        reason: Some(reason),
      })
      return
    }
  }
}

///|
pub fn MessageInbox::set_step_delivery_callback(
  self : MessageInbox,
  callback : (QueuedMessage, String?) -> Unit,
) -> Unit {
  self.on_step_delivery = Some(callback)
}

///|
/// The normal event projection acknowledges before notifying listeners.
pub fn MessageInbox::acknowledge_step_delivery(
  self : MessageInbox,
  command_id : String,
) -> Unit {
  for index, delivery in self.committed_steps {
    if delivery.command.command_id.to_string() == command_id {
      ignore(self.committed_steps.remove(index))
      return
    }
  }
}

///|
/// A failed/cancelled subscriber must not erase a committed delivery receipt.
/// Clear before callbacks so reentrant listeners cannot publish it twice.
pub fn MessageInbox::flush_step_deliveries(self : MessageInbox) -> Unit {
  let deliveries = self.committed_steps.copy()
  self.committed_steps.clear()
  if self.on_step_delivery is Some(callback) {
    for delivery in deliveries {
      callback(delivery.command, delivery.reason)
    }
  }
}

///|
pub fn MessageInbox::finish_turn(
  self : MessageInbox,
  run_id : RunId,
  turn_id : TurnId,
) -> Array[QueuedMessage] {
  if self.address is Some(address) &&
    address.run_id == run_id &&
    address.turn_id == turn_id {
    self.step_open = false
  }
  let remaining : Array[QueuedMessage] = []
  let mut index = 0
  while index < self.pending.length() {
    let command = self.pending[index].command
    if command.delivery is Step &&
      command.address.run_id == run_id &&
      command.address.turn_id == turn_id {
      ignore(self.pending.remove(index))
      remaining.push(command)
    } else {
      index = index + 1
    }
  }
  remaining
}

///|
pub fn MessageInbox::finish_operation(
  self : MessageInbox,
) -> Array[QueuedMessage] {
  let remaining = self.pending.map(fn(entry) { entry.command })
  self.pending.clear()
  self.operation_id = None
  self.session_id = ""
  self.close_turn()
  remaining
}
