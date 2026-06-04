///|
pub(all) struct NoopCompressor {}

///|
/// Default chat_streaming: ignores on_chunk, falls back to chat().
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
pub(all) struct NoopHook {}

///|
pub impl PipelineHook for NoopHook with fn on_stage(_self, stage : Stage) -> Result[
  Stage,
  HookError,
] {
  Ok(stage)
}

///|
/// Internal: chains multiple hooks in sequence.
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
/// Internal: merges multiple providers' tool lists. Agent routes via ToolRouting instead.
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
pub impl ToolProvider for CompositeToolProvider with fn execute(
  _self,
  name : String,
  _call : ToolCall,
) -> ToolResult raise RuntimeError {
  raise RuntimeError::UnknownTool(
    "CompositeToolProvider does not route execute(); Agent uses ToolRouting instead. Tool: '\{name}'",
  )
}

///|
/// Dynamic runtime tool registration. Implements ToolProvider.
pub(all) struct ToolRegistry {
  mut tools : Map[String, ToolDef]
  mut executors : Map[String, (ToolCall) -> ToolResult]
}

///|
pub fn ToolRegistry::new() -> ToolRegistry {
  { tools: Map::from_array([]), executors: Map::from_array([]) }
}

///|
pub fn ToolRegistry::register(
  self : ToolRegistry,
  tool : ToolDef,
  executor : (ToolCall) -> ToolResult,
) -> Unit {
  self.tools[tool.name] = tool
  self.executors[tool.name] = executor
}

///|
pub fn ToolRegistry::unregister(self : ToolRegistry, name : String) -> Unit {
  self.tools.remove(name)
  self.executors.remove(name)
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
pub impl ToolProvider for ToolRegistry with fn execute(
  self,
  name : String,
  call : ToolCall,
) -> ToolResult raise RuntimeError {
  match self.executors.get(name) {
    Some(exec) => exec(call)
    None =>
      raise RuntimeError::UnknownTool(
        "No executor registered for tool '\{name}'",
      )
  }
}

///|
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
pub(all) struct NoopLifecycle {}

///|
pub impl Lifecycle for NoopLifecycle with fn on_shutdown(_self) -> Unit {
  ()
}
