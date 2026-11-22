///|
/// A batch of wakeup envelopes and the ticket generations they represent.
pub struct WakeupStep {
  messages : Array[@kernel.Message]
  priv owner : WakeupRuntime
  priv activation : Int32
  priv generations : Map[String, Int32]
}

///|
pub fn WakeupRuntime::has_step_wakeup(
  self : WakeupRuntime,
  session_id : String,
) -> Bool {
  !self.closed &&
  self.order.any(fn(entry) {
    entry.ticket.session == session_id && !self.pending_stale(entry)
  })
}

///|
/// Capture pending envelopes in FIFO order without removing their tickets.
pub fn WakeupRuntime::snapshot_step(
  self : WakeupRuntime,
  session_id : String,
) -> WakeupStep? {
  if self.closed {
    return None
  }
  let messages : Array[@kernel.Message] = []
  let generations : Map[String, Int32] = Map::from_array([])
  for entry in self.order {
    if entry.ticket.session == session_id && !self.pending_stale(entry) {
      messages.push(wakeup_envelope_message(entry.ticket.tag, entry.note))
      generations[entry.ticket.id] = entry.latest_requirement
    }
  }
  if messages.is_empty() {
    None
  } else {
    Some({
      messages,
      owner: self,
      activation: self.active_generation,
      generations,
    })
  }
}

///|
pub fn WakeupStep::is_current(self : WakeupStep) -> Bool {
  !self.owner.closed && self.owner.active_generation == self.activation
}

///|
/// Confirm after the journal commits these envelopes to the scoped turn.
/// Re-requests since the snapshot remain pending, even for the same ticket.
pub fn WakeupRuntime::confirm_step(
  self : WakeupRuntime,
  step : WakeupStep,
  scope : @types.EventScope,
  operation_id : String,
) -> Unit {
  if !physical_equal(self, step.owner) || !step.is_current() {
    return
  }
  let session_id = scope.session_id.to_string()
  let satisfied : Array[WakeupPending] = []
  let mut index = 0
  while index < self.order.length() {
    let entry = self.order[index]
    if entry.ticket.session == session_id &&
      !self.pending_stale(entry) &&
      step.generations.get(entry.ticket.id) == Some(entry.latest_requirement) {
      satisfied.push(entry)
      ignore(self.order.remove(index))
      self.forget(entry)
    } else {
      index = index + 1
    }
  }
  // Clear the entire batch before observers can re-request any of its tags.
  for entry in satisfied {
    self.emit_wakeup_event(
      "wakeup_satisfied",
      entry,
      operation_id=Some(operation_id),
      step_scope=Some(scope),
    )
  }
}
