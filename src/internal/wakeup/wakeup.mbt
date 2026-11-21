///|
/// The only thing the wakeup ledger needs from its owner: whether an
/// operation currently holds the single-operation guard, and one ordinary
/// turn that the owner runs through its own admission path.
pub(open) trait WakeupHost {
  fn wakeup_idle(Self) -> Bool
  async fn run_wakeup_turn(Self, @kernel.Message, String, String, () -> Unit) -> Unit raise @error.AgentError
}

///|
let wakeup_tag_max_length : Int32 = 80

///|
let wakeup_max_pending : Int32 = 64

///|
priv struct WakeupPending {
  ticket : @port.WakeupTicket
  extension_id : String
  mut note : String
  /// Latest requirement generation seen for this key: refreshed by every
  /// request, so a snapshot taken before the latest request cannot satisfy it.
  mut latest_requirement : Int32
  /// Binding generation this ticket was admitted under; a later binding
  /// change makes it stale forever.
  activation : Int32
}

///|
pub struct WakeupRuntime {
  priv mut scope_active : Bool
  priv mut closed : Bool
  priv mut active_session : String?
  /// Bumped on every binding change; stale tickets can never execute.
  priv mut active_generation : Int32
  priv mut next_ticket_seq : Int32
  priv mut next_operation_seq : Int32
  priv wake : @cond_var.Cond
  /// Monotonic state-change count, compared instead of trusting broadcast
  /// timing so a notification landing between a check and `wait` is lost
  /// only if this counter did not move.
  priv mut epoch : Int32
  priv events : @event_runtime.EventRuntime
  /// Pending tickets in FIFO execution order.
  priv order : Array[WakeupPending]
  /// session → tag → pending entry (coalescing lookup).
  priv by_key : Map[String, Map[String, WakeupPending]]
  /// Per-session latest requirement generation, bumped on every request.
  priv generations : Map[String, Int32]
  priv mut cutoff_arm : WakeupCutoffArm?
}

///|
pub fn WakeupRuntime::WakeupRuntime(
  events~ : @event_runtime.EventRuntime,
) -> WakeupRuntime {
  {
    scope_active: false,
    closed: false,
    active_session: None,
    active_generation: 0,
    next_ticket_seq: 0,
    next_operation_seq: 0,
    epoch: 0,
    wake: Cond(),
    events,
    order: [],
    by_key: Map::from_array([]),
    generations: Map::from_array([]),
    cutoff_arm: None,
  }
}

///|
pub fn WakeupRuntime::capability(
  self : WakeupRuntime,
  extension_id : String,
) -> @port.WakeupPort {
  let runtime = self
  @port.WakeupPort::from_request(request=fn(session, tag, note) {
    runtime.request(extension_id, session, tag, note)
  })
}

///|
pub fn WakeupRuntime::activate(
  self : WakeupRuntime,
) -> Unit raise @error.AgentError {
  if self.closed {
    raise Runtime(InvocationFailed("wakeup runtime is closed"))
  }
  if self.scope_active {
    raise Runtime(InvocationFailed("wakeup scope is already active"))
  }
  self.scope_active = true
}

