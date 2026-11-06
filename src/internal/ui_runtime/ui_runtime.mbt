///|
/// Agent-owned runtime behind the owner-bound UI protocol: the single
/// authority for resources and pending interactions.

///|
/// Retained change window. A cursor older than this must re-read a baseline.
let ui_change_window : Int32 = 64

///|
/// Accepted-request window for action deduplication.
let ui_receipt_window : Int32 = 64

///|
/// Retained window of settled interactions, for receipt replay and late-answer
/// reporting.
let ui_interaction_window : Int32 = 64

///|
/// Pending questions one runtime holds at once.
let ui_max_pending_interactions : Int32 = 64

///|
/// Connected host leases one runtime holds at once.
let ui_max_host_connections : Int32 = 16

///|
/// Entries one capability list may declare.
let ui_max_host_capability_entries : Int32 = 64

///|
let ui_key_max_length : Int32 = 128

///|
/// Namespace reserved for framework kinds.
let ui_reserved_namespace : String = "posoco"

///|
let ui_generation_counter : Ref[Int32] = Ref(0)

///|
fn next_ui_generation() -> Int32 {
  ui_generation_counter.val = ui_generation_counter.val + 1
  ui_generation_counter.val
}

///|
priv struct UiReceipt {
  /// Snapshot of the accepted request, taken before the handler is awaited.
  request : @port.UiActionRequest
  /// `None` while the owner handler is running; `Some` once it settled.
  mut outcome : Result[Int32, String]?
}

///|
/// One open question. `outcome` is `None` until it settles; `waiters` counts
/// calls currently blocked in `wait`.
priv struct UiInteractionRecord {
  snapshot : @port.UiInteractionSnapshot
  mut outcome : @port.UiInteractionOutcome?
  mut waiters : Int32
}

///|
/// One connected host lease; `capabilities` is a private copy.
priv struct UiHostConnectionRecord {
  mut capabilities : @port.UiHostCapabilities
}

///|
/// One queued push delivery for one subscriber (a private copy).
priv struct UiDelivery {
  cursor : @port.UiCursor
  change : @port.UiChange
}

///|
/// One push subscriber; `active` is cleared by unsubscribe, a failing listener
/// or `close`.
priv struct UiSubscriber {
  id : Int32
  mut active : Bool
  listener : (@port.UiFeedBatch) -> Result[Unit, String]
  on_failure : (@port.UiListenerFailure) -> Unit
  queue : Array[UiDelivery]
}

///|
pub struct UiRuntime {
  priv generation : Int32
  priv mut closed : Bool
  /// Total accepted changes; `changes[i]` carries sequence `base_seq + i + 1`.
  priv mut seq : Int32
  priv mut base_seq : Int32
  priv changes : Array[@port.UiResourceChange]
  /// `owner \u0000 key` → live snapshot.
  priv live : Map[String, @port.UiResourceSnapshot]
  /// `owner \u0000 key` → highest revision ever accepted (tombstone against
  /// stale re-publish).
  priv revisions : Map[String, Int32]
  priv handlers : Map[String, @port.UiActionHandler]
  /// Host-wide action idempotency table, keyed by `request_id` alone; bounded
  /// by `ui_receipt_window`.
  priv receipts : Map[String, UiReceipt]
  priv receipt_order : Array[String]
  /// Interaction feed: same bounded-window mechanics as the resource feed.
  priv mut interaction_seq : Int32
  priv mut interaction_base_seq : Int32
  priv interaction_changes : Array[@port.UiInteractionChange]
  /// `owner \u0000 request_id` → open or retained question.
  priv interactions : Map[String, UiInteractionRecord]
  /// Open questions in open order, so the host renders a stable list.
  priv pending_order : Array[String]
  /// Retained settled ids, oldest first; bounded by `ui_interaction_window`.
  priv interaction_order : Array[String]
  /// Waiters block on this condition; the outcome check and the wait run
  /// without an await in between.
  priv interaction_wake : @cond_var.Cond
  priv subscribers : Map[Int32, UiSubscriber]
  priv subscriber_order : Array[Int32]
  priv mut next_subscriber : Int32
  /// Set while a delivery loop runs, so a re-entrant publish queues instead of
  /// recursing.
  priv mut delivering : Bool
  /// The currently admitted operation, or `None` between operations.
  priv mut current_operation : String?
  /// Operation id → keys it owns, in publish order.
  priv operation_keys : Map[String, Array[String]]
  /// Resource key → the operation that owns it (`OperationBound` live
  /// resources only).
  priv operation_bindings : Map[String, String]
  /// Connected host leases, in attach order.
  priv host_connections : Map[Int32, UiHostConnectionRecord]
  priv host_connection_order : Array[Int32]
  priv mut next_host_connection : Int32
  /// Bumped whenever the connection registry changes; waiters re-check on it.
  priv mut host_epoch : Int32
}

