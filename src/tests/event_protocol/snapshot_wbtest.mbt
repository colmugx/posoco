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
