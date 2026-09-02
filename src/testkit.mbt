///|
/// Conformance testkit for Posoco (M0-T04).
///
/// Scripted, recording fakes that let tests assert behavior contracts
/// (event order, metadata fidelity, tool-outcome consistency) rather than
/// implementation details. Distinct from the minimal Mock* types used by the
/// blackbox tests: the testkit records call order, arguments, and metadata
/// snapshots, and fails loudly when a script is exhausted.
///
/// R3 M3.7: all fixtures use canonical kernel types directly. There is no
/// legacy `@types.Message` / `ModelResponse` / `ToolResult` surface any more.
///
/// The testkit is a test/support layer only — it never enters the production
/// Agent dependency direction.

// ---------------------------------------------------------------------------
// Snapshot helpers — deep-copy plumbing shared by the recording fakes.
// The kernel-level copiers (snapshot_json/tool_call/message/...) live in
// agent.mbt; only testkit-specific shapes remain here.
// ---------------------------------------------------------------------------

///|
/// Deep-copy a `@kernel.ToolDef`.
fn testkit_snapshot_tool_def(tool : @kernel.ToolDef) -> @kernel.ToolDef {
  ToolDef(
    name=tool.name,
    description=tool.description,
    input_schema=snapshot_json(tool.input_schema),
    owner=tool.owner,
    policy=tool.policy,
    provenance=tool.provenance,
  )
}

///|
fn testkit_snapshot_completion(
  completion : @kernel.Completion,
) -> @kernel.Completion {
  let msg = completion.message
  Completion(
    content=msg.content.map(snapshot_content),
    tool_calls=msg.tool_calls.map(snapshot_tool_call),
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
    processed_messages: snapshot_messages(result.processed_messages),
  }
}

///|
/// Testkit-specific event copier. Unlike `snapshot_turn_event` (agent.mbt),
/// this preserves a recorded `ToolCallResult`'s `is_error` verbatim instead
/// of recomputing it from `result.is_failure()`: the observer must snapshot
/// what it actually saw, even if some emitter disagreed with the result.
fn testkit_snapshot_event(event : @types.TurnEvent) -> @types.TurnEvent {
  match event {
    TurnStarted => TurnStarted
    ToolCallPending(call) => ToolCallPending(snapshot_tool_call(call))
    ToolCallResult(call~, result~, is_error~) =>
      ToolCallResult(
        call=snapshot_tool_call(call),
        result=snapshot_tool_outcome(result),
        is_error~,
      )
    ModelResponseReceived(message~, usage~) =>
      ModelResponseReceived(message=snapshot_message(message), usage~)
    SessionRedirect(from~, to~, messages_before~, messages_after~) =>
      SessionRedirect(from~, to~, messages_before~, messages_after~)
    TurnCompleted => TurnCompleted
    TurnFailed(reason) => TurnFailed(reason)
    ToolCallDeferred(call~, reason~) =>
      ToolCallDeferred(call=snapshot_tool_call(call), reason~)
    StreamChunkReceived(chunk~) => StreamChunkReceived(chunk~)
    StreamChunksDropped(count~) => StreamChunksDropped(count~)
    ConfigWarning(field~, value~, reason~) =>
      ConfigWarning(field~, value~, reason~)
    ConfigChanged(field~, old_value~, new_value~) =>
      ConfigChanged(field~, old_value~, new_value~)
    Custom(source~, label~, data~) =>
      Custom(source~, label~, data=snapshot_json(data))
  }
}