///|
pub fn UiRuntime::UiRuntime() -> UiRuntime {
  {
    generation: next_ui_generation(),
    closed: false,
    seq: 0,
    base_seq: 0,
    changes: [],
    live: Map::from_array([]),
    revisions: Map::from_array([]),
    handlers: Map::from_array([]),
    receipts: Map::from_array([]),
    receipt_order: [],
    interaction_seq: 0,
    interaction_base_seq: 0,
    interaction_changes: [],
    interactions: Map::from_array([]),
    pending_order: [],
    interaction_order: [],
    interaction_wake: @cond_var.Cond::Cond(),
    subscribers: Map::from_array([]),
    subscriber_order: [],
    next_subscriber: 1,
    delivering: false,
    current_operation: None,
    operation_keys: Map::from_array([]),
    operation_bindings: Map::from_array([]),
    host_connections: Map::from_array([]),
    host_connection_order: [],
    next_host_connection: 1,
    host_epoch: 0,
  }
}

///|
/// Runtime generation carried by every ref and cursor it issues.
pub fn UiRuntime::generation(self : UiRuntime) -> Int32 {
  self.generation
}

///|
/// Build the owner-bound resource capability for one manifest id. This is the
/// composition-delivered capability: it owns `OwnerBound` resources and can
/// capture the currently admitted operation through
/// `UiResources::operation`.
pub fn UiRuntime::capability(
  self : UiRuntime,
  owner : String,
) -> @port.UiResources {
  @port.UiResources::from_callbacks(
    owner~,
    publish=fn(draft) { self.publish(owner, UiCallContext::Owner, draft) },
    replace=fn(draft, expected) {
      self.replace(owner, UiCallContext::Owner, draft, expected)
    },
    remove=fn(resource) { self.remove(owner, UiCallContext::Owner, resource) },
    set_action_handler=fn(handler) { self.set_action_handler(owner, handler) },
    host_support=fn(resource) { self.host_support(owner, resource) },
    operation=fn() { self.operation_capability(owner) },
  )
}

///|
/// Host-side handle: baseline, both change feeds, action dispatch, interaction
/// answers and push subscription.
pub fn UiRuntime::host(self : UiRuntime) -> @port.UiHost {
  @port.UiHost::from_callbacks(
    snapshot=fn() { self.snapshot() },
    changes_since=fn(cursor) { self.changes_since(cursor) },
    interactions_since=fn(cursor) { self.interactions_since(cursor) },
    dispatch=async fn(request) noraise { self.dispatch(request) },
    answer=fn(request) { self.answer_interaction(request) },
    dismiss=fn(interaction, reason) {
      self.dismiss_interaction(interaction, reason)
    },
    subscribe=fn(listener, on_failure) { self.subscribe(listener, on_failure) },
    connect=fn(capabilities) { self.connect_host(capabilities) },
  )
}

///|
/// Close the protocol: capabilities reject every later mutation, handlers are
/// dropped, pending questions settle as `Closed`, subscribers are dropped and
/// the host feeds end. A handler already running is not force-revoked; its
/// outcome still returns but stores no new state.
pub fn UiRuntime::close(self : UiRuntime) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.handlers.clear()
  self.receipts.clear()
  self.receipt_order.clear()
  self.current_operation = None
  self.operation_keys.clear()
  self.operation_bindings.clear()
  self.host_connections.clear()
  self.host_connection_order.clear()
  self.host_epoch = self.host_epoch + 1
  self.settle_all_interactions_closed()
  self.drop_all_subscribers()
}

///|
pub fn UiRuntime::is_closed(self : UiRuntime) -> Bool {
  self.closed
}

