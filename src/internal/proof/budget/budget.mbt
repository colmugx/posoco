///|
pub(all) enum BudgetDimension {
  ModelSteps
  ToolRounds
  ToolCalls
  TotalTokens
}

///|
pub(all) enum BudgetState {
  WithinBudget
  Exceeded(BudgetDimension)
  UnknownUsage(BudgetDimension)
}

///|
pub(all) struct Budget {
  max_model_steps : Int32?
  max_tool_rounds : Int32?
  max_tool_calls : Int32?
  max_total_tokens : Int32?
}

///|
pub(all) struct BudgetConsumed {
  model_steps : Int32
  tool_rounds : Int32
  tool_calls : Int32
  observed_total_tokens : Int32
  any_usage_verified : Bool
  last_context_tokens : Int32?
}

///|
pub fn saturating_add_nonneg(
  a : Int32,
  b : Int32,
) -> Int32 where {
  proof_require: a >= 0 && a <= 2_147_483_647 && b >= 0 && b <= 2_147_483_647,
  proof_ensure: result => saturating_add_bounds(a, b, result),
  proof_ensure: result => saturating_add_exact(a, b, result),
} {
  if a >= 2_147_483_647 - b {
    2_147_483_647
  } else {
    a + b
  }
}

///|
pub fn budget_consumed_zero() -> BudgetConsumed where {
  proof_ensure: result => consumed_inv(result) && zero_post(result),
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
pub fn check_exceeded(
  consumed : BudgetConsumed,
  limit : Budget,
) -> BudgetState where {
  proof_require: consumed_inv(consumed),
  proof_ensure: result => exceeded_post(consumed, limit, result),
} {
  let steps_over = match limit.max_model_steps {
    Some(max) => consumed.model_steps > max
    None => false
  }
  if steps_over {
    Exceeded(ModelSteps)
  } else {
    let rounds_over = match limit.max_tool_rounds {
      Some(max) => consumed.tool_rounds > max
      None => false
    }
    if rounds_over {
      Exceeded(ToolRounds)
    } else {
      let calls_over = match limit.max_tool_calls {
        Some(max) => consumed.tool_calls > max
        None => false
      }
      if calls_over {
        Exceeded(ToolCalls)
      } else {
        match limit.max_total_tokens {
          Some(max) =>
            if !consumed.any_usage_verified {
              UnknownUsage(TotalTokens)
            } else if consumed.observed_total_tokens >= max {
              Exceeded(TotalTokens)
            } else {
              WithinBudget
            }
          None => WithinBudget
        }
      }
    }
  }
}

///|
pub fn usage_context_occupancy(
  total_tokens : Int32?,
  input_tokens : Int32?,
  output_tokens : Int32?,
) -> Int32? where {
  proof_require: opt_bounded_nonneg(total_tokens) &&
  opt_bounded_nonneg(input_tokens) &&
  opt_bounded_nonneg(output_tokens),
  proof_ensure: result => opt_bounded_nonneg(result),
} {
  match total_tokens {
    Some(total) => Some(total)
    None =>
      match (input_tokens, output_tokens) {
        (Some(input), Some(output)) =>
          Some(saturating_add_nonneg(input, output))
        _ => None
      }
  }
}

///|
pub fn bump_model_step(
  consumed : BudgetConsumed,
  has_usage : Bool,
  total_tokens : Int32?,
  input_tokens : Int32?,
  output_tokens : Int32?,
) -> BudgetConsumed where {
  proof_require: consumed_inv(consumed) &&
  opt_bounded_nonneg(total_tokens) &&
  opt_bounded_nonneg(input_tokens) &&
  opt_bounded_nonneg(output_tokens),
  proof_ensure: result => {
    consumed_inv(result) &&
    consumed_le(consumed, result) &&
    (
      !has_usage ||
      result.any_usage_verified ==
      (
        consumed.any_usage_verified ||
        (match total_tokens {
          Some(_) => true
          None => false
        })
      )
    ) &&
    (has_usage || is_none_opt(result.last_context_tokens))
  },
} {
  let model_steps = saturating_add_nonneg(consumed.model_steps, 1)
  if has_usage {
    let added = match total_tokens {
      Some(n) => n
      None => 0
    }
    let has_total = match total_tokens {
      Some(_) => true
      None => false
    }
    {
      model_steps,
      tool_rounds: consumed.tool_rounds,
      tool_calls: consumed.tool_calls,
      observed_total_tokens: saturating_add_nonneg(
        consumed.observed_total_tokens,
        added,
      ),
      any_usage_verified: consumed.any_usage_verified || has_total,
      last_context_tokens: usage_context_occupancy(
        total_tokens, input_tokens, output_tokens,
      ),
    }
  } else {
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
pub fn bump_tool_batch(
  consumed : BudgetConsumed,
  executable_calls : Int32,
) -> BudgetConsumed where {
  proof_require: consumed_inv(consumed) &&
  executable_calls >= 1 &&
  executable_calls <= 2_147_483_647,
  proof_ensure: result => consumed_inv(result) && consumed_le(consumed, result),
} {
  {
    model_steps: consumed.model_steps,
    tool_rounds: saturating_add_nonneg(consumed.tool_rounds, 1),
    tool_calls: saturating_add_nonneg(consumed.tool_calls, executable_calls),
    observed_total_tokens: consumed.observed_total_tokens,
    any_usage_verified: consumed.any_usage_verified,
    last_context_tokens: consumed.last_context_tokens,
  }
}
