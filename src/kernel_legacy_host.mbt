///|
/// Legacy → Kernel `HostRuntime` adapter (REPAIR D4 — compatibility direction
/// is root → Kernel, never the reverse).
///
/// The Kernel defines `@kernel.HostRuntime` as the single host-side contract
/// for executing `CallModel` / `ExecuteTool` / `CancelOutstanding` effects.
/// This file implements that contract by delegating to the legacy
/// `@port.ModelPort` / `@port.ToolProvider` traits that live in the root package. All
/// legacy ↔ canonical conversion happens HERE — puppetry and the reducer
/// never see a legacy `@types.Message` / `@types.ToolCall` / `@types.ModelResponse`.
///
/// Why this lives in root and not in puppetry: puppetry must not import the
/// root package (that would form a root → puppetry → root cycle). The root
/// package imports both kernel and puppetry, so it is the natural host for
/// the adapter. Cetas, official extensions and existing user code keep using
/// `Agent::run_turn` (legacy); the opt-in `run_turn_via_kernel` /
/// `run_turn_via_harness` facades build a `LegacyHostRuntime` from the
/// `Agent`'s already-bound providers.

// ──────────────────────────────────────────────────────────────────────────
// LegacyHostRuntime
// ──────────────────────────────────────────────────────────────────────────

///|
/// Host-runtime implementation backed by legacy `@port.ModelPort` +
/// `@port.ToolProvider`s. Constructed from an `Agent`'s bound providers; the
/// lifetime of every reference is tied to the `Agent`.
pub(all) struct LegacyHostRuntime {
  model_port : &@port.ModelPort
  tool_providers : Map[String, &@port.ToolProvider]
}

///|
/// Build a `LegacyHostRuntime` from an `Agent`. Owner ids are derived from
/// each tool's `source` field (falling back to `"legacy_provider"`), matching
/// how `build_agent_catalog` assigns owners — so the owner a reducer sees in
/// an `ExecuteTool` effect resolves back to the same provider here.
pub fn LegacyHostRuntime::from_agent(agent : Agent) -> LegacyHostRuntime {
  let map : Map[String, &@port.ToolProvider] = Map::from_array([])
  for provider in agent.tool_routing.providers {
    for tool in provider.list_tools() {
      let owner_str = match tool.source {
        Some(s) if s != "" => s
        _ => "legacy_provider"
      }
      map[owner_str] = provider
    }
  }
  // Also register the raw tool name → provider so name-based lookups still
  // work for tools whose source field was unset.
  for provider in agent.tool_routing.providers {
    for tool in provider.list_tools() {
      if !map.contains(tool.name) {
        map[tool.name] = provider
      }
    }
  }
  { model_port: agent.model_port, tool_providers: map }
}

///|
/// Direct constructor (used by tests that assemble an Agent without going
/// through `Agent::new`).
pub fn LegacyHostRuntime::new(
  model_port : &@port.ModelPort,
  tool_bindings : Array[(String, &@port.ToolProvider)],
) -> LegacyHostRuntime {
  let map : Map[String, &@port.ToolProvider] = Map::from_array([])
  for binding in tool_bindings {
    let (owner, provider) = binding
    map[owner] = provider
  }
  { model_port, tool_providers: map }
}

// ──────────────────────────────────────────────────────────────────────────
// HostRuntime implementation
// ──────────────────────────────────────────────────────────────────────────

