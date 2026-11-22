///|
// Bound how often background work alone can postpone normal turn settlement.
let max_wakeup_continuations : Int32 = 64

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
  wakeup_continuations~ : Ref[Int32]? = None,
) -> FoldOutcome raise PuppetError {
  let steering = self.mailbox.steer_depth() > 0 &&
    !self.mailbox.abort_requested()
  let wakeup_only = match (input, wakeup_continuations) {
    (ModelCompleted(payload~), Some(count)) =>
      !steering &&
      !payload.completion.has_tool_calls() &&
      !self.mailbox.abort_requested() &&
      count.val < max_wakeup_continuations &&
      self.has_step_context()
    _ => false
  }
  let input : RunInput = match input {
    ModelCompleted(payload~) if steering || wakeup_only =>
      ModelCompletedContinue(payload~)
    other => other
  }
  let output = self.reduce_at(state, input, "effect")
  let completed_events = output.events()
  let completed_state = if steering && input is ModelCompletedContinue(_) {
    self.supersede_pending_tools(output.next_state(), completed_events)
  } else {
    output.next_state()
  }
  let fallback = match (wakeup_only, input) {
    (true, ModelCompletedContinue(payload~)) if completed_state.phase() ==
      ReadyForModel =>
      Some(
        self.reduce_at(state, ModelCompleted(payload~), "settle_without_wakeup"),
      )
    _ => None
  }
  self.finish_step_boundary(
    completed_state,
    completed_events,
    dispatcher,
    run_id,
    turn_id,
    session_id,
    savepoint_id_prefix,
    snap,
    fallback~,
    wakeup_continuations~,
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
  fallback~ : ReduceOutput? = None,
  wakeup_continuations~ : Ref[Int32]? = None,
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
  let prior_events = completed_events.copy()
  prior_events.append(rewrite_events)
  let steering = self.mailbox.steer_depth() > 0 &&
    !self.mailbox.abort_requested()
  let state_after_steer = self.consume_into_state(
    state_after_auto_compact, prior_events,
  )
  let prepared = self.declare_model_effect_if_ready(
    state_after_steer,
    prior_events,
    snap.call_options(),
    needs_step_context=fallback is Some(_) && !steering,
  ) catch {
    HookRejected(_) as error => {
      self.commit_boundary(
        completed_state,
        boundary_kind_for_events(completed_events),
        completed_events,
        dispatcher,
        run_id,
        turn_id,
        session_id,
        savepoint_id_prefix,
      )
      return Return(self.finalize_rejected(error~))
    }
    error => raise error
  }
  let continued_for_wakeup = !steering &&
    fallback is Some(_) &&
    prepared.2 is Some(_)
  let (next_state, boundary_events, step_context) = match (fallback, prepared) {
    (Some(original), (candidate, events, None)) if !steering &&
      !self.mailbox.abort_requested() =>
      if self.mailbox.steer_depth() > 0 {
        let steered = self.consume_into_state(candidate, events)
        self.declare_model_effect_if_ready(steered, events, snap.call_options())
      } else {
        (original.next_state(), original.events(), None)
      }
    _ => prepared
  }
  if next_state.phase() == Terminal {
    self.drain_undelivered(boundary_events, "turn ended before delivery")
  }
  let boundary_kind = boundary_kind_for_events(boundary_events)
  let committed : Result[Unit, PuppetError] = Ok(
    self.commit_boundary(
      next_state,
      boundary_kind,
      boundary_events,
      dispatcher,
      run_id,
      turn_id,
      session_id,
      savepoint_id_prefix,
      step_context~,
    ),
  ) catch {
    error => Err(error)
  }
  match committed {
    Err(error) => raise error
    Ok(_) => {
      if continued_for_wakeup && wakeup_continuations is Some(count) {
        count.val = count.val + 1
      }
      if boundary_events.any(fn(event) {
          event is TranscriptRewritten(..) ||
          event is UserMessageAppended(..) ||
          event is StepContextAppended(..)
        }) {
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
fn Puppet::has_step_context(self : Puppet) -> Bool {
  match self.step_context_source {
    Some((has_pending, _)) => has_pending()
    None => false
  }
}

///|
fn Puppet::reduce_at(
  self : Puppet,
  state : RunState,
  input : RunInput,
  phase : String,
) -> ReduceOutput raise PuppetError {
  reduce(state, self.config.catalog, input) catch {
    error =>
      raise ReducerInvariantViolation(
        category=IllegalPhase(phase~, detail=error.to_string()),
      )
  }
}

///|
async fn Puppet::apply_before_model(
  self : Puppet,
  messages : Array[Message],
) -> Array[Message] raise PuppetError {
  let mut current = messages
  for hook in self.config.hooks {
    current = hook.before_model(current) catch {
      Aborted(reason~) => raise HookRejected(reason="pre_model_hook: " + reason)
    }
  }
  current
}

///|
async fn Puppet::rewrite_before_model(
  self : Puppet,
  state : RunState,
  events : Array[KernelEvent],
) -> RunState raise PuppetError {
  if self.config.hooks.is_empty() {
    return state
  }
  let original = state.transcript().messages_snapshot()
  let updated = self.apply_before_model(
    @message_snapshot.snapshot_messages(original),
  )
  if updated == original {
    return state
  }
  let out = self.reduce_at(
    state,
    TranscriptRewrite(payload={
      rewritten_messages: updated,
      reason: "pre_model_hook",
    }),
    "pre_model_hook",
  )
  events.append(out.events())
  out.next_state()
}

///|
async fn Puppet::declare_model_effect_if_ready(
  self : Puppet,
  state : RunState,
  prior_events : Array[KernelEvent],
  call_options : Json,
  run_hooks~ : Bool = false,
  needs_step_context~ : Bool = false,
) -> (RunState, Array[KernelEvent], StepContext?) raise PuppetError {
  let events = prior_events.copy()
  if state.phase() != ReadyForModel {
    return (state, events, None)
  }
  let step_context = match self.step_context_source {
    Some((_, snapshot)) if !self.mailbox.abort_requested() => snapshot()
    _ => None
  }
  let (state, step_context) = match step_context {
    Some(context) => {
      let out = @kernel_exec.append_step_context(state, context.messages) catch {
        error =>
          raise ReducerInvariantViolation(
            category=IllegalPhase(
              phase="step_context",
              detail=error.to_string(),
            ),
          )
      }
      let candidate_events = out.events()
      let rewritten = self.rewrite_before_model(
        out.next_state(),
        candidate_events,
      ) catch {
        HookRejected(_) if self.mailbox.abort_requested() ||
          !(context.is_current)() => state
        error => raise error
      }
      if self.mailbox.abort_requested() {
        return (state, events, None)
      }
      if (context.is_current)() {
        events.append(candidate_events)
        (rewritten, step_context)
      } else {
        (state, None)
      }
    }
    None => (state, None)
  }
  if step_context is None && needs_step_context {
    return (state, events, None)
  }
  let state = if step_context is None && run_hooks {
    self.rewrite_before_model(state, events)
  } else {
    state
  }
  let out = run_model_step(state, self.config.catalog, call_options) catch {
    error =>
      raise ReducerInvariantViolation(
        category=IllegalPhase(phase="run_model_step", detail=error.to_string()),
      )
  }
  events.append(out.events())
  (out.next_state(), events, step_context)
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