///|
fn ui_resource_key(owner : String, key : String) -> String {
  owner + "\u{0}" + key
}

///|
/// Manifest ids are the first half of the internal resource key, so an owner
/// carrying the separator (or empty) could alias another owner's resources.
fn ui_validate_owner(owner : String) -> @port.UiResourceError? {
  if owner == "" {
    return Some(ui_invalid("resource owner must not be empty"))
  }
  if owner.contains("\u{0}") {
    return Some(ui_invalid("resource owner must not contain NUL"))
  }
  None
}

///|
fn ui_closed_error() -> @port.UiResourceError {
  @port.UiResourceError::Closed
}

///|
fn ui_invalid(reason : String) -> @port.UiResourceError {
  @port.UiResourceError::InvalidInput(reason~)
}

///|
fn ui_copy_json(value : Json) -> Json {
  @message_snapshot.snapshot_json(value)
}

///|
fn ui_copy_body(body : @port.UiResourceBody) -> @port.UiResourceBody {
  match body {
    Text(text) => Text(text)
    Lines(lines) => Lines(lines.copy())
    KeyValue(pairs) => KeyValue(pairs.copy())
    Entries(entries) =>
      Entries(
        entries.map(fn(entry) {
          { key: entry.key, value: entry.value, color: entry.color, }
        }),
      )
    Progress(value) => Progress(value)
    Markdown(text) => Markdown(text)
    Custom(payload) => Custom(ui_copy_json(payload))
  }
}

///|
fn ui_copy_actions(
  actions : Array[@port.UiActionSpec],
) -> Array[@port.UiActionSpec] {
  actions.map(fn(action) {
    { id: action.id, label: action.label, payload: action.payload, }
  })
}

///|
fn ui_copy_snapshot(
  snapshot : @port.UiResourceSnapshot,
) -> @port.UiResourceSnapshot {
  {
    resource: snapshot.resource,
    revision: snapshot.revision,
    kind: snapshot.kind,
    scope: snapshot.scope,
    lifetime: snapshot.lifetime,
    title: snapshot.title,
    body: ui_copy_body(snapshot.body),
    actions: ui_copy_actions(snapshot.actions),
  }
}

///|
fn ui_copy_change(change : @port.UiResourceChange) -> @port.UiResourceChange {
  match change {
    Published(snapshot~) => Published(snapshot=ui_copy_snapshot(snapshot))
    Replaced(snapshot~) => Replaced(snapshot=ui_copy_snapshot(snapshot))
    Withdrawn(owner~, key~, revision~) => Withdrawn(owner~, key~, revision~)
  }
}

///|
fn ui_validate_draft(
  owner : String,
  draft : @port.UiResourceDraft,
  context : UiCallContext,
) -> @port.UiResourceError? {
  if draft.key == "" {
    return Some(ui_invalid("resource key must not be empty"))
  }
  if draft.key.length() > ui_key_max_length {
    return Some(
      ui_invalid("resource key exceeds \{ui_key_max_length} characters"),
    )
  }
  if draft.key.contains("\u{0}") {
    return Some(ui_invalid("resource key must not contain NUL"))
  }
  if draft.kind.namespace_ == "" || draft.kind.name == "" {
    return Some(ui_invalid("resource kind needs a namespace and a name"))
  }
  if draft.kind.schema_version < 1 {
    return Some(ui_invalid("resource kind schema_version must be positive"))
  }
  match draft.body {
    // A Custom body must use the publisher's own namespace.
    Custom(_) => {
      if draft.kind.namespace_ != owner {
        return Some(
          ui_invalid(
            "a Custom body must use the publisher's own namespace \{owner}, got \{draft.kind.namespace_}",
          ),
        )
      }
      if draft.kind.namespace_ == ui_reserved_namespace {
        return Some(
          ui_invalid(
            "the \{ui_reserved_namespace} namespace is reserved for framework kinds",
          ),
        )
      }
    }
    _ => ()
  }
  match draft.scope {
    SessionScope(id~) | OperationScope(id~) | ToolCallScope(id~) =>
      if id == "" {
        return Some(ui_invalid("resource scope id must not be empty"))
      }
    AgentScope => ()
  }
  match draft.lifetime {
    OwnerBound =>
      match context {
        Operation(operation_id~) =>
          return Some(
            ui_invalid(
              "the operation-bound capability of operation \{operation_id} publishes only OperationBound resources; publish OwnerBound cards through CompositionView::ui_resources",
            ),
          )
        Owner => ()
      }
    // Only a captured operation context may publish OperationBound.
    OperationBound =>
      match context {
        Owner =>
          return Some(
            ui_invalid(
              "OperationBound resources must be published through UiResources::operation while an operation is admitted",
            ),
          )
        Operation(_) => ()
      }
    SessionBound =>
      return Some(
        @port.UiResourceError::Unsupported(
          feature="session-scoped lifetime cleanup",
        ),
      )
  }
  let seen : Map[String, Unit] = Map::from_array([])
  for action in draft.actions {
    if action.id == "" {
      return Some(ui_invalid("action id must not be empty"))
    }
    if seen.contains(action.id) {
      return Some(ui_invalid("duplicate action id \{action.id}"))
    }
    seen[action.id] = ()
  }
  None
}