///|
/// Adapt `HostRuntime::call_model` to legacy `@port.ModelPort::chat_streaming`.
/// See file header for the conversion contract.
pub impl @kernel.HostRuntime for LegacyHostRuntime with fn call_model(
  self : LegacyHostRuntime,
  messages : Array[@kernel.CanonicalMessage],
  tool_definitions : Array[@kernel.CanonicalToolDef],
  call_options : Json,
  on_chunk : @kernel.HostChunkCallback,
) -> Result[@kernel.AssistantCompletion, @kernel.ModelFailure] {
  // 1. Canonical → legacy messages.
  let legacy_messages : Array[@types.Message] = []
  for cm in messages {
    legacy_messages.push(canonical_to_legacy_message(cm))
  }
  // 2. Canonical → legacy tool definitions (forward the REAL definitions).
  let legacy_tools : Array[@types.ToolDef] = []
  for td in tool_definitions {
    legacy_tools.push({
      name: td.name.to_string(),
      description: td.description,
      input_schema: td.input_schema,
      metadata: None,
      source: td.provenance,
    })
  }
  // 3. Options: the Kernel carries them as opaque JSON; legacy @types.ChatOptions
  //    has typed fields. We parse known keys when present and fall back to
  //    None — never silently coerced (ADR §2.9).
  let legacy_options : @types.ChatOptions = match
    json_to_chat_options(call_options) {
    Ok(options) => options
    Err(reason) =>
      return Err(
        @kernel.RequestBuild(reason="invalid model options: " + reason),
      )
  }
  // 4. Call the legacy model port. Its methods are async and raise @error.ModelError.
  let result : Result[@types.ModelResponse, @error.ModelError] = Ok(
    self.model_port.chat_streaming(
      legacy_messages,
      legacy_tools,
      legacy_options,
      fn(chunk : @types.StreamChunk) { on_chunk(stream_chunk_to_json(chunk)) },
    ),
  ) catch {
    e => Err(e)
  }
  match result {
    Ok(response) => Ok(legacy_to_completion(response))
    Err(e) => Err(model_error_to_failure(e))
  }
}

///|
/// Adapt `HostRuntime::execute_tool` to legacy `@port.ToolProvider::execute`.
pub impl @kernel.HostRuntime for LegacyHostRuntime with fn execute_tool(
  self : LegacyHostRuntime,
  owner_id : @kernel.OwnerId,
  call_id : @kernel.CallId,
  tool_name : @kernel.ToolName,
  arguments : Json,
) -> @kernel.ToolOutcome {
  let owner_key = owner_id.to_string()
  let name_key = tool_name.to_string()
  // Prefer the exact tool-name binding. Tool names are composition-unique,
  // while an owner fallback such as `legacy_provider` may be shared by many
  // providers. Resolving by owner first would make the last provider win for
  // every source-less tool.
  let provider : &@port.ToolProvider? = match
    self.tool_providers.get(name_key) {
    Some(p) => Some(p)
    None => self.tool_providers.get(owner_key)
  }
  match provider {
    None =>
      @kernel.RuntimeFailure(
        error_category="MissingOwner",
        message="no provider registered for owner='\{owner_key}' / name='\{name_key}'",
      )
    Some(p) => {
      let legacy_call : @types.ToolCall = {
        id: call_id.to_string(),
        name: name_key,
        arguments,
      }
      let result : Result[@types.ToolResult, @error.RuntimeError] = Ok(
        p.execute(name_key, legacy_call),
      ) catch {
        e => Err(e)
      }
      match result {
        Ok(tr) =>
          if tr.is_error {
            @kernel.ToolReportedError(
              content=tr.content,
              structured=tr.structured,
            )
          } else {
            @kernel.Success(content=tr.content, structured=tr.structured)
          }
        Err(e) =>
          @kernel.RuntimeFailure(
            error_category="Transport",
            message=e.to_string(),
          )
      }
    }
  }
}

///|
/// Cancel is best-effort. Legacy adapters have no cancel channel, so we
/// report `NotPropagated` for every id — the reducer has already terminal-
/// transitioned and does not block on this. Real propagation hardening is M3.
pub impl @kernel.HostRuntime for LegacyHostRuntime with fn cancel_effects(
  self : LegacyHostRuntime,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  ignore(self)
  let out : Array[(@kernel.EffectId, @kernel.CancelDisposition)] = []
  for id in effect_ids {
    out.push((id, @kernel.NotPropagated))
  }
  ignore(reason)
  out
}

