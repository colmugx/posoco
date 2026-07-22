///|
/// Harness event dispatch (M2-T05, ADR §5 step 6, §6 subscriber rules).
///
/// Post-commit event dispatcher. Receives envelopes CONSTRUCTED AFTER the
/// journal barrier succeeds; assigns monotonic `seq` per run; dispatches
/// in registration order; awaits each subscriber.
///
/// M2 default (ADR §7 Q7.4 recommendation): ALL subscribers are
/// correctness-critical. A subscriber failure fails the run with
/// `HarnessError::SubscriberFailed`; the journal entry is already durable
/// (commit happened before dispatch). No best-effort escape hatch in M2.
///
/// Subscribers never receive a journal writer. If a subscriber needs to add
/// a domain entry, it must do so via a `JournalContributor` at the NEXT
/// savepoint; attempting to reach the journal from a subscriber is a
/// contract violation detected at composition (the subscriber trait has no
/// such method).

// ──────────────────────────────────────────────────────────────────────────
// EventEnvelope — wraps a KernelEvent with identity + seq + revision
// ──────────────────────────────────────────────────────────────────────────

///|
/// A KernelEvent wrapped with run/session identity, monotonic sequence
/// number, and the journal revision at which the event's savepoint
/// committed. Subscribers receive envelopes, never raw KernelEvents.
pub(all) struct EventEnvelope {
  run_id : RunId
  turn_id : TurnId
  session_id : SessionId
  /// Monotonic per-run sequence. Strictly increasing; no duplicates.
  seq : Int
  /// Journal revision at the moment the underlying savepoint committed.
  /// Subscribers can correlate events to journal entries via this.
  committed_revision : Int
  event : KernelEvent
} derive(Eq, Debug)

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
pub fn EventEnvelope::seq(self : EventEnvelope) -> Int {
  self.seq
}

///|
pub fn EventEnvelope::committed_revision(self : EventEnvelope) -> Int {
  self.committed_revision
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
/// Construct an envelope. Internal — only the Harness dispatcher builds
/// envelopes (it owns the seq counter).
pub fn EventEnvelope::new(
  run_id~ : RunId,
  turn_id~ : TurnId,
  session_id~ : SessionId,
  seq~ : Int,
  committed_revision~ : Int,
  event~ : KernelEvent,
) -> EventEnvelope {
  { run_id, turn_id, session_id, seq, committed_revision, event }
}

///|
pub impl Show for EventEnvelope with fn to_string(self : EventEnvelope) -> String {
  "EventEnvelope(run=\{self.run_id.to_string()}, turn=\{self.turn_id.to_string()}, seq=\{self.seq}, rev=\{self.committed_revision}, \{self.event.to_string()})"
}

// ──────────────────────────────────────────────────────────────────────────
// EventSubscriber trait
// ──────────────────────────────────────────────────────────────────────────

///|
/// Port: post-commit event subscriber. Receives one envelope at a time,
/// in strict seq order, after the journal barrier succeeds.
///
/// Subscribers must not:
/// - mutate the envelope (it's passed by value, but the inner KernelEvent
///   is immutable anyway)
/// - reach into the journal (the trait exposes no writer)
/// - re-enter the Harness via structural commands (ADR §11 reentrancy rule)
///
/// Subscribers may:
/// - read the envelope and any derived state
/// - raise `SubscriberError` to fail the run (correctness-critical default)
/// - maintain internal mutable state (e.g. a log buffer)
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
pub impl Show for SubscriberError with fn to_string(self : SubscriberError) -> String {
  match self {
    Internal(subscriber_id~, detail~) => "Internal(\{subscriber_id}: \{detail})"
    ContractViolation(subscriber_id~, detail~) =>
      "ContractViolation(\{subscriber_id}: \{detail})"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// NoopSubscriber — default subscriber that does nothing
// ──────────────────────────────────────────────────────────────────────────

///|
/// Default subscriber that drops every event. Useful as a baseline
/// and as a baseline for tests.
pub(all) struct NoopSubscriber {
  id : String
}

///|
pub fn NoopSubscriber::new() -> NoopSubscriber {
  { id: "noop_subscriber" }
}

///|
pub fn NoopSubscriber::with_id(id : String) -> NoopSubscriber {
  { id, }
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

// ──────────────────────────────────────────────────────────────────────────
// EventDispatcher — assigns seq, awaits subscribers in registration order
// ──────────────────────────────────────────────────────────────────────────

///|
/// Post-commit event dispatcher. Holds the per-run seq counter and the
/// subscriber list. The Harness constructs one dispatcher per Run; seq
/// starts at 1 for each Run (seq 0 is reserved for "no events yet").
///
/// ADR §5 step 6: dispatcher runs ONLY after commit succeeds.
pub struct EventDispatcher {
  subscribers : Array[&EventSubscriber]
  /// Per-run seq counter. Incremented before each dispatch.
  mut next_seq : Int
  /// Last committed revision the dispatcher has observed. Used to build
  /// envelopes.
  mut last_committed_revision : Int
  /// Run identity this dispatcher is bound to. Set once.
  run_id : RunId
  turn_id : TurnId
  session_id : SessionId
}

///|
pub fn EventDispatcher::new(
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
pub fn EventDispatcher::subscriber_count(self : EventDispatcher) -> Int {
  self.subscribers.length()
}

///|
/// Current seq counter value (next envelope gets this seq).
pub fn EventDispatcher::next_seq(self : EventDispatcher) -> Int {
  self.next_seq
}

///|
/// Dispatch a single KernelEvent to all subscribers. Assigns the next seq,
/// builds the envelope, and awaits each subscriber in order.
///
/// Raises `HarnessError::SubscriberFailed` if any subscriber raises. The
/// dispatcher stops at the first failure (correctness-critical default).
pub async fn EventDispatcher::dispatch(
  self : EventDispatcher,
  event : KernelEvent,
  committed_revision : Int,
) -> Unit raise HarnessError {
  let seq = self.next_seq
  self.next_seq = self.next_seq + 1
  self.last_committed_revision = committed_revision
  let envelope : EventEnvelope = EventEnvelope::new(
    run_id=self.run_id,
    turn_id=self.turn_id,
    session_id=self.session_id,
    seq~,
    committed_revision~,
    event~,
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
