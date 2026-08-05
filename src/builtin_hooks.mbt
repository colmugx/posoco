///|
/// Built-in adapters: Posoco-provided implementations of port traits.
///
/// These structs are concrete adapters, not extension contracts — they live
/// in the root package (not `src/port/`) so the port package contains only
/// the intentional `pub(open)` traits community extensions implement.
/// Extension authors may register their own hook implementations instead of
/// or alongside these.

// SystemPromptHook — Hook impl that assembles + injects the prompt

///|
/// Combines a fixed base prompt with contributor sections and prepends the
/// result as a System message. Empty sections are skipped.
pub(all) struct SystemPromptHook {
  base_prompt : String
  contributors : Array[SystemPromptSection]
}

///|
/// A contributor entry: manifest id (for section header) and the contributor.
pub(all) struct SystemPromptSection {
  id : String
  contributor : &@port.SystemPromptContributor
}

///|
pub fn SystemPromptSection::SystemPromptSection(
  id~ : String,
  contributor~ : &@port.SystemPromptContributor,
) -> SystemPromptSection {
  { id, contributor }
}

///|
pub fn SystemPromptHook::SystemPromptHook(
  base_prompt~ : String,
  contributors~ : Array[SystemPromptSection],
) -> SystemPromptHook {
  { base_prompt, contributors }
}

///|
/// Assemble base + non-empty contributor sections with `id:` headers.
pub fn SystemPromptHook::assemble(self : SystemPromptHook) -> String {
  let sections : Array[String] = [self.base_prompt]
  for s in self.contributors {
    let text = s.contributor.system_prompt()
    if text != "" {
      sections.push(s.id + ":\n" + text)
    }
  }
  sections.join("\n\n")
}

///|
/// Idempotent injection: replaces the existing SystemMessage at index 0
/// (structural detection, not text-marker based) so repeated hook runs
/// do not accumulate.
pub impl @port.Hook for SystemPromptHook with fn before_model(
  self : SystemPromptHook,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] raise @port.HookAbort {
  let assembled = self.assemble()
  let sys_msg : @kernel.Message = @kernel.SystemMessage(content=[
    @kernel.Text(assembled),
  ])
  if messages.length() == 0 {
    return [sys_msg]
  }
  match messages[0] {
    @kernel.SystemMessage(..) => {
      let new_messages : Array[@kernel.Message] = [sys_msg]
      for i in 1..<messages.length() {
        new_messages.push(messages[i])
      }
      new_messages
    }
    _ => {
      let new_messages : Array[@kernel.Message] = [sys_msg]
      for m in messages {
        new_messages.push(m)
      }
      new_messages
    }
  }
}

// MemoryRetrievalHook

///|
/// MemoryRetrievalHook: Hook (before_model) that retrieves durable memory
/// and injects as a SystemMessage (after the system-prompt). Best-effort,
/// non-fatal — a search failure never aborts the turn; messages pass
/// through unchanged and the failure is reported through `on_failure`
/// (Agent wires this to the `Custom(source="posoco.core",
/// label="secondary_failure")` observer event).
pub(all) struct MemoryRetrievalHook {
  memories : Array[&@port.MemoryPort]
  /// Max entries per search. Low default keeps context short.
  top_k : Int
  /// Invoked with a sanitized reason when a `MemoryPort::search` fails.
  /// The failure is still swallowed (messages pass through unchanged);
  /// this channel exists so the swallow stays observable.
  on_failure : (String) -> Unit
}

///|
pub fn MemoryRetrievalHook::MemoryRetrievalHook(
  memories~ : Array[&@port.MemoryPort],
  top_k? : Int = 5,
  on_failure? : (String) -> Unit,
) -> MemoryRetrievalHook {
  let handler : (String) -> Unit = match on_failure {
    Some(f) => f
    None => fn(_reason) { () }
  }
  { memories, top_k, on_failure: handler }
}

