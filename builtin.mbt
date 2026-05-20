///|
/// NoopCompressor — always returns CompressAction::None, never compresses.
pub(all) struct NoopCompressor {}

///|
pub impl Compressor for NoopCompressor with compress(
  _self,
  _messages : Array[Message],
  _ctx : CompressContext,
) -> CompressAction {
  CompressAction::None
}

///|
/// NoopHook — passes every stage through unchanged.
pub(all) struct NoopHook {}

///|
pub impl PipelineHook for NoopHook with on_stage(_self, stage : Stage) -> Result[
  Stage,
  HookError,
] {
  Ok(stage)
}

///|
/// HookChain — applies each registered hook in sequence.
pub(all) struct HookChain {
  hooks : Array[&PipelineHook]
}

///|
pub impl PipelineHook for HookChain with on_stage(self, stage : Stage) -> Result[
  Stage,
  HookError,
] {
  let mut current_stage = stage
  for hook in self.hooks {
    match hook.on_stage(current_stage) {
      Ok(s) => current_stage = s
      Err(e) => return Err(e)
    }
  }
  Ok(current_stage)
}

///|
/// Build a Tool-role Message from a ToolCall and ToolResult.
pub fn build_tool_result_message(
  call : ToolCall,
  result : ToolResult,
) -> Message {
  {
    role: Role::Tool,
    content: [Content::Text(result.content)],
    tool_calls: [],
    tool_call_id: Some(call.id),
    name: Some(call.name),
  }
}

///|
/// Build a Tool-role error Message from a ToolCall and RuntimeError.
pub fn build_error_message(call : ToolCall, error : RuntimeError) -> Message {
  {
    role: Role::Tool,
    content: [Content::Text(error.to_string())],
    tool_calls: [],
    tool_call_id: Some(call.id),
    name: Some(call.name),
  }
}
