///|
/// Built-in adapters: Posoco-provided implementations of port traits.
///
/// These structs are concrete adapters, not extension contracts — they live
/// in the root package (not `src/port/`) so the port package contains only
/// the intentional `pub(open)` traits community extensions implement.
/// Extension authors may register their own hook implementations instead of
/// or alongside these.

// SystemPromptHook — PipelineHook impl that assembles + injects the prompt

///|
/// Combines a fixed base prompt with contributor sections and prepends the
/// result as a single System message at index 0. Empty sections are skipped.
///
/// The assembled prompt is cached lazily on the first call to `before_model`.
/// Laziness matters because extension `Lifecycle::on_start` callbacks run
/// inside the first `run_single_turn` but before the first `before_model`, so
/// contributors whose state is initialized in `on_start` must be read after
/// that point. After caching, the text is frozen for the lifetime of the hook.
pub(all) struct SystemPromptHook {
  base_prompt : String
  contributors : Array[SystemPromptSection]
  mut assembled : String?
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
  { id, contributor, }
}

///|
pub fn SystemPromptHook::SystemPromptHook(
  base_prompt~ : String,
  contributors~ : Array[SystemPromptSection],
) -> SystemPromptHook {
  { base_prompt, contributors, assembled: None, }
}

///|
/// Assemble base + non-empty contributor sections with `id:` headers.
/// Sections are separated by a blank line (`\n\n`). The result is empty when
/// the base prompt and every contributor return empty strings.
pub fn SystemPromptHook::assemble(self : SystemPromptHook) -> String {
  let sections : Array[String] = []
  if self.base_prompt != "" {
    sections.push(self.base_prompt)
  }
  for s in self.contributors {
    let text = s.contributor.system_prompt()
    if text != "" {
      sections.push("\{s.id}:\n\{text}")
    }
  }
  sections.join("\n\n")
}

///|
/// Inject one stable SystemMessage at index 0.
///
/// Semantics:
/// 1. If the assembled prompt is empty, return `messages` unchanged.
/// 2. If `messages` is empty, return `[SystemMessage(assembled)]`.
/// 3. If `messages[0]` is a SystemMessage with the exact same text, return
///    the same array instance (no rewrite, no journal noise).
/// 4. If `messages[0]` is a SystemMessage with different text, replace it.
/// 5. Otherwise prepend the new SystemMessage.
pub impl @port.PipelineHook for SystemPromptHook with fn before_model(
  self : SystemPromptHook,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] raise @port.HookAbort {
  let assembled = match self.assembled {
    Some(text) => text
    None => {
      let text = self.assemble()
      self.assembled = Some(text)
      text
    }
  }
  if assembled == "" {
    return messages
  }
  let sys_msg : @kernel.Message = @kernel.SystemMessage(content=[
    @kernel.Text(assembled),
  ])
  if messages.length() == 0 {
    return [sys_msg]
  }
  match messages[0] {
    @kernel.SystemMessage(content~) => {
      match content {
        [@kernel.Text(existing), ..] if existing == assembled => return messages
        _ => ()
      }
      let new_messages : Array[@kernel.Message] = [sys_msg]
      new_messages.append(messages[1:])
      new_messages
    }
    _ => {
      let new_messages : Array[@kernel.Message] = [sys_msg]
      new_messages.append(messages)
      new_messages
    }
  }
}

// UiRenderHook

///|
/// UiRenderHook: PipelineHook (on_post_event) that projects events into UI render
/// intents. Non-raising by contract (both `PipelineHook::on_post_event` and
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
    key: "tool_\{call.call_id.to_string()}",
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
pub impl @port.PipelineHook for UiRenderHook with fn on_post_event(
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
        "tool_fail_\{call.call_id.to_string()}",
        "tool \{call.name.to_string()} failed: \{reason}",
      )
    @port.ModelFailed(failure~) =>
      self.render_failure("model_fail", "model failed: \{failure.to_string()}")
  }
}

// NoopUiPort

///|
/// Default UiPort for headless hosts. `request` raises `Unsupported`.
pub(all) struct NoopUiPort {}

///|
pub fn NoopUiPort::NoopUiPort() -> NoopUiPort {
  NoopUiPort::{ }
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
  { autocomplete_sources: sources, }
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
    detail="no contributor supported the request; last detail=\{last_unsupported_detail}",
  )
}

///|
pub extend CompositeUiPort with @port.UiPort::{ui_descriptor, render, request}
