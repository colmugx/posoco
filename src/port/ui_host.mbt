///|
/// Host-side entry to the UI protocol: resources, pending interactions and the
/// ordered feed that reports both.

///|
/// Position in the resource change feed.
#derive(Eq, Debug)
pub(all) struct UiCursor {
  generation : Int32
  seq : Int32
}

///|
pub extend UiCursor with Eq::{not_equal, equal}

///|
pub extend UiCursor with Debug::{to_repr}

///|
/// One consistent read of the UI protocol: every live resource, every pending
/// interaction, and the cursors the host continues from.
#derive(Eq, Debug)
pub(all) struct UiBaseline {
  /// Continue-from position of the resource feed.
  cursor : UiCursor
  /// Continue-from position of the interaction feed.
  interaction_cursor : UiCursor
  resources : Array[UiResourceSnapshot]
  pending_interactions : Array[UiInteractionSnapshot]
}

///|
pub extend UiBaseline with Eq::{not_equal, equal}

///|
pub extend UiBaseline with Debug::{to_repr}

///|
/// Changes accepted strictly after the supplied cursor, with the cursor to
/// continue from.
#derive(Eq, Debug)
pub(all) struct UiChanges {
  cursor : UiCursor
  changes : Array[UiResourceChange]
}

///|
pub extend UiChanges with Eq::{not_equal, equal}

///|
pub extend UiChanges with Debug::{to_repr}

///|
/// Host intent to run one declared action of one resource.
#derive(Eq, Debug)
pub(all) struct UiActionRequest {
  resource : UiResourceRef
  action : String
  /// Revision the host rendered. A resource that moved on rejects the action.
  expected_revision : Int32
  /// Host-supplied idempotency key across the whole host runtime: reuse
  /// returns the stored outcome, reuse with different content is `Conflict`.
  request_id : String
  payload : Json?
}

///|
pub extend UiActionRequest with Eq::{not_equal, equal}

///|
pub extend UiActionRequest with Debug::{to_repr}

///|
/// Receipt of one accepted action.
#derive(Eq, Debug)
pub(all) struct UiActionResult {
  request_id : String
  resource : UiResourceRef
  action : String
  /// Resource revision the action was accepted against.
  revision : Int32
  /// True when `request_id` was already accepted and the stored outcome is
  /// returned instead of running the handler again.
  replayed : Bool
}

///|
pub extend UiActionResult with Eq::{not_equal, equal}

///|
pub extend UiActionResult with Debug::{to_repr}

///|
/// Interaction changes accepted after the supplied interaction cursor.
#derive(Eq, Debug)
pub(all) struct UiInteractionChanges {
  cursor : UiCursor
  changes : Array[UiInteractionChange]
}

///|
pub extend UiInteractionChanges with Eq::{not_equal, equal}

///|
pub extend UiInteractionChanges with Debug::{to_repr}

///|
/// One change of the ordered push feed.
#derive(Eq, Debug)
pub(all) enum UiChange {
  Resource(change~ : UiResourceChange)
  Interaction(change~ : UiInteractionChange)
}

///|
pub extend UiChange with Eq::{not_equal, equal}

///|
pub extend UiChange with Debug::{to_repr}

///|
/// One delivered change plus the cursor of its own family.
#derive(Eq, Debug)
pub(all) struct UiFeedBatch {
  cursor : UiCursor
  change : UiChange
}

///|
pub extend UiFeedBatch with Eq::{not_equal, equal}

///|
pub extend UiFeedBatch with Debug::{to_repr}

///|
/// Reported when a subscriber's own listener fails; the failing subscription
/// is dropped and the host must subscribe again.
#derive(Eq, Debug)
pub(all) struct UiListenerFailure {
  subscription : Int32
  /// Feed position of the batch that failed.
  seq : Int32
  detail : String
}

///|
pub extend UiListenerFailure with Eq::{not_equal, equal}

///|
pub extend UiListenerFailure with Debug::{to_repr}

///|
/// Live push subscription delivering changes in commit order.
pub struct UiSubscription {
  priv id_ : Int32
  priv is_active_ : () -> Bool
  priv unsubscribe_ : () -> Unit
}

///|
/// Framework construction hook. Hosts obtain the value from the Agent.
pub fn UiSubscription::from_callbacks(
  id~ : Int32,
  is_active~ : () -> Bool,
  unsubscribe~ : () -> Unit,
) -> UiSubscription {
  { id_: id, is_active_: is_active, unsubscribe_: unsubscribe, }
}

///|
/// Subscription id, as reported by `UiListenerFailure`.
pub fn UiSubscription::id(self : UiSubscription) -> Int32 {
  self.id_
}

///|
/// False once unsubscribed, dropped after a listener failure, or closed by
/// `Agent::shutdown`.
pub fn UiSubscription::is_active(self : UiSubscription) -> Bool {
  (self.is_active_)()
}

///|
/// Stop delivery. Idempotent, and safe to call from inside the listener itself;
/// no change is delivered after it returns.
pub fn UiSubscription::unsubscribe(self : UiSubscription) -> Unit {
  (self.unsubscribe_)()
}

///|
/// The atomic handoff of a push subscription: the baseline cut plus the handle
/// for everything accepted after it.
pub(all) struct UiObservation {
  baseline : UiBaseline
  /// Subscription id; also the id carried by `UiListenerFailure`.
  subscription : UiSubscription
}

