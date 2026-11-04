///|
/// Observed-subscriber projection of committed Puppet envelopes into the
/// SessionPort checkpoint stream. It owns nothing else: no transcript scan, no
/// full-save path, no pending-output retry. The shared persisted-prefix
/// bookkeeping (`SessionProgress`) stays Agent-owned and is passed in, because
/// the terminal/full-save path advances the same cursors with absolute
/// positions.

///|
/// Correctness-critical persistence projection for committed model/tool facts.
/// Agent checkpoints the admitted input before Puppet starts; this subscriber
/// then awaits SessionPort checkpoints after each committed assistant/tool
/// boundary. A transcript rewrite marks the session dirty and pauses
/// incremental projection until the terminal full save re-establishes a
/// canonical prefix.
pub struct SessionCheckpointSubscriber {
  priv stores : Array[&@port.SessionPort]
  priv progress : @session_state.SessionProgress
}

///|
pub fn SessionCheckpointSubscriber::SessionCheckpointSubscriber(
  stores : Array[&@port.SessionPort],
  progress : @session_state.SessionProgress,
) -> SessionCheckpointSubscriber {
  { stores, progress, }
}

///|
pub extend SessionCheckpointSubscriber with @puppetry.EventSubscriber::{
  on_event,
  provenance,
  subscriber_id,
}

///|
pub impl @puppetry.EventSubscriber for SessionCheckpointSubscriber with fn subscriber_id(
  _self : SessionCheckpointSubscriber,
) -> String {
  "agent_session_checkpoint"
}

///|
pub impl @puppetry.EventSubscriber for SessionCheckpointSubscriber with fn provenance(
  _self : SessionCheckpointSubscriber,
) -> String {
  "posoco.agent.session"
}

///|
async fn SessionCheckpointSubscriber::append_committed_message(
  self : SessionCheckpointSubscriber,
  session_id : String,
  message : @kernel.Message,
) -> Unit raise @puppetry.SubscriberError {
  if self.stores.is_empty() {
    return
  }
  let cursor = self.progress.cursor_or_zero(session_id)
  let results : Array[Result[Unit, @error.SessionError]] = @async.all(
    self.stores.map(fn(store) {
      () => {
        let checkpoint : @port.SessionCheckpoint = {
          from_index: cursor,
          messages: [@message_snapshot.snapshot_message(message)],
          metadata: None,
        }
        Ok(store.checkpoint(session_id, checkpoint)) catch {
          error => Err(error)
        }
      }
    }),
  ) catch {
    error =>
      raise @puppetry.SubscriberError::Internal(
        subscriber_id="agent_session_checkpoint",
        detail="checkpoint dispatch failed: " + error.to_string(),
      )
  }
  for result in results {
    match result {
      Ok(_) => ()
      Err(error) =>
        raise @puppetry.SubscriberError::Internal(
          subscriber_id="agent_session_checkpoint",
          detail="session_id=" +
            @diagnostic.safe_error_label(session_id) +
            "; " +
            error.to_string(),
        )
    }
  }
  self.progress.advance_one(session_id)
}

///|
pub impl @puppetry.EventSubscriber for SessionCheckpointSubscriber with fn on_event(
  self : SessionCheckpointSubscriber,
  envelope : @puppetry.EventEnvelope,
) -> Unit raise @puppetry.SubscriberError {
  let session_id = envelope.session_id().to_string()
  match envelope.event() {
    RunStarted(..) => ()
    TranscriptRewritten(..) => self.progress.mark_dirty(session_id)
    // A steer message enters the transcript as a committed fact, so it must be
    // appended incrementally or the session store silently lags the core fact.
    UserMessageAppended(message~, ..) =>
      if !self.progress.is_dirty(session_id) {
        self.append_committed_message(session_id, message)
      }
    ModelStepCompleted(completion~, ..) => {
      let payload = completion.message
      let message : @kernel.Message = AssistantMessage(
        content=payload.content,
        tool_calls=payload.tool_calls,
        reasoning=payload.reasoning,
        finish_reason=payload.finish_reason,
      )
      if !self.progress.is_dirty(session_id) {
        self.append_committed_message(session_id, message)
      }
    }
    ToolCompleted(call~, outcome~, parent_effect_id=None) => {
      let message : @kernel.Message = ToolMessage(
        call_id=call.call_id,
        tool_name=call.name,
        outcome~,
      )
      if !self.progress.is_dirty(session_id) {
        self.append_committed_message(session_id, message)
      }
    }
    ToolCallsPreRejected(calls~, outcomes~, ..) => {
      // Pre-pass rejects are reducer-transcript facts (NotExecuted tool
      // messages); mirror them exactly like folded completions. Build the
      // whole batch first so one event sequence covers all its messages.
      let messages : Array[@kernel.Message] = []
      for i in 0..<calls.length() {
        messages.push(
          ToolMessage(
            call_id=calls[i].call_id,
            tool_name=calls[i].name,
            outcome=outcomes[i],
          ),
        )
      }
      if !self.progress.is_dirty(session_id) {
        for message in messages {
          self.append_committed_message(session_id, message)
        }
      }
    }
    _ => ()
  }
}
