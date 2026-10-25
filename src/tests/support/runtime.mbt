///|
/// Custom-runtime fake: wraps a `PortRuntime` and records what crosses the
/// public seam (effect contexts, cancel calls). `control` is wired after
/// Agent construction so `execute_tool` can abort mid-run.
pub(all) struct FakeRuntime {
  inner : @runtime.PortRuntime
  mut bound_support : Bool
  mut deny_tools : Bool
  mut fail_tool : String?
  seen_contexts : Array[@runtime.EffectContext]
  seen_scopes : Array[@kernel.InvocationScope]
  mut cancel_calls : Int32
  cancel_seen : Array[Array[@kernel.EffectId]]
  mut cancel_report : ((Array[@kernel.EffectId]) -> Array[
    (@kernel.EffectId, @kernel.CancelDisposition),
  ])?
  mut control : @agent.AgentControl?
  mut abort_on_tool : Bool
  mut follow_up_on_tool : Bool
  mut follow_up_sent : Bool
  /// One-shot hook fired inside the first `execute_tool` — lets a test
  /// mutate external state (e.g. a CatalogSource) mid-run.
  mut on_first_execute : (() -> Unit)?
}

///|
pub fn FakeRuntime::FakeRuntime(inner : @runtime.PortRuntime) -> FakeRuntime {
  {
    inner,
    bound_support: false,
    deny_tools: false,
    fail_tool: None,
    seen_contexts: [],
    seen_scopes: [],
    cancel_calls: 0,
    cancel_seen: [],
    cancel_report: None,
    control: None,
    abort_on_tool: false,
    follow_up_on_tool: false,
    follow_up_sent: false,
    on_first_execute: None,
  }
}

///|
pub extend FakeRuntime with @runtime.Runtime::{
  supports_bound_tools,
  call_model,
  execute_tool,
  cancel_effects,
  compact,
}

///|
pub impl @runtime.Runtime for FakeRuntime with fn supports_bound_tools(self) -> Bool {
  self.bound_support
}

///|
pub impl @runtime.Runtime for FakeRuntime with fn call_model(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tool_definitions : Array[@kernel.ToolDef],
  call_options : Json,
  on_chunk : ((@types.StreamChunk) -> Unit)?,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  self.seen_scopes.push(scope)
  return @runtime.Runtime::call_model(
    self.inner,
    scope,
    messages,
    tool_definitions,
    call_options,
    on_chunk,
  )
}

///|
pub impl @runtime.Runtime for FakeRuntime with fn execute_tool(
  self,
  ctx : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  self.seen_contexts.push(ctx)
  if self.fail_tool == Some(ctx.tool_name.to_string()) {
    raise @error.RuntimeError::InvocationFailed("child dispatch fault")
  }
  if self.deny_tools {
    return RuntimeFailure(
      error_category="HostDenied",
      message="host refused execution",
    )
  }
  match self.on_first_execute {
    Some(hook) => {
      self.on_first_execute = None
      hook()
    }
    None => ()
  }
  if self.abort_on_tool {
    match self.control {
      Some(control) => ignore(control.abort_active(Some("fake runtime abort")))
      None => ()
    }
  }
  if self.follow_up_on_tool && !self.follow_up_sent {
    self.follow_up_sent = true
    match self.control {
      Some(control) =>
        ignore(
          control.enqueue_follow_up(
            UserMessage(content=[Text("background task finished")]),
          ),
        )
      None => ()
    }
  }
  @runtime.Runtime::execute_tool(self.inner, ctx)
}

///|
pub impl @runtime.Runtime for FakeRuntime with fn cancel_effects(
  self,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  self.cancel_calls = self.cancel_calls + 1
  self.cancel_seen.push(effect_ids.copy())
  match self.cancel_report {
    Some(report) => report(effect_ids)
    None => @runtime.Runtime::cancel_effects(self.inner, effect_ids, reason)
  }
}

///|
pub impl @runtime.Runtime for FakeRuntime with fn compact(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  call_options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  @runtime.Runtime::compact(
    self.inner,
    scope,
    messages,
    tools,
    call_options,
    trigger,
  )
}

///|
/// Versioned catalog fake: the test bumps `revision` and replaces `defs`
/// wholesale to simulate dynamic tool registration.
pub(all) struct FakeCatalogSource {
  mut revision : Int32
  mut defs : Array[@kernel.ToolDef]
}

///|
pub fn FakeCatalogSource::FakeCatalogSource(
  defs : Array[@kernel.ToolDef],
) -> FakeCatalogSource {
  { revision: 1, defs, }
}

///|
pub extend FakeCatalogSource with @runtime.CatalogSource::{revision, tools}

///|
pub impl @runtime.CatalogSource for FakeCatalogSource with fn revision(self) -> Int32 {
  self.revision
}

///|
pub impl @runtime.CatalogSource for FakeCatalogSource with fn tools(self) -> Array[
  @kernel.ToolDef,
] {
  self.defs
}