// ──────────────────────────────────────────────────────────────────────────
// Legacy ↔ Canonical conversions (single source of truth for the adapter)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Convert a canonical message to the legacy `@types.Message` the `@port.ModelPort`
/// expects. Inverse of `legacy_to_completion` for assistant payloads.
pub fn canonical_to_legacy_message(
  cm : @kernel.CanonicalMessage,
) -> @types.Message {
  match cm {
    @kernel.SystemMessage(content~) =>
      {
        role: @types.System,
        content: canonical_content_to_legacy(content),
        tool_calls: [],
        tool_call_id: None,
        name: None,
        reasoning_content: None,
      }
    @kernel.UserMessage(content~) =>
      {
        role: @types.User,
        content: canonical_content_to_legacy(content),
        tool_calls: [],
        tool_call_id: None,
        name: None,
        reasoning_content: None,
      }
    @kernel.AssistantMessage(content~, tool_calls~, reasoning~, ..) =>
      {
        role: @types.Assistant,
        content: canonical_content_to_legacy(content),
        tool_calls: canonical_tool_calls_to_legacy(tool_calls),
        tool_call_id: None,
        name: None,
        reasoning_content: match reasoning {
          Some(r) => Some(r.content)
          None => None
        },
      }
    @kernel.ToolMessage(call_id~, tool_name~, outcome~) => {
      let (content, _is_error) = outcome_to_legacy(outcome)
      {
        role: @types.Tool,
        content: [@types.Text(content)],
        tool_calls: [],
        tool_call_id: Some(call_id.to_string()),
        name: Some(tool_name.to_string()),
        reasoning_content: None,
      }
    }
  }
}

///|
fn canonical_content_to_legacy(
  content : Array[@kernel.CanonicalContent],
) -> Array[@types.Content] {
  let out : Array[@types.Content] = []
  for c in content {
    match c {
      @kernel.Text(s) => out.push(@types.Text(s))
      @kernel.Image(media_type~, data~) =>
        out.push(@types.Image(media_type, data))
    }
  }
  out
}

///|
fn canonical_tool_calls_to_legacy(
  calls : Array[@kernel.CanonicalToolCall],
) -> Array[@types.ToolCall] {
  let out : Array[@types.ToolCall] = []
  for c in calls {
    out.push({
      id: c.call_id.to_string(),
      name: c.name.to_string(),
      arguments: c.arguments,
    })
  }
  out
}

///|
/// Convert legacy `@types.ModelResponse` → canonical `@kernel.AssistantCompletion`. Tool
/// calls and reasoning are read from the inner `Message` (the single source
/// of truth in canonical form); the duplicated top-level fields are ignored.
pub fn legacy_to_completion(
  response : @types.ModelResponse,
) -> @kernel.AssistantCompletion {
  let reasoning = match response.message.reasoning_content {
    Some(s) => Some(@kernel.Reasoning::{ content: s })
    None => None
  }
  @kernel.AssistantCompletion::new(
    content=legacy_content_to_canonical(response.message.content),
    tool_calls=legacy_tool_calls_to_canonical(response.message.tool_calls),
    reasoning~,
    finish_reason=legacy_finish_to_canonical(response.finish_reason),
    usage=legacy_usage_to_canonical(response.usage),
  )
}

///|
fn legacy_content_to_canonical(
  content : Array[@types.Content],
) -> Array[@kernel.CanonicalContent] {
  let out : Array[@kernel.CanonicalContent] = []
  for c in content {
    match c {
      @types.Text(s) => out.push(@kernel.Text(s))
      @types.Image(t, d) => out.push(@kernel.Image(media_type=t, data=d))
    }
  }
  out
}

///|
fn legacy_tool_calls_to_canonical(
  calls : Array[@types.ToolCall],
) -> Array[@kernel.CanonicalToolCall] {
  let out : Array[@kernel.CanonicalToolCall] = []
  for c in calls {
    out.push({
      call_id: @kernel.CallId::unchecked(c.id),
      name: @kernel.ToolName::unchecked(c.name),
      arguments: c.arguments,
    })
  }
  out
}

