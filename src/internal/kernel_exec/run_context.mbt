///|
/// Budget, Deadline and Cancel contracts for the M1 functional
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
///
/// Run/Session/Effect identity and the Cancel contracts are canonical wire
/// types defined in `@kernel` (`domain_run.mbt`) and re-exported via this
/// package's `imports.mbt` — single source of truth lives in `@kernel`.

///|
/// Identifier for a single model step within a Run. Monotonic per Run; the
/// reducer allocates these (the reducer is allowed to do arithmetic, just not
/// IO/time). Each `CallModel` effect carries the model-step id it belongs to.
pub(all) struct ModelStepId {
  value : Int
} derive(Eq, Debug)

///|
/// Contract: the first model step is exactly 1, establishing the non-negative
/// lower bound for every reducer-allocated id (ids only grow via `next`).
/// (Contracts read the `value` field directly: runtime `.mbt` function calls
/// such as `to_int` are not lowerable inside logic bodies.)
pub fn ModelStepId::first() -> ModelStepId where {
  proof_ensure: result => result.value == 1 && result.value >= 0,
} {
  { value: 1, }
}

///|
/// Contract: strictly monotonic — the next id is exactly the current id plus 1.
pub fn ModelStepId::next(
  self : ModelStepId,
) -> ModelStepId where {
  proof_ensure: result => result.value == self.value + 1,
} {
  { value: self.value + 1, }
}

///|
/// Contract: projection identity — `to_int` exposes the underlying counter
/// unchanged. (Non-negativity holds for reducer-allocated ids by induction
/// over `first`/`next`, not for arbitrary externally constructed values.)
pub fn ModelStepId::to_int(
  self : ModelStepId,
) -> Int where {
  proof_ensure: result => result == self.value,
} {
  self.value
}

///|
pub impl Show for ModelStepId with fn to_string(self : ModelStepId) -> String {
  "ModelStepId(\{self.value})"
}

///|
/// Monotonic sequence counter for KernelEvents. Allocated by the reducer.
pub(all) struct EventSequence {
  value : Int
} derive(Eq, Debug)

///|
/// Contract: the sequence starts at exactly 0, the non-negative lower bound
/// for every reducer-allocated sequence number. (Reads the `value` field —
/// runtime function calls are not lowerable in logic bodies.)
pub fn EventSequence::initial() -> EventSequence where {
  proof_ensure: result => result.value == 0 && result.value >= 0,
} {
  { value: 0, }
}

///|
/// Contract: strictly monotonic — the next sequence is exactly the current
/// one plus 1.
pub fn EventSequence::next(
  self : EventSequence,
) -> EventSequence where {
  proof_ensure: result => result.value == self.value + 1,
} {
  { value: self.value + 1, }
}

///|
/// Contract: projection identity — `to_int` exposes the underlying counter
/// unchanged.
pub fn EventSequence::to_int(
  self : EventSequence,
) -> Int where {
  proof_ensure: result => result == self.value,
} {
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
  /// Context occupancy reported by the LATEST model step: its `total_tokens`,
  /// or `input_tokens + output_tokens` when both are reported. `None` when
  /// no computable reading exists yet or the transcript was just rewritten.
  /// Run-wide `max_total_tokens` keeps using the cumulative total above;
  /// auto-compact compares only this latest occupancy against the window, so
  /// several large-but-far-from-full calls cannot sum into a false trigger.
  last_context_tokens : Int?
} derive(Eq, Debug)

///|
/// Contract: `zero` produces all-zero counters and no verified usage.
pub fn BudgetConsumed::zero() -> BudgetConsumed where {
  proof_ensure: result => zero_post(result),
} {
  {
    model_steps: 0,
    tool_rounds: 0,
    tool_calls: 0,
    observed_total_tokens: 0,
    any_usage_verified: false,
    last_context_tokens: None,
  }
}

///|
/// Returns the dimension that is now exceeded (if any), or `UnknownUsage` if token budget exists but no usage verified.
/// Limit semantics are exclusive: limit N allows N full units and rejects the
/// declaration that would push consumption to N+1. (Token observation keeps
/// `>=`: it compares an observed reading, not a declaration count.)
///
/// Contract: `exceeded_post` (budget_proof.mbtp) — the result names the
/// FIRST dimension over its exclusive limit in declaration order
/// (ModelSteps, ToolRounds, ToolCalls, TotalTokens); a `None` limit never
/// produces that dimension's `Exceeded`; a token limit with unverified
/// usage is `UnknownUsage(TotalTokens)`, never conflated with `Exceeded`.
///
/// NOTE: the per-dimension checks are inlined as explicit `match` branches
/// (no local closure) — local closures inside contracted function bodies
/// are silently skipped by the proof frontend (FORMAL-VERIFICATION §1.3).
pub fn BudgetConsumed::exceeded(
  self : BudgetConsumed,
  limit : Budget,
) -> BudgetState where {
  proof_ensure: result => exceeded_post(self, limit, result),
} {
  match limit.max_model_steps {
    Some(max) if self.model_steps > max => Exceeded(BudgetDimension::ModelSteps)
    _ =>
      match limit.max_tool_rounds {
        Some(max) if self.tool_rounds > max =>
          Exceeded(BudgetDimension::ToolRounds)
        _ =>
          match limit.max_tool_calls {
            Some(max) if self.tool_calls > max =>
              Exceeded(BudgetDimension::ToolCalls)
            _ =>
              match limit.max_total_tokens {
                Some(_) if !self.any_usage_verified =>
                  UnknownUsage(BudgetDimension::TotalTokens)
                Some(max) if self.observed_total_tokens >= max =>
                  Exceeded(BudgetDimension::TotalTokens)
                _ => WithinBudget
              }
          }
      }
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
