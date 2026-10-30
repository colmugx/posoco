///|
using @error {type RuntimeError}

///|
/// Dynamic runtime tool registration. Implements ToolProvider.
pub(all) struct ToolRegistry {
  mut tools : Map[String, @kernel.ToolDef]
  mut executors : Map[String, (@port.ToolCallContext) -> @kernel.ToolOutcome]
}

///|
pub fn ToolRegistry::ToolRegistry() -> ToolRegistry {
  { tools: Map::from_array([]), executors: Map::from_array([]), }
}

///|
/// Register (or deliberately replace) a tool at runtime. Re-registering an
/// existing name overwrites both the definition and the executor — that is
/// intentional hot-replacement semantics for dynamic registries. Callers
/// that did NOT mean to replace should use `register_strict`, which fails
/// fast on a name collision instead of silently shadowing the prior tool.
pub fn ToolRegistry::register(
  self : ToolRegistry,
  tool : @kernel.ToolDef,
  executor : (@port.ToolCallContext) -> @kernel.ToolOutcome,
) -> Unit {
  self.tools[tool.name.to_string()] = tool
  self.executors[tool.name.to_string()] = executor
}

///|
/// Register a tool, failing fast with `RuntimeError::ToolAlreadyRegistered`
/// when the name is already taken. This mirrors the composition-time rule
/// (M0-T06-B): a name collision is never silently resolved by last-wins.
pub fn ToolRegistry::register_strict(
  self : ToolRegistry,
  tool : @kernel.ToolDef,
  executor : (@port.ToolCallContext) -> @kernel.ToolOutcome,
) -> Unit raise @error.RuntimeError {
  let key = tool.name.to_string()
  if self.tools.contains(key) {
    raise ToolAlreadyRegistered("tool '\{key}' is already registered")
  }
  self.tools[key] = tool
  self.executors[key] = executor
}

///|
pub fn ToolRegistry::unregister(self : ToolRegistry, name : String) -> Unit {
  self.tools.remove(name)
  self.executors.remove(name)
}

///|
pub extend ToolRegistry with @port.ToolProvider::{execute, list_tools}

///|
pub impl @port.ToolProvider for ToolRegistry with fn list_tools(self) {
  let all : Array[@kernel.ToolDef] = []
  for v in self.tools.values() {
    all.push(v)
  }
  all
}

///|
pub impl @port.ToolProvider for ToolRegistry with fn execute(
  self,
  ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  let name = ctx.name.to_string()
  match self.executors.get(name) {
    Some(exec) => exec(ctx)
    None => raise UnknownTool("No executor registered for tool '\{name}'")
  }
}
