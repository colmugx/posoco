///|

///|
priv enum FoldOutcome {
  Continue(RunState)
  Return(PromptResult)
}

///|
async fn Puppet::fold_effect_input(
  self : Puppet,
  state : RunState,
  input : RunInput,
  dispatcher : EventDispatcher,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  savepoint_id_prefix : String,
  snap : TurnSnapshot,
) -> FoldOutcome raise PuppetError {
  let input : RunInput = match input {
    ModelCompleted(payload~) if self.mailbox.steer_depth() > 0 &&
      !self.mailbox.abort_requested() => ModelCompletedWithSteering(payload~)
    other => other
  }
  let reduced : Result[ReduceOutput, KernelError] = Ok(
    reduce(state, self.config.catalog, input),
  ) catch {
    error => Err(error)
  }
  let output = match reduced {
    Err(error) =>
      raise ReducerInvariantViolation(
        category=IllegalPhase(phase="effect", detail=error.to_string()),
      )
    Ok(value) => value
  }
  let completed_events = output.events()
  let completed_state = if input is ModelCompletedWithSteering(_) {
    self.supersede_pending_tools(output.next_state(), completed_events)
  } else {
    output.next_state()
  }
  self.finish_step_boundary(
    completed_state, completed_events, dispatcher, run_id, turn_id, session_id, savepoint_id_prefix,
    snap,
  )
}

///|
async fn Puppet::finish_step_boundary(
  self : Puppet,
  completed_state : RunState,
  completed_events : Array[KernelEvent],
  dispatcher : EventDispatcher,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  savepoint_id_prefix : String,
  snap : TurnSnapshot,
) -> FoldOutcome raise PuppetError {
  self.record_context_reading(session_id, completed_state, snap)
  let rewrite_events : Array[KernelEvent] = []
  let state_after_auto_compact = if completed_state.phase() == ReadyForModel {
    let compact = match self.check_auto_compact(completed_state, snap) {
      Some(command) => Some(command)
      None if self.mailbox.steer_depth() > 0 => {
        let prospective = completed_state.transcript().messages_snapshot()
        prospective.append(
          self.mailbox.message_inbox().pending_steer_messages(),
        )
        self.check_auto_compact_pre_request(session_id, prospective, snap)
      }
      None => None
    }
    match compact {
      Some(compact_cmd) => {
        let compact_outcome = self.handle_compact(
          completed_state, compact_cmd, run_id, turn_id, session_id, dispatcher,
          snap,
        )
        match compact_outcome {
          ReturnedResult(r) => return Return(r)
          UpdatedState(new_state, events) => {
            for event in events {
              rewrite_events.push(event)
            }
            new_state
          }
          Failed(error) => {
            let facts_committed : Result[Unit, PuppetError] = Ok(
              self.commit_boundary(
                completed_state,
                boundary_kind_for_events(completed_events),
                completed_events,
                dispatcher,
                run_id,
                turn_id,
                session_id,
                savepoint_id_prefix + "_autocompact_fail",
              ),
            ) catch {
              e => Err(e)
            }
            match facts_committed {
              Err(e) => return Return(self.finalize_rejected(error=e))
              Ok(_) => ()
            }
            self.last_completed_transcript = Some(completed_state.transcript())
            return Return(
              self.finalize_rejected(
                error=EffectExecutionFailed(
                  phase="auto_compact",
                  cause=error.to_string(),
                ),
              ),
            )
          }
        }
      }
      None => completed_state
    }
  } else {
    completed_state
  }
  let prior_events = completed_events
  for event in rewrite_events {
    prior_events.push(event)
  }
  let state_after_steer = self.consume_into_state(
    state_after_auto_compact, prior_events,
  )
  if state_after_steer.phase() == Terminal {
    self.drain_undelivered(prior_events, "turn ended before delivery")
  }
  let boundary_kind = boundary_kind_for_events(prior_events)
  let (next_state, boundary_events) = declare_model_effect_if_ready(
    state_after_steer,
    prior_events,
    self.config.catalog,
    snap.call_options(),
  )
  let committed : Result[Unit, PuppetError] = Ok(
    self.commit_boundary(
      next_state, boundary_kind, boundary_events, dispatcher, run_id, turn_id, session_id,
      savepoint_id_prefix,
    ),
  ) catch {
    error => Err(error)
  }
  match committed {
    Err(error) => raise error
    Ok(_) => {
      if !rewrite_events.is_empty() ||
        boundary_events.any(fn(event) { event is UserMessageAppended(..) }) {
        self.record_context_estimate(
          session_id,
          next_state.transcript().messages_snapshot(),
          snap,
        )
      }
      Continue(next_state)
    }
  }
}

///|
fn declare_model_effect_if_ready(
  state : RunState,
  prior_events : Array[KernelEvent],
  catalog : ToolCatalogSnapshot,
  call_options : Json,
) -> (RunState, Array[KernelEvent]) raise PuppetError {
  if state.phase() != ReadyForModel {
    return (state, prior_events.copy())
  }
  let declared : Result[ReduceOutput, KernelError] = Ok(
    run_model_step(state, catalog, call_options),
  ) catch {
    error => Err(error)
  }
  let output = match declared {
    Err(error) =>
      raise ReducerInvariantViolation(
        category=IllegalPhase(phase="run_model_step", detail=error.to_string()),
      )
    Ok(value) => value
  }
  let events = prior_events.copy()
  for event in output.events() {
    events.push(event)
  }
  (output.next_state(), events)
}

///|
fn Puppet::consume_into_state(
  self : Puppet,
  state : RunState,
  events : Array[KernelEvent],
) -> RunState raise PuppetError {
  if state.phase() != ReadyForModel || self.mailbox.abort_requested() {
    return state
  }
  let steers = self.mailbox.consume_steers()
  let mut state = state
  for command in steers {
    let input : RunInput = SteerAppended(payload={
      message: command.message,
      command_id: command.command_id.to_string(),
    })
    let reduced : Result[ReduceOutput, KernelError] = Ok(
      reduce(state, self.config.catalog, input),
    ) catch {
      error => Err(error)
    }
    let output = match reduced {
      Err(error) =>
        raise ReducerInvariantViolation(
          category=IllegalPhase(phase="steer", detail=error.to_string()),
        )
      Ok(value) => value
    }
    for event in output.events() {
      events.push(event)
    }
    state = output.next_state()
  }
  state
}

///|
fn Puppet::drain_undelivered(
  self : Puppet,
  events : Array[KernelEvent],
  reason : String,
) -> Unit {
  self.mailbox.message_inbox().close_step()
  let steers = self.mailbox.consume_steers()
  for command in steers {
    events.push(
      SteerUndelivered(command_id=command.command_id.to_string(), reason~),
    )
  }
}
