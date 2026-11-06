///|
/// Host capability negotiation and connection leases.

///|
/// What one connected host promises to display and answer. An empty
/// `resource_kinds` or `interactions` list means "none", never "all".
#derive(Eq, Debug)
pub(all) struct UiHostCapabilities {
  /// Resource kinds this host renders itself, matched exactly (namespace,
  /// name and schema version).
  resource_kinds : Array[UiResourceKind]
  /// Whether kinds not listed above may be rendered by a generic fallback.
  /// Unknown custom kinds are supported only when this is true.
  fallback : Bool
  /// Interaction body kinds this host can answer.
  interactions : Array[UiInteractionKind]
}

///|
pub extend UiHostCapabilities with Eq::{not_equal, equal}

///|
pub extend UiHostCapabilities with Debug::{to_repr}

///|
/// Construct a capability declaration.
pub fn UiHostCapabilities::new(
  resource_kinds~ : Array[UiResourceKind] = [],
  fallback~ : Bool = false,
  interactions~ : Array[UiInteractionKind] = [],
) -> UiHostCapabilities {
  { resource_kinds, fallback, interactions, }
}

///|
/// How one connected host relates to one resource kind.
#derive(Eq, Debug)
pub(all) enum UiHostSupport {
  /// The host declared this exact kind and schema version.
  Native
  /// The host declared a generic fallback for kinds it does not list.
  Fallback
  /// The host cannot display this kind.
  Unsupported
}

///|
pub extend UiHostSupport with Eq::{not_equal, equal}

///|
pub extend UiHostSupport with Debug::{to_repr}

///|
/// One host's support answer, per connection.
#derive(Eq, Debug)
pub(all) struct UiHostConnectionSupport {
  /// Framework-issued connection identity.
  connection : Int32
  support : UiHostSupport
}

///|
pub extend UiHostConnectionSupport with Eq::{not_equal, equal}

///|
pub extend UiHostConnectionSupport with Debug::{to_repr}

///|
/// Explicit host lease. `detach` is idempotent; updating capabilities after
/// detaching and answering through a detached lease are `HostUnavailable`.
/// Once the Agent closed, every call is `Closed`.
pub struct UiHostConnection {
  priv id_ : Int32
  priv is_connected_ : () -> Bool
  priv update_ : (UiHostCapabilities) -> Result[Unit, UiInteractionError]
  priv detach_ : () -> Result[Unit, UiInteractionError]
  priv answer_ : (UiInteractionAnswerRequest) -> Result[
    UiInteractionAnswerReceipt,
    UiInteractionError,
  ]
  priv dismiss_ : (UiInteractionRef, String) -> Result[
    UiInteractionOutcome,
    UiInteractionError,
  ]
}

///|
/// Framework construction hook. Hosts obtain the value from
/// `UiHost::connect`.
pub fn UiHostConnection::from_callbacks(
  id~ : Int32,
  is_connected~ : () -> Bool,
  update~ : (UiHostCapabilities) -> Result[Unit, UiInteractionError],
  detach~ : () -> Result[Unit, UiInteractionError],
  answer~ : (UiInteractionAnswerRequest) -> Result[
    UiInteractionAnswerReceipt,
    UiInteractionError,
  ],
  dismiss~ : (UiInteractionRef, String) -> Result[
    UiInteractionOutcome,
    UiInteractionError,
  ],
) -> UiHostConnection {
  {
    id_: id,
    is_connected_: is_connected,
    update_: update,
    detach_: detach,
    answer_: answer,
    dismiss_: dismiss,
  }
}

///|
/// Connection id, as reported by `UiHostConnectionSupport`.
pub fn UiHostConnection::id(self : UiHostConnection) -> Int32 {
  self.id_
}

///|
/// False after `detach`, after the Agent closed, or for an unknown lease.
pub fn UiHostConnection::is_connected(self : UiHostConnection) -> Bool {
  (self.is_connected_)()
}

///|
/// Replace this host's capability declaration; visible to the next matching
/// decision and to blocked waiters.
pub fn UiHostConnection::update(
  self : UiHostConnection,
  capabilities~ : UiHostCapabilities,
) -> Result[Unit, UiInteractionError] {
  (self.update_)(capabilities)
}

///|
/// Release the lease. Idempotent: a second detach is `Ok(())`; pending
/// questions stay pending for a later host.
pub fn UiHostConnection::detach(
  self : UiHostConnection,
) -> Result[Unit, UiInteractionError] {
  (self.detach_)()
}

///|
/// Answer one question through this lease. The question's body kind must still
/// be declared by this connected host; otherwise the answer is refused with
/// `HostUnavailable`.
pub fn UiHostConnection::answer(
  self : UiHostConnection,
  request~ : UiInteractionAnswerRequest,
) -> Result[UiInteractionAnswerReceipt, UiInteractionError] {
  (self.answer_)(request)
}

///|
/// Dismiss one question through this lease, under the same online and
/// capability checks as `answer`.
pub fn UiHostConnection::dismiss(
  self : UiHostConnection,
  interaction~ : UiInteractionRef,
  reason~ : String = "",
) -> Result[UiInteractionOutcome, UiInteractionError] {
  (self.dismiss_)(interaction, reason)
}
