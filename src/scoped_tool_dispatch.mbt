///|
/// Tool dispatch service for a program with a fixed composed capability
/// snapshot. This is NOT an alternate agent loop or a reducer-owned Effect.
/// It executes only leaf tools that are passed explicitly at composition.
/// Every request is checked against the same catalog validator and the
/// supplied PipelineHook::before_tool chain as normal tool calls.
/// Consumers must not grant recursive program execution.
pub struct ScopedToolDispatch {
  priv catalog : @kernel_exec.ToolCatalogSnapshot
  priv routes : Map[String, &@port.ToolProvider]
  priv hooks : Array[&@port.PipelineHook]
  priv mut next_call : Int32
}

///|
pub fn ScopedToolDispatch::ScopedToolDispatch(
  tools : Array[&@port.ToolProvider],
  hooks~ : Array[&@port.PipelineHook] = [],
) -> ScopedToolDispatch raise @error.CompositionError {
  let routing = build_tool_routing(tools)
  let catalog = build_agent_catalog(tools)
  { catalog, routes: routing.tool_map, hooks: hooks.copy(), next_call: 0, }
}

///|
/// A nested program call cannot be recursively dispatched to run_code,
/// regardless of whether a host accidentally included it in the catalog.
pub async fn ScopedToolDispatch::call(
  self : ScopedToolDispatch,
  name : String,
  arguments : Json,
) -> @kernel.ToolOutcome {
  if name == "run_code" {
    return @kernel.ToolReportedError(
      content="recursive program calls are not admitted",
      structured=None,
    )
  }
  self.next_call += 1
  let call_id = @kernel.CallId::unchecked(
    "scoped-" + self.next_call.to_string(),
  )
  let mut call : @kernel.ToolCall = {
    call_id,
    name: @kernel.ToolName::unchecked(name),
    arguments,
  }
  let mut rejection : String? = None
  let mut consented : @kernel.ToolCall? = None
  for hook in self.hooks {
    let decision = hook.before_tool({
      call_id: call.call_id,
      name: call.name,
      arguments: @json.parse(call.arguments.stringify()) catch {
        _ => Json::null()
      },
    }) catch {
      error =>
        return @kernel.ToolReportedError(
          content="scoped hook failed: " + error.to_string(),
          structured=None,
        )
    }
    match decision {
      @port.ToolDecision::Approve(call=rewritten) => {
        if rewritten.call_id != call_id {
          return @kernel.ToolReportedError(
            content="nested hook attempted to change call identity",
            structured=None,
          )
        }
        call = rewritten
      }
      @port.ToolDecision::ApproveAfterConsent(call=approved, consent_scope=_) => {
        if approved.call_id != call_id {
          return @kernel.ToolReportedError(
            content="nested hook attempted to change call identity",
            structured=None,
          )
        }
        call = approved
        consented = Some(approved)
      }
      @port.ToolDecision::Reject(reason~) => rejection = Some(reason)
      @port.ToolDecision::Defer(reason~) =>
        return @kernel.ToolReportedError(
          content="nested tool deferred: " + reason,
          structured=None,
        )
    }
  }
  if consented is Some(granted) && granted != call {
    return @kernel.ToolReportedError(
      content="nested tool changed after approval",
      structured=None,
    )
  }
  if rejection is Some(reason) && consented is None {
    return @kernel.ToolReportedError(content=reason, structured=None)
  }
  let selected = call.name.to_string()
  if selected == "run_code" || !self.catalog.contains(call.name) {
    return @kernel.ToolReportedError(
      content="nested tool capability unavailable: " + selected,
      structured=None,
    )
  }
  match self.catalog.validate_arguments(call.name, call.arguments) {
    Err(diagnostic) =>
      return @kernel.ToolReportedError(
        content="nested tool schema mismatch: " + diagnostic.json_path,
        structured=None,
      )
    Ok(_) => ()
  }
  let provider = match self.routes.get(selected) {
    Some(provider) => provider
    None =>
      return @kernel.ToolReportedError(
        content="nested tool provider unavailable",
        structured=None,
      )
  }
  // This provisional dispatch is owned by the enclosing program; its
  // cancellation must unwind the child as part of the program's task group.
  // The reducer never allocates a separate EffectId for this operation.
  let call_ctx : @port.ToolCallContext = {
    effect_id: @kernel.EffectId::first(),
    call_id,
    name: call.name,
    arguments: call.arguments,
    register_cancel: fn(_ : &@port.ToolCancellable) { () },
  }
  provider.execute(call_ctx) catch {
    error =>
      @kernel.ToolOutcome::RuntimeFailure(
        error_category="ScopedToolProviderError",
        message=error.to_string(),
      )
  }
}
