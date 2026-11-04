///|
/// Pairing and drain tests for the committed-envelope projection. They drive
/// the subscriber through its `EventSubscriber` surface only; the pending-call
/// cache stays private.

///|
/// Observer double recording the tag of every projected turn event plus the
/// scope it arrived with. `events` keeps the full payload for tests that
/// assert on the projected value itself.
priv struct ProjectionObserver {
  records : Array[(String, @types.EventScope?)]
  events : Array[@types.TurnEvent]
}

///|
impl @port.Observer for ProjectionObserver with fn on_event(
  self,
  scope,
  event : @types.TurnEvent,
) -> Unit {
  self.records.push((projection_event_tag(event), scope))
  self.events.push(event)
}

///|
fn projection_event_tag(event : @types.TurnEvent) -> String {
  match event {
    ToolCallPending(_) => "pending"
    ToolCallStarted(..) => "started"
    ToolCallSucceeded(..) => "succeeded"
    ToolCallRejected(..) => "rejected"
    ToolCallAbandoned(call~, ..) => "abandoned:" + call.call_id.to_string()
    MessageApplied(command_id~, delivery~) =>
      "applied:\{command_id}:\{Show::to_string(delivery)}"
    MessageUndelivered(command_id~, delivery~, ..) =>
      "undelivered:\{command_id}:\{Show::to_string(delivery)}"
    _ => "other"
  }
}

///|
fn projection_envelope(
  event : @kernel_exec.KernelEvent,
) -> @puppetry.EventEnvelope {
  @puppetry.EventEnvelope::EventEnvelope(
    run_id=@kernel.RunId::unchecked("run_projection"),
    turn_id=@kernel.TurnId::unchecked("turn_projection"),
    session_id=@kernel.SessionId::unchecked("sess_projection"),
    seq=1,
    committed_revision=0,
    event~,
  )
}

///|
fn projection_call(id : String) -> @kernel.ToolCall {
  {
    call_id: @kernel.CallId::unchecked(id),
    name: @kernel.ToolName::unchecked("echo"),
    arguments: Json::null(),
  }
}

///|
fn projection_ok_outcome() -> @kernel.ToolOutcome {
  Success(content="ok", structured=None)
}

///|
/// Minimal projection over one recording observer with no chunk dispatcher
/// attached (chunk telemetry is wired by the root, not by this package).
fn projection_with(observer : ProjectionObserver) -> &@puppetry.EventSubscriber {
  let no_dispatcher : Ref[@chunk_dispatch.ChunkDispatcher?] = Ref(None)
  let events = @event_runtime.EventRuntime()
  match events.register_observers([observer as &@port.Observer]) {
    Ok(_) => ()
    Err(error) => abort("register_observers failed: \{repr(error)}")
  }
  let projection = EventProjection(events, no_dispatcher)
  projection as &@puppetry.EventSubscriber
}

///|
async test "projection: terminal drain abandons only unpaired calls, once" {
  let observer = ProjectionObserver::{ records: [], events: [], }
  let no_dispatcher : Ref[@chunk_dispatch.ChunkDispatcher?] = Ref(None)
  let events = @event_runtime.EventRuntime()
  match events.register_observers([observer as &@port.Observer]) {
    Ok(_) => ()
    Err(error) => fail("register_observers failed: \{repr(error)}")
  }
  let projection = EventProjection(events, no_dispatcher)
  let subscriber : &@puppetry.EventSubscriber = projection
  let folded = projection_call("call_folded")
  let leftover = projection_call("call_leftover")
  subscriber.on_event(
    projection_envelope(
      ToolBatchStarted(model_step_id=@kernel_exec.ModelStepId::first(), calls=[
        folded, leftover,
      ]),
    ),
  )
  subscriber.on_event(
    projection_envelope(
      ToolCompleted(
        call=folded,
        outcome=projection_ok_outcome(),
        parent_effect_id=None,
      ),
    ),
  )
  subscriber.on_event(
    projection_envelope(RunCancelled(reason=HostRequested(detail=None))),
  )
  // The drain closes exactly the call whose completion never folded, and the
  // closure names that call, so overlapping cleanup paths cannot mispair.
  assert_eq(observer.records.map(fn(r) { r.0 }), [
    "pending", "pending", "succeeded", "abandoned:call_leftover",
  ])
  // The drain is idempotent: a second cleanup pass over an empty cache emits
  // nothing, so terminal paths may overlap without duplicating closures.
  projection.drain_pending(None, "run terminal")
  assert_eq(observer.records.length(), 4)
}

