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
    runtime.subscribe(
      fn(_) { () },
      namespace_=Some(@events.EventNamespace::Extension("alpha")),
    ) {
    Ok(subscription) => subscription
    Err(_) => abort("subscribe failed")
  }
  assert_true(runtime.has_listeners())
  subscription.cancel()
  assert_false(runtime.has_listeners())
}
