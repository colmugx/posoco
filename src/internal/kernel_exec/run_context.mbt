///|

///|
/// Identifier for a single model step within a Run. Monotonic per Run; the
/// reducer allocates these (the reducer is allowed to do arithmetic, just not
/// IO/time). Each `CallModel` effect carries the model-step id it belongs to.
#derive(Eq, Debug)
pub(all) struct ModelStepId {
  value : Int32
}

///|
pub extend ModelStepId with Eq::{not_equal, equal}

///|
pub extend ModelStepId with Debug::{to_repr}

///|
pub fn ModelStepId::first() -> ModelStepId {
  { value: 1, }
}

///|
pub fn ModelStepId::next(self : ModelStepId) -> ModelStepId {
  { value: self.value + 1, }
}

///|
pub fn ModelStepId::to_int(self : ModelStepId) -> Int32 {
  self.value
}

///|
pub extend ModelStepId with Show::{output}

///|
pub impl Show for ModelStepId with fn to_string(self : ModelStepId) -> String {
  "ModelStepId(\{self.value})"
}

///|
/// Monotonic sequence counter for KernelEvents. Allocated by the reducer.
#derive(Eq, Debug)
pub(all) struct EventSequence {
  value : Int32
}

///|
pub extend EventSequence with Eq::{not_equal, equal}

///|
pub extend EventSequence with Debug::{to_repr}

///|
pub fn EventSequence::initial() -> EventSequence {
  { value: 0, }
}

///|
pub fn EventSequence::next(self : EventSequence) -> EventSequence {
  { value: self.value + 1, }
}

///|
pub fn EventSequence::to_int(self : EventSequence) -> Int32 {
  self.value
}

///|
/// Budget dimensions tracked per Run. `Int?` → `None` means unbounded.
/// The reducer increments consumed counters as it declares effects.
#derive(Eq, Debug)
pub(all) struct Budget {
  /// Limit. `None` = unbounded.
  max_model_steps : Int32?
  /// Limit. `None` = unbounded.
  max_tool_rounds : Int32?
  /// Limit. `None` = unbounded.
  max_tool_calls : Int32?
  /// Limit. `None` = unbounded.
  max_total_tokens : Int32?
}

///|
pub extend Budget with Eq::{not_equal, equal}

///|
pub extend Budget with Debug::{to_repr}

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
  max_model_steps~ : Int32,
  max_tool_rounds~ : Int32,
  max_tool_calls~ : Int32,
  max_total_tokens~ : Int32,
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
#derive(Eq, Debug)
pub(all) struct BudgetConsumed {
  /// `CallModel` effects declared so far.
  model_steps : Int32
  /// Tool batches completed (model completion with N tool calls = 1 round).
  tool_rounds : Int32
  /// `ExecuteTool` effects declared so far.
  tool_calls : Int32
  /// Observed `Usage.total_tokens`. 0 while unknown; reducer must not terminate
  /// on a token budget with unverified consumption.
  observed_total_tokens : Int32
  /// Whether any model step reported verified token usage.
  any_usage_verified : Bool
  /// Context occupancy reported by the LATEST model step: its `total_tokens`,
  /// or `input_tokens + output_tokens` when both are reported. `None` when
  /// no computable reading exists yet or the transcript was just rewritten.
  /// Run-wide `max_total_tokens` keeps using the cumulative total above;
  /// auto-compact compares only this latest occupancy against the window, so
  /// several large-but-far-from-full calls cannot sum into a false trigger.
  last_context_tokens : Int32?
}

///|
pub extend BudgetConsumed with Eq::{not_equal, equal}

///|
pub extend BudgetConsumed with Debug::{to_repr}

///|
pub fn BudgetConsumed::zero() -> BudgetConsumed {
  let z = @proof_budget.budget_consumed_zero()
  {
    model_steps: z.model_steps,
    tool_rounds: z.tool_rounds,
    tool_calls: z.tool_calls,
    observed_total_tokens: z.observed_total_tokens,
    any_usage_verified: z.any_usage_verified,
    last_context_tokens: z.last_context_tokens,
  }
}

///|
pub fn BudgetConsumed::exceeded(
  self : BudgetConsumed,
  limit : Budget,
) -> BudgetState {
  let res = @proof_budget.check_exceeded(
    {
      model_steps: self.model_steps,
      tool_rounds: self.tool_rounds,
      tool_calls: self.tool_calls,
      observed_total_tokens: self.observed_total_tokens,
      any_usage_verified: self.any_usage_verified,
      last_context_tokens: self.last_context_tokens,
    },
    {
      max_model_steps: limit.max_model_steps,
      max_tool_rounds: limit.max_tool_rounds,
      max_tool_calls: limit.max_tool_calls,
      max_total_tokens: limit.max_total_tokens,
    },
  )
  match res {
    WithinBudget => WithinBudget
    Exceeded(ModelSteps) => Exceeded(ModelSteps)
    Exceeded(ToolRounds) => Exceeded(ToolRounds)
    Exceeded(ToolCalls) => Exceeded(ToolCalls)
    Exceeded(TotalTokens) => Exceeded(TotalTokens)
    UnknownUsage(ModelSteps) => UnknownUsage(ModelSteps)
    UnknownUsage(ToolRounds) => UnknownUsage(ToolRounds)
    UnknownUsage(ToolCalls) => UnknownUsage(ToolCalls)
    UnknownUsage(TotalTokens) => UnknownUsage(TotalTokens)
  }
}

///|
#derive(Eq, Debug)
pub enum BudgetState {
  WithinBudget
  Exceeded(BudgetDimension)
  /// Budget exists but no verified observation. Reducer MUST NOT terminate on this.
  UnknownUsage(BudgetDimension)
}

///|
pub extend BudgetState with Eq::{not_equal, equal}

///|
pub extend BudgetState with Debug::{to_repr}

///|
pub extend BudgetState with Show::{output}

///|
pub impl Show for BudgetState with fn to_string(self : BudgetState) -> String {
  match self {
    WithinBudget => "WithinBudget"
    Exceeded(d) => "Exceeded(\{d.to_string()})"
    UnknownUsage(d) => "UnknownUsage(\{d.to_string()})"
  }
}

///|
#derive(Eq, Debug)
pub(all) enum BudgetDimension {
  ModelSteps
  ToolRounds
  ToolCalls
  TotalTokens
}

///|
pub extend BudgetDimension with Eq::{not_equal, equal}

///|
pub extend BudgetDimension with Debug::{to_repr}

///|
pub extend BudgetDimension with Show::{output}

///|
pub impl Show for BudgetDimension with fn to_string(self : BudgetDimension) -> String {
  match self {
    ModelSteps => "max_model_steps"
    ToolRounds => "max_tool_rounds"
    ToolCalls => "max_tool_calls"
    TotalTokens => "max_total_tokens"
  }
}