///|
fn UiRuntime::build_snapshot(
  self : UiRuntime,
  owner : String,
  draft : @port.UiResourceDraft,
  revision : Int32,
) -> @port.UiResourceSnapshot {
  {
    resource: { owner, key: draft.key, generation: self.generation, },
    revision,
    kind: draft.kind,
    scope: draft.scope,
    lifetime: draft.lifetime,
    title: draft.title,
    body: ui_copy_body(draft.body),
    actions: ui_copy_actions(draft.actions),
  }
}

///|
fn UiRuntime::push_change(
  self : UiRuntime,
  change : @port.UiResourceChange,
) -> Unit {
  self.seq = self.seq + 1
  self.changes.push(change)
  while self.changes.length() > ui_change_window {
    ignore(self.changes.remove(0))
    self.base_seq = self.base_seq + 1
  }
  self.notify({
    cursor: { generation: self.generation, seq: self.seq, },
    change: @port.UiChange::Resource(change=ui_copy_change(change)),
  })
}

///|
/// Cursor validation shared by both feeds: a foreign generation or a position
/// outside the retained window is answered with `SnapshotRequired`.
fn ui_check_cursor(
  cursor : @port.UiCursor,
  generation : Int32,
  seq : Int32,
  base_seq : Int32,
  family : String,
) -> @port.UiResourceError? {
  if cursor.generation != generation {
    return Some(
      @port.UiResourceError::SnapshotRequired(
        reason="\{family} cursor belongs to runtime generation \{cursor.generation}, current generation is \{generation}",
      ),
    )
  }
  if cursor.seq > seq || cursor.seq < base_seq {
    return Some(
      @port.UiResourceError::SnapshotRequired(
        reason="\{family} cursor \{cursor.seq} is outside the retained window [\{base_seq}, \{seq}]",
      ),
    )
  }
  None
}

///|
/// Commit one accepted mutation: revision, live state and ownership land
/// first, then the change is published.
fn UiRuntime::commit(
  self : UiRuntime,
  snapshot : @port.UiResourceSnapshot,
  created : Bool,
  context : UiCallContext,
) -> @port.UiResourceSnapshot {
  let key = ui_resource_key(snapshot.resource.owner, snapshot.resource.key)
  let stored = ui_copy_snapshot(snapshot)
  self.revisions[key] = stored.revision
  self.live[key] = stored
  self.bind_operation_resource(context, key)
  self.push_change(
    if created {
      @port.UiResourceChange::Published(snapshot=ui_copy_snapshot(stored))
    } else {
      @port.UiResourceChange::Replaced(snapshot=ui_copy_snapshot(stored))
    },
  )
  // The publisher gets its own copy so later caller-side mutation cannot
  // reach the live table.
  ui_copy_snapshot(stored)
}

