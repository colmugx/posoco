///|
/// Conformance testkit for Posoco.
///
/// Scripted, recording fakes that let tests assert behavior contracts
/// (event order, metadata fidelity, tool-outcome consistency) rather than
/// implementation details. Distinct from the minimal Mock* types used by the
/// blackbox tests: the testkit records call order, arguments, and metadata
/// snapshots, and fails loudly when a script is exhausted.
///
/// All fixtures use canonical kernel types directly; there is no legacy
/// `@types.Message` / `ModelResponse` / `ToolResult` surface.
///
/// The testkit is a test/support layer only — it never enters the production
/// Agent dependency direction.

// The kernel-level copiers (@message_snapshot.snapshot_json/tool_call/message/...) live in
// agent.mbt; only testkit-specific shapes remain here.

///|
/// Deep-copy a `@kernel.ToolDef`.
fn testkit_snapshot_tool_def(tool : @kernel.ToolDef) -> @kernel.ToolDef {
  ToolDef(
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
fn testkit_snapshot_completion(
  completion : @kernel.Completion,
) -> @kernel.Completion {
  let msg = completion.message
  Completion(
    content=msg.content.map(@message_snapshot.snapshot_content),
    tool_calls=msg.tool_calls.map(@message_snapshot.snapshot_tool_call),
    reasoning=msg.reasoning,
    finish_reason=msg.finish_reason,
    usage=completion.usage,
  )
}

///|
fn testkit_snapshot_model_call_result(
  result : @kernel.ModelCallResult,
) -> @kernel.ModelCallResult {
  {
    completion: testkit_snapshot_completion(result.completion),
    processed_messages: @message_snapshot.snapshot_messages(
      result.processed_messages,
    ),
  }
}
