///|
/// Owner-bound UI presentation resources.

///|
/// Where a resource belongs.
#derive(Eq, Debug)
pub(all) enum UiResourceScope {
  /// The owning Agent instance.
  AgentScope
  /// A conversation/session id (turn-independent).
  SessionScope(id~ : String)
  /// One admitted operation, e.g. a single user turn.
  OperationScope(id~ : String)
  /// One tool call inside an operation.
  ToolCallScope(id~ : String)
}

///|
pub extend UiResourceScope with Eq::{not_equal, equal}

///|
pub extend UiResourceScope with Debug::{to_repr}

///|
/// Reclamation promise of a published resource.
#derive(Eq, Debug)
pub(all) enum UiResourceLifetime {
  /// Lives until the owner withdraws it or the Agent shuts down.
  OwnerBound
  /// Reclaimed when the owning session ends (not implemented yet).
  SessionBound
  /// Reclaimed when the operation that created it settles.
  OperationBound
}

///|
pub extend UiResourceLifetime with Eq::{not_equal, equal}

///|
pub extend UiResourceLifetime with Debug::{to_repr}

///|
/// Kind of a resource: namespace, name and schema version. Framework kinds
/// live in the reserved `posoco` namespace; a custom kind must use the
/// publisher's own namespace.
#derive(Eq, Debug)
pub(all) struct UiResourceKind {
  namespace_ : String
  name : String
  schema_version : Int32
}

///|
pub extend UiResourceKind with Eq::{not_equal, equal}

///|
pub extend UiResourceKind with Debug::{to_repr}

///|
/// Construct a framework (`posoco`) kind.
pub fn UiResourceKind::standard(name~ : String) -> UiResourceKind {
  { namespace_: "posoco", name, schema_version: 1, }
}

///|
/// Construct a custom namespaced kind. `schema_version` must be positive.
pub fn UiResourceKind::custom(
  namespace_~ : String,
  name~ : String,
  schema_version~ : Int32 = 1,
) -> UiResourceKind {
  { namespace_, name, schema_version, }
}

///|
/// Structured body of a resource. Standard shapes cover the common cases; a
/// kind with no standard shape carries a namespaced `Custom` payload that the
/// host renders with its generic fallback.
#derive(Eq, Debug)
pub(all) enum UiResourceBody {
  Text(String)
  Lines(Array[String])
  KeyValue(Array[(String, String)])
  Entries(Array[UiEntry])
  Progress(Double)
  Markdown(String)
  /// Namespaced, versioned payload. The kind's namespace must not be the
  /// reserved `posoco` one.
  Custom(Json)
}

///|
pub extend UiResourceBody with Eq::{not_equal, equal}

///|
pub extend UiResourceBody with Debug::{to_repr}

///|
/// Payload shape an action accepts.
#derive(Eq, Debug)
pub(all) enum UiActionPayloadKind {
  /// The action carries no payload; supplying one is invalid input.
  NoPayload
  /// The action carries a JSON value.
  JsonPayload
}

///|
pub extend UiActionPayloadKind with Eq::{not_equal, equal}

///|
pub extend UiActionPayloadKind with Debug::{to_repr}

///|
/// One user-invokable action the resource declares.
#derive(Eq, Debug)
pub(all) struct UiActionSpec {
  id : String
  label : String
  payload : UiActionPayloadKind
}

///|
pub extend UiActionSpec with Eq::{not_equal, equal}

///|
pub extend UiActionSpec with Debug::{to_repr}

///|
/// Owner-local address of one resource, bound to the runtime generation that
/// issued it. A ref from a previous runtime generation is never accepted.
#derive(Eq, Debug)
pub(all) struct UiResourceRef {
  owner : String
  key : String
  generation : Int32
}

///|
pub extend UiResourceRef with Eq::{not_equal, equal}

///|
pub extend UiResourceRef with Debug::{to_repr}

///|
/// Full replacement payload for `publish` / `replace`.
#derive(Eq, Debug)
pub(all) struct UiResourceDraft {
  key : String
  kind : UiResourceKind
  scope : UiResourceScope
  lifetime : UiResourceLifetime
  title : String?
  body : UiResourceBody
  actions : Array[UiActionSpec]
}

///|
pub extend UiResourceDraft with Eq::{not_equal, equal}

///|
pub extend UiResourceDraft with Debug::{to_repr}

