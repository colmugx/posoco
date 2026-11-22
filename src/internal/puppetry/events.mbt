///|

///|
/// A KernelEvent wrapped with run/session identity, monotonic sequence
/// number, and the journal revision at which the event's savepoint
/// committed. Subscribers receive envelopes, never raw KernelEvents.
#derive(Eq, Debug)
pub(all) struct EventEnvelope {
  run_id : RunId
  turn_id : TurnId
  session_id : SessionId
  /// Monotonic per-run sequence. Strictly increasing; no duplicates.
  seq : Int32
  /// Journal revision at the moment the underlying savepoint committed.
  /// Subscribers can correlate events to journal entries via this.
  committed_revision : Int32
  event : KernelEvent
  step_session : @types.Session?
}

///|
pub extend EventEnvelope with Eq::{not_equal, equal}

///|
pub extend EventEnvelope with Debug::{to_repr}

///|
pub fn EventEnvelope::run_id(self : EventEnvelope) -> RunId {
  self.run_id
}

///|
pub fn EventEnvelope::turn_id(self : EventEnvelope) -> TurnId {
  self.turn_id
}

///|
pub fn EventEnvelope::session_id(self : EventEnvelope) -> SessionId {
  self.session_id
}

///|
pub fn EventEnvelope::event(self : EventEnvelope) -> KernelEvent {
  self.event
}

///|
/// Whether this envelope wraps a terminal event (RunCompleted /
/// RunFailed / RunCancelled).
pub fn EventEnvelope::is_terminal(self : EventEnvelope) -> Bool {
  self.event.is_terminal()
}

///|
/// Construct an envelope. Internal — only the Puppet dispatcher builds
/// envelopes (it owns the seq counter).
pub fn EventEnvelope::EventEnvelope(
  run_id~ : RunId,
  turn_id~ : TurnId,
  session_id~ : SessionId,
  seq~ : Int32,
  committed_revision~ : Int32,
  event~ : KernelEvent,
  step_session~ : @types.Session? = None,
) -> EventEnvelope {
  { run_id, turn_id, session_id, seq, committed_revision, event, step_session, }
}

///|
pub extend EventEnvelope with Show::{to_string, output}

///|
pub impl Show for EventEnvelope with fn to_string(self : EventEnvelope) -> String {
  "EventEnvelope(run=\{self.run_id.to_string()}, turn=\{self.turn_id.to_string()}, seq=\{self.seq}, rev=\{self.committed_revision}, \{self.event.to_string()})"
}

///|
/// Port: post-commit event subscriber. Receives one envelope at a time,
/// in strict seq order, after the journal barrier succeeds.
pub(open) trait EventSubscriber {
  /// Stable identifier for this subscriber. Used in diagnostics.
  fn subscriber_id(Self) -> String

  /// Provenance (e.g. "audit_log", "metrics").
  fn provenance(Self) -> String

  /// Receive one envelope. May raise `SubscriberError` to fail the run.
  async fn on_event(Self, EventEnvelope) -> Unit raise SubscriberError
}

///|
/// Typed error a subscriber can raise.
pub(all) suberror SubscriberError {
  /// Subscriber encountered an internal error.
  Internal(subscriber_id~ : String, detail~ : String)
  /// Subscriber detected a contract violation (e.g. out-of-order seq).
  ContractViolation(subscriber_id~ : String, detail~ : String)
}

///|
pub extend SubscriberError with Show::{output}

///|
pub impl Show for SubscriberError with fn to_string(self : SubscriberError) -> String {
  match self {
    Internal(subscriber_id~, detail~) => "Internal(\{subscriber_id}: \{detail})"
    ContractViolation(subscriber_id~, detail~) =>
      "ContractViolation(\{subscriber_id}: \{detail})"
  }
}

///|
/// Default subscriber that drops every event. Useful as a baseline
/// and as a baseline for tests.
pub(all) struct NoopSubscriber {
  id : String
}

///|
pub fn NoopSubscriber::NoopSubscriber() -> NoopSubscriber {
  { id: "noop_subscriber", }
}

///|
pub fn NoopSubscriber::with_id(id : String) -> NoopSubscriber {
  { id, }
}

///|
pub extend NoopSubscriber with EventSubscriber::{
  on_event,
  provenance,
  subscriber_id,
}

///|
pub impl EventSubscriber for NoopSubscriber with fn subscriber_id(self) -> String {
  self.id
}

///|
pub impl EventSubscriber for NoopSubscriber with fn provenance(_self) -> String {
  "noop"
}

///|
pub impl EventSubscriber for NoopSubscriber with fn on_event(
  _self,
  _envelope : EventEnvelope,
) -> Unit raise SubscriberError {
  ()
}

///|
/// Post-commit event dispatcher. Holds the per-run seq counter and the
/// subscriber list. The Puppet constructs one dispatcher per Run; seq
pub struct EventDispatcher {
  subscribers : Array[&EventSubscriber]
  /// Per-run seq counter. Incremented before each dispatch.
  mut next_seq : Int32
  /// Last committed revision the dispatcher has observed. Used to build
  /// envelopes.
  mut last_committed_revision : Int32
  /// Run identity this dispatcher is bound to. Set once.
  run_id : RunId
  turn_id : TurnId
  session_id : SessionId
}

///|
pub fn EventDispatcher::EventDispatcher(
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
) -> EventDispatcher {
  {
    subscribers: [],
    next_seq: 1,
    last_committed_revision: 0,
    run_id,
    turn_id,
    session_id,
  }
}

///|
/// Register a subscriber. Subscribers are dispatched in registration order.
/// Must be called BEFORE any dispatch (the dispatcher does not support
/// concurrent subscription during a run).
pub fn EventDispatcher::register(
  self : EventDispatcher,
  subscriber : &EventSubscriber,
) -> Unit {
  self.subscribers.push(subscriber)
}

///|
pub fn EventDispatcher::subscriber_count(self : EventDispatcher) -> Int32 {
  self.subscribers.length()
}

///|
/// Current seq counter value (next envelope gets this seq).
pub fn EventDispatcher::next_seq(self : EventDispatcher) -> Int32 {
  self.next_seq
}

///|
/// Dispatch a single KernelEvent to all subscribers. Assigns the next seq,
/// builds the envelope, and awaits each subscriber in order.
pub async fn EventDispatcher::dispatch(
  self : EventDispatcher,
  event : KernelEvent,
  committed_revision : Int32,
  step_session~ : @types.Session? = None,
) -> Unit raise PuppetError {
  let seq = self.next_seq
  self.next_seq = self.next_seq + 1
  self.last_committed_revision = committed_revision
  let envelope : EventEnvelope = EventEnvelope(
    run_id=self.run_id,
    turn_id=self.turn_id,
    session_id=self.session_id,
    seq~,
    committed_revision~,
    event~,
    step_session~,
  )
  for subscriber in self.subscribers {
    let sid = subscriber.subscriber_id()
    let result : Result[Unit, SubscriberError] = try {
      subscriber.on_event(envelope)
      Ok(())
    } catch {
      e => Err(e)
    }
    match result {
      Ok(_) => ()
      Err(e) =>
        raise SubscriberFailed(
          subscriber_id=sid,
          cause=e.to_string(),
          committed_revision~,
        )
    }
  }
}
