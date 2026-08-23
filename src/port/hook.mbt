///|
/// One hook trait: interception points on the agent pipeline. Each method
/// is a distinct point with its own precise contract (M3.6 lesson: the
/// semantics of "can abort", "can rewrite" and "read-only" must not be
/// squeezed into one signature). Every method has a default implementation,
/// so implementors override only the points they care about, and adding a
/// new interception point is non-breaking: one defaulted method here plus
/// one call site in the pump — manifest, aggregation and config signatures
/// stay untouched. Hooks run in registration order at every point.

// Hook errors and decisions

///|
/// Raised by `Hook::before_model` to stop the run before the model is
/// called.
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
/// executes with the chained rewrite.
pub(all) enum ToolHookDecision {
  /// Execute the tool, possibly with a rewritten call.
  Approve(call~ : @kernel.ToolCall)
  /// Execute because the user explicitly consented (permission approval
  /// or remembered session approval). Behaves like `Approve` but beats
  /// any `Reject` in the chain; only raising outranks it.
  /// `consent_scope` names what the user agreed to (e.g. `bash:ls`).
  ApproveAfterConsent(call~ : @kernel.ToolCall, consent_scope~ : String)
  /// Request suspension: keep the call pending so the host can resolve it
  /// later. **Current runtime semantics: treated as a terminal reject** —
  /// the run aborts with `HookRejected("pre_tool_hook defer not yet
  /// supported: …")`. True suspend/resume is M5 work; do not rely on
  /// `Defer` for suspension today.
  Defer(reason~ : String)
  /// Skip this call: resolved as `NotExecuted(RejectedByHook)` whose
  /// `reason` is fed back to the model; the run continues on the next
  /// model step. Raising stays terminal; another hook's
  /// `ApproveAfterConsent` overrides this.
  Reject(reason~ : String)
} derive(Debug)

///|
pub impl Show for ToolHookDecision with fn to_string(self : ToolHookDecision) -> String {
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

// The Hook trait

///|
/// Pipeline interception points. Registration is unified: an extension puts
/// `self` (or any implementor) into the manifest's single `hooks` array and
/// overrides the methods for the points it cares about.
///
/// - `before_model`: invoked before the model is called. Can rewrite
///   messages or raise `HookAbort`. Multiple hooks form a chained rewrite
///   pipeline — each hook sees the previous hook's output.
/// - `before_tool`: invoked before every tool execution. Every hook is
///   evaluated; merge precedence on `ToolHookDecision` (consent beats
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
pub(open) trait Hook {
  fn before_model(Self, messages : Array[@kernel.Message]) -> Array[
    @kernel.Message,
  ] raise HookAbort = _
  /// `before_tool` is `async` so hooks that need host interaction (e.g. an
  /// approval prompt over `UiPort::request`) can suspend. Hooks that decide
  /// synchronously implement it as a plain `fn` — a sync `fn` satisfies an
  /// `async` trait slot under MoonBit's colorless-coroutine model. Raising
  /// from `before_tool` aborts the run as a terminal `HookRejected`; a
  /// cancellation error stays classified as cancellation, not a hook defect.
  async fn before_tool(Self, call : @kernel.ToolCall) -> ToolHookDecision = _
  fn on_post_event(Self, stage : HookStage) -> Unit = _
  fn on_post_event_at(Self, scope : @types.EventScope?, stage : HookStage) -> Unit = _
}

///|
/// Default `before_model`: pass messages through unchanged.
impl Hook with fn before_model(_self, messages : Array[@kernel.Message]) -> Array[
  @kernel.Message,
] {
  messages
}

///|
/// Default `before_tool`: approve the call unchanged.
impl Hook with fn before_tool(_self, call : @kernel.ToolCall) -> ToolHookDecision {
  Approve(call~)
}

///|
/// Default `on_post_event`: no-op.
impl Hook with fn on_post_event(_self, _stage : HookStage) -> Unit {
  ()
}

///|
/// Default `on_post_event_at`: drop the scope and delegate to
/// `on_post_event`. Override this instead when run attribution matters.
impl Hook with fn on_post_event_at(
  self,
  _scope : @types.EventScope?,
  stage : HookStage,
) -> Unit {
  self.on_post_event(stage)
}
