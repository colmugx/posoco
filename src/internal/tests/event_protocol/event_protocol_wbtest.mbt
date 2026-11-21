///|
/// Observer fake that records the manifest-order delivery log, the scope, and
/// the event shape it was handed.
priv struct RecordingObserver {
  name : String
  log : Ref[Array[String]]
  received : Array[(@types.EventScope?, @types.TurnEvent)]
}

///|
fn recording_observer(
  name : String,
  log : Ref[Array[String]],
) -> RecordingObserver {
  { name, log, received: [], }
}

///|
fn RecordingObserver::events(
  self : RecordingObserver,
) -> Array[@types.TurnEvent] {
  self.received.map(fn(entry) { entry.1 })
}

///|
fn RecordingObserver::scopes(
  self : RecordingObserver,
) -> Array[@types.EventScope?] {
  self.received.map(fn(entry) { entry.0 })
}

///|
impl @port.Observer for RecordingObserver with fn on_event(
  self : RecordingObserver,
  scope : @types.EventScope?,
  event : @types.TurnEvent,
) -> Unit {
  self.log.val.push(self.name)
  self.received.push((scope, event))
}

///|
fn test_scope(
  session : String,
  run : String,
  turn : String,
) -> @types.EventScope {
  {
    session_id: @kernel.SessionId::unchecked(session),
    run_id: @kernel.RunId::unchecked(run),
    turn_id: @kernel.TurnId::unchecked(turn),
  }
}

///|
fn core_label(event : @types.TurnEvent) -> String {
  match event {
    TurnStarted => "TurnStarted"
    TurnCompleted => "TurnCompleted"
    TurnFailed(reason) => "TurnFailed:" + reason
    Custom(label~, ..) => "Custom:" + label
    _ => "other"
  }
}

///|
/// Stable text of one delivery: namespace + typed payload. Tests compare
/// sequences instead of inspecting internal queue state.
fn envelope_label(envelope : @events.EventEnvelope) -> String {
  let owner = match envelope.namespace_of() {
    Posoco => "posoco"
    Extension(owner) => owner
  }
  let payload = match envelope.event {
    @events.Core(event) => core_label(event)
    @protocol.SprintChanged(sprint) => sprint.describe()
    _ => "unknown"
  }
  owner + "/" + payload
}

///|
fn json_value(value : Json) -> String? {
  match value {
    Object(fields) =>
      match fields["k"] {
        String(text) => Some(text)
        _ => None
      }
    _ => None
  }
}

///|
test "runtime/capability_subscribe_can_listen_to_posoco" {
  let runtime = @event_runtime.EventRuntime()
  let ext = runtime.capability("alpha")
  let seen : Array[String] = []
  ignore(
    match ext.subscribe(fn(envelope) { seen.push(envelope_label(envelope)) }) {
      Ok(subscription) => subscription
      Err(_) => abort("capability subscribe failed")
    },
  )
  runtime.emit_core(None, TurnStarted)
  assert_eq(seen, ["posoco/TurnStarted"])
}

///|
test "runtime/close_rejects_publish_and_subscribe" {
  let runtime = @event_runtime.EventRuntime()
  let ext = runtime.capability("alpha")
  ignore(runtime.subscribe(fn(_) { () }))
  assert_true(runtime.has_listeners())
  runtime.close()
  assert_false(runtime.has_listeners())
  guard runtime.subscribe(fn(_) { () }) is Err(@events.Closed) else {
    fail("subscribe after close must fail with Closed")
  }
  guard ext.subscribe(fn(_) { () }) is Err(@events.Closed) else {
    fail("capability subscribe after close must fail with Closed")
  }
  guard @protocol.publish_sprint(ext, Finished) is Err(@events.Closed) else {
    fail("publish after close must fail with Closed")
  }
  guard ext.publish(@events.Core(TurnStarted)) is Err(@events.ReservedEvent) else {
    fail("core payload rejection stays typed after close")
  }
}

///|
test "runtime/cancel_after_close_is_idempotent" {
  let runtime = @event_runtime.EventRuntime()
  let subscription = match runtime.subscribe(fn(_) { () }) {
    Ok(subscription) => subscription
    Err(_) => abort("subscribe failed")
  }
  runtime.close()
  subscription.cancel()
  subscription.cancel()
  guard runtime.subscribe(fn(_) { () }) is Err(@events.Closed) else {
    fail("closed runtime must stay closed")
  }
}

