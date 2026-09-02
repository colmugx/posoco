/// Budget accounting helpers shared by the model and tool folds.

///|
fn bump_model_step(
  consumed : BudgetConsumed,
  usage : @kernel.Usage?,
) -> BudgetConsumed {
  let model_steps = consumed.model_steps + 1
  match usage {
    Some(u) => {
      let added = match u.total_tokens {
        Some(n) => n
        None => 0
      }
      {
        model_steps,
        tool_rounds: consumed.tool_rounds,
        tool_calls: consumed.tool_calls,
        observed_total_tokens: consumed.observed_total_tokens + added,
        any_usage_verified: consumed.any_usage_verified ||
        u.total_tokens is Some(_),
        last_context_tokens: usage_context_occupancy(u),
      }
    }
    None =>
      // A step without usage leaves the context size unknown: the transcript
      // has grown since the last reliable reading, so the stale one must go.
      {
        model_steps,
        tool_rounds: consumed.tool_rounds,
        tool_calls: consumed.tool_calls,
        observed_total_tokens: consumed.observed_total_tokens,
        any_usage_verified: consumed.any_usage_verified,
        last_context_tokens: None,
      }
  }
}

///|
/// Context occupancy of one call from its usage: `total_tokens` when
/// reported, else `input_tokens + output_tokens` when both are. Partial
/// readings (only one of input/output) are not a reliable size — stay
/// unknown rather than guessing low.
fn usage_context_occupancy(u : @kernel.Usage) -> Int? {
  match u.total_tokens {
    Some(total) => Some(total)
    None =>
      match (u.input_tokens, u.output_tokens) {
        (Some(input), Some(output)) => Some(input + output)
        _ => None
      }
  }
}

///|
fn bump_tool_batch(
  consumed : BudgetConsumed,
  executable_calls : Int,
) -> BudgetConsumed {
  // This helper is only called after validation established a non-empty
  // ExecuteTool batch. Count when effects are declared, never as individual
  // completions arrive: completion order is nondeterministic under parallel
  // execution and must not alter budget accounting.
  {
    model_steps: consumed.model_steps,
    tool_rounds: consumed.tool_rounds + 1,
    tool_calls: consumed.tool_calls + executable_calls,
    observed_total_tokens: consumed.observed_total_tokens,
    any_usage_verified: consumed.any_usage_verified,
    last_context_tokens: consumed.last_context_tokens,
  }
}

///|
fn consumed_for_dim(consumed : BudgetConsumed, dim : BudgetDimension) -> Int {
  match dim {
    ModelSteps => consumed.model_steps
    ToolRounds => consumed.tool_rounds
    ToolCalls => consumed.tool_calls
    TotalTokens => consumed.observed_total_tokens
  }
}

///|
fn limit_for_dim(budget : Budget, dim : BudgetDimension) -> Int {
  match dim {
    ModelSteps =>
      match budget.max_model_steps {
        Some(n) => n
        None => 0
      }
    ToolRounds =>
      match budget.max_tool_rounds {
        Some(n) => n
        None => 0
      }
    ToolCalls =>
      match budget.max_tool_calls {
        Some(n) => n
        None => 0
      }
    TotalTokens =>
      match budget.max_total_tokens {
        Some(n) => n
        None => 0
      }
  }
}
