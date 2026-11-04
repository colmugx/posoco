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