///|
/// Host observation, interaction and action handle, owned by the Agent.
pub struct UiHost {
  priv snapshot_ : () -> Result[UiBaseline, UiResourceError]
  priv changes_since_ : (UiCursor) -> Result[UiChanges, UiResourceError]
  priv interactions_since_ : (UiCursor) -> Result[
    UiInteractionChanges,
    UiResourceError,
  ]
  priv dispatch_ : async (UiActionRequest) -> Result[
    UiActionResult,
    UiResourceError,
  ] noraise
  priv answer_ : (UiInteractionAnswerRequest) -> Result[
    UiInteractionAnswerReceipt,
    UiInteractionError,
  ]
  priv dismiss_ : (UiInteractionRef, String) -> Result[
    UiInteractionOutcome,
    UiInteractionError,
  ]
  priv subscribe_ : (
    (UiFeedBatch) -> Result[Unit, String],
    (UiListenerFailure) -> Unit,
  ) -> Result[UiObservation, UiResourceError]
  priv connect_ : (UiHostCapabilities) -> Result[
    UiHostConnection,
    UiInteractionError,
  ]
}

///|
/// Read the current baseline. Cheap, side-effect free and repeatable.
pub fn UiHost::snapshot(self : UiHost) -> Result[UiBaseline, UiResourceError] {
  (self.snapshot_)()
}

///|
/// Changes accepted after `cursor`. The caller must treat `SnapshotRequired`
/// as "re-read `snapshot`", never as "nothing changed".
pub fn UiHost::changes_since(
  self : UiHost,
  cursor~ : UiCursor,
) -> Result[UiChanges, UiResourceError] {
  (self.changes_since_)(cursor)
}

///|
/// Interaction changes accepted after `cursor`. Same window and generation
/// rules as `changes_since`, on the interaction feed.
pub fn UiHost::interactions_since(
  self : UiHost,
  cursor~ : UiCursor,
) -> Result[UiInteractionChanges, UiResourceError] {
  (self.interactions_since_)(cursor)
}

///|
/// Route one action to the resource's owner. Validation happens before the
/// owner handler is awaited; a duplicate request id replays the stored receipt
/// instead of running the handler twice.
pub async fn UiHost::dispatch(
  self : UiHost,
  request~ : UiActionRequest,
) -> Result[UiActionResult, UiResourceError] noraise {
  (self.dispatch_)(request)
}

///|
/// Answer one pending interaction. The first valid answer settles it; the same
/// value again replays the stored receipt, a different value is `Conflict`,
/// and a question that already ended is `AlreadySettled`.
pub fn UiHost::answer(
  self : UiHost,
  request~ : UiInteractionAnswerRequest,
) -> Result[UiInteractionAnswerReceipt, UiInteractionError] {
  (self.answer_)(request)
}

///|
/// Dismiss one pending interaction: the user closed the prompt without
/// choosing; the owner's waiter resumes with `Dismissed`. Re-dismissing a
/// settled question is `AlreadySettled`.
pub fn UiHost::dismiss(
  self : UiHost,
  interaction~ : UiInteractionRef,
  reason~ : String = "",
) -> Result[UiInteractionOutcome, UiInteractionError] {
  (self.dismiss_)(interaction, reason)
}

///|
/// Subscribe to every change accepted from now on. The returned baseline
/// already contains everything committed before the subscription; the listener
/// receives everything after it, in commit order, synchronously inside the
/// accepting mutation. Returning `Err(detail)` keeps the change accepted,
/// calls `on_failure` once and drops the subscription.
pub fn UiHost::subscribe(
  self : UiHost,
  listener~ : (UiFeedBatch) -> Result[Unit, String],
  on_failure~ : (UiListenerFailure) -> Unit,
) -> Result[UiObservation, UiResourceError] {
  (self.subscribe_)(listener, on_failure)
}

///|
/// Attach an explicit host lease with the capabilities this host declares.
/// A subscription is observation only; only a connection whose `interactions`
/// include the question's body kind keeps a blocking `wait` blocked. Detaching
/// releases the lease and wakes waiters that lost their last matching host.
pub fn UiHost::connect(
  self : UiHost,
  capabilities~ : UiHostCapabilities,
) -> Result[UiHostConnection, UiInteractionError] {
  (self.connect_)(capabilities)
}

///|
/// Framework construction hook. Hosts obtain the value from the Agent.
pub fn UiHost::from_callbacks(
  snapshot~ : () -> Result[UiBaseline, UiResourceError],
  changes_since~ : (UiCursor) -> Result[UiChanges, UiResourceError],
  interactions_since~ : (UiCursor) -> Result[
    UiInteractionChanges,
    UiResourceError,
  ],
  dispatch~ : async (UiActionRequest) -> Result[UiActionResult, UiResourceError] noraise,
  answer~ : (UiInteractionAnswerRequest) -> Result[
    UiInteractionAnswerReceipt,
    UiInteractionError,
  ],
  dismiss~ : (UiInteractionRef, String) -> Result[
    UiInteractionOutcome,
    UiInteractionError,
  ],
  subscribe~ : (
    (UiFeedBatch) -> Result[Unit, String],
    (UiListenerFailure) -> Unit,
  ) -> Result[UiObservation, UiResourceError],
  connect? : (UiHostCapabilities) -> Result[
    UiHostConnection,
    UiInteractionError,
  ],
) -> UiHost {
  let connect_callback = match connect {
    Some(callback) => callback
    None =>
      fn(_capabilities) {
        Err(
          UiInteractionError::HostUnavailable(
            reason="this UiHost adapter does not support host connections",
          ),
        )
      }
  }
  {
    snapshot_: snapshot,
    changes_since_: changes_since,
    interactions_since_: interactions_since,
    dispatch_: dispatch,
    answer_: answer,
    dismiss_: dismiss,
    subscribe_: subscribe,
    connect_: connect_callback,
  }
}
