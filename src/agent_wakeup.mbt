///|
/// Agent-owned wakeup capability, ledger, and pump (plan step 3).
///
/// The ledger is synchronous and self-contained (safe to touch from task
/// bodies, observers, and hooks): per-(session, tag) pending tickets with
/// latest-requirement generations, a FIFO execution order, and a cond-var
/// notification primitive — new requests, operation settled, and shutdown
/// all broadcast, so the pump never polls. Execution reuses
/// `run_turn_with_mode`: a wakeup is an ordinary turn through the
/// single-operation lifecycle, nothing else. The pump itself is not a public
/// Background Task and produces no outcome.

///|
/// Envelope key cap: tags beyond this length are rejected at admission.
let wakeup_tag_max_length : Int = 80

///|
priv struct WakeupPending {
  ticket : @port.WakeupTicket
  extension_id : String
  mut note : String
}

///|
priv struct AgentWakeupRuntime {
  /// Request admission is open only inside a live `run_scoped` and before
  /// shutdown begins; once closed it never reopens.
  mut scope_active : Bool
  mut closed : Bool
  mut next_ticket_seq : Int
  mut next_operation_seq : Int
  /// Pump notification primitive. Broadcast on: new request, operation
  /// settled, shutdown.
  wake : @async.CondVar
  /// Composed observers for the wakeup lifecycle projection. Available at
  /// composition, before `on_compose` delivers the capability.
  observers : Array[&@port.Observer]
  /// Pending tickets in FIFO execution order.
  order : Array[WakeupPending]
  /// session → tag → pending entry (coalescing lookup).
  by_key : Map[String, Map[String, WakeupPending]]
  /// Per-session latest requirement generation, bumped on every request.
  generations : Map[String, Int]
}

///|
fn AgentWakeupRuntime::AgentWakeupRuntime(
  observers~ : Array[&@port.Observer],
) -> AgentWakeupRuntime {
  {
    scope_active: false,
    closed: false,
    next_ticket_seq: 0,
    next_operation_seq: 0,
    wake: @async.CondVar::Cond(),
    observers,
    order: [],
    by_key: Map::from_array([]),
    generations: Map::from_array([]),
  }
}

///|
/// Bind one extension's capability view: requests carry the extension id for
/// event attribution. The runtime is fully built before `on_compose`, so the
/// capability never exposes an uninitialized object.
fn AgentWakeupRuntime::capability(
  self : AgentWakeupRuntime,
  extension_id : String,
) -> @port.WakeupPort {
  let runtime = self
  @port.WakeupPort::from_request(request=fn(session, tag, note) {
    runtime.request(extension_id, session, tag, note)
  })
}

///|
fn AgentWakeupRuntime::activate(
  self : AgentWakeupRuntime,
) -> Unit raise @error.AgentError {
  if self.closed {
    raise @error.AgentError::Runtime(
      @error.RuntimeError::InvocationFailed("wakeup runtime is closed"),
    )
  }
  if self.scope_active {
    raise @error.AgentError::Runtime(
      @error.RuntimeError::InvocationFailed("wakeup scope is already active"),
    )
  }
  self.scope_active = true
}

///|
fn AgentWakeupRuntime::emit_wakeup_event(
  self : AgentWakeupRuntime,
  label : String,
  entry : WakeupPending,
  operation_id? : String? = None,
  envelope? : String? = None,
) -> Unit {
  let ticket = entry.ticket
  let fields : Array[(String, Json)] = [
    ("ticket_id", Json::string(ticket.id)),
    ("session", Json::string(ticket.session)),
    ("tag", Json::string(ticket.tag)),
    ("extension_id", Json::string(entry.extension_id)),
    ("ticket_enqueued_at", Json::number(ticket.enqueued_at.to_double())),
  ]
  match operation_id {
    Some(id) => fields.push(("operation_id", Json::string(id)))
    None => ()
  }
  match envelope {
    Some(text) => fields.push(("envelope", Json::string(text)))
    None => ()
  }
  emit_custom_event(self.observers, None, "posoco.wakeup", label, fields)
}

