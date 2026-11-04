///|
/// Only called before any root starts or after the whole launched wave joins.
/// Per-root completion folding must not replace another root's real result.
fn Puppet::supersede_pending_tools(
  self : Puppet,
  state : RunState,
  events : Array[KernelEvent],
) -> RunState raise PuppetError {
  if state.phase() != AwaitingTools ||
    self.mailbox.steer_depth() == 0 ||
    self.mailbox.abort_requested() {
    return state
  }
  let pending = state.pending_effects()
  let mut state = state
  for effect in pending {
    guard effect is ExecuteTool(effect_id~, payload~) else {
      raise ReducerInvariantViolation(
        category=IllegalPhase(
          phase="steering",
          detail="pending effect is not a tool",
        ),
      )
    }
    if payload.parent is Some(_) {
      raise ReducerInvariantViolation(
        category=IllegalPhase(
          phase="steering",
          detail="cannot supersede an active child tree",
        ),
      )
    }
    let output = reduce(
      state,
      self.config.catalog,
      ToolCompleted(payload={
        effect_id,
        call_id: payload.call_id,
        tool_name: payload.tool_name,
        arguments: payload.arguments,
        outcome: NotExecuted(
          reason=SupersededByMessage,
          original_call_id=payload.call_id,
        ),
      }),
    ) catch {
      error =>
        raise ReducerInvariantViolation(
          category=IllegalPhase(phase="steering", detail=error.to_string()),
        )
    }
    for event in output.events() {
      events.push(event)
    }
    state = output.next_state()
    if state.phase() == Terminal {
      break
    }
  }
  state
}

///|
async fn Puppet::pump_steering(
  self : Puppet,
  state : RunState,
  dispatcher : EventDispatcher,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  snap : TurnSnapshot,
) -> PumpStep noraise {
  let events : Array[KernelEvent] = []
  let result : Result[FoldOutcome, PuppetError] = Ok(
    {
      let next = self.supersede_pending_tools(state, events)
      self.finish_step_boundary(
        next, events, dispatcher, run_id, turn_id, session_id, "sp_steering", snap,
      )
    },
  ) catch {
    error => Err(error)
  }
  match result {
    Err(error) => StopWith(self.finalize_rejected(error~))
    Ok(Return(result)) => StopWith(result)
    Ok(Continue(next)) => ContinueWith(next)
  }
}
