///|
/// Canonical transcript message types for the functional Kernel.
/// Tool calls, reasoning, and finish_reason live only on `AssistantMessage`.
/// Pure data — no IO, no trait references, no async.

///|
/// Canonical content block. `Text` is the common case; `Image` carries a
/// stable media-type identifier plus opaque payload data (base64, URL, or an
/// adapter-managed handle — the Kernel does not interpret it).
pub(all) enum Content {
  Text(String)
  Image(media_type~ : String, data~ : String)
} derive(Eq, Debug)

///|
pub impl Show for Content with fn to_string(self) -> String {
  match self {
    Text(s) => "Text(\{s.length()} chars)"
    Image(media_type~, data~) =>
      "Image(\{media_type}, \{data.length()} bytes-suffix)"
  }
}

///|
/// Stable identifier for a single tool call requested by the assistant. The
/// reducer and scheduler only ever compare/store this string; it is opaque to
/// the Kernel and is produced by the model adapter or by the host.
pub(all) struct CallId {
  value : String
} derive(Eq, Hash, Debug)

///|
/// Construct a `CallId`. Empty strings are rejected — an empty id would make
/// correlation ambiguous. The Kernel invariant treats a missing/empty call id
/// in a streamed completion as `ModelParseFailure`, not as a usable call.
pub fn CallId::new(value : String) -> Result[CallId, String] {
  if value == "" {
    Err("CallId must be non-empty")
  } else {
    Ok(CallId::{ value, })
  }
}

///|
/// Internal constructor used by Kernel tests and by callers that have already
/// validated the string. Production callers should prefer `CallId::new` and
/// handle the typed rejection.
pub fn CallId::unchecked(value : String) -> CallId {
  CallId::{ value, }
}

///|
pub fn CallId::to_string(self : CallId) -> String {
  self.value
}

