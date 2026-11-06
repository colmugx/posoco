///|
fn snapshot_opt_json(value : Json?) -> Json? {
  match value {
    Some(j) => Some(@message_snapshot.snapshot_json(j))
    None => None
  }
}

///|
fn snapshot_tool_failure(failure : @kernel.ToolFailure) -> @kernel.ToolFailure {
  match failure {
    ReportedError(content~, structured~) =>
      ReportedError(content~, structured=snapshot_opt_json(structured))
    Runtime(category~, message~) => Runtime(category~, message~)
  }
}

///|
/// Deep-copy one observer event. Tool calls/messages use the shared message
/// snapshot layer; the payload-free and scalar-only variants pass through.
pub fn snapshot_turn_event(event : @types.TurnEvent) -> @types.TurnEvent {
  match event {
    TurnStarted => TurnStarted
    ModelRequestStarted => ModelRequestStarted
    ToolChildDeclared(..) => event
    ToolCatalogChanged(..) => event
    ToolCallPending(call) =>
      ToolCallPending(@message_snapshot.snapshot_tool_call(call))
    ToolCallApproved(call~, consent_scope~) =>
      ToolCallApproved(
        call=@message_snapshot.snapshot_tool_call(call),
        consent_scope~,
      )
    ToolCallStarted(call~) =>
      ToolCallStarted(call=@message_snapshot.snapshot_tool_call(call))
    ToolCallSucceeded(call~, content~, structured~, attachments~) =>
      ToolCallSucceeded(
        call=@message_snapshot.snapshot_tool_call(call),
        content~,
        structured=snapshot_opt_json(structured),
        attachments=attachments.copy(),
      )
    ToolCallFailed(call~, failure~) =>
      ToolCallFailed(
        call=@message_snapshot.snapshot_tool_call(call),
        failure=snapshot_tool_failure(failure),
      )
    ToolCallRejected(call~, reason~) =>
      ToolCallRejected(call=@message_snapshot.snapshot_tool_call(call), reason~)
    ToolCallAbandoned(call~, reason~) =>
      ToolCallAbandoned(
        call=@message_snapshot.snapshot_tool_call(call),
        reason~,
      )
    ModelResponseReceived(message~, usage~) =>
      ModelResponseReceived(
        message=@message_snapshot.snapshot_message(message),
        usage~,
      )
    SessionRedirect(from~, to~, messages_before~, messages_after~) =>
      SessionRedirect(from~, to~, messages_before~, messages_after~)
    TurnCompleted => TurnCompleted
    TurnFailed(reason) => TurnFailed(reason)
    TurnCancelled => TurnCancelled
    StreamChunkReceived(chunk~) => StreamChunkReceived(chunk~)
    StreamChunksDropped(count~) => StreamChunksDropped(count~)
    ConfigWarning(field~, value~, reason~) =>
      ConfigWarning(field~, value~, reason~)
    ConfigChanged(field~, old_value~, new_value~) =>
      ConfigChanged(field~, old_value~, new_value~)
    ContextStateUpdated(state~) => ContextStateUpdated(state~)
    CompactStarted(trigger~) => CompactStarted(trigger~)
    CompactFinished(trigger~, mode~, final_session_id~, messages_after~) =>
      CompactFinished(trigger~, mode~, final_session_id~, messages_after~)
    OperationFinalized(operation~, outcome~, detail~) =>
      OperationFinalized(operation~, outcome~, detail~)
    Custom(source~, label~, data~) =>
      Custom(source~, label~, data=@message_snapshot.snapshot_json(data))
    UserRequestStarted(kind~, prompt~) =>
      UserRequestStarted(kind~, prompt=@diagnostic.safe_error_label(prompt))
    UserRequestFinished(kind~, outcome~) => UserRequestFinished(kind~, outcome~)
    MessageApplied(command_id~, delivery~) =>
      MessageApplied(command_id~, delivery~)
    MessageUndelivered(command_id~, delivery~, reason~) =>
      MessageUndelivered(command_id~, delivery~, reason~)
  }
}