///|
fn UiRuntime::publish(
  self : UiRuntime,
  owner : String,
  context : UiCallContext,
  draft : @port.UiResourceDraft,
) -> Result[@port.UiResourceSnapshot, @port.UiResourceError] {
  if self.closed {
    return Err(ui_closed_error())
  }
  match ui_validate_owner(owner) {
    Some(error) => return Err(error)
    None => ()
  }
  match self.check_call_context(context) {
    Some(error) => return Err(error)
    None => ()
  }
  match ui_validate_draft(owner, draft, context) {
    Some(error) => return Err(error)
    None => ()
  }
  let key = ui_resource_key(owner, draft.key)
  let created = !self.live.contains(key)
  match self.live.get(key) {
    Some(live) =>
      match self.check_takeover(context, key, live) {
        Some(error) => return Err(error)
        None => ()
      }
    None => ()
  }
  let revision = match self.revisions.get(key) {
    Some(previous) => previous + 1
    None => 1
  }
  let snapshot = self.build_snapshot(owner, draft, revision)
  Ok(self.commit(snapshot, created, context))
}

///|
fn UiRuntime::replace(
  self : UiRuntime,
  owner : String,
  context : UiCallContext,
  draft : @port.UiResourceDraft,
  expected : Int32,
) -> Result[@port.UiResourceSnapshot, @port.UiResourceError] {
  if self.closed {
    return Err(ui_closed_error())
  }
  match ui_validate_owner(owner) {
    Some(error) => return Err(error)
    None => ()
  }
  match self.check_call_context(context) {
    Some(error) => return Err(error)
    None => ()
  }
  match ui_validate_draft(owner, draft, context) {
    Some(error) => return Err(error)
    None => ()
  }
  let key = ui_resource_key(owner, draft.key)
  let live = match self.live.get(key) {
    Some(snapshot) => snapshot
    None => return Err(@port.UiResourceError::NotFound(owner~, key=draft.key))
  }
  // A replacement never migrates a resource off its lifetime or into another
  // operation.
  match self.check_takeover(context, key, live) {
    Some(error) => return Err(error)
    None => ()
  }
  if live.revision != expected {
    return Err(
      @port.UiResourceError::StaleRevision(expected~, actual=live.revision),
    )
  }
  let snapshot = self.build_snapshot(owner, draft, expected + 1)
  Ok(self.commit(snapshot, false, context))
}

///|
fn UiRuntime::remove(
  self : UiRuntime,
  owner : String,
  context : UiCallContext,
  resource : @port.UiResourceRef,
) -> Result[Int32, @port.UiResourceError] {
  if self.closed {
    return Err(ui_closed_error())
  }
  if resource.owner != owner {
    return Err(ui_invalid("resource owner does not match this capability"))
  }
  if resource.key.contains("\u{0}") {
    return Err(ui_invalid("resource key must not contain NUL"))
  }
  match self.check_call_context(context) {
    Some(error) => return Err(error)
    None => ()
  }
  if resource.generation != self.generation {
    return Err(@port.UiResourceError::NotFound(owner~, key=resource.key))
  }
  let key = ui_resource_key(owner, resource.key)
  let live = match self.live.get(key) {
    Some(snapshot) => snapshot
    None =>
      return Err(@port.UiResourceError::NotFound(owner~, key=resource.key))
  }
  // An operation-bound handle only sees resources that operation owns.
  if !self.owns_live_resource(context, key) {
    return Err(@port.UiResourceError::NotFound(owner~, key=resource.key))
  }
  self.live.remove(key)
  self.operation_bindings.remove(key)
  self.push_change(
    @port.UiResourceChange::Withdrawn(
      owner~,
      key=resource.key,
      revision=live.revision,
    ),
  )
  Ok(live.revision)
}

///|
fn UiRuntime::set_action_handler(
  self : UiRuntime,
  owner : String,
  handler : @port.UiActionHandler,
) -> Result[Unit, @port.UiResourceError] {
  if self.closed {
    return Err(ui_closed_error())
  }
  match ui_validate_owner(owner) {
    Some(error) => return Err(error)
    None => ()
  }
  self.handlers[owner] = handler
  Ok(())
}

///|
fn UiRuntime::snapshot(
  self : UiRuntime,
) -> Result[@port.UiBaseline, @port.UiResourceError] {
  if self.closed {
    return Err(ui_closed_error())
  }
  let resources : Array[@port.UiResourceSnapshot] = []
  for _, snapshot in self.live {
    resources.push(ui_copy_snapshot(snapshot))
  }
  Ok({
    cursor: { generation: self.generation, seq: self.seq, },
    interaction_cursor: {
      generation: self.generation,
      seq: self.interaction_seq,
    },
    resources,
    pending_interactions: self.pending_snapshots(),
  })
}

