///|
pub(all) enum HookError {
  Aborted(String)
  Deferred(reason~ : String)
} derive(Eq, Debug)

///|
pub impl Show for HookError with fn to_string(self) -> String {
  match self {
    Aborted(msg) => "HookError::Aborted(\{msg})"
    Deferred(reason~) => "HookError::Deferred(\{reason})"
  }
}

///|
/// Pipeline hook stages. The `Before*` variants run hooks in forward order
/// (short-circuit on error); the `After*`/`*Error` variants run in reverse
/// order (onion semantics) without short-circuiting (finally semantics).
pub(all) enum Stage {
  BeforeTurn
  BeforeModel(Array[@types.Message])
  AfterModel(@types.ModelResponse)
  ModelError(String)
  BeforeTool(@types.ToolCall)
  AfterTool(@types.ToolCall, @types.ToolResult)
  ToolError(@types.ToolCall, @error.RuntimeError)
  AfterTurn(@types.TurnResult)
  TurnError(@error.AgentError)
} derive(Debug)

///|
/// Pipeline hook: observe or mutate stages before/after each phase.
/// `Before*` stages may rewrite or abort; `After*`/`*Error` stages run under
/// finally semantics (always invoked) in reverse hook order.
pub(open) trait PipelineHook {
  async fn on_stage(Self, stage : Stage) -> Result[Stage, HookError]
}