///|
/// Construct a draft with the common defaults: `AgentScope`, `OwnerBound`, no
/// title and no actions.
pub fn UiResourceDraft::new(
  key~ : String,
  kind~ : UiResourceKind,
  body~ : UiResourceBody,
  scope~ : UiResourceScope = AgentScope,
  lifetime~ : UiResourceLifetime = OwnerBound,
  title? : String,
  actions~ : Array[UiActionSpec] = [],
) -> UiResourceDraft {
  { key, kind, scope, lifetime, title, body, actions, }
}

///|
/// Immutable copy of one accepted resource revision, as read through the host
/// feed. Replacing a resource bumps `revision` and keeps the same ref.
#derive(Eq, Debug)
pub(all) struct UiResourceSnapshot {
  resource : UiResourceRef
  revision : Int32
  kind : UiResourceKind
  scope : UiResourceScope
  lifetime : UiResourceLifetime
  title : String?
  body : UiResourceBody
  actions : Array[UiActionSpec]
}

///|
pub extend UiResourceSnapshot with Eq::{not_equal, equal}

///|
pub extend UiResourceSnapshot with Debug::{to_repr}

///|
/// Lifecycle change of one resource in the host feed.
#derive(Eq, Debug)
pub(all) enum UiResourceChange {
  /// The resource did not exist before this revision.
  Published(snapshot~ : UiResourceSnapshot)
  /// Full replacement of an existing resource; the resource did not move.
  Replaced(snapshot~ : UiResourceSnapshot)
  /// The resource is no longer valid: withdrawn by the owner, or reclaimed by
  /// operation settlement. `revision` is the last live revision.
  Withdrawn(owner~ : String, key~ : String, revision~ : Int32)
}

///|
pub extend UiResourceChange with Eq::{not_equal, equal}

///|
pub extend UiResourceChange with Debug::{to_repr}

///|
/// Explicit, non-silent outcomes of the resource protocol.
#derive(Eq, Debug)
pub(all) enum UiResourceError {
  /// The Agent shut down, or composition failed after this capability was
  /// delivered; capabilities are closed and the feed is over.
  Closed
  /// The runtime does not implement the requested behavior yet.
  Unsupported(feature~ : String)
  /// No live resource for this owner/key at the current generation.
  NotFound(owner~ : String, key~ : String)
  /// The caller's expected revision is not the live one.
  StaleRevision(expected~ : Int32, actual~ : Int32)
  /// Structurally invalid input (draft, action, payload, forged owner).
  InvalidInput(reason~ : String)
  /// The request id is already bound to a different action request.
  Conflict(reason~ : String)
  /// The same request id is currently being handled; retry after it settles.
  InProgress(request_id~ : String)
  /// The owner's action handler failed, raised, or is not installed.
  HandlerFailed(detail~ : String)
  /// The change cursor is out of the runtime's bounded window or generation.
  SnapshotRequired(reason~ : String)
}

///|
pub extend UiResourceError with Eq::{not_equal, equal}

///|
pub extend UiResourceError with Debug::{to_repr}

///|
pub extend UiResourceError with Show::{to_string, output}

///|
pub impl Show for UiResourceError with fn to_string(self : UiResourceError) -> String {
  match self {
    Closed => "UiResourceError::Closed"
    Unsupported(feature~) => "UiResourceError::Unsupported(\{feature})"
    NotFound(owner~, key~) =>
      "UiResourceError::NotFound(owner=\{owner}, key=\{key})"
    StaleRevision(expected~, actual~) =>
      "UiResourceError::StaleRevision(expected=\{expected}, actual=\{actual})"
    InvalidInput(reason~) => "UiResourceError::InvalidInput(\{reason})"
    Conflict(reason~) => "UiResourceError::Conflict(\{reason})"
    InProgress(request_id~) => "UiResourceError::InProgress(\{request_id})"
    HandlerFailed(detail~) => "UiResourceError::HandlerFailed(\{detail})"
    SnapshotRequired(reason~) => "UiResourceError::SnapshotRequired(\{reason})"
  }
}

///|
/// One action delivered back to the publishing extension.
#derive(Eq, Debug)
pub(all) struct UiActionInvocation {
  resource : UiResourceRef
  revision : Int32
  action : String
  request_id : String
  payload : Json?
}

///|
pub extend UiActionInvocation with Eq::{not_equal, equal}

///|
pub extend UiActionInvocation with Debug::{to_repr}

///|
/// Owner-supplied action handler. Returning `Err` reports a handled failure;
/// raising is caught by the runtime and reported as `HandlerFailed`.
pub type UiActionHandler = async (UiActionInvocation) -> Result[Unit, String]

