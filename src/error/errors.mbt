///|
/// Structured quota/rate-limit verdict returned by a provider. Raised as
/// `ModelError::RateLimited` instead of `Transport` so hosts can schedule
/// recovery from typed data instead of parsing strings. Providers disagree on
/// the carrier (HTTP 429, Kimi's 403, gateway JSON fields, free text), so the
/// verdict deliberately carries no status code — only scheduling semantics.
///
/// `reset_at_ms` is the Unix epoch in milliseconds at which the provider
/// stated the quota window frees; `None` means no explicit reset time was
/// stated, so waiting is not schedulable and the caller should treat the
/// verdict as terminal for this turn. `provider_code` is the provider's own
/// machine code for the verdict when available (for example z.ai `"1308"`,
/// OpenAI `"usage_limit_reached"`). `message` is a bounded excerpt of the
/// provider message, safe to display.
pub(all) struct RateLimitInfo {
  message : String
  reset_at_ms : Int64?
  provider_code : String?
} derive(Eq, Debug)

///|
fn bounded_rate_limit_message(message : String) -> String {
  let chars : Array[Char] = []
  let mut truncated = false
  for char in message {
    if chars.length() >= 120 {
      truncated = true
      break
    }
    match char {
      '\n' | '\r' => chars.push(' ')
      other => chars.push(other)
    }
  }
  let label = String::from_array(chars)
  if truncated {
    label + "…"
  } else {
    label
  }
}

///|
pub(all) suberror ModelError {
  RequestBuild(String)
  Transport(String)
  ResponseParse(String)
  /// The provider answered with a quota/rate-limit verdict instead of
  /// serving the request. Distinct from `Transport` throttles so a host can
  /// decide between waiting for `reset_at_ms` and failing fast.
  RateLimited(RateLimitInfo)
} derive(Debug)

///|
pub impl Show for ModelError with fn to_string(self) -> String {
  match self {
    RequestBuild(msg) => "ModelError::RequestBuild(\{msg})"
    Transport(msg) => "ModelError::Transport(\{msg})"
    ResponseParse(msg) => "ModelError::ResponseParse(\{msg})"
    RateLimited(info) => {
      let code_label = match info.provider_code {
        Some(code) => code
        None => "none"
      }
      let reset_label = match info.reset_at_ms {
        Some(at) => "\{at}"
        None => "none"
      }
      "ModelError::RateLimited(code=\{code_label}, reset_at_ms=\{reset_label}, message=\{bounded_rate_limit_message(info.message)})"
    }
  }
}

///|
pub(all) suberror SessionError {
  Load(String)
  Save(String)
} derive(Debug)

///|
pub impl Show for SessionError with fn to_string(self) -> String {
  match self {
    Load(msg) => "SessionError::Load(\{msg})"
    Save(msg) => "SessionError::Save(\{msg})"
  }
}

///|
pub(all) suberror RuntimeError {
  UnknownTool(String)
  InvocationFailed(String)
  Transport(String)
  /// `ToolRegistry::register_strict` rejected a duplicate tool name.
  ToolAlreadyRegistered(String)
} derive(Debug)

///|
pub impl Show for RuntimeError with fn to_string(self) -> String {
  match self {
    UnknownTool(msg) => "RuntimeError::UnknownTool(\{msg})"
    InvocationFailed(msg) => "RuntimeError::InvocationFailed(\{msg})"
    Transport(msg) => "RuntimeError::Transport(\{msg})"
    ToolAlreadyRegistered(msg) => "RuntimeError::ToolAlreadyRegistered(\{msg})"
  }
}

///|
pub(all) suberror AgentError {
  Model(String)
  Session(SessionError)
  Runtime(RuntimeError)
  /// The kernel tool-round budget rejected a batch. `consumed` is the round
  /// count at rejection (`limit + 1`); `limit` is the configured bound.
  ToolLoopExceeded(consumed~ : Int, limit~ : Int)
  PipelineAborted(String)
} derive(Debug)

///|
pub impl Show for AgentError with fn to_string(self) -> String {
  match self {
    Model(msg) => "AgentError::Model(\{msg})"
    Session(err) => "AgentError::Session(\{err.to_string()})"
    Runtime(err) => "AgentError::Runtime(\{err.to_string()})"
    ToolLoopExceeded(consumed~, limit~) =>
      "AgentError::ToolLoopExceeded(consumed=\{consumed}, limit=\{limit}; raise AgentConfig.max_tool_rounds or set None for unbounded)"
    PipelineAborted(msg) => "AgentError::PipelineAborted(\{msg})"
  }
}

///|
pub(all) suberror MemoryError {
  Store(String)
  Search(String)
  Delete(String)
} derive(Debug)