///|
fn UiRuntime::changes_since(
  self : UiRuntime,
  cursor : @port.UiCursor,
) -> Result[@port.UiChanges, @port.UiResourceError] {
  if self.closed {
    return Err(ui_closed_error())
  }
  let cursor_error = ui_check_cursor(
    cursor,
    self.generation,
    self.seq,
    self.base_seq,
    "resource",
  )
  match cursor_error {
    Some(error) => return Err(error)
    None => ()
  }
  let changes : Array[@port.UiResourceChange] = []
  let from = cursor.seq - self.base_seq
  for index in from..<self.changes.length() {
    changes.push(ui_copy_change(self.changes[index]))
  }
  Ok({ cursor: { generation: self.generation, seq: self.seq, }, changes, })
}

///|
fn ui_find_action(
  actions : Array[@port.UiActionSpec],
  id : String,
) -> @port.UiActionSpec? {
  for action in actions {
    if action.id == id {
      return Some(action)
    }
  }
  None
}

///|
fn ui_same_request(
  left : @port.UiActionRequest,
  right : @port.UiActionRequest,
) -> Bool {
  left.resource == right.resource &&
  left.action == right.action &&
  left.expected_revision == right.expected_revision &&
  left.payload == right.payload
}

///|
fn ui_copy_request(request : @port.UiActionRequest) -> @port.UiActionRequest {
  {
    resource: request.resource,
    action: request.action,
    expected_revision: request.expected_revision,
    request_id: request.request_id,
    payload: match request.payload {
      Some(payload) => Some(ui_copy_json(payload))
      None => None
    },
  }
}

///|
/// Reserve the request id before the owner handler is awaited.
fn UiRuntime::reserve_receipt(
  self : UiRuntime,
  request : @port.UiActionRequest,
) -> Unit {
  let id = request.request_id
  let mut index = 0
  while index < self.receipt_order.length() {
    if self.receipt_order[index] == id {
      ignore(self.receipt_order.remove(index))
    } else {
      index = index + 1
    }
  }
  self.receipts[id] = { request: ui_copy_request(request), outcome: None, }
  self.receipt_order.push(id)
  self.evict_receipts()
}

///|
/// Trim the window oldest-first, never dropping an in-flight reservation.
fn UiRuntime::evict_receipts(self : UiRuntime) -> Unit {
  let mut index = 0
  while self.receipt_order.length() > ui_receipt_window &&
        index < self.receipt_order.length() {
    let id = self.receipt_order[index]
    let settled = match self.receipts.get(id) {
      Some(entry) => entry.outcome is Some(_)
      None => true
    }
    if settled {
      ignore(self.receipt_order.remove(index))
      self.receipts.remove(id)
    } else {
      index = index + 1
    }
  }
}

///|
/// Record the outcome of an accepted dispatch; a closed runtime stores nothing.
fn UiRuntime::settle_receipt(
  self : UiRuntime,
  request_id : String,
  outcome : Result[Int32, String],
) -> Unit {
  if self.closed {
    return
  }
  match self.receipts.get(request_id) {
    Some(entry) =>
      if entry.outcome is None {
        entry.outcome = Some(outcome)
        self.evict_receipts()
      }
    None => ()
  }
}

///|
/// Drop an unsettled reservation; idempotent, and the window slot goes with
/// it.
fn UiRuntime::release_reservation(
  self : UiRuntime,
  request_id : String,
) -> Unit {
  match self.receipts.get(request_id) {
    Some(entry) =>
      if entry.outcome is None {
        self.receipts.remove(request_id)
        let mut index = 0
        while index < self.receipt_order.length() {
          if self.receipt_order[index] == request_id {
            ignore(self.receipt_order.remove(index))
          } else {
            index = index + 1
          }
        }
      }
    None => ()
  }
}

///|
fn ui_validate_payload(
  request : @port.UiActionRequest,
  spec : @port.UiActionSpec,
) -> @port.UiResourceError? {
  match spec.payload {
    NoPayload =>
      match request.payload {
        Some(_) =>
          return Some(ui_invalid("action \{spec.id} does not accept a payload"))
        None => ()
      }
    JsonPayload =>
      match request.payload {
        Some(_) => ()
        None => return Some(ui_invalid("action \{spec.id} requires a payload"))
      }
  }
  None
}

