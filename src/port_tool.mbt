///|
/// Unified tool interface: declare tools via list_tools(), execute via execute().
pub(open) trait ToolProvider {
  fn list_tools(Self) -> Array[ToolDef]
  async fn execute(Self, name : String, call : ToolCall) -> ToolResult raise RuntimeError
}
