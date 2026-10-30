///|
pub fn build_tool_result_message(
  call : @kernel.ToolCall,
  result : @kernel.ToolOutcome,
) -> @kernel.Message {
  let content : String = match result {
    Success(content~, ..) => content
    SuccessWithAttachments(content~, ..) => content
    ToolReportedError(content~, ..) => content
    RuntimeFailure(message~, ..) => message
    NotExecuted(reason~, ..) => reason.to_string()
  }
  ToolMessage(
    call_id=call.call_id,
    tool_name=call.name,
    outcome=Success(content~, structured=None),
  )
}

///|
pub fn build_error_message(
  call : @kernel.ToolCall,
  error : @error.RuntimeError,
) -> @kernel.Message {
  ToolMessage(
    call_id=call.call_id,
    tool_name=call.name,
    outcome=RuntimeFailure(
      error_category="RuntimeError",
      message=error.to_string(),
    ),
  )
}

///|
pub(all) struct NoopLifecycle {}

///|
pub extend NoopLifecycle with @port.Lifecycle::{
  on_compose,
  on_shutdown,
  on_start,
}

///|
pub impl @port.Lifecycle for NoopLifecycle

///|
/// No-op CommandPort: declares no commands, invoke always raises NotFound.
/// Useful as a default or for testing.
pub(all) struct NoopCommandPort {}

///|
pub impl @port.CommandPort for NoopCommandPort with fn commands(_self) -> Array[
  @port.CommandDef,
] {
  []
}

///|
pub impl @port.CommandPort for NoopCommandPort with fn invoke(
  _self,
  id : String,
  _args : Json,
) -> @port.CommandOutcome raise @error.CommandError {
  raise NotFound(id)
}
