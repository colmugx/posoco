///|
/// DangerousCommandHook — PipelineHook that defers "hack" tool calls
///
/// Intercepts "hack" tool calls and defers them for the approval flow demo.
pub(all) struct DangerousCommandHook {}

///|
pub impl @posoco.PipelineHook for DangerousCommandHook with on_stage(
  self,
  stage : @posoco.Stage,
) {
  match stage {
    @posoco.BeforeTool(call) if call.name == "hack" =>
      Err(
        @posoco.HookError::Deferred(
          reason="⚠️  HACKING attempt detected! This requires admin approval. Enter 'y' to approve or 'n' to deny.",
        ),
      )
    _ => Ok(stage)
  }
}
