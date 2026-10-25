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
  let call_ctx = @port.ToolCallContext(
    effect_id=@kernel.EffectId::first(),
    call_id~,
    name=call.name,
    arguments=call.arguments,
    register_cancel=fn(_ : &@port.ToolCancellable) { () },
  )
  provider.execute(call_ctx) catch {
    error =>
      @kernel.ToolOutcome::RuntimeFailure(
        error_category="ScopedToolProviderError",
        message=error.to_string(),
      )
  }
}

///|
/// Build the tool routing table. Raises CompositionError::ToolCollision on
/// the FIRST name collision (fail-fast), rather than last-wins. The
/// collision message identifies the tool name and a provenance hint for each
/// conflicting provider (ToolDef.provenance if present, else an actionable marker).
fn build_tool_routing(
  tools : Array[&@port.ToolProvider],
) -> ToolRouting raise @error.CompositionError {
  let tool_map : Map[String, &@port.ToolProvider] = Map::from_array([])
  let seen_names = ToolNameIndex::new()
  for provider in tools {
    let tool_defs = provider.list_tools()
    for tool in tool_defs {
      let name = tool.name.to_string()
      let provenance = tool_provenance(tool)
      match seen_names.record(name, provenance) {
        Some(labels) =>
          // T06-B: fail-fast on collision. The error names the tool and both
          // sources so the caller can locate the conflict without guessing.
          raise ToolCollision(
            safe_error_label(name),
            tool_collision_message(labels[0], provenance),
            manifests=[],
          )
        None => ()
      }
      tool_map[name] = provider
    }
  }
  { tool_map, }
}

///|
/// Legacy provisional ScopedToolDispatch assembly. Agent does not call this:
/// its manifest-bound entries are assembled once in aggregate_extensions.
/// Remove this helper with the old scoped bypass when real invoke lands.
fn provider_tool_defs(
  providers : Array[&@port.ToolProvider],
) -> Array[@kernel.ToolDef] {
  let defs : Array[@kernel.ToolDef] = []
  for provider in providers {
    for tool in provider.list_tools() {
      let owner_str = tool.owner.to_string()
      let owner : @kernel.OwnerId = if owner_str == "placeholder" ||
        owner_str == "" {
        match tool.provenance {
          Some(p) if p != "" => @kernel.OwnerId::unchecked(p)
          _ => @kernel.OwnerId::unchecked("legacy_provider")
        }
      } else {
        tool.owner
      }
      defs.push(
        ToolDef(
          name=tool.name,
          description=tool.description,
          input_schema=tool.input_schema,
          owner~,
          policy=tool.policy,
          provenance=tool.provenance,
          exposure=tool.exposure,
        ),
      )
    }
  }
  defs
}

///|
/// Legacy scoped/test catalog, not the Agent assembly path.
fn build_agent_catalog(
  providers : Array[&@port.ToolProvider],
) -> @kernel_exec.ToolCatalogSnapshot raise @error.CompositionError {
  build_catalog_from_defs(provider_tool_defs(providers), CatalogVersion(1))
}
