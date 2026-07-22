///|
/// Unified tool interface: declare tools via list_tools(), execute via execute().
pub(open) trait ToolProvider {
  fn list_tools(Self) -> Array[@types.ToolDef]
  async fn execute(Self, name : String, call : @types.ToolCall) -> @types.ToolResult raise @error.RuntimeError
}