///|
fn legacy_finish_to_canonical(
  reason : @types.FinishReason,
) -> @kernel.AssistantFinishReason {
  match reason {
    @types.Stop => @kernel.Stop
    @types.Length => @kernel.Length
    @types.ToolCalls => @kernel.ToolCalls
    @types.Other(s) => @kernel.Other(s)
  }
}

///|
fn legacy_usage_to_canonical(usage : @types.Usage?) -> @kernel.CanonicalUsage? {
  match usage {
    Some(u) =>
      Some({
        input_tokens: u.input_tokens,
        output_tokens: u.output_tokens,
        total_tokens: u.total_tokens,
      })
    None => None
  }
}

///|
/// Convert legacy `@error.ModelError` → canonical `@kernel.ModelFailure`. No error is
/// collapsed to a default; each variant preserves its category.
pub fn model_error_to_failure(e : @error.ModelError) -> @kernel.ModelFailure {
  match e {
    @error.RequestBuild(msg) => @kernel.RequestBuild(reason=msg)
    @error.Transport(msg) => @kernel.Transport(reason=msg)
    @error.ResponseParse(msg) => @kernel.Parse(reason=msg)
  }
}

///|
/// Convert canonical `@kernel.ToolOutcome` → (legacy content, legacy is_error). Used
/// when feeding outcomes back to legacy observers/session save.
pub fn outcome_to_legacy(outcome : @kernel.ToolOutcome) -> (String, Bool) {
  match outcome {
    @kernel.Success(content~, ..) => (content, false)
    @kernel.ToolReportedError(content~, ..) => (content, true)
    @kernel.RuntimeFailure(message~, ..) => (message, true)
    @kernel.NotExecuted(reason~, ..) =>
      ("tool not executed: " + reason.to_string(), true)
  }
}

///|
/// Convert a canonical `@kernel.ToolOutcome` → legacy `@types.ToolResult`. The `is_error`
/// boolean is derived from the outcome variant — never hardcoded (REPAIR
/// M0-T06-A single-source rule).
pub fn outcome_to_legacy_tool_result(
  outcome : @kernel.ToolOutcome,
) -> @types.ToolResult {
  let (content, is_error) = outcome_to_legacy(outcome)
  let structured : Json? = match outcome {
    @kernel.Success(structured~, ..) => structured
    @kernel.ToolReportedError(structured~, ..) => structured
    _ => None
  }
  { content, structured, is_error }
}

// ──────────────────────────────────────────────────────────────────────────
// Options + stream chunk helpers
// ──────────────────────────────────────────────────────────────────────────

///|
/// Parse the opaque JSON options carried by a `CallModel` effect into legacy
/// `@types.ChatOptions`. Missing keys are `None` — never silently coerced (§2.9).
fn json_field(options : Json, key : String) -> Json? {
  match options {
    Json::Object(fields) => fields.get(key)
    _ => None
  }
}

///|
fn parse_tool_choice(value : Json) -> Result[@types.ToolChoice?, String] {
  match value {
    Json::Null => Ok(None)
    Json::String(name) =>
      match name {
        "auto" => Ok(Some(@types.Auto))
        "none" => Ok(Some(@types.NoTool))
        "required" => Ok(Some(@types.Required))
        _ => Ok(Some(@types.NamedTool(name)))
      }
    Json::Object(fields) =>
      match fields.get("name") {
        Some(Json::String(name)) => Ok(Some(@types.NamedTool(name)))
        _ => Err("tool_choice object requires a string name")
      }
    _ => Err("tool_choice must be null, a string, or an object with name")
  }
}

///|
fn parse_reasoning_effort(
  value : Json,
) -> Result[@types.ReasoningEffort?, String] {
  match value {
    Json::Null => Ok(None)
    Json::String(name) =>
      match name {
        "off" => Ok(Some(@types.Off))
        "minimal" => Ok(Some(@types.Minimal))
        "low" => Ok(Some(@types.Low))
        "medium" => Ok(Some(@types.Medium))
        "high" => Ok(Some(@types.High))
        "maximum" => Ok(Some(@types.Maximum))
        _ => Err("reasoning_effort has an unknown value")
      }
    _ => Err("reasoning_effort must be null or a string")
  }
}

