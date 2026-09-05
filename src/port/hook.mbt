///|
/// One hook trait: interception points across nearly the whole agent
/// lifecycle — turn begin/end, before/after the model, before/after tools.
/// Each method is a distinct point with its own precise contract (M3.6
/// lesson: the semantics of "can abort", "can rewrite" and "read-only" must
/// not be squeezed into one signature). Every method has a default
/// implementation, so implementors override only the points they care
/// about, and adding a new interception point is non-breaking: one
/// defaulted method here plus one call site in the pump — manifest,
/// aggregation and config signatures stay untouched. Hooks run in
/// registration order at every point.
///
/// Hooks run synchronously *in the async flow*: async spreads — IO in a
/// method body propagates through async — but the pipeline dispatches each
/// hook sequentially, awaiting one before the next, and never spawns
/// threads or workers, so registration order is preserved everywhere.

// PipelineHook errors and decisions

///|
/// Raised by `PipelineHook::before_model` to stop the run before the model
/// is called.
pub(all) suberror HookAbort {
  Aborted(reason~ : String)
}

///|
pub impl Show for HookAbort with fn to_string(self : HookAbort) -> String {
  match self {
    Aborted(reason~) => "HookAbort(\{reason})"
  }
}

///|
/// The hook's decision for a pending tool call.
///
/// Chain semantics: every registered hook is evaluated (no
/// short-circuit). Precedence: a raise aborts the run; `Defer`
/// terminal-rejects until M5; `ApproveAfterConsent` beats `Reject`;
/// `Reject` skips the call and feeds the joined reasons back to the model
/// as a `NotExecuted(RejectedByHook)` tool result; otherwise the call
/// executes with the chained rewrite. The complete chain is finalized before
/// catalog validation and scheduling, so the final call determines its
/// schema, owner, and execution policy. Consent binds to the exact
/// `call_id`, name, and arguments returned by that consent decision; a later
/// mutation cannot reuse it, and `call_id` is never rewriteable.
pub(all) enum ToolDecision {
  /// Execute the tool, possibly with a rewritten call. Rewrites are finalized
  /// and validated after every hook has run.
  Approve(call~ : @kernel.ToolCall)
  /// Execute because the user explicitly consented (permission approval
  /// or remembered session approval). Behaves like `Approve` but beats
  /// any `Reject` in the chain; only raising outranks it.
  /// `consent_scope` names what the user agreed to (e.g. `bash:ls`). The
  /// consent applies only to the exact call carried by this decision.
  ApproveAfterConsent(call~ : @kernel.ToolCall, consent_scope~ : String)
  /// Request suspension: keep the call pending so the host can resolve it
  /// later. **Current runtime semantics: treated as a terminal reject** —
  /// the run aborts, surfaced to the caller as `AgentError::PipelineAborted`
  /// ("pre_tool_hook defer not yet supported: …"). True suspend/resume is
  /// M5 work; do not rely on `Defer` for suspension today.
  Defer(reason~ : String)
  /// Skip this call: resolved as `NotExecuted(RejectedByHook)` whose
  /// `reason` is fed back to the model; the run continues on the next
  /// model step. Raising stays terminal; another hook's
  /// `ApproveAfterConsent` overrides this.
  Reject(reason~ : String)
} derive(Debug)

///|
pub impl Show for ToolDecision with fn to_string(self : ToolDecision) -> String {
  match self {
    Approve(call~) => "Approve(\{call.call_id.to_string()})"
    ApproveAfterConsent(call~, consent_scope~) =>
      "ApproveAfterConsent(\{call.call_id.to_string()}, scope=\{consent_scope})"
    Defer(reason~) => "Defer(\{reason})"
    Reject(reason~) => "Reject(\{reason})"
  }
}

// Post-event stage

///|
/// Describes what just completed, delivered after the effect is committed.
pub(all) enum HookStage {
  /// Model call completed successfully.
  ModelCompleted(completion~ : @kernel.Completion)
  /// Tool call completed (success, error, NotExecuted).
  ToolCompleted(call~ : @kernel.ToolCall, outcome~ : @kernel.ToolOutcome)
  /// Tool call failed at the adapter level.
  ToolFailed(call~ : @kernel.ToolCall, reason~ : String)
  /// Model call failed at the adapter level.
  ModelFailed(failure~ : @kernel.ModelFailure)
} derive(Debug)

///|
pub impl Show for HookStage with fn to_string(self : HookStage) -> String {
  match self {
    ModelCompleted(..) => "ModelCompleted"
    ToolCompleted(call~, ..) => "ToolCompleted(\{call.call_id.to_string()})"
    ToolFailed(call~, ..) => "ToolFailed(\{call.call_id.to_string()})"
    ModelFailed(..) => "ModelFailed"
  }
}

// The PipelineHook trait