///|
/// Owner-bound capability delivered through `CompositionView::ui_resources`.
pub struct UiResources {
  priv owner_ : String
  priv publish_ : (UiResourceDraft) -> Result[
    UiResourceSnapshot,
    UiResourceError,
  ]
  priv replace_ : (UiResourceDraft, Int32) -> Result[
    UiResourceSnapshot,
    UiResourceError,
  ]
  priv remove_ : (UiResourceRef) -> Result[Int32, UiResourceError]
  priv set_action_handler_ : (UiActionHandler) -> Result[Unit, UiResourceError]
  priv host_support_ : (UiResourceRef) -> Result[
    Array[UiHostConnectionSupport],
    UiResourceError,
  ]
  priv operation_ : (() -> Result[UiResources, UiResourceError])?
}

///|
/// The manifest id this capability is bound to.
pub fn UiResources::owner(self : UiResources) -> String {
  self.owner_
}

///|
/// Create the resource, or fully replace it when this owner already published
/// the same key. Returns the accepted snapshot (with its new revision).
pub fn UiResources::publish(
  self : UiResources,
  draft~ : UiResourceDraft,
) -> Result[UiResourceSnapshot, UiResourceError] {
  (self.publish_)(draft)
}

///|
/// Full replacement guarded by `expected` (the revision the caller last read).
/// A missing resource is `NotFound`; a different live revision is
/// `StaleRevision` and changes nothing.
pub fn UiResources::replace(
  self : UiResources,
  draft~ : UiResourceDraft,
  expected~ : Int32,
) -> Result[UiResourceSnapshot, UiResourceError] {
  (self.replace_)(draft, expected)
}

///|
/// Withdraw this owner's resource. Returns the last live revision; repeating
/// the withdrawal is `NotFound`.
pub fn UiResources::remove(
  self : UiResources,
  resource~ : UiResourceRef,
) -> Result[Int32, UiResourceError] {
  (self.remove_)(resource)
}

///|
/// Install the owner's action handler. Registering again replaces the previous
/// handler; after `Agent::shutdown` registration is rejected with `Closed`.
pub fn UiResources::set_action_handler(
  self : UiResources,
  handler~ : UiActionHandler,
) -> Result[Unit, UiResourceError] {
  (self.set_action_handler_)(handler)
}

///|
/// Ask every connected host how it can display this resource, in attach order.
/// Each entry is per connection (`Native` / `Fallback` / `Unsupported`); an
/// empty result means no host is connected.
pub fn UiResources::host_support(
  self : UiResources,
  resource~ : UiResourceRef,
) -> Result[Array[UiHostConnectionSupport], UiResourceError] {
  (self.host_support_)(resource)
}

///|
/// Capture the currently admitted operation as a restricted handle: calls
/// through it only touch resources bound to that operation and accept only
/// `OperationBound` drafts. Every call is refused with `InvalidInput` once
/// the operation settles, and without an admitted operation the call itself
/// is refused.
pub fn UiResources::operation(
  self : UiResources,
) -> Result[UiResources, UiResourceError] {
  match self.operation_ {
    Some(acquire) => acquire()
    None =>
      Err(
        UiResourceError::Unsupported(feature="operation-scoped UI capability"),
      )
  }
}

///|
/// Framework construction hook. Omitting `operation` or `host_support` makes
/// the corresponding calls report `Unsupported`.
pub fn UiResources::from_callbacks(
  owner~ : String,
  publish~ : (UiResourceDraft) -> Result[UiResourceSnapshot, UiResourceError],
  replace~ : (UiResourceDraft, Int32) -> Result[
    UiResourceSnapshot,
    UiResourceError,
  ],
  remove~ : (UiResourceRef) -> Result[Int32, UiResourceError],
  set_action_handler~ : (UiActionHandler) -> Result[Unit, UiResourceError],
  operation? : () -> Result[UiResources, UiResourceError],
  host_support? : (UiResourceRef) -> Result[
    Array[UiHostConnectionSupport],
    UiResourceError,
  ],
) -> UiResources {
  let support_callback = match host_support {
    Some(callback) => callback
    None =>
      fn(_resource) {
        Err(UiResourceError::Unsupported(feature="host capability query"))
      }
  }
  {
    owner_: owner,
    publish_: publish,
    replace_: replace,
    remove_: remove,
    set_action_handler_: set_action_handler,
    host_support_: support_callback,
    operation_: operation,
  }
}
