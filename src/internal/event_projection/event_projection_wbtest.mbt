///|
/// Pairing and drain tests for the committed-envelope projection. They drive
/// the subscriber through its `EventSubscriber` surface only; the pending-call
/// cache stays private.

///|
/// Observer double recording the tag of every projected turn event plus the
/// scope it arrived with.
priv struct ProjectionObserver {
  records : Array[(String, @types.EventScope?)]
}

///|
impl @port.Observer for ProjectionObserver with fn on_event(
  self,
  scope,
  event : @types.TurnEvent,
) -> Unit {
  self.records.push((projection_event_tag(event), scope))
}

///|
fn projection_event_tag(event : @types.TurnEvent) -> String {
  match event {
    ToolCallPending(_) => "pending"
    ToolCallStarted(..) => "started"
    ToolCallSucceeded(..) => "succeeded"
    ToolCallRejected(..) => "rejected"
    ToolCallAbandoned(call~, ..) => "abandoned:" + call.call_id.to_string()
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
  let projection = EventProjection([observer], no_dispatcher)
  projection as &@puppetry.EventSubscriber
}

///|
async test "projection: completion pairs with the committed pending call" {
  let observer = ProjectionObserver::{ records: [], }
  let subscriber = projection_with(observer)
  let first = projection_call("call_a")
  let second = projection_call("call_b")
  let batch : @kernel_exec.KernelEvent = ToolBatchStarted(
    model_step_id=@kernel_exec.ModelStepId::first(),
    calls=[first, second],
  )
  subscriber.on_event(projection_envelope(batch))
  subscriber.on_event(
    projection_envelope(
      ToolCompleted(
        call=first,
        outcome=projection_ok_outcome(),
        parent_effect_id=None,
      ),
    ),
  )
  assert_eq(observer.records.map(fn(r) { r.0 }), [
    "pending", "pending", "succeeded",
  ])
}

///|
async test "projection: terminal drain abandons only unpaired calls, once" {
  let observer = ProjectionObserver::{ records: [], }
  let no_dispatcher : Ref[@chunk_dispatch.ChunkDispatcher?] = Ref(None)
  let projection = EventProjection([observer], no_dispatcher)
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
  let observer = ProjectionObserver::{ records: [], }
  let no_dispatcher : Ref[@chunk_dispatch.ChunkDispatcher?] = Ref(None)
  let projection = EventProjection([observer], no_dispatcher)
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
