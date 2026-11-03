///|
/// Conformance testkit for Posoco.
///
/// Scripted, recording fakes that let tests assert behavior contracts
/// (event order, metadata fidelity, tool-outcome consistency) rather than
/// implementation details: they record call order, arguments, and metadata
/// snapshots, and fail loudly when a script is exhausted.

///|
/// Deep-copy a `@kernel.ToolDef`.
pub fn snapshot_tool_def(tool : @kernel.ToolDef) -> @kernel.ToolDef {
  @kernel.ToolDef(
    name=tool.name,
    description=tool.description,
    input_schema=@message_snapshot.snapshot_json(tool.input_schema),
    owner=tool.owner,
    policy=tool.policy,
    provenance=tool.provenance,
    exposure=tool.exposure,
  )
}

///|
fn snapshot_completion(completion : @kernel.Completion) -> @kernel.Completion {
  let msg = completion.message
  @kernel.Completion(
    content=msg.content.map(@message_snapshot.snapshot_content),
    tool_calls=msg.tool_calls.map(@message_snapshot.snapshot_tool_call),
    reasoning=msg.reasoning,
    finish_reason=msg.finish_reason,
    usage=completion.usage,
  )
}

///|
fn snapshot_model_call_result(
  result : @kernel.ModelCallResult,
) -> @kernel.ModelCallResult {
  {
    completion: snapshot_completion(result.completion),
    processed_messages: @message_snapshot.snapshot_messages(
      result.processed_messages,
    ),
  }
}
