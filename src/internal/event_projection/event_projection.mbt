///|
/// Agent-facing projection of committed Puppet envelopes. It never scans a
/// final transcript: the pending call cache is correlation state populated by
/// `ToolBatchStarted` and consumed by completion events. Committed pending
/// events retain the model's original call; completion events carry the
/// canonical call that reached the host.
priv struct PendingToolProjection {
  call : @kernel.ToolCall
  mut started : Bool
}

///|
/// Observer-side projection of committed Puppet envelopes: the Agent's own
/// event subscriber. The pending-call correlation state and the whole
/// projection algorithm live here and nowhere else; callers only construct
/// one, install it as a subscriber and, when a run ends without folding its
/// tool completions, call `drain_pending`.
pub struct EventProjection {
  priv observers : Array[&@port.Observer]
  priv pending_calls : Map[String, PendingToolProjection]
  priv chunk_dispatcher : Ref[@chunk_dispatch.ChunkDispatcher?]
  /// Late-bound live context-state lookup (session id -> puppet state),
  /// wired after the runtime exists in `AgentRuntime::compose`. `None` (or
  /// a lookup returning `None`) projects nothing.
  priv context_state_of : Ref[((String) -> @types.ContextState?)?]
}

///|
pub fn EventProjection::EventProjection(
  observers : Array[&@port.Observer],
  chunk_dispatcher : Ref[@chunk_dispatch.ChunkDispatcher?],
  context_state_of~ : Ref[((String) -> @types.ContextState?)?] = Ref(None),
) -> EventProjection {
  {
    observers,
    pending_calls: Map::from_array([]),
    chunk_dispatcher,
    context_state_of,
  }
}

///|
pub extend EventProjection with @puppetry.EventSubscriber::{
  on_event,
  provenance,
  subscriber_id,
}

///|
pub impl @puppetry.EventSubscriber for EventProjection with fn subscriber_id(
  _self : EventProjection,
) -> String {
  "agent_committed_event_projection"
}

///|
pub impl @puppetry.EventSubscriber for EventProjection with fn provenance(
  _self : EventProjection,
) -> String {
  "posoco.agent"
}

///|
fn EventProjection::emit(
  self : EventProjection,
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
    observer.on_event(scope, @event_snapshot.snapshot_turn_event(event))
  }
}

///|
fn EventProjection::emit_tool_result(
  self : EventProjection,
  scope : @types.EventScope,
  call : @kernel.ToolCall,
  outcome : @kernel.ToolOutcome,
) -> Unit raise @puppetry.SubscriberError {
  let key = call.call_id.to_string()
  if !self.pending_calls.contains(key) {
    raise ContractViolation(
      subscriber_id="agent_committed_event_projection",
      detail="ToolCompleted without committed ToolBatchStarted for call " + key,
    )
  }
  let started = self.pending_calls[key].started
  self.pending_calls.remove(key)
  if started && outcome is NotExecuted(reason=Revoked, ..) {
    self.emit(
      Some(scope),
      ToolCallAbandoned(
        call~,
        reason="tool version revoked before provider start",
      ),
    )
    return
  }
  // One outcome shape maps to one terminal tool event: success, failure and
  // rejection never share an event.
  let event : @types.TurnEvent = match outcome {
    Success(content~, structured~) =>
      ToolCallSucceeded(call~, content~, structured~, attachments=[])
    SuccessWithAttachments(content~, structured~, attachments~) =>
      ToolCallSucceeded(call~, content~, structured~, attachments~)
    ToolReportedError(content~, structured~) =>
      ToolCallFailed(call~, failure=ReportedError(content~, structured~))
    RuntimeFailure(error_category~, message~) =>
      ToolCallFailed(call~, failure=Runtime(category=error_category, message~))
    NotExecuted(reason~, ..) => ToolCallRejected(call~, reason~)
  }
  self.emit(Some(scope), event)
}

