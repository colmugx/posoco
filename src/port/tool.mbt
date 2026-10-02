///|
/// Effect-scoped execution context handed to `ToolProvider::execute`.
///
/// `effect_id` is the reducer-assigned identity of this `ExecuteTool`
/// effect — the exact id a later cancellation carries, so a provider that
/// owns interruptible work (a subprocess, a request) keys its in-flight
/// state by it. `call_id`, `name`, and `arguments` identify the model's
/// tool call.
pub(all) struct ToolCallContext {
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
}

///|
/// Cancellation facet a `ToolProvider` may also implement for effects it
/// owns. Register via `ToolCallContext.register_cancel` inside `execute`;
/// the runtime routes a later cancel back through the same `effect_id`.
///
/// Contract (mirrors the Runtime seam's `cancel_effects`): best effort and
/// idempotent per effect id; must not raise. A typical implementation
/// signals the child, waits out a bounded grace period, then hard-kills,
/// reporting `Propagated`. Stale entries for already-exited children are
/// the provider's own state to prune.
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
/// R3 M3.7: signatures use canonical kernel types directly. `ToolDef` carries
/// owner + policy at the catalog level; `list_tools` returns the kernel
/// `ToolDef` minus those (they are filled in by the catalog builder, since
/// they depend on the agent's tool-routing configuration, not on the tool
/// itself). `execute` returns `ToolOutcome` so business errors, runtime
/// errors, and not-executed cases are all distinguishable without a boolean.
pub(open) trait ToolProvider {
  /// Declare the tools this provider offers. The catalog builder augments
  /// each `ToolDef` with owner + execution policy when composing the
  /// snapshot, so providers do not need to fill those fields here. Use
  /// `OwnerId::unchecked("placeholder")` and `Parallel` (the safe default)
  /// — they will be overwritten.
  fn list_tools(Self) -> Array[@kernel.ToolDef]

  /// Execute one tool call described by `ctx`. The provider maps its
  /// internal result/error to `ToolOutcome`: `Success` for normal returns,
  /// `ToolReportedError` for business-level failures the model should see,
  /// and let posoco's catch-all convert raised `RuntimeError` to
  /// `RuntimeFailure`. Providers that own interruptible work register a
  /// `ToolCancellable` facet via `ctx.register_cancel` before starting it.
  async fn execute(Self, ctx : ToolCallContext) -> @kernel.ToolOutcome raise @error.RuntimeError
}
