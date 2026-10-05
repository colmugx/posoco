///|
/// Agent-owned session wakeup capability: extension-requested ordinary turns.
///
/// Core never wakes a session on its own. Extensions that hold knowledge the
/// model has not seen (a finished background task, a file watcher debounce, a
/// timer deadline, an inbound server push) use `request` to ask the Agent to
/// run one ordinary turn for the session. The Agent executes the request
/// through the single-operation lifecycle as a normal `run_turn` — same
/// journal, boundaries, observers and cancel semantics as a host turn.
///
/// The port is a concrete composed value (like `Tasks`), not a replaceable
/// trait: wakeup admission is Agent-owned and has no extension-side substitute.

///|
/// Opaque admission ticket. `id` is stable per pending (session, tag) entry;
/// a coalesced re-request returns the same ticket. `enqueued_at` is an
/// observation timestamp read from the async runtime's timer clock, for
/// display and diagnostics only — it is never part of ticket identity or
/// correctness, and carries no monotonicity guarantee.
pub(all) struct WakeupTicket {
  id : String
  session : String
  tag : String
  enqueued_at : Int64
} derive(Eq, Debug)

///|
pub extend WakeupTicket with Eq::{not_equal, equal}

///|
pub extend WakeupTicket with Debug::{to_repr}

///|
/// Admission failures are explicit so an extension cannot mistake a closed
/// scope, a malformed tag, or an invalid session for accepted work.
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
} derive(Eq, Debug)

///|
pub extend WakeupError with Eq::{not_equal, equal}

///|
pub extend WakeupError with Debug::{to_repr}

///|
/// Queue one ordinary turn for the session. Synchronous by contract:
/// callable from task bodies, observer callbacks, and hook tails — never
/// awaits. The session must be the Agent's currently bound active window
/// session (set by the host through `Agent::set_active_session`); pending
/// tickets die when that binding changes or the process exits, and are not
/// revived by binding the same session again. Coalescing key is
/// `(session, tag)`: a pending entry returns the same ticket (the requested
/// event fires once), while every request updates the entry's latest
/// requirement generation. A request that lands after an input snapshot is
/// never satisfied by that snapshot.
pub struct WakeupPort {
  priv request_ : (String, String, String) -> Result[WakeupTicket, WakeupError]
}

///|
pub fn WakeupPort::request(
  self : WakeupPort,
  session~ : String,
  tag~ : String,
  note? : String = "",
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
