///|
/// UiRenderHook: PostEventHook that projects events into UI render intents.
/// Best-effort, non-fatal — hook failures never propagate.
pub(all) struct UiRenderHook {
  ui : &UiPort
}

///|
pub fn UiRenderHook::UiRenderHook(ui~ : &UiPort) -> UiRenderHook {
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
  let intent : UiRender = {
    slot: Notice,
    key: "tool_" + call.call_id.to_string(),
    title: Some(label),
    body: Text(outcome_tag),
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
  let intent : UiRender = {
    slot: Status,
    key,
    title: None,
    body: Text(reason),
    ttl_ms: None,
  }
  self.ui.render(intent)
}

///|
pub impl PostEventHook for UiRenderHook with fn on_post_event(
  self : UiRenderHook,
  stage : PostStage,
) -> Unit {
  match stage {
    // ModelCompleted is intentionally NOT rendered: it is an intermediate
    // state in every tool→model round-trip, and a persistent "model
    // responded" status misleads the user into thinking the turn stalled
    // (QA issue: status shows model response while tools feed back to the
    // LLM). Hosts own progress/status; this hook surfaces tool outcomes and
    // typed failures only.
    ModelCompleted(..) => ()
    ToolCompleted(call~, outcome~) => self.render_tool_completed(call, outcome)
    ToolFailed(call~, reason~) =>
      self.render_failure(
        "tool_fail_" + call.call_id.to_string(),
        "tool " + call.name.to_string() + " failed: " + reason,
      )
    ModelFailed(failure~) =>
      self.render_failure("model_fail", "model failed: " + failure.to_string())
  }
}