///|
/// Synchronous admission. Validates scope, session, and tag; coalesces on
/// (session, tag); every request records the latest requirement generation.
/// A pending entry returns the same ticket (the `wakeup_requested` event
/// fired once, at creation); during execution the key is free again, so a
/// same-key request forms the next pending ticket.
fn AgentWakeupRuntime::request(
  self : AgentWakeupRuntime,
  extension_id : String,
  session : String,
  tag : String,
  note : String,
) -> Result[@port.WakeupTicket, @port.WakeupError] {
  if self.closed || !self.scope_active {
    return Err(ScopeInactive)
  }
  if session == "" {
    return Err(InvalidSession(reason="session must not be empty"))
  }
  if tag == "" {
    return Err(TagInvalid(reason="tag must not be empty"))
  }
  if tag.length() > wakeup_tag_max_length {
    return Err(
      TagInvalid(
        reason="tag must not exceed \{wakeup_tag_max_length} characters",
      ),
    )
  }
  let generation = match self.generations.get(session) {
    Some(value) => value + 1
    None => 1
  }
  self.generations[session] = generation
  let session_map = match self.by_key.get(session) {
    Some(existing) => existing
    None => {
      let created : Map[String, WakeupPending] = Map::from_array([])
      self.by_key[session] = created
      created
    }
  }
  match session_map.get(tag) {
    Some(entry) => {
      // Late requirement on the same key: keep the ticket (requested fired
      // once) and move the session's demand to the latest generation, so a
      // stale snapshot cannot satisfy it.
      entry.note = note
      Ok(entry.ticket)
    }
    None => {
      self.next_ticket_seq = self.next_ticket_seq + 1
      let ticket : @port.WakeupTicket = {
        id: "wakeup_ticket_\{self.next_ticket_seq}",
        session,
        tag,
        enqueued_at: @async.now(),
      }
      let entry : WakeupPending = { ticket, extension_id, note, }
      session_map[tag] = entry
      self.order.push(entry)
      self.emit_wakeup_event("wakeup_requested", entry)
      self.wake.broadcast()
      Ok(ticket)
    }
  }
}

///|
/// The ordinary input for `session_id` entered the model-input preparation
/// stage (the snapshot that appends the caller's input). Every wakeup that
/// was still pending for that session is now covered by this input
/// opportunity: satisfied means "the scheduling demand was met", not that
/// extension knowledge was understood. Requests arriving after this point
/// survive to a later ordinary turn.
fn AgentWakeupRuntime::satisfy_covered(
  self : AgentWakeupRuntime,
  session_id : String,
  operation_id : String,
) -> Unit {
  let covered : Array[WakeupPending] = []
  let mut index = 0
  while index < self.order.length() {
    let entry = self.order[index]
    if entry.ticket.session == session_id {
      covered.push(entry)
      ignore(self.order.remove(index))
    } else {
      index = index + 1
    }
  }
  for entry in covered {
    self.forget(entry)
    self.emit_wakeup_event(
      "wakeup_satisfied",
      entry,
      operation_id=Some(operation_id),
    )
  }
}

///|
fn AgentWakeupRuntime::forget(
  self : AgentWakeupRuntime,
  entry : WakeupPending,
) -> Unit {
  match self.by_key.get(entry.ticket.session) {
    Some(session_map) => {
      session_map.remove(entry.ticket.tag)
      if session_map.is_empty() {
        self.by_key.remove(entry.ticket.session)
      }
    }
    None => ()
  }
}

///|
/// Take the oldest pending ticket when the Agent is idle. The check and the
/// subsequent admission happen with no await in between, so a wakeup turn
/// never steals the guard from an operation that already ran its admission.
fn AgentWakeupRuntime::take_next(
  self : AgentWakeupRuntime,
  agent : AgentRuntime,
) -> WakeupPending? {
  if self.closed || agent.turn_active {
    return None
  }
  match self.order.get(0) {
    Some(entry) => {
      ignore(self.order.remove(0))
      self.forget(entry)
      Some(entry)
    }
    None => None
  }
}

///|
/// Start the pump after `run_scoped`'s startup lifecycle completed, so the
/// first lifecycle `on_start` never races a pump turn.
fn[G] AgentWakeupRuntime::start_pump(
  self : AgentWakeupRuntime,
  group : @async.TaskGroup[G],
  agent : AgentRuntime,
) -> Unit {
  group.spawn_bg(async fn() { self.pump_loop(agent) })
}

///|
/// Wake only on notifications: new request, operation settled, shutdown.
async fn AgentWakeupRuntime::pump_loop(
  self : AgentWakeupRuntime,
  agent : AgentRuntime,
) -> Unit {
  for ;; {
    match self.take_next(agent) {
      Some(entry) => {
        self.execute_ticket(agent, entry)
        continue
      }
      None => ()
    }
    if self.closed {
      return
    }
    self.wake.wait()
  }
}

