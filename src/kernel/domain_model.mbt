///|
/// Canonical model-step types for the functional Kernel.
///
/// ADR `docs/design/08-functional-kernel-contract.md` §2.1, §2.11: the
/// assistant completion is the single source of truth for tool calls and
/// reasoning. The canonical type has one authoritative owner for each fact.

///|
/// Token usage reported by the model for a single step. The Kernel only counts
/// what is actually reported; absent dimensions are `None`, **never** silently
/// coerced to 0 (ADR §2.9 — unknown usage is never reported as 0).
pub(all) struct Usage {
  input_tokens : Int?
  output_tokens : Int?
  total_tokens : Int?
  /// Cached (reused) portion of the input prompt when the provider reports
  /// it — OpenAI `prompt_tokens_details.cached_tokens`, DeepSeek
  /// `prompt_cache_hit_tokens`, Moonshot `cached_tokens`. `input_tokens`
  /// stays the provider-reported prompt total; the cache hit rate is
  /// `cached_input_tokens / input_tokens`.
  cached_input_tokens : Int?
  /// The uncached (miss) portion of the input prompt when the provider
  /// reports it natively — DeepSeek `prompt_cache_miss_tokens`. Providers
  /// that report hit and miss as a pair spare consumers the subtraction
  /// (`uncached = input - cached`); this field is never synthesized.
  uncached_input_tokens : Int?
} derive(Eq, Debug)

///|
/// Validate provider-reported token usage before it enters the reducer.
///
/// Every field is optional because providers omit different dimensions, but a
/// reported value is always a count and therefore must be non-negative. Keep
/// this check here as the single canonical usage invariant so every host
/// adapter applies exactly the same rule.
pub fn Usage::validate(self : Usage) -> Result[Unit, String] {
  let fields : Array[(String, Int?)] = [
    ("input_tokens", self.input_tokens),
    ("output_tokens", self.output_tokens),
    ("total_tokens", self.total_tokens),
    ("cached_input_tokens", self.cached_input_tokens),
    ("uncached_input_tokens", self.uncached_input_tokens),
  ]
  for entry in fields {
    let (field, value) = entry
    match value {
      Some(n) if n < 0 => return Err("usage." + field + " must be non-negative")
      _ => ()
    }
  }
  Ok(())
}

///|
pub impl Show for Usage with fn to_string(self : Usage) -> String {
  let fmt = fn(opt : Int?) -> String {
    match opt {
      Some(n) => n.to_string()
      None => "?"
    }
  }
  "Usage(in=\{fmt(self.input_tokens)}, out=\{fmt(self.output_tokens)}, total=\{fmt(self.total_tokens)}, cached=\{fmt(self.cached_input_tokens)}, uncached=\{fmt(self.uncached_input_tokens)})"
}

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
pub(all) struct Completion {
  message : CompletionPayload
  usage : Usage?
} derive(Eq, Debug)

///|
/// Re-flattened assistant payload used inside `Completion`. We cannot
/// reuse `Message::AssistantMessage` directly because that variant
/// already carries `finish_reason`; the completion's `message` field is the
/// transcript entry, while the `usage` lives at the completion level. This
/// struct mirrors only the fields that travel together as the assistant's
/// contribution to a single step.
pub(all) struct CompletionPayload {
  content : Array[Content]
  tool_calls : Array[ToolCall]
  reasoning : Reasoning?
  finish_reason : FinishReason
} derive(Eq, Debug)

///|
/// Build an `Completion` from its parts. The reducer constructs this
/// from a `ModelCompleted` input after parsing the model adapter's wire
/// representation.
pub fn Completion::Completion(
  content~ : Array[Content],
  tool_calls~ : Array[ToolCall],
  reasoning~ : Reasoning?,
  finish_reason~ : FinishReason,
  usage~ : Usage?,
) -> Completion {
  let message : CompletionPayload = {
    content: content.copy(),
    tool_calls: tool_calls.copy(),
    reasoning,
    finish_reason,
  }
  { message, usage, }
}

///|
/// Convenience: does this completion request any tool calls?
pub fn Completion::has_tool_calls(self : Completion) -> Bool {
  !self.message.tool_calls.is_empty()
}

///|
/// Returns the tool calls in source order (already a copy of the internal
/// array).
pub fn Completion::tool_calls(self : Completion) -> Array[ToolCall] {
  self.message.tool_calls.copy()
}

///|
/// Returns the finish reason. `Length` is preserved as a distinct variant so
/// the reducer can refuse to emit `ExecuteTool` effects for a truncated
/// completion (ADR §2.7, M0 `StreamAccumulator::to_response` behaviour).
pub fn Completion::finish_reason(self : Completion) -> FinishReason {
  self.message.finish_reason
}

///|
/// Categorises why a model step failed (ADR §2.4). The reducer maps this to a
/// `FailureReason::Model*` variant. Each variant carries a safe bounded label,
/// never a raw provider payload.
pub(all) enum ModelFailure {
  RequestBuild(reason~ : String)
  Transport(reason~ : String)
  Runtime(reason~ : String)
  Parse(reason~ : String)
  /// The host rejected a reducer-declared model effect before invoking the
  /// provider (for example, an explicit policy gate). This is deliberately
  /// distinct from provider failures so callers can preserve the rejection's
  /// typed meaning instead of string-matching a model error.
  HostRejected(reason~ : String)
  /// The provider answered with a quota/rate-limit verdict instead of serving
  /// the request (HTTP 429, Kimi's 403, or an equivalent carrier). `reset_at_ms` is the provider-stated
  /// Unix epoch (milliseconds) when the quota window frees; `None` means the
  /// provider stated no reset time. Kept as primitive fields (not the error
  /// package's `RateLimitInfo`) because the kernel sits below the error
  /// package in the dependency order.
  RateLimited(reason~ : String, reset_at_ms~ : Int64?, provider_code~ : String?)
} derive(Eq, Debug)

///|
pub impl Show for ModelFailure with fn to_string(self : ModelFailure) -> String {
  match self {
    RequestBuild(reason~) =>
      "ModelFailure::RequestBuild(\{safe_model_label(reason)})"
    Transport(reason~) => "ModelFailure::Transport(\{safe_model_label(reason)})"
    Runtime(reason~) => "ModelFailure::Runtime(\{safe_model_label(reason)})"
    Parse(reason~) => "ModelFailure::Parse(\{safe_model_label(reason)})"
    HostRejected(reason~) =>
      "ModelFailure::HostRejected(\{safe_model_label(reason)})"
    RateLimited(reason~, ..) =>
      "ModelFailure::RateLimited(\{safe_model_label(reason)})"
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
