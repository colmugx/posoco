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
/// Render a model-completed stage to the Status slot.
fn UiRenderHook::render_model_completed(
  self : UiRenderHook,
  completion : @kernel.Completion,
) -> Unit {
  let tool_count = completion.tool_calls().length()
  let body : UiBody = if tool_count > 0 {
    Text(
      "model responded (requested " + tool_count.to_string() + " tool calls)",
    )
  } else {
    Text("model responded")
  }
  let intent : UiRender = {
    slot: Status,
    key: "model_status",
    title: None,
    body,
    ttl_ms: None,
  }
  self.ui.render(intent)
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
    ModelCompleted(completion~) => self.render_model_completed(completion)
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