///|
test "panic runtime/emit_core_after_close_aborts" {
  let runtime = @event_runtime.EventRuntime()
  runtime.close()
  runtime.emit_core(None, TurnStarted)
}

///|
test "runtime/dispatches_listeners_in_registration_order" {
  let runtime = @event_runtime.EventRuntime()
  let log : Array[String] = []
  ignore(runtime.subscribe(fn(_) { log.push("first") }))
  ignore(runtime.subscribe(fn(_) { log.push("second") }))
  ignore(runtime.subscribe(fn(_) { log.push("third") }))
  runtime.emit_core(None, TurnStarted)
  assert_eq(log, ["first", "second", "third"])
}

///|
test "runtime/observers_keep_manifest_order_and_receive_scope" {
  let log : Ref[Array[String]] = Ref([])
  let first = recording_observer("observer-1", log)
  let second = recording_observer("observer-2", log)
  let runtime = @event_runtime.EventRuntime()
  match
    runtime.register_observers([
      first as &@port.Observer,
      second as &@port.Observer,
    ]) {
    Ok(_) => ()
    Err(error) => fail("register_observers failed: \{repr(error)}")
  }
  ignore(runtime.subscribe(fn(_) { log.val.push("listener") }))
  let scope = test_scope("session-1", "run-1", "turn-1")
  runtime.emit_core(Some(scope), TurnStarted)
  assert_eq(log.val, ["observer-1", "observer-2", "listener"])
  assert_eq(first.scopes(), [Some(scope)])
  assert_eq(second.events(), [TurnStarted])
}

///|
test "runtime/reentrant_publish_is_queued_after_the_current_batch" {
  let runtime = @event_runtime.EventRuntime()
  let ext = runtime.capability("alpha")
  let log : Array[String] = []
  ignore(
    runtime.subscribe(fn(envelope) {
      match envelope.event {
        @events.Core(_) => {
          log.push("core")
          ignore(@protocol.publish_sprint(ext, Started(1)))
          ignore(@protocol.publish_sprint(ext, Started(2)))
          log.push("core-returned")
        }
        _ => log.push(envelope_label(envelope))
      }
    }),
  )
  runtime.emit_core(None, TurnStarted)
  assert_eq(log, [
    "core", "core-returned", "alpha/started #1", "alpha/started #2",
  ])
}

///|
test "runtime/batch_snapshot_defers_add_and_cancel_to_next_batch" {
  let runtime = @event_runtime.EventRuntime()
  let log : Array[String] = []
  let second : Ref[@events.Subscription?] = Ref(None)
  let adding = Ref(true)
  ignore(
    runtime.subscribe(fn(_) {
      log.push("A")
      match second.val {
        Some(subscription) => subscription.cancel()
        None => ()
      }
      if adding.val {
        adding.val = false
        ignore(runtime.subscribe(fn(_) { log.push("C") }))
      }
    }),
  )
  second.val = match runtime.subscribe(fn(_) { log.push("B") }) {
    Ok(subscription) => Some(subscription)
    Err(_) => abort("subscribe failed")
  }
  runtime.emit_core(None, TurnStarted)
  // Batch one still sees B (cancelled inside the batch) and not C (added
  // inside the batch).
  assert_eq(log, ["A", "B"])
  runtime.emit_core(None, TurnCompleted)
  assert_eq(log, ["A", "B", "A", "C"])
}

///|
test "runtime/new_listener_receives_no_history" {
  let runtime = @event_runtime.EventRuntime()
  runtime.emit_core(None, TurnStarted)
  let seen : Array[String] = []
  ignore(
    runtime.subscribe(fn(envelope) { seen.push(envelope_label(envelope)) }),
  )
  assert_true(seen.is_empty())
  runtime.emit_core(None, TurnCompleted)
  assert_eq(seen, ["posoco/TurnCompleted"])
}

///|
test "runtime/publish_without_listeners_succeeds" {
  let runtime = @event_runtime.EventRuntime()
  let ext = runtime.capability("alpha")
  assert_false(runtime.has_listeners())
  runtime.emit_core(None, TurnStarted)
  guard @protocol.publish_sprint(ext, Finished) is Ok(_) else {
    fail("publishing without listeners must succeed")
  }
  assert_false(runtime.has_listeners())
}

