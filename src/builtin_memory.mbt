///|
/// Built-in memory surface: the fixed lead line for the session-opening
/// memory message, the inbound collector behind the Agent's injection step,
/// and the `memory_search` / `memory_add` tool provider built over the
/// aggregated `MemoryPort` sources. Like the other built-in adapters, these
/// live in the root package (not `src/port/`) — concrete adapters, not
/// extension contracts.

///|
/// Fixed lead line core puts in front of the injected memory message — the
/// one piece of memory-specific text core ever produces. Everything past
/// this line is provider content, untouched by core.
pub const MEMORY_INBOUND_LEAD : String =
  #| ## Memory
  #|
  #| The following is memory recalled for this session, for your information. It may be stale or incomplete — verify against the current conversation before relying on it.

///|
/// One provider's inbound read with an optional per-call timeout. Any
/// failure — provider raise or timeout — is reported via `on_failure`
/// (cancellation is not a defect and is not reported) and contributes
/// nothing (`None`).
async fn memory_inbound_one(
  source : String,
  port : &@port.MemoryPort,
  session_id : String,
  request : String,
  timeout_ms : Int?,
  on_failure : (String) -> Unit,
) -> String? {
  let call = async fn() -> String? {
    match timeout_ms {
      Some(n) =>
        @async.with_timeout(n, () => port.inbound(session_id~, request~))
      None => port.inbound(session_id~, request~)
    }
  }
  call() catch {
    @async.TimeoutError => {
      match timeout_ms {
        Some(n) => on_failure("\{source}: timeout after \{n}ms")
        None => ()
      }
      None
    }
    err => {
      if !@async.is_cancellation_error(err) {
        on_failure("\{source}: \{err.to_string()}")
      }
      None
    }
  }
}

///|
/// Fetch inbound memory bodies for every provider concurrently. Failures and
/// timeouts are reported via `on_failure` and swallowed — the session
/// continues without that provider's content. `noraise`: every
/// `MemoryPort::inbound` raise is caught locally, so the injection step it
/// feeds never widens its raise set. Results stay in provider-registration
/// order because `@async.all` returns values in submission order.
async fn collect_memory_inbound(
  sources : Array[(String, &@port.MemoryPort)],
  session_id : String,
  request : String,
  timeout_ms : Int?,
  on_failure : (String) -> Unit,
) -> Array[String] noraise {
  let attempted : Result[Array[String?], Error] = Ok(
    @async.all(
      sources.map(fn(pair) {
        let (source, port) = pair
        () => {
          memory_inbound_one(
            source, port, session_id, request, timeout_ms, on_failure,
          )
        }
      }),
    ),
  ) catch {
    error => Err(error)
  }
  let out : Array[String] = []
  match attempted {
    Ok(results) =>
      for result in results {
        match result {
          Some(body) if body.trim() != "" => out.push(body)
          _ => ()
        }
      }
    Err(_) => () // cancellation: turn is aborting, skip injection
  }
  out
}

///|
/// Assemble the single frozen user message: core's lead line followed by the
/// provider bodies in registration order. Placed before the real first user
/// input; never rewritten, never re-read.
fn memory_inbound_message(bodies : Array[String]) -> @kernel.Message {
  @kernel.UserMessage(content=[
    @kernel.Text(MEMORY_INBOUND_LEAD + "\n\n" + bodies.join("\n\n")),
  ])
}

///|
/// JSON-schema fragment for one tool argument: `{"type": <t>}`.
fn memory_arg_schema(ty : String) -> Json {
  Json::object(Map::from_array([("type", Json::string(ty))]))
}

///|
fn memory_search_schema() -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map::from_array([
            ("query", memory_arg_schema("string")),
            ("top_k", memory_arg_schema("integer")),
          ]),
        ),
      ),
      ("required", Json::array([Json::string("query")])),
    ]),
  )
}

///|
fn memory_add_schema() -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map::from_array([
            ("content", memory_arg_schema("string")),
            ("source", memory_arg_schema("string")),
          ]),
        ),
      ),
      ("required", Json::array([Json::string("content")])),
    ]),
  )
}

///|
/// Read a required string argument from a tool call's JSON object args.
/// `Err` carries the model-facing diagnostic.
fn memory_required_string_arg(
  args : Map[String, Json],
  tool : String,
  key : String,
) -> Result[String, String] {
  match args.get(key) {
    Some(Json::String(s)) => Ok(s)
    Some(_) => Err("\{tool}: argument '\{key}' must be a string")
    None => Err("\{tool}: missing required argument '\{key}'")
  }
}

///|
/// Built-in ToolProvider over the aggregated memory sources: exposes
/// `memory_search` / `memory_add` to the model and fans each call out to
/// every matching provider. Provider failures are reported via `on_failure`
/// (the Agent wires it to the `secondary_failure` observer event) and never
/// abort the calling turn.
priv struct MemoryToolProvider {
  sources : Array[(String, &@port.MemoryPort)]
  on_failure : (String) -> Unit
}

///|
fn MemoryToolProvider::MemoryToolProvider(
  sources~ : Array[(String, &@port.MemoryPort)],
  on_failure~ : (String) -> Unit,
) -> MemoryToolProvider {
  { sources, on_failure, }
}

