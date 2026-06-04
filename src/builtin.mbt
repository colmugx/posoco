///|
/// NoopCompressor — always returns CompressAction::None, never compresses.
pub(all) struct NoopCompressor {}

///|
/// Default implementation of ModelPort::chat_streaming — falls back to chat(),
/// ignoring the on_chunk callback. Non-streaming adapters use this automatically.
impl ModelPort with fn chat_streaming(
  self : Self,
  messages : Array[Message],
  tools : Array[ToolDef],
  options : ChatOptions,
  _on_chunk : (StreamChunk) -> Unit,
) -> ModelResponse raise ModelError {
  self.chat(messages, tools, options)
}

///|
pub impl Compressor for NoopCompressor with fn compress(
  _self,
  _messages : Array[Message],
  _ctx : CompressContext,
) -> CompressAction {
  None
}

///|
/// NoopHook — passes every stage through unchanged.
pub(all) struct NoopHook {}

///|
pub impl PipelineHook for NoopHook with fn on_stage(_self, stage : Stage) -> Result[
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
pub impl PipelineHook for HookChain with fn on_stage(self, stage : Stage) -> Result[
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
    role: Tool,
    content: [Text(result.content)],
    tool_calls: [],
    tool_call_id: Some(call.id),
    name: Some(call.name),
  }
}

///|
/// Build a Tool-role error Message from a ToolCall and RuntimeError.
pub fn build_error_message(call : ToolCall, error : RuntimeError) -> Message {
  {
    role: Tool,
    content: [Text(error.to_string())],
    tool_calls: [],
    tool_call_id: Some(call.id),
    name: Some(call.name),
  }
}

///|
/// CompositeToolProvider — merges multiple ToolProviders
pub(all) struct CompositeToolProvider {
  providers : Array[&ToolProvider]
}

///|
pub impl ToolProvider for CompositeToolProvider with fn list_tools(self) {
  let all : Array[ToolDef] = []
  for p in self.providers {
    for t in p.list_tools() {
      all.push(t)
    }
  }
  all
}

///|
/// ToolRegistry — dynamic runtime tool registration
pub(all) struct ToolRegistry {
  mut tools : Map[String, ToolDef]
}

///|
pub fn ToolRegistry::new() -> ToolRegistry {
  { tools: Map::from_array([]) }
}

///|
pub fn ToolRegistry::register(self : ToolRegistry, tool : ToolDef) -> Unit {
  self.tools[tool.name] = tool
}

///|
pub fn ToolRegistry::unregister(self : ToolRegistry, name : String) -> Unit {
  self.tools.remove(name)
}

///|
pub impl ToolProvider for ToolRegistry with fn list_tools(self) {
  let all : Array[ToolDef] = []
  for v in self.tools.values() {
    all.push(v)
  }
  all
}

///|
/// NoopMemoryPort — returns empty/error for all operations
pub(all) struct NoopMemoryPort {}

///|
pub impl MemoryPort for NoopMemoryPort with fn store(_self, _entry) -> String raise MemoryError {
  raise Store("not implemented")
}

///|
pub impl MemoryPort for NoopMemoryPort with fn search(_self, _query) -> Array[
  MemoryEntry,
] raise MemoryError {
  raise Search("not implemented")
}

///|
pub impl MemoryPort for NoopMemoryPort with fn delete(_self, _id) -> Unit raise MemoryError {
  raise Delete("not implemented")
}

///|
/// NoopLifecycle — no-op shutdown, for components that hold no resources.
pub(all) struct NoopLifecycle {}

///|
pub impl Lifecycle for NoopLifecycle with fn on_shutdown(_self) -> Unit {
  ()
}

///|
/// CompositeToolRuntime — routes tool calls to the correct runtime via
/// Map-based O(1) lookup.
///
/// Each `(ToolProvider, ToolRuntime)` pair is registered via `add()`.
/// The provider's `list_tools()` populates an internal routing map.
/// `execute()` looks up the tool name in the map — no error-based routing.
pub(all) struct CompositeToolRuntime {
  tool_map : Map[String, &ToolRuntime]
  runtimes : Array[&ToolRuntime]
  collisions : Array[String]
}

///|
pub fn CompositeToolRuntime::new() -> CompositeToolRuntime {
  { tool_map: Map::from_array([]), runtimes: [], collisions: [] }
}

///|
/// Register a (provider, runtime) pair. The provider's `list_tools()` is
/// called to populate the routing map. Tool name collisions are recorded
/// for later validation via `validate()`.
pub async fn CompositeToolRuntime::add(
  self : CompositeToolRuntime,
  provider : &ToolProvider,
  runtime : &ToolRuntime,
) -> Unit {
  self.runtimes.push(runtime)
  let tools = provider.list_tools() catch { _ => return () }
  for tool in tools {
    if self.tool_map.contains(tool.name) {
      self.collisions.push(
        "Tool '\{tool.name}' already registered; overwritten by new provider",
      )
    }
    self.tool_map[tool.name] = runtime
  }
}

///|
/// Returns collision warnings from all `add()` calls.
/// Empty array means no collisions. Caller may raise or warn.
pub fn CompositeToolRuntime::validate(
  self : CompositeToolRuntime,
) -> Array[String] {
  self.collisions.copy()
}

///|
pub impl ToolRuntime for CompositeToolRuntime with fn execute(
  self,
  name : String,
  call : ToolCall,
) -> ToolResult raise RuntimeError {
  match self.tool_map.get(name) {
    Some(runtime) => runtime.execute(name, call)
    None =>
      raise RuntimeError::UnknownTool(
        "No runtime registered for tool '\{name}'",
      )
  }
}
