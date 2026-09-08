// ──────────────────────────────────────────────────────────────────────────
// Effect completion folding — reducer then durable savepoint
// ──────────────────────────────────────────────────────────────────────────

///|
/// Fold one completed effect through the reducer, declare the next model
/// effect when the reducer reaches `ReadyForModel`, and commit the complete
/// side-effect boundary before returning. Execution and scheduling remain
/// outside this helper; it is only the reducer → boundary-journal seam.

///|
/// Outcome of `fold_effect_input`. Either the next state to drive, or a
/// terminal PromptResult to return early (used by auto-compact when the
/// modelport chose NewThread — the run stops with CompactCompleted).
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
  self.record_context_reading(session_id, output.next_state(), snap)
  // M3.5: auto-compact threshold check. If the reducer just landed in
  // ReadyForModel AND observed token usage crossed the threshold, fire
  // a compact (trigger=Auto) BEFORE declaring the next model effect.
  // NewThread mode stops the turn with CompactCompleted; Replace / Append
  // updates the state and we proceed to declare_model_effect_if_ready
  // on the post-compact transcript.
  let rewrite_events : Array[KernelEvent] = []
  let state_after_auto_compact = if output.next_state().phase() == ReadyForModel {
    match self.check_auto_compact(output.next_state(), snap) {
      Some(compact_cmd) => {
        let compact_outcome = self.handle_compact(
          output.next_state(),
          compact_cmd,
          run_id,
          turn_id,
          session_id,
          dispatcher,
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
                output.next_state(),
                boundary_kind_for_events(output.events()),
                output.events(),
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
            self.last_completed_transcript = Some(
              output.next_state().transcript(),
            )
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
      None => output.next_state()
    }
  } else {
    output.next_state()
  }
  // Journal order stays causal: the effect-completion events that produced
  // the pre-compact state come first, then the compact rewrite, then the
  // next declared model intent — all committed in one boundary.
  let prior_events = output.events()
  for event in rewrite_events {
    prior_events.push(event)
  }
  let boundary_kind = boundary_kind_for_events(prior_events)
  let (next_state, boundary_events) = declare_model_effect_if_ready(
    state_after_auto_compact,
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
      if !rewrite_events.is_empty() {
        self.mark_context_awaiting_measurement(
          session_id,
          next_state.transcript().messages_snapshot().length(),
          snap,
        )
      }
      Continue(next_state)
    }
  }
}

///|
/// The pump is allowed to request a model step only after the reducer has
/// reached `ReadyForModel`. Merge that declared intent into the same durable
/// boundary as the fact that made it ready; the model effect is never
/// dispatched before this boundary commits.
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
