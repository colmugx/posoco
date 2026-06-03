///|
/// NoopCompressor — always returns CompressAction::None, never compresses.
pub(all) struct NoopCompressor {}

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