///|
/// Pipeline interception points covering nearly the whole agent lifecycle:
/// turn begin/end, before/after the model, before/after tools.
/// Registration is unified: an extension puts `self` (or any implementor)
/// into the manifest's single `hooks` array and overrides the methods for
/// the points it cares about.
///
/// - `on_turn_begin`: async turn-start slot. Dispatched once per
///   `run_single_turn`, after the `TurnStarted` observer projection and
///   before the pump's first `before_model`. Symmetric with `on_turn_end`:
///   pre-turn failures (agent-shutdown guard, lifecycle `on_start` raises)
///   dispatch nothing — the turn never began. A raise is a secondary
///   failure — reported to observers, never failing the turn — and later
///   hooks still run; cancellation is not a defect.
/// - `before_model`: invoked before the model is called. Can rewrite
///   messages or raise `HookAbort`. Multiple hooks form a chained rewrite
///   pipeline — each hook sees the previous hook's output.
/// - `before_tool`: invoked before every tool execution. Every hook is
///   evaluated; merge precedence on `ToolDecision` (consent beats
///   Reject; Defer still aborts the run until M5).
/// - `on_post_event`: invoked after every effect completes. Read-only and
///   non-raising — all registered hooks run in registration order; a
///   handler cannot fail in a typed way, and a contract violation aborts
///   loudly by design. For interception or abortion use `before_model` /
///   `before_tool`.
/// - `on_post_event_at`: scoped variant of `on_post_event`, additionally
///   carrying the `EventScope` attribution of the run that committed the
///   effect. The core dispatches ONLY this variant; its default delegates
///   to `on_post_event`, so pre-scope hooks keep working unchanged.
/// - `on_turn_end`: async turn-end slot, no payload. The terminal outcome
///   already lives on the Observer channel — `TurnCompleted` /
///   `TurnFailed(String)` — and an extension typically implements Observer
///   and PipelineHook as two views over one shared struct, so a hook that
///   needs the outcome reads its own observer-side state instead of a
///   second payload type. Dispatched
///   once per `run_turn`, after the terminal observer projection
///   (`TurnCompleted` / `TurnFailed`) and before the call returns — on both
///   the completed and the failed path. This is the slot for side effects
///   that must finish by turn end, such as committing buffered writes to an
///   external system. Implementations must carry their own timeout budget
///   and may not block the turn's return indefinitely. Division of labor
///   with `Observer::on_event_at(TurnCompleted)`: the observer slot is
///   sync, read-only and fires first; `on_turn_end` may await. A raise from
///   `on_turn_end` is a secondary failure — reported to observers, never
///   replacing the turn's primary outcome — and cancellation is not a
///   defect.
///
/// Async spread: the slots are `async`, so IO in an implementation body
/// propagates through async. The pipeline dispatches hooks sequentially —
/// each hook is awaited before the next runs — and never opens a thread or
/// worker, so registration order is preserved at every point.
pub(open) trait PipelineHook {
  /// `before_model` is `async` so hooks whose rewrite needs IO can await.
  /// Synchronous implementations write a plain `fn` body — a sync body
  /// satisfies an `async` trait slot under MoonBit's colorless-coroutine
  /// model. Raising `HookAbort` stops the run before the model is called.
  async fn before_model(Self, messages : Array[@kernel.Message]) -> Array[
    @kernel.Message,
  ] raise HookAbort = _
  /// `before_tool` is `async` so hooks that need host interaction (e.g. an
  /// approval prompt over `UiPort::request`) can suspend. Hooks that decide
  /// synchronously implement it as a plain `fn` — a sync `fn` satisfies an
  /// `async` trait slot under MoonBit's colorless-coroutine model. Raising
  /// from `before_tool` aborts the run as a terminal `HookRejected`; a
  /// cancellation error stays classified as cancellation, not a hook defect.
  async fn before_tool(Self, call : @kernel.ToolCall) -> ToolDecision = _
  /// `on_post_event` is `async` so read-only observers of effects (e.g. a
  /// telemetry sink) can await their IO. `noraise` keeps the read-only,
  /// non-raising contract: a handler cannot fail in a typed way. Sync bodies
  /// keep working unchanged.
  async fn on_post_event(Self, stage : HookStage) -> Unit noraise = _
  async fn on_post_event_at(Self, scope : @types.EventScope?, stage : HookStage) -> Unit noraise = _
  async fn on_turn_begin(Self) -> Unit = _
  /// `on_turn_end` is `async` so hooks with turn-end side effects that must
  /// complete before the turn returns (e.g. committing buffered writes to an
  /// external system) can await. The terminal outcome is not a payload: read
  /// it from the Observer channel (`TurnCompleted` / `TurnFailed`), which an
  /// extension shares state with as a second view over the same struct.
  /// Synchronous implementations write a plain `fn` body — a sync `fn`
  /// satisfies an `async` trait slot under MoonBit's colorless-coroutine
  /// model.
  async fn on_turn_end(Self) -> Unit = _
}

///|
/// Default `before_model`: pass messages through unchanged.
impl PipelineHook with fn before_model(_self, messages : Array[@kernel.Message]) -> Array[
  @kernel.Message,
] {
  messages
}

///|
/// Default `before_tool`: approve the call unchanged.
impl PipelineHook with fn before_tool(_self, call : @kernel.ToolCall) -> ToolDecision {
  Approve(call~)
}

///|
/// Default `on_post_event`: no-op.
impl PipelineHook with fn on_post_event(_self, _stage : HookStage) -> Unit {
  ()
}

///|
/// Default `on_post_event_at`: drop the scope and delegate to
/// `on_post_event`. Override this instead when run attribution matters.
impl PipelineHook with fn on_post_event_at(
  self,
  _scope : @types.EventScope?,
  stage : HookStage,
) -> Unit {
  self.on_post_event(stage)
}

///|
/// Default `on_turn_begin`: no-op.
impl PipelineHook with fn on_turn_begin(_self) -> Unit {
  ()
}

///|
/// Default `on_turn_end`: no-op. Sync body satisfies the async slot.
impl PipelineHook with fn on_turn_end(_self) -> Unit {
  ()
}