///|
/// Abandon every still-pending call. Used when a run ends without folding
/// their completions (cancel, terminal hook failure, suspension) and
/// defensively when a new run starts over leftovers. With `scope` the drain
/// attributes to the run that owned the calls; `None` marks out-of-run
/// cleanup.
pub fn EventProjection::drain_pending(
  self : EventProjection,
  scope : @types.EventScope?,
  reason : String,
) -> Unit {
  if self.pending_calls.is_empty() {
    return
  }
  for _key, pending in self.pending_calls {
    self.emit(scope, ToolCallAbandoned(call=pending.call, reason~))
  }
  self.pending_calls.clear()
}

///|
pub impl @puppetry.EventSubscriber for EventProjection with fn on_event(
  self : EventProjection,
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
    RunStarted(..) =>
      self.drain_pending(None, "run restarted before completion")
    RunSuspended(..) => self.drain_pending(Some(scope), "run suspended")
    RunCompleted(..) | RunFailed(..) | RunCancelled(..) =>
      // Terminal-only drain: cancelled tool effects still receive their
      // closing ToolCompleted events between CancelRequested and the
      // terminal event, so draining any earlier would break pairing.
      self.drain_pending(Some(scope), "run terminal")
    ToolCallsPreRejected(calls~, outcomes~, ..) =>
      // Pre-pass rejects never entered the pipeline: emit the rejection
      // directly, no pending marker, nothing to drain.
      for i in 0..<calls.length() {
        match outcomes[i] {
          NotExecuted(reason~, ..) =>
            self.emit(Some(scope), ToolCallRejected(call=calls[i], reason~))
          _ =>
            raise ContractViolation(
              subscriber_id="agent_committed_event_projection",
              detail="ToolCallsPreRejected carries a non-NotExecuted outcome",
            )
        }
      }
    ToolChildDeclared(
      effect_id~,
      parent_effect_id~,
      root_effect_id~,
      depth~,
      call~
    ) =>
      self.emit(
        Some(scope),
        ToolChildDeclared(
          call_id=call.call_id,
          effect_id~,
          parent_effect_id~,
          root_effect_id~,
          depth~,
        ),
      )
    ToolChildAbandoned(call~, ..) => {
      let key = call.call_id.to_string()
      if !self.pending_calls.contains(key) {
        raise ContractViolation(
          subscriber_id="agent_committed_event_projection",
          detail="abandoned child without committed declaration",
        )
      }
      self.pending_calls.remove(key)
      self.emit(
        Some(scope),
        ToolCallAbandoned(call~, reason="run cancelled before child completion"),
      )
    }
    ToolCallApproved(model_step_id=_, call~, consent_scope~) =>
      self.emit(Some(scope), ToolCallApproved(call~, consent_scope~))
    ToolWaveStarted(calls~, ..) =>
      for call in calls {
        if self.pending_calls.get(call.call_id.to_string()) is Some(pending) {
          pending.started = true
        }
        self.emit(
          Some(scope),
          ToolCallStarted(call=@message_snapshot.snapshot_tool_call(call)),
        )
      }
    ModelStepStarted(..) => self.emit(Some(scope), ModelRequestStarted)
    ModelStepCompleted(completion~, ..) => {
      let payload = completion.message
      let message : @kernel.Message = AssistantMessage(
        content=payload.content,
        tool_calls=payload.tool_calls,
        reasoning=payload.reasoning,
        finish_reason=payload.finish_reason,
      )
      self.emit(
        Some(scope),
        ModelResponseReceived(message~, usage=completion.usage),
      )
      // The puppet recorded this step's usage into the session's context
      // state before the boundary committed, so the lookup is fresh.
      // Projecting per model step keeps the ctx indicator at the same
      // cadence as cache — every round, not only at turn boundaries.
      match self.context_state_of.val {
        Some(lookup) =>
          match lookup(envelope.session_id().to_string()) {
            Some(state) => self.emit(Some(scope), ContextStateUpdated(state~))
            None => ()
          }
        None => ()
      }
    }
    ToolBatchStarted(calls~, ..) =>
      for call in calls {
        let snapshot = @message_snapshot.snapshot_tool_call(call)
        self.pending_calls[snapshot.call_id.to_string()] = {
          call: snapshot,
          started: false,
        }
        self.emit(Some(scope), ToolCallPending(snapshot))
      }
    ToolCompleted(call~, outcome~, ..) =>
      self.emit_tool_result(scope, call, outcome)
    _ => ()
  }
}
