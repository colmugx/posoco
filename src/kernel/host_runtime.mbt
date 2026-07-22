///|
/// Host-side runtime contract for executing Kernel `Effect`s (ADR §2.5, §5).
///
/// The Kernel reducer is pure and only emits `Effect` data. Actually calling a
/// model or running a tool is a host concern. Rather than reach back into the
/// legacy `ModelPort` / `ToolProvider` traits (which live in the root
/// compatibility facade and would create a package cycle), the Kernel defines
/// this minimal `pub(open)` trait. The root facade provides a concrete
/// implementation that adapts legacy providers; M3 providers can implement it
/// directly against their own wire types.
///
/// Design rules (frozen by this contract):
/// - Inputs and outputs are ALL canonical Kernel types. The host never receives
///   a raw legacy `Message`/`ToolCall` here — it receives `CanonicalMessage`
///   and the parsed tool arguments. This is the single conversion boundary.
/// - Tool catalog definitions are passed explicitly so the model adapter sees
///   the same definitions the reducer validated against (ADR §2.7). The host
///   MUST forward the real definitions; it MUST NOT substitute an empty array
///   (that would hide a missing-catalog bug as a successful but tool-blind
///   model call — explicitly forbidden by §6.3).
/// - Every failure path returns a typed `ModelFailure` / `ToolOutcome`. The
///   host MUST NOT collapse an error into an empty success or a default
///   `Stop`. Malformed JSON from a provider surfaces as `ModelFailure::Parse`.
/// - Streaming chunks are delivered via the optional `on_chunk` callback. The
///   host MAY ignore it (non-streaming adapters). If the host has no streaming
///   support it MUST still return the final completion; it MUST NOT silently
///   drop the call.
/// - `cancel_effects` is best-effort: the host records the request and returns
///   a `CancelDisposition` per effect id (reuses the existing
///   `CancelDisposition` enum from `run_context.mbt`). The reducer never blocks
///   on cancel.
///
/// This trait is allowed to be async because hosts use async I/O. The Kernel
/// reducer never calls it — only the imperative shell (puppetry executor /
/// root adapter) does.

// ──────────────────────────────────────────────────────────────────────────
// HostRuntime trait
// ──────────────────────────────────────────────────────────────────────────

///|
/// Streaming chunk callback shape. The host delivers raw provider chunks to
/// the observer/telemetry surface without interpretation — the Kernel does not
/// define a canonical chunk type because streaming is a host/telemetry concern,
/// not a transcript fact (ADR §2.11).
pub type HostChunkCallback = (Json) -> Unit

///|
/// Host runtime contract. Implementations live outside the Kernel package
/// (root compatibility facade or M3 provider packages).
pub(open) trait HostRuntime {
  /// Execute a `CallModel` effect. The host:
  /// 1. converts `messages` + `tool_definitions` to its provider wire format,
  /// 2. calls the model (optionally streaming via `on_chunk`),
  /// 3. converts the provider response back to `AssistantCompletion`,
  /// 4. returns either the completion or a typed `ModelFailure`.
  ///
  /// `tool_definitions` is the snapshot of definitions the reducer validated;
  /// the host MUST forward them. `call_options` is opaque provider config
  /// carried verbatim from the host (temperature, max_tokens, etc.).
  async fn call_model(
    Self,
    messages : Array[CanonicalMessage],
    tool_definitions : Array[CanonicalToolDef],
    call_options : Json,
    on_chunk : HostChunkCallback,
  ) -> Result[AssistantCompletion, ModelFailure]

  /// Execute a single tool call. The host:
  /// 1. looks up the owner bound to `owner_id` at registration time,
  /// 2. invokes the provider's execute path with the parsed `arguments`,
  /// 3. maps the provider result/error to a canonical `ToolOutcome`.
  ///
  /// Missing owner / stale registration is a typed
  /// `ToolOutcome::RuntimeFailure` with `error_category="MissingOwner"`; the
  /// stateless executor promotes that category to `ToolFailed` with a Kernel
  /// `MissingOwner` invariant before it reaches the reducer. Business-level
  /// tool errors are `ToolReportedError`; transport/adapter errors are
  /// `RuntimeFailure`.
  /// `Success` is reserved for tools that ran and returned data.
  async fn execute_tool(
    Self,
    owner_id : OwnerId,
    call_id : CallId,
    tool_name : ToolName,
    arguments : Json,
  ) -> ToolOutcome

  /// Best-effort cancel. The host records each effect id and returns a
  /// disposition. This MUST NOT raise — cancel is fire-and-forget from the
  /// reducer's perspective.
  async fn cancel_effects(
    Self,
    effect_ids : Array[EffectId],
    reason : CancelReason,
  ) -> Array[(EffectId, CancelDisposition)]
}