///|
/// Bounded, newline-free envelope header field: the tag is a coalescing key,
/// not free-form envelope content, so control characters are flattened
/// before the value joins the transcript.
fn wakeup_envelope_field(value : String, cap : Int) -> String {
  bounded_error_label(value, cap)
}

///|
/// The wakeup turn's input is a user message of the task-outcome envelope
/// family: `[posoco-wakeup tag=<tag>] <note>`, with the trailing note
/// omitted when empty. The envelope belongs to the session record; the
/// wakeup turn is audited exactly like a host turn.
fn wakeup_envelope_message(tag : String, note : String) -> @kernel.Message {
  let head = "[posoco-wakeup tag=\{wakeup_envelope_field(tag, wakeup_tag_max_length)}]"
  if note == "" {
    @kernel.Message::UserMessage(content=[@kernel.Content::Text(head)])
  } else {
    @kernel.Message::UserMessage(content=[
      @kernel.Content::Text("\{head} \{note}"),
    ])
  }
}

///|
async fn AgentWakeupRuntime::execute_ticket(
  self : AgentWakeupRuntime,
  agent : AgentRuntime,
  entry : WakeupPending,
) -> Unit {
  let ticket = entry.ticket
  self.next_operation_seq = self.next_operation_seq + 1
  let operation_id = "agent_wakeup_\{self.next_operation_seq}"
  let envelope_text = if entry.note == "" {
    "[posoco-wakeup tag=\{wakeup_envelope_field(ticket.tag, wakeup_tag_max_length)}]"
  } else {
    "[posoco-wakeup tag=\{wakeup_envelope_field(ticket.tag, wakeup_tag_max_length)}] \{entry.note}"
  }
  self.emit_wakeup_event(
    "wakeup_executing",
    entry,
    operation_id=Some(operation_id),
    envelope=Some(envelope_text),
  )
  let result : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn_with_mode(
      wakeup_envelope_message(ticket.tag, entry.note),
      ticket.session,
      false,
      origin=Wakeup,
      operation_label=Some(operation_id),
    ),
  ) catch {
    error => Err(error)
  }
  let label = match result {
    Ok(_) => "wakeup_completed"
    // Defensive: admission raced a host operation. Re-queue at the head and
    // wait for its settled notification instead of failing the ticket —
    // busy is a queueing signal, not a terminal state.
    Err(@error.AgentError::Busy(..)) => {
      self.requeue_front(entry)
      return
    }
    Err(@error.AgentError::Cancelled(_)) => "wakeup_cancelled"
    Err(_) => "wakeup_failed"
  }
  self.emit_wakeup_event(label, entry, operation_id=Some(operation_id))
}

///|
fn AgentWakeupRuntime::requeue_front(
  self : AgentWakeupRuntime,
  entry : WakeupPending,
) -> Unit {
  self.order.insert(0, entry)
  let session_map = match self.by_key.get(entry.ticket.session) {
    Some(existing) => existing
    None => {
      let created : Map[String, WakeupPending] = Map::from_array([])
      self.by_key[entry.ticket.session] = created
      created
    }
  }
  session_map[entry.ticket.tag] = entry
}

///|
fn AgentWakeupRuntime::notify_operation_settled(
  self : AgentWakeupRuntime,
) -> Unit {
  self.wake.broadcast()
}

///|
/// Block until the in-flight operation releases the guard. Every settlement
/// broadcasts on the pump condvar (`release_operation`), and the cooperative
/// scheduler cannot interleave the guard check with the wait registration, so
/// this wakes exactly when the current operation settles.
async fn AgentWakeupRuntime::wait_operation_settled(
  self : AgentWakeupRuntime,
  agent : AgentRuntime,
) -> Unit {
  while agent.operations.current is Some(_) {
    self.wake.wait()
  }
}

///|
/// Shutdown step 1: close request admission (never reopens) and wake the
/// pump so it stops taking tickets. A ticket already executing finishes its
/// ordinary turn lifecycle on its own.
fn AgentWakeupRuntime::begin_shutdown(self : AgentWakeupRuntime) -> Unit {
  if !self.closed {
    self.closed = true
    self.scope_active = false
    self.wake.broadcast()
  }
}

///|
/// Shutdown step 2: pending scheduling requests die with the scope. Each
/// pending ticket gets exactly one `dropped` terminal; a ticket already
/// executing is not touched here — its turn settles it.
fn AgentWakeupRuntime::drop_pending(self : AgentWakeupRuntime) -> Unit {
  let pending = self.order.copy()
  self.order.clear()
  for entry in pending {
    self.forget(entry)
    self.emit_wakeup_event("wakeup_dropped", entry)
  }
}