///|
test "runtime/has_listeners_sees_new_subscribers_without_observers" {
  let runtime = @event_runtime.EventRuntime()
  assert_false(runtime.has_listeners())
  let subscription = match
    runtime.subscribe(fn(_) { () }, namespace_=Some(Extension("alpha"))) {
    Ok(subscription) => subscription
    Err(_) => abort("subscribe failed")
  }
  assert_true(runtime.has_listeners())
  subscription.cancel()
  assert_false(runtime.has_listeners())
}

///|
test "protocol/community_adt_travels_typed_across_packages" {
  let runtime = @event_runtime.EventRuntime()
  let started : Array[Int32] = []
  let blocked : Array[String] = []
  let scoped : Array[(@types.EventScope?, String)] = []
  ignore(
    runtime.subscribe(fn(envelope) {
      match envelope.event {
        @protocol.SprintChanged(sprint) => {
          scoped.push((envelope.scope, sprint.describe()))
          // The payload is a plain enum from the protocol package: the match
          // is exhaustive without a wildcard inside the business ADT.
          match sprint {
            Started(sprint_no) => started.push(sprint_no)
            Blocked(reason~) => blocked.push(reason)
            Finished => ()
          }
        }
        _ => abort("expected a sprint protocol event")
      }
    }),
  )
  let ext = runtime.capability("sprints")
  let scope = test_scope("session-1", "run-1", "turn-1")
  guard @protocol.publish_sprint(ext, Started(7), scope=Some(scope)) is Ok(_) else {
    fail("protocol publish failed")
  }
  ignore(@protocol.publish_sprint(ext, Blocked(reason="review pending")))
  assert_eq(started, [7])
  assert_eq(blocked, ["review pending"])
  assert_eq(scoped, [
    (Some(scope), "started #7"),
    (None, "blocked: review pending"),
  ])
}

///|
test "runtime/core_payload_snapshot_isolates_each_receiver" {
  let log : Ref[Array[String]] = Ref([])
  let observer = recording_observer("observer", log)
  let runtime = @event_runtime.EventRuntime()
  match runtime.register_observers([observer as &@port.Observer]) {
    Ok(_) => ()
    Err(error) => fail("register_observers failed: \{repr(error)}")
  }
  let second_seen : Array[String?] = []
  // The first listener poisons the payload copy it received.
  ignore(
    runtime.subscribe(fn(envelope) {
      guard envelope.event is @events.Core(Custom(data~, ..)) else { return }
      match data {
        Object(fields) => fields["k"] = Json::string("poisoned")
        _ => ()
      }
    }),
  )
  ignore(
    runtime.subscribe(fn(envelope) {
      guard envelope.event is @events.Core(Custom(data~, ..)) else { return }
      second_seen.push(json_value(data))
    }),
  )
  let data = Json::object(Map::from_array([("k", Json::string("original"))]))
  runtime.emit_core(None, Custom(source="test", label="isolation", data~))
  assert_eq(second_seen, [Some("original")])
  assert_eq(json_value(data), Some("original"))
  match observer.events() {
    [Custom(data~, ..)] => assert_eq(json_value(data), Some("original"))
    _ => fail("expected one observed custom event")
  }
}

///|
test "runtime/core_payload_enqueue_snapshot_survives_producer_mutation" {
  let runtime = @event_runtime.EventRuntime()
  let seen : Array[String?] = []
  ignore(
    runtime.subscribe(fn(envelope) {
      guard envelope.event is @events.Core(Custom(label~, data~, ..)) else {
        return
      }
      if label == "trigger" {
        // Queued, not delivered yet: the snapshot is taken at this boundary.
        runtime.emit_core(None, Custom(source="test", label="queued", data~))
        match data {
          Object(fields) => fields["k"] = Json::string("poisoned")
          _ => ()
        }
        return
      }
      seen.push(json_value(data))
    }),
  )
  let data = Json::object(Map::from_array([("k", Json::string("original"))]))
  runtime.emit_core(None, Custom(source="test", label="trigger", data~))
  assert_eq(seen, [Some("original")])
}
