///|
let effect_abort_poll_ms : Int32 = 16

///|
async fn await_abort_requested(mailbox : &Mailbox) -> Unit {
  while !mailbox.abort_requested() {
    @async.sleep(effect_abort_poll_ms)
  }
}

///|
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
async fn propagate_terminal_cancellations(
  effects : Array[Effect],
  context : ExecutionContext,
  on_cancel~ : (Array[(EffectId, CancelDisposition)]) -> Unit,
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
fn execution_error(phase : String, error : Error) -> PuppetError {
  match error {
    EffectExecutionCancelled(phase=inner_phase) =>
      EffectExecutionCancelled(phase=inner_phase)
    other => EffectExecutionFailed(phase~, cause=other.to_string())
  }
}
