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
  match stage {
    AfterTurn(_)
    | AfterModel(_)
    | AfterTool(_, _)
    | TurnError(_)
    | ModelError(_)
    | ToolError(_, _) => {
      let mut last_err : HookError? = None
      let mut i = self.hooks.length() - 1
      while i >= 0 {
        match self.hooks[i].on_stage(current_stage) {
          Ok(s) => current_stage = s
          Err(e) => last_err = Some(e)
        }
        i -= 1
      }
      match last_err {
        Some(e) => Err(e)
        None => Ok(current_stage)
      }
    }
    _ => {
      for hook in self.hooks {
        match hook.on_stage(current_stage) {
          Ok(s) => current_stage = s
          Err(e) => return Err(e)
        }
      }
      Ok(current_stage)
    }
  }
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
    reasoning_content: None,
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
    reasoning_content: None,
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

///|
/// No-op CommandPort: declares no commands, invoke always raises NotFound.
/// Useful as a default or for testing.
pub(all) struct NoopCommandPort {}

///|
pub impl CommandPort for NoopCommandPort with fn commands(_self) -> Array[
  CommandDef,
] {
  []
}

///|
pub impl CommandPort for NoopCommandPort with fn invoke(
  _self,
  id : String,
  _args : Json,
) -> CommandOutcome raise CommandError {
  raise NotFound(id)
}

///|
/// Tokenize a slash argument string into words, honoring double-quoted spans.
/// `"a b" c` → ["a b", "c"]. Internal helper for parse_slash_args.
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
/// Coerce a raw string token into the Json value matching the param's ptype.
fn coerce_param(p : CommandParam, raw : String) -> Result[Json, String] {
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
fn find_param(params : Array[CommandParam], name : String) -> CommandParam? {
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
  params : Array[CommandParam],
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
pub fn validate_args(def : CommandDef, args : Json) -> Result[Json, String] {
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
