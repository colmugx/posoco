///|
fn step_scope(session_id : String) -> @types.EventScope {
  {
    session_id: @kernel.SessionId::unchecked(session_id),
    run_id: @kernel.RunId::unchecked("run"),
    turn_id: @kernel.TurnId::unchecked("turn"),
  }
}

///|
async test "step snapshot freezes FIFO envelopes and confirms only exact generations" {
  let events = @event_runtime.EventRuntime()
  let runtime = @wakeup.WakeupRuntime(events~)
  runtime.activate()
  runtime.set_active_session(Some("s"))
  let port = runtime.capability("ext")
  let satisfied : Array[(@types.EventScope?, Json)] = []
  ignore(
    events
    .subscribe(fn(envelope) {
      if envelope.event
        is @events.Core(
          Custom(source="posoco.wakeup", label="wakeup_satisfied", data~),
        ) {
        satisfied.push((envelope.scope, data))
      }
    })
    .unwrap(),
  )

  assert_false(runtime.has_step_wakeup("s"))
  assert_true(runtime.snapshot_step("s") is None)
  let first = port.request(session="s", tag="[first]", note="old").unwrap()
  let second = port.request(session="s", tag="second").unwrap()
  assert_true(runtime.has_step_wakeup("s"))
  assert_false(runtime.has_step_wakeup("other"))
  assert_true(runtime.snapshot_step("other") is None)
  let step = runtime.snapshot_step("s").unwrap()
  assert_eq(
    port.request(session="s", tag="[first]", note="new").unwrap(),
    first,
  )
  ignore(port.request(session="s", tag="late").unwrap())
  assert_eq(step.messages, [
    UserMessage(content=[
      Text("[posoco-wakeup tag=\"\\u005bfirst\\u005d\"] old"),
    ]),
    UserMessage(content=[Text("[posoco-wakeup tag=\"second\"]")]),
  ])
  assert_true(satisfied.is_empty())

  let scope = step_scope("s")
  runtime.confirm_step(step, scope, "operation")
  runtime.confirm_step(step, scope, "operation")
  guard satisfied is [(Some(actual_scope), Object(fields))] else {
    fail("expected exactly one scoped satisfaction")
  }
  assert_eq(actual_scope, scope)
  assert_eq(fields.get("ticket_id"), Some(Json::string(second.id)))
  assert_eq(fields.get("delivery"), Some(Json::string("step")))
  assert_eq(fields.get("operation_id"), Some(Json::string("operation")))
  assert_eq(fields.get("turn_id"), Some(Json::string("turn")))
  let remaining = runtime.snapshot_step("s").unwrap()
  assert_eq(remaining.messages, [
    UserMessage(content=[
      Text("[posoco-wakeup tag=\"\\u005bfirst\\u005d\"] new"),
    ]),
    UserMessage(content=[Text("[posoco-wakeup tag=\"late\"]")]),
  ])
  runtime.confirm_step(remaining, scope, "operation")
  assert_false(runtime.has_step_wakeup("s"))
}

///|
async test "step confirmation cannot consume a replacement ticket after rebinding" {
  let runtime = @wakeup.WakeupRuntime(events=@event_runtime.EventRuntime())
  runtime.activate()
  runtime.set_active_session(Some("s"))
  let port = runtime.capability("ext")
  let original = port.request(session="s", tag="tag").unwrap()
  let step = runtime.snapshot_step("s").unwrap()
  runtime.confirm_step(step, step_scope("other"), "operation")
  assert_true(runtime.has_step_wakeup("s"))
  runtime.set_active_session(Some("other"))
  runtime.set_active_session(Some("s"))
  let replacement = port.request(session="s", tag="tag").unwrap()
  assert_true(replacement.id != original.id)
  runtime.confirm_step(step, step_scope("s"), "operation")
  assert_true(runtime.has_step_wakeup("s"))
  assert_eq(port.request(session="s", tag="tag").unwrap(), replacement)
}

///|
async test "step confirmation clears the batch before reentrant requests" {
  let events = @event_runtime.EventRuntime()
  let runtime = @wakeup.WakeupRuntime(events~)
  runtime.activate()
  runtime.set_active_session(Some("s"))
  let port = runtime.capability("ext")
  ignore(port.request(session="s", tag="first").unwrap())
  let second = port.request(session="s", tag="second").unwrap()
  let reentered : Array[@port.WakeupTicket] = []
  ignore(
    events
    .subscribe(fn(envelope) {
      if envelope.event
        is @events.Core(
          Custom(source="posoco.wakeup", label="wakeup_satisfied", ..),
        ) &&
        reentered.is_empty() {
        reentered.push(
          port.request(session="s", tag="second", note="reentrant").unwrap(),
        )
      }
    })
    .unwrap(),
  )

  let step = runtime.snapshot_step("s").unwrap()
  runtime.confirm_step(step, step_scope("s"), "operation")
  guard reentered is [ticket] else { fail("expected one reentrant request") }
  assert_true(ticket.id != second.id)
  assert_eq(runtime.snapshot_step("s").unwrap().messages, [
    UserMessage(content=[Text("[posoco-wakeup tag=\"second\"] reentrant")]),
  ])
}
