///|
priv struct ScopedDenyHook {}

///|
impl @port.PipelineHook for ScopedDenyHook with fn before_tool(
  _self : ScopedDenyHook,
  _call : @kernel.ToolCall,
) -> @port.ToolDecision {
  @port.ToolDecision::Reject(reason="scoped permission denied")
}

///|
async test "scoped calls enforce canonical schemas and never execute denied tools" {
  let defs : Array[@kernel.ToolDef] = [{
    name: @kernel.ToolName::unchecked("inspect"),
    description: "Inspect",
    input_schema: {
      "type": "object",
      "properties": {"path": {"type": "string"}},
      "required": ["path"],
    },
    owner: @kernel.OwnerId::unchecked("scoped-test"),
    policy: @kernel.ExecutionPolicy::Parallel,
    provenance: None,
  }]
  let recording = @posoco.RecordingToolProvider(
    defs,
    {"inspect": @posoco.ScriptedToolOutcome::OutcomeOk(@kernel.ToolOutcome::Success(
      content="ok", structured=Some({"data": true}),
    ))},
  )
  let dispatcher = @posoco.ScopedToolDispatch(
    [recording as &@port.ToolProvider],
    hooks=[ScopedDenyHook::{} as &@port.PipelineHook],
  )
  let denied = dispatcher.call("inspect", {"path": "a"})
  assert_true(denied is @kernel.ToolOutcome::ToolReportedError(..))
  assert_eq(recording.exec_records().length(), 0)
  let mismatch = dispatcher.call("inspect", {"path": 42})
  assert_true(mismatch is @kernel.ToolOutcome::ToolReportedError(..))
  assert_eq(recording.exec_records().length(), 0)
}

///|
async test "scoped dispatch refuses recursive execution without touching providers" {
  let dispatcher = @posoco.ScopedToolDispatch([])
  let result = dispatcher.call("run_code", {})
  assert_true(result is @kernel.ToolOutcome::ToolReportedError(..))
}
