///|
pub fn build_tool_result_message(
  call : @kernel.ToolCall,
  result : @kernel.ToolOutcome,
) -> @kernel.Message {
  let content : String = match result {
    @kernel.Success(content~, ..) => content
    @kernel.ToolReportedError(content~, ..) => content
    @kernel.RuntimeFailure(message~, ..) => message
    @kernel.NotExecuted(reason~, ..) => reason.to_string()
  }
  @kernel.ToolMessage(
    call_id=call.call_id,
    tool_name=call.name,
    outcome=@kernel.Success(content~, structured=None),
  )
}

///|
pub fn build_error_message(
  call : @kernel.ToolCall,
  error : @error.RuntimeError,
) -> @kernel.Message {
  @kernel.ToolMessage(
    call_id=call.call_id,
    tool_name=call.name,
    outcome=@kernel.RuntimeFailure(
      error_category="RuntimeError",
      message=error.to_string(),
    ),
  )
}

///|
/// Internal: merges multiple providers' tool lists. Agent routes via ToolRouting instead.
pub(all) struct CompositeToolProvider {
  providers : Array[&@port.ToolProvider]
}

///|
pub impl @port.ToolProvider for CompositeToolProvider with fn list_tools(self) {
  let all : Array[@kernel.ToolDef] = []
  for p in self.providers {
    for t in p.list_tools() {
      all.push(t)
    }
  }
  all
}

///|
pub impl @port.ToolProvider for CompositeToolProvider with fn execute(
  _self,
  name : String,
  _call : @kernel.ToolCall,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  raise @error.RuntimeError::UnknownTool(
    "CompositeToolProvider does not route execute(); Agent uses ToolRouting instead. Tool: '\{name}'",
  )
}

///|
/// Dynamic runtime tool registration. Implements ToolProvider.
pub(all) struct ToolRegistry {
  mut tools : Map[String, @kernel.ToolDef]
  mut executors : Map[String, (@kernel.ToolCall) -> @kernel.ToolOutcome]
}

