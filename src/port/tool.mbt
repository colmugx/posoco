///|
/// `ToolProvider`: declare tools via `list_tools()`, execute via `execute()`.
///
/// R3 M3.7: signatures use canonical kernel types directly. `ToolDef` carries
/// owner + policy at the catalog level; `list_tools` returns the kernel
/// `ToolDef` minus those (they are filled in by the catalog builder, since
/// they depend on the agent's tool-routing configuration, not on the tool
/// itself). `execute` returns `ToolOutcome` so business errors, runtime
/// errors, and not-executed cases are all distinguishable without a boolean.
pub(open) trait ToolProvider {
  /// Declare the tools this provider offers. The catalog builder augments
  /// each `ToolDef` with owner + execution policy when composing the
  /// snapshot, so providers do not need to fill those fields here. Use
  /// `OwnerId::unchecked("placeholder")` and `Parallel` (the safe default)
  /// — they will be overwritten.
  fn list_tools(Self) -> Array[@kernel.ToolDef]

  /// Execute one tool call. The provider maps its internal result/error to
  /// `ToolOutcome`: `Success` for normal returns, `ToolReportedError` for
  /// business-level failures the model should see, and let posoco's
  /// catch-all convert raised `RuntimeError` to `RuntimeFailure`.
  async fn execute(Self, name : String, call : @kernel.ToolCall) -> @kernel.ToolOutcome raise @error.RuntimeError
}
