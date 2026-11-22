///|

///|
/// Opaque admission ticket. `id` is stable per pending (session, tag) entry;
/// a coalesced re-request returns the same ticket. `enqueued_at` is an
/// observation timestamp read from the async runtime's timer clock, for
/// display and diagnostics only — it is never part of ticket identity or
/// correctness, and carries no monotonicity guarantee.
#derive(Eq, Debug)
pub(all) struct WakeupTicket {
  id : String
  session : String
  tag : String
  enqueued_at : Int64
}

///|
pub extend WakeupTicket with Eq::{not_equal, equal}

///|
pub extend WakeupTicket with Debug::{to_repr}

///|
/// Admission failures are explicit so an extension cannot mistake a closed
/// scope, a malformed tag, or an invalid session for accepted work.
#derive(Eq, Debug)
pub(all) enum WakeupError {
  /// No live `run_scoped`, or the Agent already shut down. Wakeups are
  /// scope-scoped; a closed admission never reopens.
  ScopeInactive
  /// Empty tag, a tag over the length limit, or an otherwise unusable key.
  TagInvalid(reason~ : String)
  /// Empty session id, no active session bound, or a session that is not
  /// the currently bound active window session. A request never binds the
  /// active session itself.
  InvalidSession(reason~ : String)
  /// The session already holds the maximum number of pending tickets. The
  /// request is rejected — never silently dropped — and coalescing onto an
  /// already pending tag is still accepted.
  PendingFull(session~ : String, limit~ : Int32)
}

///|
pub extend WakeupError with Eq::{not_equal, equal}

///|
pub extend WakeupError with Debug::{to_repr}

///|
/// Queue a wakeup for the session. At an eligible step boundary in a turn
/// for that session, pending wakeups can enter the turn as separate input
/// messages. A ticket is satisfied only after the journal commits the
/// boundary that applies its message. `wakeup_satisfied` is scoped to the
/// actual turn and reports `delivery=step` and the operation id. If the
/// Agent is idle, the pump can instead start an ordinary turn for the ticket.
/// Wakeup alone can extend a turn at most 64 times; outstanding tickets remain
/// eligible for the idle pump.
///
/// Requests are synchronous and never await, including from task bodies,
/// observer callbacks, and hook tails. The session must be the Agent's
/// currently bound active window session (set by `Agent::set_active_session`).
/// Pending tickets are dropped when that binding changes and do not survive
/// process exit. Requests for a pending `(session, tag)` return the same
/// ticket and replace its note without another `wakeup_requested` event.
/// A request made after a step snapshot remains pending even if the earlier
/// message is committed.
pub struct WakeupPort {
  priv request_ : (String, String, String) -> Result[WakeupTicket, WakeupError]
}

///|
pub fn WakeupPort::request(
  self : WakeupPort,
  session~ : String,
  tag~ : String,
  note~ : String = "",
) -> Result[WakeupTicket, WakeupError] {
  (self.request_)(session, tag, note)
}

///|
/// Framework construction hook. Product extensions obtain the value through
/// `CompositionView::wakeup` and do not need this constructor.
pub fn WakeupPort::from_request(
  request~ : (String, String, String) -> Result[WakeupTicket, WakeupError],
) -> WakeupPort {
  { request_: fn(session, tag, note) { request(session, tag, note) }, }
}