///|
pub fn ToolRegistry::ToolRegistry() -> ToolRegistry {
  { tools: Map::from_array([]), executors: Map::from_array([]) }
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
  executor : (@kernel.ToolCall) -> @kernel.ToolOutcome,
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
  executor : (@kernel.ToolCall) -> @kernel.ToolOutcome,
) -> Unit raise @error.RuntimeError {
  let key = tool.name.to_string()
  if self.tools.contains(key) {
    raise @error.RuntimeError::ToolAlreadyRegistered(
      "tool '\{key}' is already registered",
    )
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
  name : String,
  call : @kernel.ToolCall,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  match self.executors.get(name) {
    Some(exec) => exec(call)
    None =>
      raise @error.RuntimeError::UnknownTool(
        "No executor registered for tool '\{name}'",
      )
  }
}

///|
pub(all) struct NoopMemoryPort {}

///|
pub impl @port.MemoryPort for NoopMemoryPort with fn store(_self, _entry) -> String raise @error.MemoryError {
  raise @error.MemoryError::Store("not implemented")
}

///|
pub impl @port.MemoryPort for NoopMemoryPort with fn search(_self, _query) -> Array[
  @types.MemoryEntry,
] raise @error.MemoryError {
  raise @error.MemoryError::Search("not implemented")
}

///|
pub impl @port.MemoryPort for NoopMemoryPort with fn delete(_self, _id) -> Unit raise @error.MemoryError {
  raise @error.MemoryError::Delete("not implemented")
}

///|
pub(all) struct NoopLifecycle {}

///|
pub impl @port.Lifecycle for NoopLifecycle with fn on_shutdown(_self) -> Unit {
  ()
}

///|
/// No-op CommandPort: declares no commands, invoke always raises NotFound.
/// Useful as a default or for testing.
pub(all) struct NoopCommandPort {}

///|
pub impl @port.CommandPort for NoopCommandPort with fn commands(_self) -> Array[
  @port.CommandDef,
] {
  []
}

///|
pub impl @port.CommandPort for NoopCommandPort with fn invoke(
  _self,
  id : String,
  _args : Json,
) -> @port.CommandOutcome raise @error.CommandError {
  raise @error.CommandError::NotFound(id)
}

///|
/// Tokenize a slash argument string, honoring double-quoted spans.
fn tokenize_args(text : String) -> Array[String] {
  let tokens : Array[String] = []
  let mut current = StringBuilder::new()
  let mut in_quote = false
  for ch in text {
    if ch == '"' {
      in_quote = !in_quote
    } else if ch == ' ' && !in_quote {
      if current.to_string() != "" {
        tokens.push(current.to_string())
        current = StringBuilder::new()
      }
    } else {
      current.write_char(ch)
    }
  }
  let last = current.to_string()
  if last != "" {
    tokens.push(last)
  }
  tokens
}

///|
/// Coerce a string token to Json matching the param's ptype.
fn coerce_param(p : @port.CommandParam, raw : String) -> Result[Json, String] {
  match p.ptype {
    Str => Ok(Json::string(raw))
    Int => {
      let n = @string.parse_int(raw) catch {
        _ => return Err("parameter " + p.name + " expects Int, got: " + raw)
      }
      Ok(Json::number(n.to_double()))
    }
    Bool =>
      match raw {
        "true" | "on" | "yes" => Ok(Json::boolean(true))
        "false" | "off" | "no" => Ok(Json::boolean(false))
        _ => Err("parameter " + p.name + " expects Bool, got: " + raw)
      }
    Strs =>
      Ok(
        Json::array(
          raw.split(",").map(fn(s) { Json::string(s.to_owned()) }).collect(),
        ),
      )
  }
}

///|
/// Split a `key=value` token into (key, value). Returns None if no `=`.
fn split_kv(token : String) -> (String, String)? {
  let bytes = token.to_array()
  let mut i = 0
  while i < bytes.length() {
    if bytes[i] == '=' {
      let key = token[0:i].to_owned()
      let val = token[i + 1:].to_owned()
      return Some((key, val))
    }
    i += 1
  }
  None
}

///|
/// Find a CommandParam by name in an array. Returns None if not found.
fn find_param(
  params : Array[@port.CommandParam],
  name : String,
) -> @port.CommandParam? {
  for p in params {
    if p.name == name {
      return Some(p)
    }
  }
  None
}

///|
/// Parse a slash argument string into a JSON object according to CommandParam
/// definitions. Positional params fill in declaration order; non-positional
/// params expect `key=value` form. Applies defaults for missing optional params.
/// Returns Err with a reason string on type conversion failure or missing
/// required params. Pure function (no IO).
pub fn parse_slash_args(
  text : String,
  params : Array[@port.CommandParam],
) -> Result[Json, String] {
  let tokens = tokenize_args(text)
  let positional_params = params.filter(fn(p) { p.positional })
  let map : Map[String, Json] = Map::from_array([])
  let mut positional_idx = 0
  // First pass: positional params consume tokens in order, key=value fills others
  for token in tokens {
    match split_kv(token) {
      Some((key, val)) =>
        match find_param(params, key) {
          Some(p) =>
            match coerce_param(p, val) {
              Ok(v) => map[key] = v
              Err(e) => return Err(e)
            }
          None => return Err("unknown parameter: " + key)
        }
      None =>
        if positional_idx < positional_params.length() {
          let p = positional_params[positional_idx]
          match coerce_param(p, token) {
            Ok(v) => map[p.name] = v
            Err(e) => return Err(e)
          }
          positional_idx = positional_idx + 1
        }
    }
  }
  // Second pass: apply defaults + check required
  for p in params {
    if !map.contains(p.name) {
      match p.default {
        Some(d) => map[p.name] = d
        None =>
          if p.required {
            return Err("missing required parameter: " + p.name)
          }
      }
    }
  }
  Ok(Json::object(map))
}

///|
/// Validate a JSON object of args against a CommandDef's params.
/// Checks required presence; optional params with no value and no default
/// are omitted (not an error). Returns the (possibly defaulted) args on Ok.
/// Pure function (no IO).
pub fn validate_args(
  def : @port.CommandDef,
  args : Json,
) -> Result[Json, String] {
  let incoming : Map[String, Json] = match args {
    Object(m) => m
    _ => Map::from_array([])
  }
  let out : Map[String, Json] = Map::from_array([])
  for p in def.params {
    if incoming.contains(p.name) {
      out[p.name] = incoming[p.name]
    } else {
      match p.default {
        Some(d) => out[p.name] = d
        None =>
          if p.required {
            return Err("missing required parameter: " + p.name)
          }
      }
    }
  }
  Ok(Json::object(out))
}
