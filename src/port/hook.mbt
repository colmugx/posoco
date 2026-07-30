///|
/// Three hook traits: PreModelHook (rewrite messages or abort),
/// PreToolHook (approve/defer/reject tool calls), PostEventHook (read-only
/// after-effect telemetry). Each runs in registration order; PreModelHook
/// and PreToolHook short-circuit on the first non-default decision.

// PreModelHook

///|
/// Raised by `PreModelHook::before_model` to stop the run before the model
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
/// Invoked before every model call. Can rewrite messages or raise
/// `HookAbort`. Multiple hooks form a chained rewrite pipeline.
pub(open) trait PreModelHook {
  fn before_model(Self, messages : Array[@kernel.Message]) -> Array[
    @kernel.Message,
  ] raise HookAbort
}

// PreToolHook

///|
/// The hook's decision for a pending tool call.
pub(all) enum ToolHookDecision {
  /// Execute the tool, possibly with a rewritten call.
  Approve(call~ : @kernel.ToolCall)
  /// Keep the call pending; the run transitions to Suspended with a
  /// suspension requirement the host can later resolve.
  Defer(reason~ : String)
  /// Stop the run — the tool must not execute.
  Reject(reason~ : String)
} derive(Debug)

///|
pub impl Show for ToolHookDecision with fn to_string(self : ToolHookDecision) -> String {
  match self {
    Approve(call~) => "Approve(\{call.call_id.to_string()})"
    Defer(reason~) => "Defer(\{reason})"
    Reject(reason~) => "Reject(\{reason})"
  }
}

///|
/// Invoked before every tool execution. Approve (with optional rewrite),
/// Defer (suspend), or Reject (abort). First non-Approve wins.
pub(open) trait PreToolHook {
  fn before_tool(Self, call : @kernel.ToolCall) -> ToolHookDecision
}

// PostEventHook

///|
/// Describes what just completed, delivered after the effect is committed.
pub(all) enum PostStage {
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
pub impl Show for PostStage with fn to_string(self : PostStage) -> String {
  match self {
    ModelCompleted(..) => "ModelCompleted"
    ToolCompleted(call~, ..) => "ToolCompleted(\{call.call_id.to_string()})"
    ToolFailed(call~, ..) => "ToolFailed(\{call.call_id.to_string()})"
    ModelFailed(..) => "ModelFailed"
  }
}

///|
/// Invoked after every effect completes. Read-only — all registered hooks
/// run with finally semantics; failures are logged but never propagate.
pub(open) trait PostEventHook {
  fn on_post_event(Self, stage : PostStage) -> Unit
}
