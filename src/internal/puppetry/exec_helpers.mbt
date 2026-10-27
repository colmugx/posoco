///|
/// Abort watcher cadence. Mirrors the SSE reader's 16ms yield interval: fine
/// enough that an ESC abort feels immediate while an effect is in flight,
/// coarse enough to add no measurable overhead to the awaited effect.
let effect_abort_poll_ms : Int32 = 16

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
/// Race the single reducer-declared model effect against the mailbox abort
/// flag. Provider failures travel as `ModelFailed` data; raised host defects
/// never become a fabricated completion.
///
/// Returns `None` when abort was requested while the call was in flight: the
/// effect task is cancelled, its partial result discarded (cancellation has no
/// reducer completion input), and the pump falls back to its loop top where
/// `pump_abort` feeds `CancelRequested`.
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
/// Propagate reducer-declared cancellation effects at their terminal boundary.
/// Cancellation has no reducer completion input: converting it into a tool or
/// model result would fabricate a fact. Malformed reports fail the run loudly.
async fn propagate_terminal_cancellations(
  effects : Array[Effect],
  context : ExecutionContext,
  on_cancel~ : (Array[(EffectId, CancelDisposition)]) -> Unit = fn(_) { () },
) -> Unit raise PuppetError {
  for effect in effects {
    match effect {
      CancelOutstanding(payload~, ..) => {
        let cancel_ids = Array::from_iter(payload.effect_ids.iter())
        let attempted : Result[Array[(EffectId, CancelDisposition)], Error] = Ok(
          context.host.cancel_effects(
            cancel_ids,
            payload.reason,
            run_id=context.run_id,
          ),
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
        on_cancel(dispositions)
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
/// Convert an executor-raised error into an observable typed product error;
/// typed cancellation outcomes and host defects stay distinct, and neither
/// becomes a normal tool result or a synthetic model completion.
fn execution_error(phase : String, error : Error) -> PuppetError {
  match error {
    EffectExecutionCancelled(phase=inner_phase) =>
      EffectExecutionCancelled(phase=inner_phase)
    other => EffectExecutionFailed(phase~, cause=other.to_string())
  }
}
