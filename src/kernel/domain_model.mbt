///|
/// Canonical model-step types for the M1 functional Kernel.
///
/// ADR `docs/design/08-functional-kernel-contract.md` §2.1, §2.11: the
/// assistant completion is the single source of truth for tool calls and
/// reasoning. The legacy `ModelResponse` type (in `types_model.mbt`) duplicates
/// `tool_calls` and `reasoning_content` between the top-level struct and the
/// nested message; the canonical type below has no such duplication.

// ──────────────────────────────────────────────────────────────────────────
// Usage
// ──────────────────────────────────────────────────────────────────────────

///|
/// Token usage reported by the model for a single step. The Kernel only counts
/// what is actually reported; absent dimensions are `None`, **never** silently
/// coerced to 0 (ADR §2.9 — unknown usage is never reported as 0).
pub(all) struct CanonicalUsage {
  input_tokens : Int?
  output_tokens : Int?
  total_tokens : Int?
} derive(Eq, Debug)

///|
pub impl Show for CanonicalUsage with fn to_string(self : CanonicalUsage) -> String {
  let fmt = fn(opt : Int?) -> String {
    match opt {
      Some(n) => n.to_string()
      None => "?"
    }
  }
  "Usage(in=\{fmt(self.input_tokens)}, out=\{fmt(self.output_tokens)}, total=\{fmt(self.total_tokens)})"
}

// ──────────────────────────────────────────────────────────────────────────
// Assistant completion — the single source for tool calls + reasoning
// ──────────────────────────────────────────────────────────────────────────

///|
/// A completed assistant step. The `message` field is the canonical assistant
/// message that the reducer appends to the transcript; tool calls and reasoning
/// live there (single source of truth, ADR §2.11). The `usage` field reports
/// token consumption observed for this step, which the reducer may aggregate
/// into the Run budget.
///
/// Construction note: do NOT build this by hand in production code. The
/// `from_assistant_message` constructor enforces the invariant that the message
/// payload is consistent (assistant role, no `ToolMessage` shape, etc.).
pub(all) struct AssistantCompletion {
  message : AssistantMessagePayload
  usage : CanonicalUsage?
} derive(Eq, Debug)

///|
/// Re-flattened assistant payload used inside `AssistantCompletion`. We cannot
/// reuse `CanonicalMessage::AssistantMessage` directly because that variant
/// already carries `finish_reason`; the completion's `message` field is the
/// transcript entry, while the `usage` lives at the completion level. This
/// struct mirrors only the fields that travel together as the assistant's
/// contribution to a single step.
pub(all) struct AssistantMessagePayload {
  content : Array[CanonicalContent]
  tool_calls : Array[CanonicalToolCall]
  reasoning : Reasoning?
  finish_reason : AssistantFinishReason
} derive(Eq, Debug)

///|
/// Build an `AssistantCompletion` from its parts. The reducer constructs this
/// from a `ModelCompleted` input after parsing the model adapter's wire
/// representation.
pub fn AssistantCompletion::new(
  content~ : Array[CanonicalContent],
  tool_calls~ : Array[CanonicalToolCall],
  reasoning~ : Reasoning?,
  finish_reason~ : AssistantFinishReason,
  usage~ : CanonicalUsage?,
) -> AssistantCompletion {
  let message : AssistantMessagePayload = {
    content: content.copy(),
    tool_calls: tool_calls.copy(),
    reasoning,
    finish_reason,
  }
  { message, usage }
}

///|
/// Convenience: does this completion request any tool calls?
pub fn AssistantCompletion::has_tool_calls(self : AssistantCompletion) -> Bool {
  !self.message.tool_calls.is_empty()
}

///|
/// Returns the tool calls in source order (already a copy of the internal
/// array).
pub fn AssistantCompletion::tool_calls(
  self : AssistantCompletion,
) -> Array[CanonicalToolCall] {
  self.message.tool_calls.copy()
}

///|
/// Returns the finish reason. `Length` is preserved as a distinct variant so
/// the reducer can refuse to emit `ExecuteTool` effects for a truncated
/// completion (ADR §2.7, M0 `StreamAccumulator::to_response` behaviour).
pub fn AssistantCompletion::finish_reason(
  self : AssistantCompletion,
) -> AssistantFinishReason {
  self.message.finish_reason
}

// ──────────────────────────────────────────────────────────────────────────
// Model-step failure (delivered to the reducer via ModelFailed input)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Categorises why a model step failed (ADR §2.4). The reducer maps this to a
/// `FailureReason::Model*` variant. Each variant carries a safe bounded label,
/// never a raw provider payload.
pub(all) enum ModelFailure {
  RequestBuild(reason~ : String)
  Transport(reason~ : String)
  Runtime(reason~ : String)
  Parse(reason~ : String)
} derive(Eq, Debug)

///|
pub impl Show for ModelFailure with fn to_string(self : ModelFailure) -> String {
  match self {
    RequestBuild(reason~) =>
      "ModelFailure::RequestBuild(\{safe_model_label(reason)})"
    Transport(reason~) => "ModelFailure::Transport(\{safe_model_label(reason)})"
    Runtime(reason~) => "ModelFailure::Runtime(\{safe_model_label(reason)})"
    Parse(reason~) => "ModelFailure::Parse(\{safe_model_label(reason)})"
  }
}

///|
fn safe_model_label(value : String) -> String {
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
