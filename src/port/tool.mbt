///|
/// Effect-scoped execution context handed to `ToolProvider::execute`.
///
/// `effect_id` is the reducer-assigned identity of this `ExecuteTool`
/// effect — the exact id a later cancellation carries, so a provider that
/// owns interruptible work (a subprocess, a request) keys its in-flight
/// state by it. `call_id`, `name`, and `arguments` identify the model's
/// tool call.
pub struct ToolCallContext {
  effect_id : @kernel.EffectId
  call_id : @kernel.CallId
  name : @kernel.ToolName
  arguments : Json
  /// Register the cancellable facet for THIS effect. Providers that cannot
  /// be interrupted simply never call it; the runtime then reports
  /// `NotPropagated` for the effect, exactly as a ports-only agent does
  /// today. The registrar is valid only during the execute call it
  /// arrived in.
  register_cancel : (&ToolCancellable) -> Unit
  scope : @kernel.InvocationScope?
  parent_effect_id : @kernel.EffectId?
  root_effect_id : @kernel.EffectId
  priv tools_ : () -> Array[@kernel.ToolDef]
  priv invoke_ : (async (String, Json) -> @kernel.InvocationResult)?
  priv active_ : () -> Bool
}

///|
/// Framework construction seam. An ordinary manually constructed context has
/// no invocation authority. Supplied callbacks are local to this effect scope.
pub fn ToolCallContext::ToolCallContext(
  effect_id~ : @kernel.EffectId,
  call_id~ : @kernel.CallId,
  name~ : @kernel.ToolName,
  arguments~ : Json,
  register_cancel~ : (&ToolCancellable) -> Unit,
  scope? : @kernel.InvocationScope,
  parent_effect_id? : @kernel.EffectId,
  root_effect_id? : @kernel.EffectId,
  tools~ : () -> Array[@kernel.ToolDef] = fn() { [] },
  invoke? : async (String, Json) -> @kernel.InvocationResult,
  active~ : () -> Bool = fn() { true },
) -> ToolCallContext {
  {
    effect_id,
    call_id,
    name,
    arguments,
    scope,
    parent_effect_id,
    root_effect_id: root_effect_id.unwrap_or(effect_id),
    register_cancel: handler => if active() { register_cancel(handler) },
    tools_: tools,
    invoke_: invoke,
    active_: active,
  }
}

///|
pub fn ToolCallContext::tools(self : ToolCallContext) -> Array[@kernel.ToolDef] {
  if (self.active_)() {
    (self.tools_)()
  } else {
    []
  }
}

///|
pub async fn ToolCallContext::invoke(
  self : ToolCallContext,
  name : String,
  arguments : Json,
) -> @kernel.InvocationResult raise @error.RuntimeError {
  if !(self.active_)() {
    return Interrupted(
      reason="tool invocation scope has ended",
      cancellation=AlreadySettled,
      side_effects_possible=false,
    )
  }
  match self.invoke_ {
    Some(invoke) =>
      invoke(name, arguments) catch {
        error => raise @error.RuntimeError::InvocationFailed(error.to_string())
      }
    None =>
      Interrupted(
        reason="tool invocation scope is unavailable",
        cancellation=NotPropagated,
        side_effects_possible=false,
      )
  }
}

///|
/// Cancellation facet a `ToolProvider` may also implement for effects it
/// owns. Register via `ToolCallContext.register_cancel` inside `execute`;
/// the runtime routes a later cancel back through the same `effect_id`.
///
/// Idempotent per execution. `Propagated` means only that a signal was sent;
/// `Stopped` requires confirmation that owned work has stopped (not rollback).
/// Return `AlreadySettled` for previously completed work. Core bounds cleanup
/// attempts and retains unresolved registrations on failure or timeout so
/// shutdown can retry; never disguise an error as confirmed termination.
pub(open) trait ToolCancellable {
  async fn cancel(
    Self,
    effect_id : @kernel.EffectId,
    reason : @kernel.CancelReason,
  ) -> @kernel.CancelDisposition
}

///|
/// `ToolProvider`: declare tools via `list_tools()`, execute via `execute()`.
///
/// Agent binds each definition's owner to the declaring manifest. Providers
/// declare their own execution policy and exposure; these are not inferred
/// from names or provenance. `execute` returns the canonical ToolOutcome.
///
/// A composing tool must reserve a policy strong enough for its children:
/// Parallel cannot invoke Sequential/Exclusive; Sequential cannot invoke
/// Exclusive. Such requests are rejected before starting, not upgraded at
/// runtime. The parent's scheduling slot covers the whole joined subtree.
pub(open) trait ToolProvider {
  /// Read once per static assembly or dynamic publication. Agent deep-copies
  /// definitions and replaces owner with the manifest id. Choose Sequential
  /// for isolated execution; Parallel explicitly permits concurrent effects.
  /// Exposure defaults to Direct and operation hooks may only narrow it.
  fn list_tools(Self) -> Array[@kernel.ToolDef]

  /// Execute one tool call described by `ctx`. The provider maps its
  /// internal result/error to `ToolOutcome`: `Success` for normal returns,
  /// `ToolReportedError` for business-level failures the model should see,
  /// and let posoco's catch-all convert raised `RuntimeError` to
  /// `RuntimeFailure`. Providers that own interruptible work register a
  /// `ToolCancellable` facet via `ctx.register_cancel` before starting it.
  async fn execute(Self, ctx : ToolCallContext) -> @kernel.ToolOutcome raise @error.RuntimeError
}