///|
pub impl Show for MemoryError with fn to_string(self) -> String {
  match self {
    Store(msg) => "MemoryError::Store(\{msg})"
    Search(msg) => "MemoryError::Search(\{msg})"
    Delete(msg) => "MemoryError::Delete(\{msg})"
  }
}

///|
/// Composition errors raised during Agent::new (manifest aggregation failures).
///
/// Every variant that involves a specific extension carries `manifest_id` so
/// callers can locate the offending extension without guessing. Multi-party
/// collisions carry the list of involved manifest ids.
pub(all) suberror CompositionError {
  /// Two extensions declared a tool with the same name. Fail-fast; no
  /// last-wins routing. First arg is the tool name, second is a diagnostic
  /// message, third is the list of manifest ids that declared it.
  ToolCollision(String, String, manifests~ : Array[String])
  /// Two extensions declared a slash command with the same id.
  CommandCollision(String, manifests~ : Array[String])
  /// No extension contributed a ModelPort. Exactly one is required.
  MissingModel
  /// More than one extension contributed a ModelPort. Multi-model routing
  /// must be solved inside a meta-extension (e.g. posoco-ext-llm), not by
  /// declaring multiple top-level models.
  MultipleModels(manifests~ : Array[String])
  /// Empty extension list passed to Agent::new.
  EmptyManifests
  /// An extension manifest was malformed (e.g. empty id, structural issue).
  ManifestSchemaError(manifest_id~ : String, detail~ : String)
  /// Legacy: a required port had zero contributors. Kept for compatibility
  /// with older composition paths that do not use manifests.
  EmptyPort(String)
  /// An extension's `Lifecycle::on_compose` raised, failing the composition
  /// loudly. No partial Agent is produced. Extensions raise this themselves
  /// when a capability they need reads `None` in the `CompositionView`
  /// (typically because it was not declared in `requires`).
  ExtensionComposeFailed(manifest_id~ : String, detail~ : String)
} derive(Debug)

///|
pub impl Show for CompositionError with fn to_string(self) -> String {
  match self {
    ToolCollision(name, msg, manifests~) =>
      "CompositionError::ToolCollision(\{name}: \{msg}; manifests=\{manifests.join(",")})"
    CommandCollision(name, manifests~) =>
      "CompositionError::CommandCollision(\{name}; manifests=\{manifests.join(",")})"
    MissingModel => "CompositionError::MissingModel"
    MultipleModels(manifests~) =>
      "CompositionError::MultipleModels(manifests=\{manifests.join(",")})"
    EmptyManifests => "CompositionError::EmptyManifests"
    ManifestSchemaError(manifest_id~, detail~) =>
      "CompositionError::ManifestSchemaError(manifest=\{manifest_id}, detail=\{detail})"
    EmptyPort(port) => "CompositionError::EmptyPort(\{port})"
    ExtensionComposeFailed(manifest_id~, detail~) =>
      "CompositionError::ExtensionComposeFailed(manifest=\{manifest_id}, detail=\{detail})"
  }
}

///|
/// Errors raised by UiPort implementations. `UiPort::request` MUST raise one
/// of these typed variants instead of an untyped error, so that callers can
/// distinguish "user cancelled" from "this UI doesn't support requests".
pub(all) suberror UiError {
  /// The UiPort does not support interactive requests at all (e.g. NoopUiPort,
  /// or a headless host). Distinct from Cancelled (which means the request
  /// was presented to the user and they dismissed it).
  Unsupported(detail~ : String)
  /// User saw the request and explicitly cancelled it.
  Cancelled
  /// The request payload was structurally invalid (e.g. Select with empty
  /// options). Raised by the UiPort before any user interaction.
  InvalidRequest(detail~ : String)
  /// The host reported a transport/IO failure while servicing the request.
  IoFailure(detail~ : String)
} derive(Debug)

///|
pub impl Show for UiError with fn to_string(self) -> String {
  match self {
    Unsupported(detail~) => "UiError::Unsupported(\{detail})"
    Cancelled => "UiError::Cancelled"
    InvalidRequest(detail~) => "UiError::InvalidRequest(\{detail})"
    IoFailure(detail~) => "UiError::IoFailure(\{detail})"
  }
}

///|
/// Errors raised by CommandPort.invoke: unknown command id, invalid args,
/// or execution failure.
pub(all) suberror CommandError {
  NotFound(String)
  InvalidArgs(reason~ : String)
  ExecutionFailed(String)
} derive(Debug)

///|
pub impl Show for CommandError with fn to_string(self) -> String {
  match self {
    NotFound(id) => "CommandError::NotFound(\{id})"
    InvalidArgs(reason~) => "CommandError::InvalidArgs(\{reason})"
    ExecutionFailed(msg) => "CommandError::ExecutionFailed(\{msg})"
  }
}