///|
/// `Some(id)` binds, `None` clears. Reaffirming the bound id is a no-op; a
/// real change retires the previous window's pending tickets with exactly one
/// `dropped` terminal, and an already admitted operation settles on its own.
pub fn WakeupRuntime::set_active_session(
  self : WakeupRuntime,
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
fn WakeupRuntime::pending_stale(
  self : WakeupRuntime,
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
fn WakeupRuntime::emit_wakeup_event(
  self : WakeupRuntime,
  label : String,
  entry : WakeupPending,
  operation_id~ : String? = None,
  envelope~ : String? = None,
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
  let event : @types.TurnEvent = Custom(
    source="posoco.wakeup",
    label~,
    data=Json::object(Map::from_array(fields)),
  )
  self.events.emit_core(None, event)
}

///|
fn WakeupRuntime::request(
  self : WakeupRuntime,
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
      self.generations[session] = generation
      entry.note = note
      entry.latest_requirement = generation
      Ok(entry.ticket)
    }
    None => {
      if session_map.length() >= wakeup_max_pending {
        return Err(PendingFull(session~, limit=wakeup_max_pending))
      }
      self.generations[session] = generation
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
fn WakeupRuntime::satisfy_covered(
  self : WakeupRuntime,
  session_id : String,
  cutoff : Int32,
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
fn WakeupRuntime::forget(self : WakeupRuntime, entry : WakeupPending) -> Unit {
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
fn WakeupRuntime::take_next(
  self : WakeupRuntime,
  host : &WakeupHost,
) -> WakeupPending? {
  for ;; {
    if self.closed || !host.wakeup_idle() {
      return None
    }
    match self.order {
      [entry, ..] => {
        ignore(self.order.remove(0))
        self.forget(entry)
        if self.pending_stale(entry) {
          self.emit_wakeup_event("wakeup_dropped", entry)
          continue
        }
        return Some(entry)
      }
      [] => return None
    }
  }
}

///|
pub fn WakeupRuntime::start_pump(
  self : WakeupRuntime,
  group : @async.TaskGroup,
  host : &WakeupHost,
) -> Unit {
  group.spawn_bg(async fn() { self.pump_loop(host) })
}

///|
fn WakeupRuntime::notify_state_change(self : WakeupRuntime) -> Unit {
  self.epoch = self.epoch + 1
  self.wake.broadcast()
}

///|
async fn WakeupRuntime::wait_for_change(
  self : WakeupRuntime,
  seen : Int32,
) -> Unit {
  if self.epoch == seen {
    self.wake.wait()
  }
}

///|
async fn WakeupRuntime::pump_loop(
  self : WakeupRuntime,
  host : &WakeupHost,
) -> Unit {
  for ;; {
    let seen = self.epoch
    match self.take_next(host) {
      Some(entry) => {
        if self.execute_ticket(host, entry) {
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
fn WakeupRuntime::requeue_front(
  self : WakeupRuntime,
  entry : WakeupPending,
) -> Bool {
  let key_present = match self.by_key.get(entry.ticket.session) {
    Some(existing) => existing.contains(entry.ticket.tag)
    None => false
  }
  match
    @proof_wakeup.decide_requeue(
      self.closed,
      self.pending_stale(entry),
      key_present,
    ) {
    DropStaleOrClosed | DropSuperseded => {
      self.emit_wakeup_event("wakeup_dropped", entry)
      false
    }
    RequeueAtFront => {
      let session_map = match self.by_key.get(entry.ticket.session) {
        Some(existing) => existing
        None => {
          let created : Map[String, WakeupPending] = Map::from_array([])
          self.by_key[entry.ticket.session] = created
          created
        }
      }
      self.order.insert(0, entry)
      session_map[entry.ticket.tag] = entry
      true
    }
  }
}

///|
pub fn WakeupRuntime::notify_operation_settled(self : WakeupRuntime) -> Unit {
  self.notify_state_change()
}

///|
/// Shutdown step 1: admission never reopens and the pump stops taking
/// tickets. A ticket already executing settles through its own turn.
pub fn WakeupRuntime::begin_shutdown(self : WakeupRuntime) -> Unit {
  if !self.closed {
    self.closed = true
    self.scope_active = false
    // Pending tickets get their single `dropped` terminal in the later step,
    // so clearing the binding here must not emit it.
    self.active_session = None
    self.notify_state_change()
  }
}

///|
/// Shutdown step 2: each pending ticket gets exactly one `dropped` terminal.
pub fn WakeupRuntime::drop_pending(self : WakeupRuntime) -> Unit {
  let pending = self.order.copy()
  self.order.clear()
  for entry in pending {
    self.forget(entry)
    self.emit_wakeup_event("wakeup_dropped", entry)
  }
}
