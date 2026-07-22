///|
/// Typed Kernel errors for the M1 functional Kernel.
///
/// These errors are returned from constructor validation and from the reducer
/// when an input combination violates the contract (ADR §2.2, §2.4, §2.5).
/// They are deliberately distinct from the M0 `AgentError` family: the Kernel
/// does not speak `ModelPort` or `SessionStore`, so its errors must not reuse
/// their carrier types. The compatibility facade translates between the two
/// families.

// ──────────────────────────────────────────────────────────────────────────
// Invariant categories (one home per failure — ADR §2.4)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Why the reducer (or constructor) declared a kernel invariant failure.
/// Each variant carries enough context (phase, effect id, call id) to
/// diagnose the violation without leaking raw prompt/tool payloads.
pub(all) enum InvariantCategory {
  /// `ToolCompleted` or `ModelCompleted` arrived for an effect id that is not
  /// in the pending set (or has already been resolved).
  DuplicateCompletion(effect_id~ : EffectId)
  /// Completion arrived for an effect id never declared by this Run.
  StaleCorrelation(effect_id~ : EffectId)
  /// `ExecuteTool` effect referenced an `OwnerId` that has no registered
  /// provider in the runtime registry.
  MissingOwner(owner~ : OwnerId)
  /// `ExecuteTool` effect's catalog version differs from the version the
  /// `CallModel` effect used to prompt the model.
  StaleSnapshot(expected~ : CatalogVersion, actual~ : CatalogVersion)
  /// A duplicate `call_id` was emitted by the model within a single
  /// completion, or two `ExecuteTool` effects were declared for the same call.
  DuplicateCallId(call_id~ : CallId)
  /// RunState constructor or reducer transition produced a phase/effect
  /// combination that violates §2.2 invariants (e.g. `AwaitingModel` with
  /// zero or two pending model effects, `Suspended` with non-empty pending).
  IllegalPhase(phase~ : String, detail~ : String)
  /// Reducer received an input that is not legal in the current phase.
  IllegalInputForPhase(input_kind~ : String, phase~ : String)
  /// Reducer received an input after the Run was already Terminal. Distinct
  /// from `IllegalInputForPhase` so conformance tests can assert post-terminal
  /// rejection precisely.
  PostTerminal(input_kind~ : String)
} derive(Eq, Debug)

///|
pub impl Show for InvariantCategory with fn to_string(self : InvariantCategory) -> String {
  match self {
    DuplicateCompletion(effect_id~) =>
      "DuplicateCompletion(\{effect_id.to_string()})"
    StaleCorrelation(effect_id~) => "StaleCorrelation(\{effect_id.to_string()})"
    MissingOwner(owner~) => "MissingOwner(\{owner.to_string()})"
    StaleSnapshot(expected~, actual~) =>
      "StaleSnapshot(expected=\{expected.to_string()}, actual=\{actual.to_string()})"
    DuplicateCallId(call_id~) => "DuplicateCallId(\{call_id.to_string()})"
    IllegalPhase(phase~, detail~) =>
      "IllegalPhase(phase=\{phase}, detail=\{detail})"
    IllegalInputForPhase(input_kind~, phase~) =>
      "IllegalInputForPhase(input=\{input_kind}, phase=\{phase})"
    PostTerminal(input_kind~) => "PostTerminal(input=\{input_kind})"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Failure reasons (terminal Failed outcome — ADR §2.3, §2.4)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Why a Run terminated with `Failed`. Mirrors ADR §2.4 taxonomy: model
/// parse / transport / runtime, kernel invariant, budget, deadline.
///
/// `Cancelled` is a separate outcome (`RunOutcome::Cancelled`) and uses
/// `CancelReason`, never `FailureReason`.
pub(all) enum FailureReason {
  ModelParseFailure(detail~ : String)
  ModelTransport(detail~ : String)
  ModelRuntime(detail~ : String)
  InvariantViolation(category~ : InvariantCategory)
  BudgetExhausted(dimension~ : BudgetDimension)
  DeadlineReached
} derive(Eq, Debug)

///|
pub impl Show for FailureReason with fn to_string(self : FailureReason) -> String {
  match self {
    ModelParseFailure(detail~) =>
      "ModelParseFailure(\{safe_kernel_label(detail)})"
    ModelTransport(detail~) => "ModelTransport(\{safe_kernel_label(detail)})"
    ModelRuntime(detail~) => "ModelRuntime(\{safe_kernel_label(detail)})"
    InvariantViolation(category~) =>
      "InvariantViolation(\{category.to_string()})"
    BudgetExhausted(dimension~) => "BudgetExhausted(\{dimension.to_string()})"
    DeadlineReached => "DeadlineReached"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// KernelError — the unified typed error for Kernel construction + reducer
// ──────────────────────────────────────────────────────────────────────────

///|
/// Unified error type raised by Kernel constructors (`RunState::*`) and the
/// reducer. The compatibility facade translates this to the legacy
/// `AgentError` family.
///
/// Variant `ReducerInvariant` is the only one that terminates a Run; the
/// other variants are raised synchronously from constructors before the Run
/// starts.
pub(all) suberror KernelError {
  /// Constructor invariant violation. Run was never created.
  ConstructorInvariant(category~ : InvariantCategory)
  /// Reducer invariant violation. Run transitions to `Terminal(Failed)` with
  /// `InvariantViolation(category)`.
  ReducerInvariant(
    run_id~ : RunId,
    phase~ : String,
    category~ : InvariantCategory
  )
  /// Adapter call failed in a way the reducer cannot continue from (this is
  /// rare — most adapter failures arrive as `ModelFailed`/`ToolFailed` inputs;
  /// this variant is reserved for cases where the reducer itself cannot build
  /// a legal next state from the input).
  IllegalTransition(
    run_id~ : RunId,
    phase~ : String,
    input_kind~ : String,
    detail~ : String
  )
}

///|
pub impl Show for KernelError with fn to_string(self : KernelError) -> String {
  match self {
    ConstructorInvariant(category~) =>
      "KernelError::ConstructorInvariant(\{category.to_string()})"
    ReducerInvariant(run_id~, phase~, category~) =>
      "KernelError::ReducerInvariant(run=\{run_id.to_string()}, phase=\{phase}, \{category.to_string()})"
    IllegalTransition(run_id~, phase~, input_kind~, detail~) =>
      "KernelError::IllegalTransition(run=\{run_id.to_string()}, phase=\{phase}, input=\{input_kind}, \{safe_kernel_label(detail)})"
  }
}

///|
/// Internal bounded-label helper, mirrors `safe_error_label` from
/// `agent.mbt`. Kept local so the Kernel files do not import production
/// cross-file helpers.
fn safe_kernel_label(value : String) -> String {
  let chars : Array[Char] = []
  let mut truncated = false
  for char in value {
    if chars.length() >= 64 {
      truncated = true
      break
    }
    match char {
      '\n' | '\r' => chars.push(' ')
      other => chars.push(other)
    }
  }
  let label = String::from_array(chars)
  if truncated {
    label + "...(truncated)"
  } else {
    label
  }
}