///|
impl @port.ToolProvider for MemoryToolProvider with fn list_tools(
  self : MemoryToolProvider,
) -> Array[@kernel.ToolDef] {
  let valid_sources : Array[String] = []
  for pair in self.sources {
    let (id, _) = pair
    valid_sources.push(id)
  }
  [
    @kernel.ToolDef(
      name=@kernel.ToolName::unchecked("memory_search"),
      description="Search accumulated memory (past work, settled decisions, SOPs) before answering questions it may have settled, and before saving anything new.",
      input_schema=memory_search_schema(),
      owner=@kernel.OwnerId::unchecked("placeholder"),
      policy=@kernel.ExecutionPolicy::Sequential,
      provenance=Some("posoco.core"),
    ),
    @kernel.ToolDef(
      name=@kernel.ToolName::unchecked("memory_add"),
      description="Save a durable memory for future sessions. Omit source to save to every connected memory provider; valid sources: \{valid_sources.join(", ")}",
      input_schema=memory_add_schema(),
      owner=@kernel.OwnerId::unchecked("placeholder"),
      policy=@kernel.ExecutionPolicy::Sequential,
      provenance=Some("posoco.core"),
    ),
  ]
}

///|
async fn MemoryToolProvider::execute_memory_search(
  self : MemoryToolProvider,
  args : Map[String, Json],
) -> @kernel.ToolOutcome noraise {
  let query = match memory_required_string_arg(args, "memory_search", "query") {
    Ok(q) => q
    Err(msg) => return @kernel.ToolReportedError(content=msg, structured=None)
  }
  let top_k : Int? = match args.get("top_k") {
    Some(Json::Number(n, ..)) => Some(n.to_int())
    Some(_) =>
      return @kernel.ToolReportedError(
        content="memory_search: argument 'top_k' must be an integer",
        structured=None,
      )
    None => None
  }
  let searched : Array[(String, String?)] = @async.all(
    self.sources.map(fn(pair) {
      let (source, port) = pair
      () => {
        let text : String? = match top_k {
          Some(k) =>
            port.search(query~, top_k=k) catch {
              err => {
                if !@async.is_cancellation_error(err) {
                  (self.on_failure)(
                    "memory_search \{source}: \{err.to_string()}",
                  )
                }
                None
              }
            }
          None =>
            port.search(query~) catch {
              err => {
                if !@async.is_cancellation_error(err) {
                  (self.on_failure)(
                    "memory_search \{source}: \{err.to_string()}",
                  )
                }
                None
              }
            }
        }
        (source, text)
      }
    }),
  ) catch {
    _ => [] // cancellation: the calling turn is aborting; contribute nothing
  }
  let hits : Array[String] = []
  for pair in searched {
    let (_, text) = pair
    match text {
      Some(body) if body.trim() != "" => hits.push(body)
      _ => ()
    }
  }
  if hits.is_empty() {
    @kernel.Success(content="No matching memory.", structured=None)
  } else {
    @kernel.Success(content=hits.join("\n\n"), structured=None)
  }
}

///|
async fn MemoryToolProvider::execute_memory_add(
  self : MemoryToolProvider,
  args : Map[String, Json],
) -> @kernel.ToolOutcome noraise {
  let content = match
    memory_required_string_arg(args, "memory_add", "content") {
    Ok(c) => c
    Err(msg) => return @kernel.ToolReportedError(content=msg, structured=None)
  }
  if content.trim() == "" {
    return @kernel.ToolReportedError(
      content="memory_add: argument 'content' must be non-empty",
      structured=None,
    )
  }
  let source = match args.get("source") {
    Some(Json::String(s)) => Some(s)
    Some(_) =>
      return @kernel.ToolReportedError(
        content="memory_add: argument 'source' must be a string",
        structured=None,
      )
    None => None
  }
  let targets : Array[(String, &@port.MemoryPort)] = match source {
    Some(id) => {
      let matched : Array[(String, &@port.MemoryPort)] = []
      for pair in self.sources {
        let (mid, port) = pair
        if mid == id {
          matched.push((mid, port))
        }
      }
      if matched.is_empty() {
        let valid : Array[String] = []
        for pair in self.sources {
          let (mid, _) = pair
          valid.push(mid)
        }
        return @kernel.ToolReportedError(
          content="memory_add: unknown source '\{id}'; valid sources: \{valid.join(", ")}",
          structured=None,
        )
      }
      matched
    }
    None => self.sources
  }
  // Concurrent writes; receipt lines stay in registration order because
  // `@async.all` returns values in submission order.
  let receipts : Array[(String, Result[String, String])] = @async.all(
    targets.map(fn(pair) {
      let (source, port) = pair
      () => {
        let outcome : Result[String, String] = Ok(
          port.store(content~, metadata=Map::from_array([])),
        ) catch {
          err => Err(err.to_string())
        }
        (source, outcome)
      }
    }),
  ) catch {
    _ => [] // cancellation: the calling turn is aborting
  }
  let lines : Array[String] = []
  let mut failures = 0
  for pair in receipts {
    let (source, outcome) = pair
    match outcome {
      Ok(ticket) => lines.push("\{source}: \{ticket}")
      Err(reason) => {
        failures = failures + 1
        lines.push("\{source}: failed (\{reason})")
      }
    }
  }
  if failures == targets.length() {
    @kernel.ToolReportedError(content=lines.join("\n"), structured=None)
  } else {
    @kernel.Success(content=lines.join("\n"), structured=None)
  }
}

///|
impl @port.ToolProvider for MemoryToolProvider with fn execute(
  self : MemoryToolProvider,
  name : String,
  call : @kernel.ToolCall,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  let args : Map[String, Json] = match call.arguments {
    Json::Object(fields) => fields
    _ =>
      return @kernel.ToolReportedError(
        content="\{name}: arguments must be a JSON object",
        structured=None,
      )
  }
  match name {
    "memory_search" => self.execute_memory_search(args)
    "memory_add" => self.execute_memory_add(args)
    _ =>
      raise @error.RuntimeError::UnknownTool(
        "No executor registered for tool '\{name}'",
      )
  }
}
