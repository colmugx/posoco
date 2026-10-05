///|
/// Agent-owned wakeup capability, ledger, and pump.
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
  /// Latest requirement generation seen for this key (port §4): refreshed
  /// by every request, so a snapshot taken before the latest request can
  /// never satisfy the entry.
  mut latest_requirement : Int
  /// Activation generation this ticket was admitted under: the binding
  /// generation of the window that owned it. A later binding change makes
  /// the ticket stale forever, even if the same session is bound again.
  activation : Int
}

///|
priv struct AgentWakeupRuntime {
  /// Request admission is open only inside a live `run_scoped` and before
  /// shutdown begins; once closed it never reopens.
  mut scope_active : Bool
  mut closed : Bool
  /// The host-bound active window session. `None` until the host binds one
  /// and cleared again at shutdown; requests may only target it.
  mut active_session : String?
  /// Bumped on every binding change. Pending tickets carry the generation
  /// they were admitted under; the pump rejects mismatched ones, so a
  /// dropped window's tickets can never execute after a switch back.
  mut active_generation : Int
  mut next_ticket_seq : Int
  mut next_operation_seq : Int
  /// Pump notification primitive. Signalled on: new request, operation
  /// settled, shutdown.
  wake : @async.CondVar
  /// Monotonic count of those state changes. Waiters compare epochs instead
  /// of trusting broadcast timing, so a notification landing between a
  /// condition check and `wait` can never be lost.
  mut epoch : Int
  /// Composed observers for the wakeup lifecycle projection.
  observers : Array[&@port.Observer]
  /// Pending tickets in FIFO execution order.
  order : Array[WakeupPending]
  /// session → tag → pending entry (coalescing lookup).
  by_key : Map[String, Map[String, WakeupPending]]
  /// Per-session latest requirement generation, bumped on every request.
  generations : Map[String, Int]
  /// Armed input cutoff of the one ordinary turn currently between its
  /// input snapshot and its committed run start. Keyed by that run's id;
  /// commit and unwind both match the key, so cleanup can never remove
  /// another turn's arm.
  mut cutoff_arm : WakeupCutoffArm?
}

///|
fn AgentWakeupRuntime::AgentWakeupRuntime(
  observers~ : Array[&@port.Observer],
) -> AgentWakeupRuntime {
  {
    scope_active: false,
    closed: false,
    active_session: None,
    active_generation: 0,
    next_ticket_seq: 0,
    next_operation_seq: 0,
    epoch: 0,
    wake: @async.CondVar::Cond(),
    observers,
    order: [],
    by_key: Map::from_array([]),
    generations: Map::from_array([]),
    cutoff_arm: None,
  }
}

///|
/// Bind one extension's capability view: requests carry the extension id for
/// event attribution.
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
/// Host-driven active-window binding (synchronous, usable while idle).
/// `Some(id)` binds, `None` clears. Reaffirming the bound id is a no-op:
/// valid tickets keep their place. A real change retires the previous
/// window — its pending tickets get exactly one `dropped` terminal and are
/// never revived by binding the same session again. An already admitted
/// operation is untouched: it settles through its own lifecycle.
fn AgentWakeupRuntime::set_active_session(
  self : AgentWakeupRuntime,
  session : String?,
) -> Unit {
  if self.closed {
    return
  }
  match (self.active_session, session) {
    (Some(current), Some(next)) if current == next => return
    _ => ()
  }
  self.active_session = session
  self.active_generation = self.active_generation + 1
  let stale : Array[WakeupPending] = []
  let mut index = 0
  while index < self.order.length() {
    let entry = self.order[index]
    match session {
      Some(active) if entry.ticket.session == active => index = index + 1
      _ => {
        stale.push(entry)
        ignore(self.order.remove(index))
      }
    }
  }
  for entry in stale {
    self.forget(entry)
  }
  for entry in stale {
    self.emit_wakeup_event("wakeup_dropped", entry)
  }
}

///|
/// A taken-but-not-yet-admitted ticket is stale once its window is gone.
fn AgentWakeupRuntime::pending_stale(
  self : AgentWakeupRuntime,
  entry : WakeupPending,
) -> Bool {
  match self.active_session {
    Some(active) => {
      let stale_generation = entry.activation != self.active_generation
      stale_generation || entry.ticket.session != active
    }
    None => true
  }
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
/// same-key request forms the next pending ticket at a new generation.
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
  // A request never binds the active session itself: only the currently
  // bound window session may be targeted.
  match self.active_session {
    Some(active) if active == session => ()
    Some(_) =>
      return Err(
        InvalidSession(reason="session does not match the active session"),
      )
    None => return Err(InvalidSession(reason="no active session is bound"))
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
      // once), refresh its note, and move the entry to the latest
      // generation, so a snapshot taken before this request can never
      // satisfy it.
      entry.note = note
      entry.latest_requirement = generation
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
      let entry : WakeupPending = {
        ticket,
        extension_id,
        note,
        latest_requirement: generation,
        activation: self.active_generation,
      }
      session_map[tag] = entry
      self.order.push(entry)
      self.emit_wakeup_event("wakeup_requested", entry)
      self.notify_state_change()
      Ok(ticket)
    }
  }
}