///|
fn json_to_chat_options(options : Json) -> Result[@types.ChatOptions, String] {
  let temperature : Double? = match json_field(options, "temperature") {
    None | Some(Json::Null) => None
    Some(Json::Number(value, ..)) => Some(value)
    Some(_) => return Err("temperature must be a JSON number")
  }
  let max_output_tokens : Int? = match
    json_field(options, "max_output_tokens") {
    None | Some(Json::Null) => None
    Some(Json::Number(value, ..)) => {
      if value.floor() != value {
        return Err("max_output_tokens must be an integer")
      }
      Some(value.to_int())
    }
    Some(_) => return Err("max_output_tokens must be a JSON number")
  }
  let tool_choice_result : Result[@types.ToolChoice?, String] = match
    json_field(options, "tool_choice") {
    None => Ok(None)
    Some(value) => parse_tool_choice(value)
  }
  let tool_choice : @types.ToolChoice? = match tool_choice_result {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  let reasoning_effort_result : Result[@types.ReasoningEffort?, String] = match
    json_field(options, "reasoning_effort") {
    None => Ok(None)
    Some(value) => parse_reasoning_effort(value)
  }
  let reasoning_effort : @types.ReasoningEffort? = match
    reasoning_effort_result {
    Ok(value) => value
    Err(reason) => return Err(reason)
  }
  Ok({ temperature, max_output_tokens, tool_choice, reasoning_effort })
}

///|
/// Wrap a legacy `@types.StreamChunk` as opaque JSON for the host callback. The
/// Kernel does not define a canonical chunk type (streaming is a
/// host/telemetry concern, ADR §2.11); we carry enough information for an
/// observer to render the chunk without leaking the full legacy type.
fn stream_chunk_to_json(chunk : @types.StreamChunk) -> Json {
  match chunk {
    @types.TextDelta(token~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("text_delta")),
          ("token", Json::string(token)),
        ]),
      )
    @types.ReasoningDelta(token~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("reasoning_delta")),
          ("token", Json::string(token)),
        ]),
      )
    @types.ToolCallDelta(index~, id~, name~, arguments_delta~) => {
      let fields : Array[(String, Json)] = [
        ("kind", Json::string("tool_call_delta")),
        ("index", Json::number(index.to_double())),
      ]
      match id {
        Some(s) => fields.push(("id", Json::string(s)))
        None => ()
      }
      match name {
        Some(s) => fields.push(("name", Json::string(s)))
        None => ()
      }
      match arguments_delta {
        Some(s) => fields.push(("arguments_delta", Json::string(s)))
        None => ()
      }
      Json::object(Map::from_array(fields))
    }
    @types.Usage(u) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("usage")),
          ("usage", usage_to_json(u)),
        ]),
      )
    @types.Finish(reason~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("finish")),
          ("reason", Json::string(finish_reason_to_string(reason))),
        ]),
      )
  }
}

///|
fn finish_reason_to_string(reason : @types.FinishReason) -> String {
  match reason {
    @types.Stop => "Stop"
    @types.Length => "Length"
    @types.ToolCalls => "ToolCalls"
    @types.Other(s) => "Other(" + s + ")"
  }
}

///|
fn usage_to_json(u : @types.Usage) -> Json {
  let fields : Array[(String, Json)] = []
  match u.input_tokens {
    Some(i) => fields.push(("input_tokens", Json::number(i.to_double())))
    None => ()
  }
  match u.output_tokens {
    Some(i) => fields.push(("output_tokens", Json::number(i.to_double())))
    None => ()
  }
  match u.total_tokens {
    Some(i) => fields.push(("total_tokens", Json::number(i.to_double())))
    None => ()
  }
  Json::object(Map::from_array(fields))
}