///|
/// Truncate and flatten an adapter-controlled error string before it can
/// reach an event payload (64 chars, no newlines).
fn memory_safe_label(value : String) -> String {
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
/// Marker prefix for idempotent detection of existing memory messages.
let memory_marker : String = "[MEMORY]"

///|
/// Build a SystemMessage from retrieved entries. Returns `None` if empty.
fn MemoryRetrievalHook::build_memory_message(
  _self : MemoryRetrievalHook,
  entries : Array[@types.MemoryEntry],
) -> @kernel.Message? {
  if entries.is_empty() {
    return None
  }
  let lines : Array[String] = [memory_marker]
  for entry in entries {
    lines.push("- " + entry.content)
  }
  Some(@kernel.SystemMessage(content=[@kernel.Text(lines.join("\n"))]))
}

///|
/// Extract query from the last UserMessage. Returns `None` if absent.
fn MemoryRetrievalHook::extract_query(
  _self : MemoryRetrievalHook,
  messages : Array[@kernel.Message],
) -> String? {
  let mut i = messages.length() - 1
  while i >= 0 {
    match messages[i] {
      @kernel.UserMessage(content~) => {
        for c in content {
          match c {
            @kernel.Text(s) => return Some(s)
            _ => continue
          }
        }
        return None
      }
      _ => ()
    }
    i = i - 1
  }
  None
}

///|
/// Search every MemoryPort and merge results. Failures are reported via
/// `on_failure` and swallowed — the turn continues without memory context.
fn MemoryRetrievalHook::search_all(
  self : MemoryRetrievalHook,
  query : String,
) -> Array[@types.MemoryEntry] {
  let out : Array[@types.MemoryEntry] = []
  for mem in self.memories {
    let q : @types.MemoryQuery = {
      query,
      top_k: self.top_k,
      threshold: None,
      filter: Map::from_array([]),
    }
    let entries : Array[@types.MemoryEntry] = mem.search(q) catch {
      err => {
        (self.on_failure)(memory_safe_label(err.to_string()))
        []
      }
    }
    for e in entries {
      out.push(e)
    }
  }
  out
}

///|
/// Idempotent injection: replace existing memory SystemMessage or insert
/// after the system-prompt message.
fn MemoryRetrievalHook::inject(
  _self : MemoryRetrievalHook,
  messages : Array[@kernel.Message],
  memory_msg : @kernel.Message,
) -> Array[@kernel.Message] {
  let out : Array[@kernel.Message] = []
  let mut injected = false
  for m in messages {
    let is_memory_msg = match m {
      @kernel.SystemMessage(content~) =>
        match content {
          [@kernel.Text(s), ..] => s.has_prefix(memory_marker)
          _ => false
        }
      _ => false
    }
    if is_memory_msg {
      out.push(memory_msg)
      injected = true
    } else {
      out.push(m)
    }
  }
  if !injected {
    let final_out : Array[@kernel.Message] = []
    if out.length() > 0 {
      match out[0] {
        @kernel.SystemMessage(..) => {
          final_out.push(out[0])
          final_out.push(memory_msg)
          for i in 1..<out.length() {
            final_out.push(out[i])
          }
        }
        _ => {
          final_out.push(memory_msg)
          for m in out {
            final_out.push(m)
          }
        }
      }
      return final_out
    }
    out.push(memory_msg)
  }
  out
}

///|
pub impl @port.Hook for MemoryRetrievalHook with fn before_model(
  self : MemoryRetrievalHook,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] raise @port.HookAbort {
  match self.extract_query(messages) {
    None => return messages
    Some(query) => {
      let entries = self.search_all(query)
      match self.build_memory_message(entries) {
        None => return messages
        Some(memory_msg) => return self.inject(messages, memory_msg)
      }
    }
  }
}

// UiRenderHook

///|
/// UiRenderHook: Hook (on_post_event) that projects events into UI render
/// intents. Non-raising by contract (both `Hook::on_post_event` and
/// `UiPort::render` are non-raising), so there is nothing to propagate.
pub(all) struct UiRenderHook {
  ui : &@port.UiPort
}

///|
pub fn UiRenderHook::UiRenderHook(ui~ : &@port.UiPort) -> UiRenderHook {
  { ui, }
}

///|
/// Render a tool-completed stage to the Notice slot.
fn UiRenderHook::render_tool_completed(
  self : UiRenderHook,
  call : @kernel.ToolCall,
  outcome : @kernel.ToolOutcome,
) -> Unit {
  let label = call.name.to_string()
  let outcome_tag = outcome.to_string()
  let intent : @port.UiRender = {
    slot: UiSlot::Notice,
    key: "tool_" + call.call_id.to_string(),
    title: Some(label),
    body: UiBody::Text(outcome_tag),
    ttl_ms: None,
  }
  self.ui.render(intent)
}

///|
/// Render a failure stage to the Status slot.
fn UiRenderHook::render_failure(
  self : UiRenderHook,
  key : String,
  reason : String,
) -> Unit {
  let intent : @port.UiRender = {
    slot: UiSlot::Status,
    key,
    title: None,
    body: UiBody::Text(reason),
    ttl_ms: None,
  }
  self.ui.render(intent)
}

///|
pub impl @port.Hook for UiRenderHook with fn on_post_event(
  self : UiRenderHook,
  stage : @port.HookStage,
) -> Unit {
  match stage {
    // ModelCompleted is intentionally NOT rendered: it is an intermediate
    // state in every tool→model round-trip, and a persistent "model
    // responded" status misleads the user into thinking the turn stalled
    // (QA issue: status shows model response while tools feed back to the
    // LLM). Hosts own progress/status; this hook surfaces tool outcomes and
    // typed failures only.
    @port.ModelCompleted(..) => ()
    @port.ToolCompleted(call~, outcome~) =>
      self.render_tool_completed(call, outcome)
    @port.ToolFailed(call~, reason~) =>
      self.render_failure(
        "tool_fail_" + call.call_id.to_string(),
        "tool " + call.name.to_string() + " failed: " + reason,
      )
    @port.ModelFailed(failure~) =>
      self.render_failure("model_fail", "model failed: " + failure.to_string())
  }
}

// NoopUiPort

///|
/// Default UiPort for headless hosts. `request` raises `Unsupported`.
pub(all) struct NoopUiPort {}

///|
pub fn NoopUiPort::NoopUiPort() -> NoopUiPort {
  NoopUiPort::{  }
}

///|
pub impl @port.UiPort for NoopUiPort with fn ui_descriptor(_self) -> @port.UiDescriptor {
  @port.UiDescriptor::empty()
}

///|
pub impl @port.UiPort for NoopUiPort with fn render(_self, _intent) -> Unit {

}

///|
pub impl @port.UiPort for NoopUiPort with fn request(_self, _req) -> @port.UiResponse {
  raise @error.UiError::Unsupported(detail="NoopUiPort has no UI backend")
}

///|
pub extend NoopUiPort with @port.UiPort::{ui_descriptor, render, request}

// CompositeUiPort

///|
/// Fan-out UiPort: `render` delivers to every contributor; `request` tries
/// each in order, first non-`Unsupported` wins.
pub(all) struct CompositeUiPort {
  contributors : Array[&@port.UiPort]
}

///|
pub fn CompositeUiPort::CompositeUiPort(
  contributors : Array[&@port.UiPort],
) -> CompositeUiPort {
  { contributors, }
}

///|
pub fn CompositeUiPort::contributors(
  self : CompositeUiPort,
) -> Array[&@port.UiPort] {
  self.contributors.copy()
}

///|
/// Concatenate autocomplete sources in registration order.
pub impl @port.UiPort for CompositeUiPort with fn ui_descriptor(self) -> @port.UiDescriptor {
  let sources : Array[@port.AutocompleteSource] = []
  for c in self.contributors {
    let d = c.ui_descriptor()
    for s in d.autocomplete_sources {
      sources.push(s)
    }
  }
  { autocomplete_sources: sources }
}

///|
/// Broadcast to every contributor in registration order. Best-effort.
pub impl @port.UiPort for CompositeUiPort with fn render(self, intent) -> Unit {
  for c in self.contributors {
    c.render(intent)
  }
}

///|
/// Try each contributor in order. First non-`Unsupported` result wins;
/// all-`Unsupported` raises `Unsupported`.
pub impl @port.UiPort for CompositeUiPort with fn request(self, req) -> @port.UiResponse {
  let mut last_unsupported_detail = "no contributors"
  for c in self.contributors {
    let result : Result[@port.UiResponse, @error.UiError] = Ok(c.request(req)) catch {
      e => Err(e)
    }
    match result {
      Ok(resp) => return resp
      Err(@error.UiError::Unsupported(detail~)) =>
        last_unsupported_detail = detail
      Err(other) => raise other
    }
  }
  raise @error.UiError::Unsupported(
    detail="no contributor supported the request; last detail=" +
      last_unsupported_detail,
  )
}

///|
pub extend CompositeUiPort with @port.UiPort::{ui_descriptor, render, request}
