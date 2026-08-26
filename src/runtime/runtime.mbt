///|
/// Public runtime seam (experimental): `Runtime` is the supported
/// correspondence of the internal effect-execution boundary. Advanced hosts
/// implement or wrap it to customize how effects are executed — cancellation
/// propagation, effect correlation, remote execution — while Posoco keeps
/// owning the run loop, journal, mailbox, and session commit.
///
/// Vocabulary: **Ports** are for extension authors (default path);
/// **Runtime** is for host builders (`Agent::with_runtime`). The run loop
/// itself is never public.

///|
/// Stable execution context for a single tool effect. `effect_id` is the
/// reducer-allocated identity of the `ExecuteTool` effect — the same id the
/// runtime later receives in `cancel_effects`. Runtimes that propagate
/// cancellation MUST key their in-flight execution state (e.g. an
/// `AbortController`) by `effect_id`, not by execution order or call content.
pub(all) struct EffectContext {
  effect_id : @kernel.EffectId
  owner : @kernel.OwnerId
  call_id : @kernel.CallId
  tool_name : @kernel.ToolName
  arguments : Json
}

///|
/// The public effect-execution contract. Mirrors the internal boundary 1:1;
/// Posoco adapts it mechanically (a thin shim packs/unpacks `EffectContext`),
/// so this trait never grows semantics the internal loop does not have.
///
/// Implementors usually wrap `PortRuntime` and override only the methods
/// they need (typically `execute_tool` + `cancel_effects`); see
/// `docs/RUNTIME.md`.
pub(open) trait Runtime {
  /// Execute a `CallModel` effect. `on_chunk` is the live streaming sink;
  /// `None` means the product did not enable streaming. `scope` carries the
  /// run/session identity; `scope.effect_id` is always `Some` here and hosts
  /// that propagate cancellation MUST key in-flight model calls by it,
  /// mirroring `EffectContext.effect_id` on the tool side. `messages` is an
  /// `ArrayView` borrow valid only for the duration of the call; hosts must
  /// not retain it.
  async fn call_model(
    Self,
    scope : @kernel.InvocationScope,
    messages : ArrayView[@kernel.Message],
    tool_definitions : Array[@kernel.ToolDef],
    call_options : Json,
    on_chunk : ((@types.StreamChunk) -> Unit)?,
  ) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure]

  /// Execute a single tool call described by `ctx`. Business errors map to
  /// `ToolReportedError`; transport/runtime errors map to `RuntimeFailure`.
  /// A well-formed runtime never returns `NotExecuted` (that is a
  /// reducer-side category).
  async fn execute_tool(Self, ctx : EffectContext) -> @kernel.ToolOutcome

  /// Best-effort cancel. Fire-and-forget from the loop's perspective; the
  /// returned dispositions are recorded for observability. MUST be
  /// idempotent per effect id: cancelling an already-settled effect reports
  /// `AlreadySettled`, never raises.
  async fn cancel_effects(
    Self,
    effect_ids : Array[@kernel.EffectId],
    reason : @kernel.CancelReason,
  ) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)]

  /// Compact the conversation. Forwarded to the model side; `trigger` lets
  /// the implementation pick a strategy (Auto = cheap elision, Manual =
  /// thorough). `scope.effect_id` is always `None` here: compact is
  /// host-driven, not a reducer-allocated effect. `messages` is an `ArrayView`
  /// borrow valid only for the duration of the call; hosts must not retain it.
  async fn compact(
    Self,
    scope : @kernel.InvocationScope,
    messages : ArrayView[@kernel.Message],
    call_options : Json,
    trigger : @kernel.CompactTrigger,
  ) -> Result[@kernel.CompactResult, @kernel.ModelFailure]
}
