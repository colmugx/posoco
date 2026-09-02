///|
/// Execute the single reducer-declared model effect. Expected provider
/// failures travel as `ModelFailed` data; raised host defects are surfaced as
/// a distinct Puppet error and never fabricated into a completion.
///
/// (R3 M3.7: the previous `(RunInput, NewThreadSpec?)` tuple has been removed
/// — compact is now a separate `ModelPort::compact` method driven by posoco,
/// not a side-channel of `CallModel`.)
async fn execute_model_effect(
  effect : Effect,
  context : ExecutionContext,
  on_chunk : @kernel_exec.HostChunkCallback?,
) -> RunInput raise PuppetError {
  let attempted : Result[RunInput, Error] = Ok(
    execute_one(effect, context, on_chunk),
  ) catch {
    error => Err(error)
  }
  match attempted {
    Ok(value) => value
    Err(error) => raise execution_error("AwaitingModel", error)
  }
}

///|
/// Execute one already-scheduled tool wave. `@async.all` supplies the actual
/// parallelism and cancels peers if one task raises. Its result array remains
/// in source order, which the caller feeds to the reducer deterministically.
async fn execute_tool_wave(
  effects : Array[Effect],
  context : ExecutionContext,
) -> Array[RunInput] raise PuppetError {
  let attempted : Result[Array[RunInput], Error] = Ok(
    @async.all(
      effects.map(fn(effect) { () => execute_one(effect, context, None) }),
    ),
  ) catch {
    error => Err(error)
  }
  match attempted {
    Ok(values) => values
    Err(error) => raise execution_error("AwaitingTools", error)
  }
}

///|
/// Propagate reducer-declared cancellation effects at their terminal boundary.
/// Cancellation has no reducer completion input: converting it into a tool or
/// model result would fabricate a fact. The host must return one disposition
/// for every requested effect id; malformed reports fail the run loudly.
async fn propagate_terminal_cancellations(
  effects : Array[Effect],
  context : ExecutionContext,
) -> Unit raise PuppetError {
  for effect in effects {
    match effect {
      @kernel_exec.CancelOutstanding(payload~, ..) => {
        let cancel_ids = Array::from_iter(payload.effect_ids.iter())
        let attempted : Result[Array[(EffectId, CancelDisposition)], Error] = Ok(
          context.host.cancel_effects(cancel_ids, payload.reason),
        ) catch {
          error => Err(error)
        }
        let dispositions = match attempted {
          Ok(value) => value
          Err(error) =>
            raise EffectExecutionFailed(
              phase="CancelOutstanding",
              cause=error.to_string(),
            )
        }
        validate_cancel_dispositions(cancel_ids, dispositions)
      }
      other =>
        raise EffectExecutionFailed(
          phase="CancelOutstanding",
          cause="terminal cancellation boundary received non-cancellation effect: " +
            other.to_string(),
        )
    }
  }
}

///|
/// Verify that a host reported exactly one disposition for every requested
/// effect. `NotPropagated` is an explicit adapter fact; missing, duplicate,
/// or foreign ids are contract failures.
fn validate_cancel_dispositions(
  expected : Array[EffectId],
  reported : Array[(EffectId, CancelDisposition)],
) -> Unit raise PuppetError {
  if expected.length() != reported.length() {
    raise EffectExecutionFailed(
      phase="CancelOutstanding",
      cause="host returned a cancellation disposition count different from the request",
    )
  }
  let expected_ids : Map[String, Bool] = Map::from_array([])
  for effect_id in expected {
    let key = effect_id.to_string()
    if expected_ids.contains(key) {
      raise EffectExecutionFailed(
        phase="CancelOutstanding",
        cause="reducer declared duplicate cancellation effect id " + key,
      )
    }
    expected_ids[key] = true
  }
  let reported_ids : Map[String, Bool] = Map::from_array([])
  for entry in reported {
    let (effect_id, _disposition) = entry
    let key = effect_id.to_string()
    if !expected_ids.contains(key) {
      raise EffectExecutionFailed(
        phase="CancelOutstanding",
        cause="host reported cancellation for unknown effect id " + key,
      )
    }
    if reported_ids.contains(key) {
      raise EffectExecutionFailed(
        phase="CancelOutstanding",
        cause="host reported duplicate cancellation disposition for effect id " +
          key,
      )
    }
    reported_ids[key] = true
  }
}

///|
/// Convert an executor-raised error into an observable typed product error.
/// Cancellation stays distinct from a host defect; neither becomes a normal
/// tool result or a synthetic model completion.
fn execution_error(phase : String, error : Error) -> PuppetError {
  if @async.is_cancellation_error(error) {
    EffectExecutionCancelled(phase~)
  } else {
    EffectExecutionFailed(phase~, cause=error.to_string())
  }
}

///|
/// Run `f` to completion, turning its typed error into a `Result`. Removes
/// the `Ok(expr) catch { e => Err(e) }` wrapping boilerplate at call sites.
/// Sync only: wrapping an async closure in the `async () -> T raise E` slot
/// generalizes its precise raise type to `Error`.
fn[T, E : Error] attempt(f : () -> T raise E) -> Result[T, E] {
  Ok(f()) catch {
    e => Err(e)
  }
}