///|
/// Commit the armed input cutoff for `session_id`: every still-pending
/// entry whose latest requirement generation is at or before `cutoff` is
/// covered by the qualifying ordinary input that took the snapshot (the
/// satisfaction means the scheduling demand was met by that input
/// opportunity — nothing about outcomes). Entries created or refreshed
/// after the snapshot survive to a later ordinary turn.
fn AgentWakeupRuntime::satisfy_covered(
  self : AgentWakeupRuntime,
  session_id : String,
  cutoff : Int,
  operation_id : String,
) -> Unit {
  let covered : Array[WakeupPending] = []
  let mut index = 0
  while index < self.order.length() {
    let entry = self.order[index]
    if entry.ticket.session == session_id && entry.latest_requirement <= cutoff {
      covered.push(entry)
      ignore(self.order.remove(index))
    } else {
      index = index + 1
    }
  }
  for entry in covered {
    self.forget(entry)
  }
  for entry in covered {
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
  for ;; {
    if self.closed || agent.turn_active {
      return None
    }
    match self.order.get(0) {
      Some(entry) => {
        ignore(self.order.remove(0))
        self.forget(entry)
        if self.pending_stale(entry) {
          // The window that owned this ticket is gone: its terminal fired
          // at the switch (this is the defensive second layer). Skip it and
          // keep scanning so a fresher ticket behind it stays reachable.
          continue
        }
        return Some(entry)
      }
      None => return None
    }
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
fn AgentWakeupRuntime::notify_state_change(self : AgentWakeupRuntime) -> Unit {
  self.epoch = self.epoch + 1
  self.wake.broadcast()
}

///|
/// Wait for a pump-relevant state change at or after `seen`. Returns
/// immediately when the epoch already moved past `seen`: the notification
/// raced the caller's condition check (e.g. the incumbent operation settled
/// between the Busy rejection and this wait) and must not be slept through.
async fn AgentWakeupRuntime::wait_for_change(
  self : AgentWakeupRuntime,
  seen : Int,
) -> Unit {
  if self.epoch == seen {
    self.wake.wait()
  }
}

///|
/// `seen` is captured before the condition is read, so every state change
/// that could invalidate the decision to sleep is observable as an epoch
/// advance — the waits never spin and never miss a notification.
async fn AgentWakeupRuntime::pump_loop(
  self : AgentWakeupRuntime,
  agent : AgentRuntime,
) -> Unit {
  for ;; {
    let seen = self.epoch
    match self.take_next(agent) {
      Some(entry) => {
        if self.execute_ticket(agent, entry) {
          // Re-queued behind a live incumbent: wait on the state-change
          // notification (its settled broadcast) — never a no-await
          // hotloop. A settle that already raced the Busy return advanced
          // the epoch past `seen`, so this returns instead of sleeping.
          self.wait_for_change(seen)
        }
        continue
      }
      None => ()
    }
    if self.closed {
      return
    }
    self.wait_for_change(seen)
  }
}

///|
/// Bounded, injection-safe envelope header field: the tag is untrusted
/// extension input, so it is length-capped and newline-flattened, then
/// JSON string-escaped via `Json::stringify` — the envelope's `"` / `[` /
/// `]` delimiters can no longer appear unescaped inside the value, so the
/// header closes exactly once no matter what the tag contains.
fn wakeup_envelope_field(value : String, cap : Int) -> String {
  Json::string(bounded_error_label(value, cap))
  .stringify()
  .replace(old="[", new="\\u005b")
  .replace(old="]", new="\\u005d")
}

///|
/// The envelope head all wakeup shapes share (transcript input and the
/// `wakeup_executing` display envelope).
fn wakeup_envelope_head(tag : String) -> String {
  "[posoco-wakeup tag=\{wakeup_envelope_field(tag, wakeup_tag_max_length)}]"
}

///|
/// The wakeup turn's input is a user message of the task-outcome envelope
/// family: `[posoco-wakeup tag=<tag>] <note>`, with the trailing note
/// omitted when empty. The envelope belongs to the session record; the
/// wakeup turn is audited exactly like a host turn.
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
async fn AgentWakeupRuntime::execute_ticket(
  self : AgentWakeupRuntime,
  agent : AgentRuntime,
  entry : WakeupPending,
) -> Bool {
  if self.pending_stale(entry) {
    // Taken before a binding change, never admitted: no operation exists,
    // so rejecting here cannot disturb any in-flight user turn or guard.
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
  // Exactly one terminal per ticket. A raw pump cancellation bypasses the
  // catch below, so this unwind emitter still fires once — after the
  // operation settled cancelled on its own unwind — and the cancellation
  // keeps propagating raw, never translated into an ordinary fallback.
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
  let result : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn_with_mode(
      wakeup_envelope_message(ticket.tag, entry.note),
      ticket.session,
      false,
      origin=Wakeup,
      operation_label=Some(operation_id),
      on_admitted=Some(fn(admission) {
        ignore(admission)
        self.emit_wakeup_event(
          "wakeup_executing",
          entry,
          operation_id=Some(operation_id),
          envelope=Some(envelope_text),
        )
      }),
    ),
  ) catch {
    error => Err(error)
  }
  let label = match result {
    Ok(_) => "wakeup_completed"
    // Defensive: admission raced a host operation. Re-queue at the head and
    // wait for its settled notification instead of failing the ticket —
    // busy is a queueing signal, not a terminal state; neither a terminal
    // nor an executing event fired.
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
  self.notify_state_change()
}

///|
/// Shutdown step 1: close request admission (never reopens) and wake the
/// pump so it stops taking tickets. A ticket already executing finishes its
/// ordinary turn lifecycle on its own.
fn AgentWakeupRuntime::begin_shutdown(self : AgentWakeupRuntime) -> Unit {
  if !self.closed {
    self.closed = true
    self.scope_active = false
    // The window is gone: clear the binding. Pending tickets still receive
    // their `dropped` terminal in the later shutdown step, so the clear here
    // must not emit them a second time.
    self.active_session = None
    self.notify_state_change()
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
