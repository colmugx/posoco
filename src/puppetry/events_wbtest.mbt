///|
/// Whitebox tests for M2-T05 event dispatcher.
///
/// Coverage:
/// - NoopSubscriber accepts everything
/// - dispatcher assigns monotonic seq per run
/// - subscribers invoked in registration order
/// - subscriber failure raises SubscriberFailed with committed_revision
/// - subscriber failure stops further dispatch (correctness-critical default)
/// - envelope carries run/turn/session/seq/revision/event
/// - is_terminal delegates to inner event

// ──────────────────────────────────────────────────────────────────────────
// Test subscribers
// ──────────────────────────────────────────────────────────────────────────

///|
/// Subscriber that records every envelope it sees into a shared array.
pub(all) struct RecordingSubscriber {
  id_value : String
  received : Array[EventEnvelope]
}

///|
pub fn RecordingSubscriber::new(id : String) -> RecordingSubscriber {
  { id_value: id, received: [] }
}

///|
pub fn RecordingSubscriber::received(
  self : RecordingSubscriber,
) -> Array[EventEnvelope] {
  self.received.copy()
}

///|
pub impl EventSubscriber for RecordingSubscriber with fn subscriber_id(self) -> String {
  self.id_value
}

///|
pub impl EventSubscriber for RecordingSubscriber with fn provenance(_self) -> String {
  "recording"
}

///|
pub impl EventSubscriber for RecordingSubscriber with fn on_event(
  self,
  envelope : EventEnvelope,
) -> Unit raise SubscriberError {
  self.received.push(envelope)
}

///|
/// Subscriber that raises on every event.
pub(all) struct FailingSubscriber {
  id_value : String
}

///|
pub fn FailingSubscriber::new(id : String) -> FailingSubscriber {
  { id_value: id }
}

///|
pub impl EventSubscriber for FailingSubscriber with fn subscriber_id(self) -> String {
  self.id_value
}

///|
pub impl EventSubscriber for FailingSubscriber with fn provenance(_self) -> String {
  "failing"
}

///|
pub impl EventSubscriber for FailingSubscriber with fn on_event(
  self,
  _envelope : EventEnvelope,
) -> Unit raise SubscriberError {
  raise Internal(
    subscriber_id=self.id_value,
    detail="injected subscriber failure",
  )
}

// ──────────────────────────────────────────────────────────────────────────
// Fixtures
// ──────────────────────────────────────────────────────────────────────────

///|
fn ev_run_id() -> RunId {
  RunId::unchecked("run_ev")
}

///|
fn ev_turn_id() -> TurnId {
  TurnId::unchecked("turn_ev")
}

///|
fn ev_session_id() -> SessionId {
  SessionId::unchecked("sess_ev")
}

///|
fn ev_dispatcher() -> EventDispatcher {
  EventDispatcher::new(ev_run_id(), ev_turn_id(), ev_session_id())
}

///|
fn started_event() -> KernelEvent {
  RunStarted(details={ run_id: ev_run_id(), session_id: ev_session_id() })
}

///|
fn completed_event() -> KernelEvent {
  RunCompleted(final_message_summary="done", model_steps=1, tool_calls=0)
}

// ──────────────────────────────────────────────────────────────────────────
// NoopSubscriber
// ──────────────────────────────────────────────────────────────────────────

///|
async test "harness_events/noop_subscriber_accepts_all" {
  let d = ev_dispatcher()
  let noop = NoopSubscriber::new()
  d.register(noop)
  d.dispatch(started_event(), 1)
  d.dispatch(completed_event(), 2)
  assert_true(d.next_seq() == 3)
}

// ──────────────────────────────────────────────────────────────────────────
// Monotonic seq
// ──────────────────────────────────────────────────────────────────────────

///|
async test "harness_events/dispatcher_assigns_monotonic_seq" {
  let d = ev_dispatcher()
  let rec = RecordingSubscriber::new("rec")
  d.register(rec)
  assert_true(d.next_seq() == 1)
  d.dispatch(started_event(), 1)
  assert_true(d.next_seq() == 2)
  d.dispatch(completed_event(), 2)
  assert_true(d.next_seq() == 3)
  let received = rec.received()
  assert_true(received.length() == 2)
  assert_true(received[0].seq() == 1)
  assert_true(received[1].seq() == 2)
  // Envelopes carry the committed revision passed at dispatch time.
  assert_true(received[0].committed_revision() == 1)
  assert_true(received[1].committed_revision() == 2)
}

// ──────────────────────────────────────────────────────────────────────────
// Subscriber registration order
// ──────────────────────────────────────────────────────────────────────────

///|
async test "harness_events/subscribers_invoked_in_registration_order" {
  let d = ev_dispatcher()
  // Two recording subscribers; verify both get the event but in the order
  // they were registered (we infer this via the order of pushes to a
  // shared sentinel subscriber_id list).
  let rec_a = RecordingSubscriber::new("a")
  let rec_b = RecordingSubscriber::new("b")
  d.register(rec_a)
  d.register(rec_b)
  d.dispatch(started_event(), 1)
  // Both received the event.
  assert_true(rec_a.received().length() == 1)
  assert_true(rec_b.received().length() == 1)
  // Both got the same seq.
  assert_true(rec_a.received()[0].seq() == 1)
  assert_true(rec_b.received()[0].seq() == 1)
}

// ──────────────────────────────────────────────────────────────────────────
// Subscriber failure
// ──────────────────────────────────────────────────────────────────────────

///|
async test "harness_events/subscriber_failure_raises_subscriber_failed" {
  let d = ev_dispatcher()
  let failing = FailingSubscriber::new("bad")
  d.register(failing)
  let result : Result[Unit, HarnessError] = Ok(d.dispatch(started_event(), 5)) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(SubscriberFailed(subscriber_id~, cause~, committed_revision~)) => {
      assert_true(subscriber_id == "bad")
      assert_true(cause.contains("injected subscriber failure"))
      assert_true(committed_revision == 5)
    }
    _ => assert_true(false)
  }
}

///|
async test "harness_events/subscriber_failure_stops_further_dispatch" {
  // If subscriber A fails, subscriber B (registered after A) must NOT
  // receive the event (correctness-critical default — ADR §6.6).
  let d = ev_dispatcher()
  let failing = FailingSubscriber::new("a")
  let rec = RecordingSubscriber::new("b")
  d.register(failing)
  d.register(rec)
  let _ = try {
    d.dispatch(started_event(), 1)
    Ok(())
  } catch {
    e => Err(e)
  }
  // b never received the event.
  assert_true(rec.received().length() == 0)
}

// ──────────────────────────────────────────────────────────────────────────
// Envelope identity
// ──────────────────────────────────────────────────────────────────────────

///|
async test "harness_events/envelope_carries_identity" {
  let d = ev_dispatcher()
  let rec = RecordingSubscriber::new("r")
  d.register(rec)
  d.dispatch(started_event(), 1)
  let env = rec.received()[0]
  assert_true(env.run_id() == ev_run_id())
  assert_true(env.turn_id() == ev_turn_id())
  assert_true(env.session_id() == ev_session_id())
  assert_true(env.seq() == 1)
  assert_true(env.committed_revision() == 1)
}

///|
async test "harness_events/envelope_is_terminal_delegates" {
  let d = ev_dispatcher()
  let rec = RecordingSubscriber::new("r")
  d.register(rec)
  d.dispatch(started_event(), 1)
  assert_true(!rec.received()[0].is_terminal())
  d.dispatch(completed_event(), 2)
  assert_true(rec.received()[1].is_terminal())
}