///|
async test "projection: completion without a committed pending call is a violation" {
  let observer = ProjectionObserver::{ records: [], events: [], }
  let no_dispatcher : Ref[@chunk_dispatch.ChunkDispatcher?] = Ref(None)
  let events = @event_runtime.EventRuntime()
  match events.register_observers([observer as &@port.Observer]) {
    Ok(_) => ()
    Err(error) => fail("register_observers failed: \{repr(error)}")
  }
  let projection = EventProjection(events, no_dispatcher)
  let outcome : Result[Unit, @puppetry.SubscriberError] = try {
    projection.on_event(
      projection_envelope(
        ToolCompleted(
          call=projection_call("call_unknown"),
          outcome=projection_ok_outcome(),
          parent_effect_id=None,
        ),
      ),
    )
    Ok(())
  } catch {
    error => Err(error)
  }
  guard outcome is Err(ContractViolation(detail~, ..)) else {
    fail("an unpaired completion must raise ContractViolation")
  }
  assert_true(
    detail.contains("ToolCompleted without committed ToolBatchStarted"),
  )
  assert_eq(observer.records.length(), 0)
}

///|
async test "projection: appended user message projects as a step delivery" {
  let observer = ProjectionObserver::{ records: [], events: [], }
  let subscriber = projection_with(observer)
  subscriber.on_event(
    projection_envelope(
      UserMessageAppended(
        command_id="cmd_step",
        message=UserMessage(content=[Text("target the release branch")]),
      ),
    ),
  )
  // The delivery carries the acceptance receipt and the boundary, never the
  // message body; the body stays in the session transcript.
  assert_eq(observer.events, [
    MessageApplied(command_id="cmd_step", delivery=Step),
  ])
  assert_eq(observer.records.map(fn(r) { r.0 }), ["applied:cmd_step:step"])
}

///|
async test "projection: undelivered steer projects as a step undelivery" {
  let observer = ProjectionObserver::{ records: [], events: [], }
  let subscriber = projection_with(observer)
  subscriber.on_event(
    projection_envelope(
      SteerUndelivered(command_id="cmd_lost", reason="run completed first"),
    ),
  )
  assert_eq(observer.events, [
    MessageUndelivered(
      command_id="cmd_lost",
      delivery=Step,
      reason="run completed first",
    ),
  ])
  assert_eq(observer.records.map(fn(r) { r.0 }), ["undelivered:cmd_lost:step"])
}

///|
async test "projection: superseded call closes as abandoned, not rejected" {
  let observer = ProjectionObserver::{ records: [], events: [], }
  let no_dispatcher : Ref[@chunk_dispatch.ChunkDispatcher?] = Ref(None)
  let events = @event_runtime.EventRuntime()
  match events.register_observers([observer as &@port.Observer]) {
    Ok(_) => ()
    Err(error) => fail("register_observers failed: \{repr(error)}")
  }
  let projection = EventProjection(events, no_dispatcher)
  let subscriber : &@puppetry.EventSubscriber = projection
  let call = projection_call("call_superseded")
  subscriber.on_event(
    projection_envelope(
      ToolBatchStarted(model_step_id=@kernel_exec.ModelStepId::first(), calls=[
        call,
      ]),
    ),
  )
  subscriber.on_event(
    projection_envelope(
      ToolCompleted(
        call~,
        outcome=NotExecuted(
          reason=SupersededByMessage,
          original_call_id=call.call_id,
        ),
        parent_effect_id=None,
      ),
    ),
  )
  // Supersession is not a decision about the call: it closes as an
  // abandonment naming the cause, the same shape a drain produces.
  assert_eq(observer.events, [
    ToolCallPending(call),
    ToolCallAbandoned(call~, reason="superseded by message"),
  ])
  // The correlation cache is already clean, so the terminal drain stays
  // silent instead of emitting a second closure for the same call.
  subscriber.on_event(
    projection_envelope(
      RunCompleted(final_message_summary="done", model_steps=1, tool_calls=1),
    ),
  )
  assert_eq(observer.events.length(), 2)
}

///|
async test "projection: other not-executed reasons stay rejections" {
  let observer = ProjectionObserver::{ records: [], events: [], }
  let subscriber = projection_with(observer)
  let call = projection_call("call_unknown")
  subscriber.on_event(
    projection_envelope(
      ToolBatchStarted(model_step_id=@kernel_exec.ModelStepId::first(), calls=[
        call,
      ]),
    ),
  )
  subscriber.on_event(
    projection_envelope(
      ToolCompleted(
        call~,
        outcome=NotExecuted(reason=UnknownTool, original_call_id=call.call_id),
        parent_effect_id=None,
      ),
    ),
  )
  assert_eq(observer.events, [
    ToolCallPending(call),
    ToolCallRejected(call~, reason=UnknownTool),
  ])
}
