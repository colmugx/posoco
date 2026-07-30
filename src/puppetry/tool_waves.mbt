///|
/// Projection from reducer-declared ExecuteTool effects to Kernel scheduler
/// waves. This is deliberately a narrow adapter: scheduling policy stays in
/// the pure Kernel, while the Puppet receives only ordered effect batches to
/// execute at side-effect boundaries.

///|
fn scheduled_tool_effect_waves(
  pending : Array[Effect],
  catalog : ToolCatalogSnapshot,
  expected_version : CatalogVersion,
) -> Array[Array[Effect]] raise PuppetError {
  let calls : Array[ToolCall] = []
  for effect in pending {
    match effect {
      @kernel.ExecuteTool(payload~, ..) =>
        calls.push({
          call_id: payload.call_id,
          name: payload.tool_name,
          arguments: payload.arguments,
        })
      _ =>
        raise ReducerInvariantViolation(
          category=IllegalPhase(
            phase="AwaitingTools",
            detail="pending effect is not ExecuteTool",
          ),
        )
    }
  }
  if calls.is_empty() {
    raise ReducerInvariantViolation(
      category=IllegalPhase(
        phase="AwaitingTools",
        detail="scheduler received an empty pending effect set",
      ),
    )
  }

  let planned : Result[ExecutionPlan, SchedulingError] = Ok(
    schedule(catalog, expected_version, calls),
  ) catch {
    error => Err(error)
  }
  let plan = match planned {
    Ok(value) => value
    Err(@kernel.DuplicateCallId(call_id~)) =>
      raise ReducerInvariantViolation(category=DuplicateCallId(call_id~))
    Err(@kernel.StaleSnapshotVersion(expected~, actual~)) =>
      raise ReducerInvariantViolation(
        category=StaleSnapshot(expected~, actual~),
      )
    Err(@kernel.UnknownToolReachedScheduler(..)) =>
      raise ReducerInvariantViolation(
        category=IllegalPhase(
          phase="ToolScheduler",
          detail="reducer declared an unknown tool",
        ),
      )
  }

  let waves : Array[Array[Effect]] = []
  let mut scheduled_count = 0
  for wave in plan.waves() {
    let wave_effects : Array[Effect] = []
    for call in wave.calls() {
      wave_effects.push(find_pending_effect_for_call(pending, call))
    }
    if wave_effects.is_empty() {
      raise ReducerInvariantViolation(
        category=IllegalPhase(
          phase="ToolScheduler",
          detail="scheduler produced an empty wave",
        ),
      )
    }
    scheduled_count = scheduled_count + wave_effects.length()
    waves.push(wave_effects)
  }
  if scheduled_count != pending.length() {
    raise ReducerInvariantViolation(
      category=IllegalPhase(
        phase="ToolScheduler",
        detail="scheduled effect count differs from pending effect count",
      ),
    )
  }
  waves
}

///|
/// Recover one reducer-declared effect for a scheduler call id. Duplicates
/// and omissions are hard invariants; this function never selects an
/// arbitrary effect or drops a declared one.
fn find_pending_effect_for_call(
  pending : Array[Effect],
  call : ToolCall,
) -> Effect raise PuppetError {
  let mut matched : Effect? = None
  for effect in pending {
    match effect {
      @kernel.ExecuteTool(payload~, ..) =>
        if payload.call_id == call.call_id {
          match matched {
            Some(_) =>
              raise ReducerInvariantViolation(
                category=DuplicateCallId(call_id=call.call_id),
              )
            None => matched = Some(effect)
          }
        }
      _ =>
        raise ReducerInvariantViolation(
          category=IllegalPhase(
            phase="AwaitingTools",
            detail="pending effect is not ExecuteTool",
          ),
        )
    }
  }
  match matched {
    Some(effect) => effect
    None =>
      raise ReducerInvariantViolation(
        category=IllegalPhase(
          phase="ToolScheduler",
          detail="scheduled call has no pending effect",
        ),
      )
  }
}