///|
/// Accept, validate and route one host action. Everything up to the handler
/// call is synchronous; the request id is reserved before the handler is
/// awaited, so a duplicate gets `InProgress`/`Conflict` and a settled id
/// replays its stored receipt.
async fn UiRuntime::dispatch(
  self : UiRuntime,
  request : @port.UiActionRequest,
) -> Result[@port.UiActionResult, @port.UiResourceError] noraise {
  if self.closed {
    return Err(ui_closed_error())
  }
  if request.request_id == "" {
    return Err(ui_invalid("action request_id must not be empty"))
  }
  if request.action == "" {
    return Err(ui_invalid("action id must not be empty"))
  }
  match ui_validate_owner(request.resource.owner) {
    Some(error) => return Err(error)
    None => ()
  }
  if request.resource.key.contains("\u{0}") {
    return Err(ui_invalid("resource key must not contain NUL"))
  }
  // Idempotency is decided before any state validation; an in-flight handler
  // is reported as `InProgress`, never awaited.
  match self.receipts.get(request.request_id) {
    Some(stored) =>
      if !ui_same_request(stored.request, request) {
        return Err(
          @port.UiResourceError::Conflict(
            reason="request id \{request.request_id} is bound to a different action",
          ),
        )
      } else {
        return match stored.outcome {
          Some(Ok(revision)) =>
            Ok({
              request_id: request.request_id,
              resource: request.resource,
              action: request.action,
              revision,
              replayed: true,
            })
          Some(Err(detail)) =>
            Err(@port.UiResourceError::HandlerFailed(detail~))
          None =>
            Err(
              @port.UiResourceError::InProgress(request_id=request.request_id),
            )
        }
      }
    None => ()
  }
  if request.resource.generation != self.generation {
    return Err(
      @port.UiResourceError::NotFound(
        owner=request.resource.owner,
        key=request.resource.key,
      ),
    )
  }
  let key = ui_resource_key(request.resource.owner, request.resource.key)
  let live = match self.live.get(key) {
    Some(snapshot) => snapshot
    None =>
      return Err(
        @port.UiResourceError::NotFound(
          owner=request.resource.owner,
          key=request.resource.key,
        ),
      )
  }
  if live.revision != request.expected_revision {
    return Err(
      @port.UiResourceError::StaleRevision(
        expected=request.expected_revision,
        actual=live.revision,
      ),
    )
  }
  let spec = match ui_find_action(live.actions, request.action) {
    Some(action) => action
    None =>
      return Err(
        ui_invalid("action \{request.action} is not declared by this resource"),
      )
  }
  match ui_validate_payload(request, spec) {
    Some(error) => return Err(error)
    None => ()
  }
  let handler = match self.handlers.get(request.resource.owner) {
    Some(handle) => handle
    None =>
      // Routing failure before any owner code ran; nothing is reserved.
      return Err(
        @port.UiResourceError::HandlerFailed(
          detail="owner \{request.resource.owner} has no action handler",
        ),
      )
  }
  let invocation : @port.UiActionInvocation = {
    resource: request.resource,
    revision: live.revision,
    action: request.action,
    request_id: request.request_id,
    payload: match request.payload {
      Some(payload) => Some(ui_copy_json(payload))
      None => None
    },
  }
  // Reserve before the first await.
  self.reserve_receipt(request)
  defer self.release_reservation(request.request_id)
  errdefer self.release_reservation(request.request_id)
  let called : Result[Result[Unit, String], String] = Ok(handler(invocation)) catch {
    error => Err(error.to_string())
  }
  let outcome : Result[Unit, String] = match called {
    Ok(Ok(_)) => Ok(())
    Ok(Err(detail)) => Err(detail)
    Err(detail) => Err(detail)
  }
  match outcome {
    Ok(_) => {
      self.settle_receipt(request.request_id, Ok(live.revision))
      Ok({
        request_id: request.request_id,
        resource: request.resource,
        action: request.action,
        revision: live.revision,
        replayed: false,
      })
    }
    Err(detail) => {
      self.settle_receipt(request.request_id, Err(detail))
      Err(@port.UiResourceError::HandlerFailed(detail~))
    }
  }
}
