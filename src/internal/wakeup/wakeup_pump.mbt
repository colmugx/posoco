///|
/// Bounded, injection-safe envelope header field: the tag is untrusted
/// extension input, so it is length-capped and newline-flattened, then JSON
/// string-escaped, so the header closes exactly once whatever it contains.
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
    @kernel.Message::UserMessage(content=[@kernel.Content::Text(head)])
  } else {
    @kernel.Message::UserMessage(content=[
      @kernel.Content::Text("\{head} \{note}"),
    ])
  }
}

///|
/// Run one ticket as an ordinary turn. Returns `true` only when the turn was
/// re-queued behind a live incumbent.
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
  // Exactly one terminal per ticket: a raw pump cancellation bypasses the
  // catch below, so this unwind emitter still fires once, after the operation
  // settled cancelled on its own unwind, and the cancellation keeps
  // propagating raw.
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
    // Busy is a queueing signal, not a terminal state: no terminal and no
    // executing event fired, so re-queue at the head and wait for the
    // incumbent's settled notification.
    Err(@error.AgentError::Busy(..)) => {
      self.requeue_front(entry)
      return true
    }
    Err(@error.AgentError::Cancelled(_)) => "wakeup_cancelled"
    Err(_) => "wakeup_failed"
  }
  terminal.val = Some(label)
  self.emit_wakeup_event(label, entry, operation_id=Some(operation_id))
  false
}
