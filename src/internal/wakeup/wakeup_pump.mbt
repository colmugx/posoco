///|
fn wakeup_envelope_field(value : String, cap : Int32) -> String {
  Json::string(@diagnostic.bounded_error_label(value, cap))
  .stringify()
  .replace(old="[", new="\\u005b")
  .replace(old="]", new="\\u005d")
}

///|
fn wakeup_envelope_head(tag : String) -> String {
  "[posoco-wakeup tag=\{wakeup_envelope_field(tag, wakeup_tag_max_length)}]"
}

///|
fn wakeup_envelope_message(tag : String, note : String) -> @kernel.Message {
  let head = wakeup_envelope_head(tag)
  if note == "" {
    UserMessage(content=[Text(head)])
  } else {
    UserMessage(content=[Text("\{head} \{note}")])
  }
}

///|
async fn WakeupRuntime::execute_ticket(
  self : WakeupRuntime,
  host : &WakeupHost,
  entry : WakeupPending,
) -> Bool {
  if self.pending_stale(entry) {
    self.emit_wakeup_event("wakeup_dropped", entry)
    return false
  }
  let ticket = entry.ticket
  self.next_operation_seq = self.next_operation_seq + 1
  let operation_id = "agent_wakeup_\{self.next_operation_seq}"
  let head = wakeup_envelope_head(ticket.tag)
  let envelope_text = if entry.note == "" {
    head
  } else {
    "\{head} \{entry.note}"
  }
  let terminal : Ref[String?] = Ref(None)
  errdefer (match terminal.val {
    Some(_) => ()
    None =>
      self.emit_wakeup_event(
        "wakeup_cancelled",
        entry,
        operation_id=Some(operation_id),
      )
  })
  let result : Result[Unit, @error.AgentError] = Ok(
    host.run_wakeup_turn(
      wakeup_envelope_message(ticket.tag, entry.note),
      ticket.session,
      operation_id,
      fn() {
        self.emit_wakeup_event(
          "wakeup_executing",
          entry,
          operation_id=Some(operation_id),
          envelope=Some(envelope_text),
        )
      },
    ),
  ) catch {
    error => Err(error)
  }
  let label = match result {
    Ok(_) => "wakeup_completed"
    Err(Busy(..)) => {
      let requeued = self.requeue_front(entry)
      terminal.val = Some("requeued")
      return requeued
    }
    Err(Cancelled(_)) => "wakeup_cancelled"
    Err(_) => "wakeup_failed"
  }
  terminal.val = Some(label)
  self.emit_wakeup_event(label, entry, operation_id=Some(operation_id))
  false
}
