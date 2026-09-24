///|
/// Abort watcher cadence. Mirrors the SSE reader's 16ms yield interval: fine
/// enough that an ESC abort feels immediate while an effect is in flight,
/// coarse enough to add no measurable overhead to the awaited effect.
let effect_abort_poll_ms : Int = 16

///|
/// Block until the control mailbox records an abort for the active run. Runs
/// as the losing side of `@async.any`: when the effect settles first, `any`
/// cancels this loop at its sleep suspension point.
async fn await_abort_requested(mailbox : &Mailbox) -> Unit {
  while !mailbox.abort_requested() {
    @async.sleep(effect_abort_poll_ms)
  }
}

///|
/// Execute the single reducer-declared model effect, racing the await against
/// the mailbox abort flag. Expected provider failures travel as `ModelFailed`
/// data; raised host defects are surfaced as a distinct Puppet error and never
/// fabricated into a completion.
///
/// Returns `None` when abort was requested while the call was in flight: the
/// effect task is cancelled, its partial result discarded (cancellation has no
/// reducer completion input), and the pump falls back to its loop top where
/// `pump_abort` feeds `CancelRequested` to the reducer.
///
/// (R3 M3.7: the previous `(RunInput, NewThreadSpec?)` tuple has been removed
/// — compact is now a separate `ModelPort::compact` method driven by posoco,
/// not a side-channel of `CallModel`.)
async fn execute_model_effect(
  effect : Effect,
  context : ExecutionContext,
  on_chunk : @kernel_exec.HostChunkCallback?,
) -> RunInput? raise PuppetError {
  let raced : Result[RunInput?, Error] = Ok(
    @async.any([
      () => Some(execute_one(effect, context, on_chunk)),
      () => {
        await_abort_requested(context.mailbox)
        None
      },
    ]),
  ) catch {
    error => Err(error)
  }
  match raced {
    Ok(value) => value
    Err(error) => raise execution_error("AwaitingModel", error)
  }
}

///|
/// Execute one already-scheduled tool wave, racing the await against the
/// mailbox abort flag. `@async.all` supplies the actual parallelism and
/// cancels peers if one task raises. Its result array remains in source
/// order, which the caller feeds to the reducer deterministically.
///
/// Returns `None` when abort was requested while the wave was in flight: the
/// wave's effect tasks are cancelled, their partial results discarded
/// (cancellation has no reducer completion input), and the pump falls back to
/// its loop top where `pump_abort` feeds `CancelRequested` to the reducer,
/// which then declares `CancelOutstanding` for the still-pending effects.
async fn execute_tool_wave(
  effects : Array[Effect],
  context : ExecutionContext,
) -> Array[RunInput]? raise PuppetError {
  let raced : Result[Array[RunInput]?, Error] = Ok(
    @async.any([
      () => {
        Some(
          @async.all(
            effects.map(fn(effect) { () => execute_one(effect, context, None) }),
          ),
        )
      },
      () => {
        await_abort_requested(context.mailbox)
        None
      },
    ]),
  ) catch {
    error => Err(error)
  }
  match raced {
    Ok(value) => value
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
      CancelOutstanding(payload~, ..) => {
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
/// Cancellation travels as a runtime signal and never reaches this function;
/// typed cancellation outcomes and host defects stay distinct, and neither
/// becomes a normal tool result or a synthetic model completion.
fn execution_error(phase : String, error : Error) -> PuppetError {
  match error {
    EffectExecutionCancelled(phase=inner_phase) =>
      EffectExecutionCancelled(phase=inner_phase)
    other => EffectExecutionFailed(phase~, cause=other.to_string())
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
