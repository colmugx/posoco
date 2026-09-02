///|
/// Agent-facing projection of committed Puppet envelopes onto observers,
/// plus the per-turn stream-chunk callback wiring.

///|
/// Agent-facing projection of committed Puppet envelopes. It never scans a
/// final transcript. The pending call cache is correlation state populated by
/// `ToolBatchStarted` and consumed by `ToolCompleted`.
priv struct AgentEventSubscriber {
  observers : Array[&@port.Observer]
  pending_calls : Map[String, @kernel.ToolCall]
  chunk_dispatcher : Ref[ChunkDispatcher?]
}

///|
fn AgentEventSubscriber::AgentEventSubscriber(
  observers : Array[&@port.Observer],
  chunk_dispatcher : Ref[ChunkDispatcher?],
) -> AgentEventSubscriber {
  { observers, pending_calls: Map::from_array([]), chunk_dispatcher, }
}

///|
impl @puppetry.EventSubscriber for AgentEventSubscriber with fn subscriber_id(
  _self : AgentEventSubscriber,
) -> String {
  "agent_committed_event_projection"
}

///|
impl @puppetry.EventSubscriber for AgentEventSubscriber with fn provenance(
  _self : AgentEventSubscriber,
) -> String {
  "posoco.agent"
}

///|
fn AgentEventSubscriber::emit(
  self : AgentEventSubscriber,
  scope : @types.EventScope?,
  event : @types.TurnEvent,
) -> Unit {
  // Piggyback flush: catch up buffered chunk telemetry before every committed
  // event so observers see chunks before ModelResponseReceived, ToolCallPending,
  // etc., and so they catch up at boundaries during an unbroken SSE burst.
  match self.chunk_dispatcher.val {
    Some(dispatcher) => dispatcher.flush()
    None => ()
  }
  for observer in self.observers {
    observer.on_event_at(scope, snapshot_turn_event(event))
  }
}

///|
impl @puppetry.EventSubscriber for AgentEventSubscriber with fn on_event(
  self : AgentEventSubscriber,
  envelope : @puppetry.EventEnvelope,
) -> Unit raise @puppetry.SubscriberError {
  let event = envelope.event()
  // Envelope-projected events always carry the envelope's run identity as
  // their attribution scope.
  let scope : @types.EventScope = {
    session_id: envelope.session_id(),
    run_id: envelope.run_id(),
    turn_id: envelope.turn_id(),
  }
  match event {
    @kernel_exec.RunStarted(..) => self.pending_calls.clear()
    @kernel_exec.ModelStepCompleted(completion~, ..) => {
      let payload = completion.message
      let message : @kernel.Message = @kernel.AssistantMessage(
        content=payload.content,
        tool_calls=payload.tool_calls,
        reasoning=payload.reasoning,
        finish_reason=payload.finish_reason,
      )
      self.emit(
        Some(scope),
        @types.ModelResponseReceived(message~, usage=completion.usage),
      )
    }
    @kernel_exec.ToolBatchStarted(calls~, ..) =>
      for call in calls {
        let snapshot = snapshot_tool_call(call)
        self.pending_calls[snapshot.call_id.to_string()] = snapshot
        self.emit(Some(scope), @types.ToolCallPending(snapshot))
      }
    @kernel_exec.ToolCompleted(call_id~, outcome~) => {
      let key = call_id.to_string()
      let call = match self.pending_calls.get(key) {
        Some(call) => call
        None =>
          raise @puppetry.SubscriberError::ContractViolation(
            subscriber_id="agent_committed_event_projection",
            detail="ToolCompleted without committed ToolBatchStarted for call " +
              key,
          )
      }
      self.pending_calls.remove(key)
      self.emit(Some(scope), @types.TurnEvent::tool_call_result(call, outcome))
    }
    _ => ()
  }
}

///|
/// Wrap the puppet's `HostChunkCallback` so each `StreamChunk` is re-emitted
/// to observers as `StreamChunkReceived`. The chunk is already the canonical
/// typed shape; no JSON decoding is needed here.
fn create_agent_stream_callback(
  observers : Array[&@port.Observer],
  dispatcher_ref : Ref[ChunkDispatcher?],
) -> @kernel_exec.HostChunkCallback? {
  if observers.is_empty() {
    return None
  }
  let cb = fn(chunk : @types.StreamChunk) {
    // Route to the active turn's dispatcher. If no turn is active (should not
    // happen for chunks produced by the Puppet), drop silently.
    match dispatcher_ref.val {
      Some(dispatcher) => dispatcher.enqueue(chunk)
      None => ()
    }
  }
  Some(cb)
}