///|
/// A tool name as it appears in the catalog (call-visible name). The Kernel
/// uses this only for lookup in the catalog snapshot; it never re-parses or
/// re-normalizes it.
pub(all) struct ToolName {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn ToolName::new(value : String) -> Result[ToolName, String] {
  if value == "" {
    Err("ToolName must be non-empty")
  } else {
    Ok(ToolName::{ value, })
  }
}

///|
pub fn ToolName::unchecked(value : String) -> ToolName {
  ToolName::{ value, }
}

///|
pub fn ToolName::to_string(self : ToolName) -> String {
  self.value
}

///|
/// Tool arguments as parsed JSON. This is the post-parsing representation: if
/// the model stream produced malformed JSON, the reducer has already terminated
/// the Run with `ModelParseFailure` before this type is constructed. Therefore
/// any `ToolCall` reaching the scheduler has well-formed arguments,
/// but the arguments may still fail the catalog schema (handled separately as
/// `NotExecuted(SchemaMismatch)`).
pub(all) struct ToolCall {
  call_id : CallId
  name : ToolName
  arguments : Json
} derive(Eq, Debug)

///|
pub impl Show for ToolCall with fn to_string(self) -> String {
  let args_summary = match self.arguments {
    Object(_) => "object"
    Array(_) => "array"
    _ => "scalar"
  }
  "ToolCall(call_id=\{self.call_id.to_string()}, name=\{self.name.to_string()}, args=\{args_summary})"
}

///|
/// Reasoning trace produced by the assistant (e.g. DeepSeek deepseek-reasoner
/// chain-of-thought, OpenAI o-series reasoning content). The Kernel never
/// interprets the content; it stores and replays it. `None` means the assistant
/// produced no reasoning for this step.
///
/// `raw` is a provider-defined replay payload: OpenAI Responses API
/// reasoning items must be replayed verbatim when the host manually manages
/// conversation state (per the official reasoning guide), so the adapter
/// stores the raw items here. The kernel never interprets it; providers that
/// replay plain `content` text (DeepSeek, Kimi, OpenAI-compatible) leave it
/// `None`.
pub(all) struct Reasoning {
  content : String
  raw : Json?
} derive(Eq, Debug)

///|
pub impl Show for Reasoning with fn to_string(self : Reasoning) -> String {
  "Reasoning(\{self.content.length()} chars)"
}

///|
/// Canonical conversation message. The role determines which payload is
/// legal, making invalid role/payload combinations unrepresentable.
///
/// Invariants:
/// - `SystemMessage` / `UserMessage` never carry tool calls.
/// - `AssistantMessage` is the ONLY variant that carries tool calls and the
///   ONLY variant that carries reasoning.
/// - `ToolMessage` is the ONLY variant that carries a `call_id` correlation
///   and a `ToolOutcome`. It never carries tool calls.
pub(all) enum Message {
  SystemMessage(content~ : Array[Content])
  UserMessage(content~ : Array[Content])
  AssistantMessage(
    content~ : Array[Content],
    tool_calls~ : Array[ToolCall],
    reasoning~ : Reasoning?,
    finish_reason~ : FinishReason
  )
  ToolMessage(call_id~ : CallId, tool_name~ : ToolName, outcome~ : ToolOutcome)
} derive(Eq, Debug)

///|
/// Why the assistant finished a step. It is owned by the assistant message
/// (per ADR §2.11: single source of truth).
///
/// `Length` is preserved as a distinct variant because the reducer must NOT
/// emit `ExecuteTool` effects after a length-truncated completion, even if the
/// provider tried to stream partial tool calls.
pub(all) enum FinishReason {
  Stop
  Length
  ToolCalls
  Other(String)
} derive(Eq, Debug)

///|
pub impl Show for FinishReason with fn to_string(self : FinishReason) -> String {
  match self {
    Stop => "Stop"
    Length => "Length"
    ToolCalls => "ToolCalls"
    Other(s) => "Other(\{s})"
  }
}

///|
/// Discriminator for the reason a tool call was NOT executed even though the
/// model requested it (ADR §2.7).
///
/// - `UnknownTool`: the requested tool name is not present in the catalog
///   snapshot that was handed to the `CallModel` effect.
/// - `SchemaMismatch`: the model's arguments parsed successfully but failed
///   validation against the tool's input schema. The diagnostic carries a safe
///   JSON path and type expectation; it never includes the raw argument
///   payload.
///
/// Malformed-argument cases never reach this variant — they are
/// `ModelParseFailure` at the reducer boundary (ADR §2.4).
pub(all) enum NotExecutedReason {
  UnknownTool
  SchemaMismatch(json_path~ : String, expected~ : String, actual~ : String)
} derive(Eq, Debug)

///|
pub impl Show for NotExecutedReason with fn to_string(self : NotExecutedReason) -> String {
  match self {
    UnknownTool => "UnknownTool"
    SchemaMismatch(json_path~, expected~, actual~) =>
      "SchemaMismatch(path=\{json_path}, expected=\{expected}, actual=\{actual})"
  }
}

///|
/// Outcome of a single tool invocation (ADR §2.4, §2.11).
///
/// Variants:
/// - `Success`: tool ran and returned structured data. `structured` is the
///   model-facing JSON payload; `content` is the human-readable mirror used by
///   the transcript.
/// - `ToolReportedError`: tool ran and reported a business-level failure. The
///   Run continues; the failure is fed back to the model as a normal tool
///   message.
/// - `RuntimeFailure`: tool did not run to completion — adapter raised a
///   `RuntimeError`. Still non-terminal for the Run.
/// - `NotExecuted`: model requested a tool that was not executed (unknown name
///   or parseable-but-schema-invalid args). The original call id is preserved
///   so the model can correlate the feedback.
///
/// There is deliberately no boolean `is_error` field here. The variant tag IS
/// the error status.
pub(all) enum ToolOutcome {
  Success(content~ : String, structured~ : Json?)
  ToolReportedError(content~ : String, structured~ : Json?)
  RuntimeFailure(error_category~ : String, message~ : String)
  NotExecuted(reason~ : NotExecutedReason, original_call_id~ : CallId)
} derive(Eq, Debug)

///|
/// Whether the outcome represents a non-success path (any variant other than
/// `Success`). Product adapters may use this for presentation, while canonical
/// control flow pattern-matches the outcome exhaustively.
pub fn ToolOutcome::is_failure(self : ToolOutcome) -> Bool {
  match self {
    Success(..) => false
    _ => true
  }
}

///|
/// Single-line summary that excludes raw payloads. Used by `Show` and by any
/// debug/log surface, so that prompts and tool arguments never leak.
pub fn ToolOutcome::summary(self : ToolOutcome) -> String {
  match self {
    Success(content~, structured~) =>
      "Success(\{content.length()} chars, structured=\{structured is Some(_)})"
    ToolReportedError(content~, ..) =>
      "ToolReportedError(\{content.length()} chars)"
    RuntimeFailure(error_category~, message~) =>
      "RuntimeFailure(\{error_category}, \{safe_outcome_label(message)})"
    NotExecuted(reason~, original_call_id~) =>
      "NotExecuted(\{reason.to_string()}, call_id=\{original_call_id.to_string()})"
  }
}

///|
pub impl Show for ToolOutcome with fn to_string(self : ToolOutcome) -> String {
  self.summary()
}

///|
/// Internal bounded single-line label helper for safe diagnostics.
fn safe_outcome_label(value : String) -> String {
  let chars : Array[Char] = []
  let mut truncated = false
  for char in value {
    if chars.length() >= 64 {
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
    label + "...(truncated)"
  } else {
    label
  }
}

///|
/// Canonical conversation transcript. Every transition produces a fresh array
/// (the reducer never mutates caller-owned arrays, ADR §2.10). The reducer is
/// the only writer.
pub(all) struct Transcript {
  messages : Array[Message]
} derive(Eq, Debug)

///|
pub fn Transcript::empty() -> Transcript {
  { messages: [] }
}

///|
pub fn Transcript::from_array(messages : Array[Message]) -> Transcript {
  // Defensive copy: the transcript must be reducer-owned. Callers that pass
  // an array they continue to mutate will not affect this transcript.
  { messages: messages.copy() }
}

///|
/// Returns a new transcript with `message` appended. The original transcript
/// is not mutated (ADR §2.10).
pub fn Transcript::append(self : Transcript, message : Message) -> Transcript {
  let next = self.messages.copy()
  next.push(message)
  { messages: next }
}

///|
/// Returns a new transcript with `messages` appended in order.
pub fn Transcript::append_all(
  self : Transcript,
  messages : Array[Message],
) -> Transcript {
  let next = self.messages.copy()
  for m in messages {
    next.push(m)
  }
  { messages: next }
}

///|
/// Returns the number of messages.
pub fn Transcript::length(self : Transcript) -> Int {
  self.messages.length()
}

///|
/// Read-only snapshot of the message array. Returns a copy so callers cannot
/// mutate the reducer-owned transcript.
pub fn Transcript::messages_snapshot(self : Transcript) -> Array[Message] {
  self.messages.copy()
}
