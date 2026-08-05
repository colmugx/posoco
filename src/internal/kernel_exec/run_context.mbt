///|
/// RunContext, Budget, Deadline and Cancel contracts for the M1 functional
/// Kernel (ADR §2.5, §2.6, §2.9).
///
/// Key invariants:
/// - The reducer NEVER reads a clock. Deadlines are delivered as
///   `DeadlineReached` inputs; the reducer only compares its own budget
///   counters.
/// - Budget dimensions are `Int?` because the host may not configure every
///   dimension. Unknown usage is NEVER reported as 0 (ADR §2.9).
/// - Cancel is idempotent: the second `CancelRequested` after
///   `Terminal(Cancelled)` is a typed rejection, not a new terminal event.

///|
/// Stable identifier for a single Run. Supplied by the host in the `Start` input and carried through every state.
pub(all) struct RunId {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn RunId::new(value : String) -> Result[RunId, String] {
  if value == "" {
    Err("RunId must be non-empty")
  } else {
    Ok(RunId::{ value, })
  }
}

///|
pub fn RunId::unchecked(value : String) -> RunId {
  RunId::{ value, }
}

///|
pub fn RunId::to_string(self : RunId) -> String {
  self.value
}

///|
pub impl Show for RunId with fn to_string(self : RunId) -> String {
  "RunId(\{self.value})"
}

///|
/// Stable identifier for a product session. The Kernel never opens or
/// materializes session storage; it carries this identity through effects,
/// journal entries, and committed event envelopes.
pub(all) struct SessionId {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn SessionId::new(value : String) -> Result[SessionId, String] {
  if value == "" {
    Err("SessionId must be non-empty")
  } else {
    Ok(SessionId::{ value, })
  }
}

///|
pub fn SessionId::unchecked(value : String) -> SessionId {
  SessionId::{ value, }
}

///|
pub fn SessionId::to_string(self : SessionId) -> String {
  self.value
}

///|
/// Identifier for a single model step within a Run. Monotonic per Run; the
/// reducer allocates these (the reducer is allowed to do arithmetic, just not
/// IO/time). Each `CallModel` effect carries the model-step id it belongs to.
pub(all) struct ModelStepId {
  value : Int
} derive(Eq, Debug)

///|
pub fn ModelStepId::first() -> ModelStepId {
  { value: 1 }
}

///|
pub fn ModelStepId::next(self : ModelStepId) -> ModelStepId {
  { value: self.value + 1 }
}

///|
pub fn ModelStepId::to_int(self : ModelStepId) -> Int {
  self.value
}

///|
pub impl Show for ModelStepId with fn to_string(self : ModelStepId) -> String {
  "ModelStepId(\{self.value})"
}

///|
/// Identifier for a single declared Effect. Monotonic per Run. Each completion
/// input must correlate to a pending effect with this id; a mismatch is
/// `InvariantViolation::StaleCorrelation`.
pub(all) struct EffectId {
  value : Int
} derive(Eq, Hash, Debug)

///|
pub fn EffectId::first() -> EffectId {
  { value: 1 }
}

///|
pub fn EffectId::next(self : EffectId) -> EffectId {
  { value: self.value + 1 }
}

///|
pub fn EffectId::to_int(self : EffectId) -> Int {
  self.value
}

///|
pub impl Show for EffectId with fn to_string(self : EffectId) -> String {
  "EffectId(\{self.value})"
}

///|
/// Monotonic sequence counter for KernelEvents. Allocated by the reducer.
pub(all) struct EventSequence {
  value : Int
} derive(Eq, Debug)

///|
pub fn EventSequence::initial() -> EventSequence {
  { value: 0 }
}

///|
pub fn EventSequence::next(self : EventSequence) -> EventSequence {
  { value: self.value + 1 }
}

///|
pub fn EventSequence::to_int(self : EventSequence) -> Int {
  self.value
}

///|
/// Budget dimensions tracked per Run (ADR §2.9). `Int?` → `None` means unbounded.
/// The reducer increments consumed counters as it declares effects.
pub(all) struct Budget {
  /// Limit. `None` = unbounded.
  max_model_steps : Int?
  /// Limit. `None` = unbounded.
  max_tool_rounds : Int?
  /// Limit. `None` = unbounded.
  max_tool_calls : Int?
  /// Limit. `None` = unbounded.
  max_total_tokens : Int?
} derive(Eq, Debug)

///|
/// Default budget: only `max_tool_rounds` is bounded, at a conservative 32.
/// All other dimensions are unbounded. Products with stronger safety limits
/// must use `Budget::bounded` at composition.
pub fn Budget::default_run() -> Budget {
  {
    max_model_steps: None,
    max_tool_rounds: Some(32),
    max_tool_calls: None,
    max_total_tokens: None,
  }
}

///|
/// Build a fully-bounded budget.
pub fn Budget::bounded(
  max_model_steps~ : Int,
  max_tool_rounds~ : Int,
  max_tool_calls~ : Int,
  max_total_tokens~ : Int,
) -> Budget {
  {
    max_model_steps: Some(max_model_steps),
    max_tool_rounds: Some(max_tool_rounds),
    max_tool_calls: Some(max_tool_calls),
    max_total_tokens: Some(max_total_tokens),
  }
}

///|
/// Per-Run consumed counters. Incremented by the reducer as it declares effects.
pub(all) struct BudgetConsumed {
  /// `CallModel` effects declared so far.
  model_steps : Int
  /// Tool batches completed (model completion with N tool calls = 1 round).
  tool_rounds : Int
  /// `ExecuteTool` effects declared so far.
  tool_calls : Int
  /// Observed `Usage.total_tokens`. 0 while unknown; reducer must not terminate
  /// on a token budget with unverified consumption.
  observed_total_tokens : Int
  /// Whether any model step reported verified token usage.
  any_usage_verified : Bool
} derive(Eq, Debug)

///|
pub fn BudgetConsumed::zero() -> BudgetConsumed {
  {
    model_steps: 0,
    tool_rounds: 0,
    tool_calls: 0,
    observed_total_tokens: 0,
    any_usage_verified: false,
  }
}

///|
/// Returns the dimension that is now exceeded (if any), or `UnknownUsage` if token budget exists but no usage verified.
pub fn BudgetConsumed::exceeded(
  self : BudgetConsumed,
  limit : Budget,
) -> BudgetState {
  let check = fn(consumed : Int, max_opt : Int?) -> Bool {
    match max_opt {
      Some(max) => consumed >= max
      None => false
    }
  }
  if check(self.model_steps, limit.max_model_steps) {
    return Exceeded(BudgetDimension::ModelSteps)
  }
  if check(self.tool_rounds, limit.max_tool_rounds) {
    return Exceeded(BudgetDimension::ToolRounds)
  }
  if check(self.tool_calls, limit.max_tool_calls) {
    return Exceeded(BudgetDimension::ToolCalls)
  }
  match limit.max_total_tokens {
    Some(_) if !self.any_usage_verified =>
      UnknownUsage(BudgetDimension::TotalTokens)
    Some(max) if self.observed_total_tokens >= max =>
      Exceeded(BudgetDimension::TotalTokens)
    _ => WithinBudget
  }
}

///|
pub enum BudgetState {
  WithinBudget
  Exceeded(BudgetDimension)
  /// Budget exists but no verified observation. Reducer MUST NOT terminate on this.
  UnknownUsage(BudgetDimension)
} derive(Eq, Debug)

///|
pub impl Show for BudgetState with fn to_string(self : BudgetState) -> String {
  match self {
    WithinBudget => "WithinBudget"
    Exceeded(d) => "Exceeded(\{d.to_string()})"
    UnknownUsage(d) => "UnknownUsage(\{d.to_string()})"
  }
}

///|
pub(all) enum BudgetDimension {
  ModelSteps
  ToolRounds
  ToolCalls
  TotalTokens
} derive(Eq, Debug)

///|
pub impl Show for BudgetDimension with fn to_string(self : BudgetDimension) -> String {
  match self {
    ModelSteps => "max_model_steps"
    ToolRounds => "max_tool_rounds"
    ToolCalls => "max_tool_calls"
    TotalTokens => "max_total_tokens"
  }
}

///|
/// Immutable runtime context for a single Run (ADR §2.9). Carried by RunState but never mutated.
/// The reducer reads from this for budget/limit checks; it does NOT read a clock.
pub(all) struct RunContext {
  run_id : RunId
  session_id : SessionId
  budget : Budget
} derive(Eq, Debug)

///|
pub fn RunContext::RunContext(
  run_id~ : RunId,
  session_id~ : SessionId,
  budget~ : Budget,
) -> RunContext {
  { run_id, session_id, budget }
}

///|
/// Why a Run was cancelled.
pub(all) enum CancelReason {
  /// Host explicitly cancelled.
  HostRequested(detail~ : String?)
  /// Adapter/host observed the deadline.
  DeadlineReached
} derive(Eq, Debug)

///|
pub impl Show for CancelReason with fn to_string(self : CancelReason) -> String {
  match self {
    HostRequested(detail~) => "HostRequested(\{detail_or_empty(detail)})"
    DeadlineReached => "DeadlineReached"
  }
}

///|
fn detail_or_empty(detail : String?) -> String {
  match detail {
    Some(s) => s
    None => ""
  }
}

///|
/// What an adapter reports after a `CancelOutstanding` effect. The reducer never waits for this.
pub(all) enum CancelDisposition {
  /// Cancel signal propagated.
  Propagated
  /// Cancel not propagated; only stops the reducer waiting.
  NotPropagated
  /// Effect already settled before cancel arrived.
  AlreadySettled
} derive(Eq, Debug)

///|
pub impl Show for CancelDisposition with fn to_string(self : CancelDisposition) -> String {
  match self {
    Propagated => "Propagated"
    NotPropagated => "NotPropagated"
    AlreadySettled => "AlreadySettled"
  }
}
