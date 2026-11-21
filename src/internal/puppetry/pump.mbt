///|
async fn Puppet::drive_run(
  self : Puppet,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  initial_messages : Array[Message],
  snap : TurnSnapshot,
) -> PromptResult raise PuppetError {
  // Release the run binding on cancellation unwind so the phase gate cannot
  // stay stuck Active.
  errdefer {
    self.release_run_binding()
    self.mailbox.set_quiescent(Idle)
  }
  let initial_state = RunState::initial(
    run_id~,
    session_id~,
    budget=snap.budget(),
  ) catch {
    e =>
      return self.finalize_rejected(
        error=ReducerInvariantViolation(
          category=IllegalPhase(phase="initial", detail=e.to_string()),
        ),
      )
  }
  let exec_ctx = ExecutionContext(
    self.config.host,
    catalog=self.config.catalog,
    run_id~,
    session_id~,
    mailbox=self.mailbox,
    launch_gate?=self.launch_gate,
    revocations?=self.tool_revocations,
  )
  let dispatcher = EventDispatcher(run_id, turn_id, session_id)
  for sub in self.config.subscribers {
    dispatcher.register(sub)
  }
  // Inside a run the identity is always known, so hooks always see `Some`.
  let hook_scope : @types.EventScope = { session_id, run_id, turn_id, }
  // before_model hooks may rewrite or abort the initial messages.
  let mut seeded_messages = initial_messages.copy()
  for hook in self.config.hooks {
    seeded_messages = hook.before_model(seeded_messages) catch {
      Aborted(reason~) =>
        return self.finalize_rejected(
          error=HookRejected(reason="pre_model_hook: " + reason),
        )
    }
  }
  let start_input : RunInput = Start(payload={
    initial_messages: seeded_messages,
    catalog_version: snap.catalog_version(),
  })
  let mut state = initial_state
  let out0 = reduce(state, self.config.catalog, start_input) catch {
    e =>
      return self.finalize_rejected(
        error=ReducerInvariantViolation(
          category=IllegalPhase(phase="Start", detail=e.to_string()),
        ),
      )
  }
  let initial_events : Array[KernelEvent] = out0.events()
  let mut pre_compact_fired = false
  let prospective = seeded_messages.copy()
  prospective.append(self.mailbox.message_inbox().pending_steer_messages())
  let pre_compact_state : RunState = match
    self.check_auto_compact_pre_request(session_id, prospective, snap) {
    Some(compact_cmd) => {
      pre_compact_fired = true
      match
        self.handle_compact(
          out0.next_state(),
          compact_cmd,
          run_id,
          turn_id,
          session_id,
          dispatcher,
          snap,
        ) {
        ReturnedResult(r) => return r
        UpdatedState(new_state, events) => {
          for event in events {
            initial_events.push(event)
          }
          new_state
        }
        Failed(error) =>
          return self.finalize_rejected(
            error=EffectExecutionFailed(
              phase="auto_compact",
              cause="pre-request: " + error.to_string(),
            ),
          )
      }
    }
    None => out0.next_state()
  }
  let steered : Result[RunState, PuppetError] = Ok(
    self.consume_into_state(pre_compact_state, initial_events),
  ) catch {
    error => Err(error)
  }
  let state_after_steer = match steered {
    Err(error) => return self.finalize_rejected(error~)
    Ok(value) => value
  }
  let (initial_state, initial_boundary_events) = declare_model_effect_if_ready(
    state_after_steer,
    initial_events,
    self.config.catalog,
    snap.call_options(),
  ) catch {
    error => return self.finalize_rejected(error~)
  }
  // The initial boundary durably accepts input, starts the run, and declares
  // the first model intent in one append before the effect can execute.
  let commit_result : Result[Unit, PuppetError] = Ok(
    self.commit_boundary(
      initial_state,
      InputAccepted,
      initial_boundary_events,
      dispatcher,
      run_id,
      turn_id,
      session_id,
      "sp_input",
    ),
  ) catch {
    e => Err(e)
  }
  match commit_result {
    Err(e) => return self.finalize_rejected(error=e)
    Ok(_) =>
      if pre_compact_fired ||
        initial_boundary_events.any(fn(event) {
          event is UserMessageAppended(..)
        }) {
        self.record_context_estimate(
          session_id,
          initial_state.transcript().messages_snapshot(),
          snap,
        )
      }
  }
  state = initial_state
  let mut iter = 0
  let max_iter = self.config.max_iterations
  while state.phase() != Terminal && state.phase() != Suspended {
    iter = iter + 1
    match max_iter {
      Some(m) if iter > m =>
        return self.finalize_rejected(error=PumpLoopExceeded(iterations=iter))
      _ => ()
    }
    if self.mailbox.abort_requested() {
      match
        self.pump_abort(
          state, exec_ctx, dispatcher, run_id, turn_id, session_id,
        ) {
        StopWith(result) => return result
        ContinueWith(next_state) => {
          state = next_state
          continue
        }
      }
    }
    match self.mailbox.consume_one_fork() {
      Some(fork_cmd) =>
        return self.pump_fork(state, fork_cmd, session_id, run_id, turn_id)
      None => ()
    }
    // Safe point: manual compact, enqueued by `/compact`. Auto compacts
    // (context-window pressure) are decided inside `fold_effect_input`.
    match self.mailbox.consume_one_compact() {
      Some(compact_cmd) =>
        match
          self.pump_compact(
            state, compact_cmd, run_id, turn_id, session_id, dispatcher, snap, iter,
          ) {
          StopWith(result) => return result
          ContinueWith(next_state) => {
            state = next_state
            continue
          }
        }
      None => ()
    }
    match state.phase() {
      ReadyForModel =>
        match
          self.pump_ready_for_model(
            state, dispatcher, run_id, turn_id, session_id, snap, iter,
          ) {
          StopWith(result) => return result
          ContinueWith(next_state) => state = next_state
        }
      AwaitingModel =>
        match
          self.pump_awaiting_model(
            state, exec_ctx, dispatcher, run_id, turn_id, session_id, snap, iter,
            hook_scope,
          ) {
          StopWith(result) => return result
          ContinueWith(next_state) => state = next_state
        }
      AwaitingTools =>
        match
          self.pump_awaiting_tools(
            state, exec_ctx, dispatcher, run_id, turn_id, session_id, snap, hook_scope,
          ) {
          StopWith(result) => return result
          ContinueWith(next_state) => state = next_state
        }
      _ => break
    }
  }
  match state.phase() {
    Terminal => {
      let outcome = match state.outcome() {
        Some(outcome) => outcome
        None =>
          return self.finalize_rejected(
            error=ReducerInvariantViolation(
              category=IllegalPhase(
                phase="Terminal",
                detail="outcome is None at Terminal",
              ),
            ),
          )
      }
      return self.finalize_run(
        Terminated(run_id~, turn_id~, outcome~, transcript=state.transcript()),
      )
    }
    Suspended => {
      let req = match state.suspension_requirement() {
        Some(req) => req
        None =>
          return self.finalize_rejected(
            error=ReducerInvariantViolation(
              category=IllegalPhase(
                phase="Suspended",
                detail="requirement is None",
              ),
            ),
          )
      }
      // Deterministic suspension id derived from the current model step.
      let suspension_id = "susp_\{run_id.to_string()}_\{state.current_model_step_id().to_int()}"
      return self.finalize_run(
        Suspended(run_id~, turn_id~, suspension_id~, requirement_kind=req.kind),
      )
    }
    _ =>
      // Pump exited without reaching terminal or suspended.
      return self.finalize_rejected(error=PumpLoopExceeded(iterations=iter))
  }
}

///|
priv enum PumpStep {
  ContinueWith(RunState)
  StopWith(PromptResult)
}

///|
async fn Puppet::pump_abort(
  self : Puppet,
  state : RunState,
  exec_ctx : ExecutionContext,
  dispatcher : EventDispatcher,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  on_cancel~ : (Array[(EffectId, CancelDisposition)]) -> Unit = fn(_) { () },
) -> PumpStep noraise {
  let mut state = state
  let cancel_input : RunInput = CancelRequested(payload={ detail: None, })
  let r : Result[ReduceOutput, KernelError] = Ok(
    reduce(state, self.config.catalog, cancel_input),
  ) catch {
    e => Err(e)
  }
  match r {
    Err(e) =>
      StopWith(
        self.finalize_rejected(
          error=ReducerInvariantViolation(
            category=IllegalPhase(phase="cancel", detail=e.to_string()),
          ),
        ),
      )
    Ok(out) => {
      state = out.next_state()
      let propagated : Result[Unit, PuppetError] = Ok(
        propagate_terminal_cancellations(out.effects(), exec_ctx, on_cancel~),
      ) catch {
        error => Err(error)
      }
      match propagated {
        Err(error) => return StopWith(self.finalize_rejected(error~))
        Ok(_) => ()
      }
      let terminal_events = out.events()
      self.drain_undelivered(terminal_events, "run aborted before delivery")
      let cr : Result[Unit, PuppetError] = Ok(
        self.commit_boundary(
          state,
          RunTerminal,
          terminal_events,
          dispatcher,
          run_id,
          turn_id,
          session_id,
          "sp_cancel",
        ),
      ) catch {
        e => Err(e)
      }
      match cr {
        Err(e) => return StopWith(self.finalize_rejected(error=e))
        Ok(_) => ()
      }
      ContinueWith(state)
    }
  }
}

///|
fn Puppet::pump_fork(
  self : Puppet,
  state : RunState,
  fork_cmd : ForkCommand,
  session_id : SessionId,
  run_id : RunId,
  turn_id : TurnId,
) -> PromptResult raise PuppetError {
  let transcript_msgs = state.transcript().messages_snapshot()
  let len = transcript_msgs.length()
  let fork_index = if fork_cmd.fork_index < 0 {
    0
  } else if fork_cmd.fork_index > len {
    len
  } else {
    fork_cmd.fork_index
  }
  let forked_messages : Array[@kernel.Message] = Array::from_iter(
    transcript_msgs.iter().take(fork_index),
  )
  let parent_session_id = session_id.to_string()
  let new_session_id = parent_session_id +
    "_fork_" +
    fork_cmd.command_id().to_string()
  self.capture_source(run_id, parent_session_id, transcript_msgs, fork_index)
  // Release lease + clear mailbox before returning ForkCompleted so
  // the next prompt can bind cleanly.
  return self.finalize_run(
    ReleasedNoCommit(
      result=ForkCompleted(
        run_id~,
        turn_id~,
        parent_session_id~,
        new_session_id~,
        forked_messages~,
      ),
    ),
  )
}

///|
async fn Puppet::pump_compact(
  self : Puppet,
  state : RunState,
  compact_cmd : CompactCommand,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  dispatcher : EventDispatcher,
  snap : TurnSnapshot,
  iter : Int32,
) -> PumpStep raise PuppetError {
  let compact_outcome = self.handle_compact(
    state, compact_cmd, run_id, turn_id, session_id, dispatcher, snap,
  )
  match compact_outcome {
    ReturnedResult(r) => StopWith(r)
    UpdatedState(new_state, rewrite_events) => {
      let cr : Result[Unit, PuppetError] = Ok(
        self.commit_boundary(
          new_state,
          boundary_kind_for_events(rewrite_events),
          rewrite_events,
          dispatcher,
          run_id,
          turn_id,
          session_id,
          "sp_compact_\{iter}",
        ),
      ) catch {
        e => Err(e)
      }
      match cr {
        Err(e) => StopWith(self.finalize_rejected(error=e))
        Ok(_) => {
          if rewrite_events.length() > 0 {
            self.record_context_estimate(
              session_id,
              new_state.transcript().messages_snapshot(),
              snap,
            )
          }
          ContinueWith(new_state)
        }
      }
    }
    Failed(error) => StopWith(self.finalize_rejected(error~))
  }
}

///|
async fn Puppet::pump_ready_for_model(
  self : Puppet,
  state : RunState,
  dispatcher : EventDispatcher,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  snap : TurnSnapshot,
  iter : Int32,
) -> PumpStep noraise {
  let mut state = state
  let prior_events : Array[KernelEvent] = []
  let steered : Result[RunState, PuppetError] = Ok(
    self.consume_into_state(state, prior_events),
  ) catch {
    error => Err(error)
  }
  match steered {
    Err(error) => return StopWith(self.finalize_rejected(error~))
    Ok(next_state) => state = next_state
  }
  // Rewrites chain — each hook sees the previous output — and the result
  // replaces the reducer's transcript for the next CallModel effect.
  let initial_messages = state.transcript().messages_snapshot()
  let mut current_messages = initial_messages
  let mut hook_aborted = false
  let mut abort_reason = ""
  let mut hook_changed = false
  for hook in self.config.hooks {
    let new_messages = hook.before_model(current_messages) catch {
      Aborted(reason~) => {
        hook_aborted = true
        abort_reason = reason
        []
      }
    }
    if !physical_equal(new_messages, current_messages) {
      hook_changed = true
    }
    current_messages = new_messages
    if hook_aborted {
      break
    }
  }
  if hook_aborted {
    return StopWith(
      self.finalize_rejected(
        error=HookRejected(reason="pre_model_hook: " + abort_reason),
      ),
    )
  }
  if hook_changed && current_messages != initial_messages {
    let rewrite_input : RunInput = TranscriptRewrite(payload={
      rewritten_messages: current_messages,
      reason: "pre_model_hook",
    })
    let reduced : Result[ReduceOutput, KernelError] = Ok(
      reduce(state, self.config.catalog, rewrite_input),
    ) catch {
      e => Err(e)
    }
    match reduced {
      Err(e) =>
        return StopWith(
          self.finalize_rejected(
            error=ReducerInvariantViolation(
              category=IllegalPhase(
                phase="ReadyForModel",
                detail="pre_model_hook transcript rewrite: " + e.to_string(),
              ),
            ),
          ),
        )
      Ok(out) => {
        state = out.next_state()
        for event in out.events() {
          prior_events.push(event)
        }
      }
    }
  }
  let declared : Result[(RunState, Array[KernelEvent]), PuppetError] = Ok(
    declare_model_effect_if_ready(
      state,
      prior_events,
      self.config.catalog,
      snap.call_options(),
    ),
  ) catch {
    error => Err(error)
  }
  match declared {
    Err(error) => return StopWith(self.finalize_rejected(error~))
    Ok((next_state, events)) => {
      state = next_state
      let cr : Result[Unit, PuppetError] = Ok(
        self.commit_boundary(
          state,
          boundary_kind_for_events(events),
          events,
          dispatcher,
          run_id,
          turn_id,
          session_id,
          "sp_ready_\{iter}",
        ),
      ) catch {
        e => Err(e)
      }
      match cr {
        Err(e) => return StopWith(self.finalize_rejected(error=e))
        Ok(_) => ()
      }
    }
  }
  ContinueWith(state)
}

///|
async fn Puppet::pump_awaiting_model(
  self : Puppet,
  state : RunState,
  exec_ctx : ExecutionContext,
  dispatcher : EventDispatcher,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  snap : TurnSnapshot,
  iter : Int32,
  hook_scope : @types.EventScope,
) -> PumpStep noraise {
  let pending = state.pending_effects()
  if pending.length() != 1 {
    return StopWith(
      self.finalize_rejected(
        error=ReducerInvariantViolation(
          category=IllegalPhase(
            phase="AwaitingModel",
            detail="expected exactly one pending model effect",
          ),
        ),
      ),
    )
  }
  let executed : Result[RunInput?, PuppetError] = Ok(
    execute_model_effect(pending[0], exec_ctx, self.config.stream_chunks),
  ) catch {
    error => Err(error)
  }
  let input = match executed {
    Err(error) => return StopWith(self.finalize_rejected(error~))
    Ok(None) => return ContinueWith(state)
    Ok(Some(value)) => value
  }
  let folded : Result[FoldOutcome, PuppetError] = Ok(
    self.fold_effect_input(
      state,
      input,
      dispatcher,
      run_id,
      turn_id,
      session_id,
      "sp_model_effect_\{iter}",
      snap,
    ),
  ) catch {
    error => Err(error)
  }
  match folded {
    Err(error) => return StopWith(self.finalize_rejected(error~))
    Ok(Return(r)) => StopWith(r)
    Ok(Continue(next_state)) => {
      self.fire_post_event_hooks(input, hook_scope)
      ContinueWith(next_state)
    }
  }
}

///|

///|
fn snapshot_tool_call(call : ToolCall) -> ToolCall {
  @message_snapshot.snapshot_tool_call(call)
}

///|
async fn Puppet::pump_awaiting_tools(
  self : Puppet,
  state : RunState,
  exec_ctx : ExecutionContext,
  dispatcher : EventDispatcher,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  snap : TurnSnapshot,
  hook_scope : @types.EventScope,
) -> PumpStep noraise {
  if self.mailbox.steer_depth() > 0 && !self.mailbox.abort_requested() {
    return self.pump_steering(
      state, dispatcher, run_id, turn_id, session_id, snap,
    )
  }
  let pending = state.pending_effects()
  let mut state = state
  // Every hook runs before scheduling. Scheduling first would make a later
  // rewrite execute with the original tool's owner/policy and wave barriers.
  let executable_effects : Array[Effect] = []
  let normalized_pending : Array[Effect] = []
  let hook_rejected_inputs : Array[RunInput] = []
  // Approved calls with the consent scope that survived the full chain
  // (None for plain approval), published in the ToolCallApproved boundary.
  let approved_finalized : Array[(ModelStepId, ToolCall, String?)] = []
  for effect in pending {
    match effect {
      ExecuteTool(effect_id~, payload~) => {
        let finalized = finalize_tool_call(
          self.config.catalog,
          self.config.hooks,
          payload.tool_call(),
          direct=true,
          revocations?=self.tool_revocations,
        ) catch {
          error => return StopWith(self.finalize_rejected(error~))
        }
        let current_call = finalized.call
        let consent_scope = finalized.consent_scope
        let hook_outcome = finalized.rejection
        let final_owner = match self.config.catalog.find(current_call.name) {
          Some(entry) => entry.definition.owner
          None => payload.owner
        }
        let final_call = snapshot_tool_call(current_call)
        let normalized_pending_effect : Effect = ExecuteTool(effect_id~, payload={
          call_id: payload.call_id,
          tool_name: final_call.name,
          // Keep the reducer's pending payload independent from the effect
          // handed to the host as well as from every hook input.
          arguments: @message_snapshot.snapshot_json(final_call.arguments),
          owner: final_owner,
          model_step_id: payload.model_step_id,
          catalog_version: payload.catalog_version,
          parent: payload.parent,
        })
        normalized_pending.push(normalized_pending_effect)
        match hook_outcome {
          Some(outcome) =>
            hook_rejected_inputs.push(
              ToolCompleted(payload={
                effect_id,
                call_id: payload.call_id,
                tool_name: final_call.name,
                arguments: final_call.arguments,
                outcome,
              }),
            )
          None => {
            let executable_effect : Effect = ExecuteTool(effect_id~, payload={
              call_id: payload.call_id,
              tool_name: final_call.name,
              arguments: @message_snapshot.snapshot_json(final_call.arguments),
              owner: final_owner,
              model_step_id: payload.model_step_id,
              catalog_version: payload.catalog_version,
              parent: payload.parent,
            })
            executable_effects.push(executable_effect)
            approved_finalized.push(
              (payload.model_step_id, final_call, consent_scope),
            )
          }
        }
      }
      _ =>
        return StopWith(
          self.finalize_rejected(
            error=ReducerInvariantViolation(
              category=IllegalPhase(
                phase="AwaitingTools",
                detail="pending effect is not ExecuteTool",
              ),
            ),
          ),
        )
    }
  }

  let normalized_result : Result[RunState, PuppetError] = Ok(
    state.transition(
      phase=AwaitingTools,
      transcript=state.transcript(),
      pending_effects=normalized_pending,
      next_event_sequence=state.next_event_sequence(),
      next_effect_id=state.next_effect_id(),
      current_model_step_id=state.current_model_step_id(),
      catalog_version=None,
      budget_consumed=state.budget_consumed(),
      outcome=state.outcome(),
      suspension_requirement=state.suspension_requirement(),
    ),
  ) catch {
    error =>
      Err(
        ReducerInvariantViolation(
          category=IllegalPhase(
            phase="AwaitingTools",
            detail="failed to normalize finalized tool effects: " +
              error.to_string(),
          ),
        ),
      )
  }
  state = match normalized_result {
    Err(error) => return StopWith(self.finalize_rejected(error~))
    Ok(value) => value
  }

  if !approved_finalized.is_empty() {
    let approved_events : Array[KernelEvent] = []
    for finalized in approved_finalized {
      let (model_step_id, final_call, scope) = finalized
      approved_events.push(
        ToolCallApproved(model_step_id~, call=final_call, consent_scope=scope),
      )
    }
    let approved_cr : Result[Unit, PuppetError] = Ok(
      self.commit_boundary(
        state,
        ToolCommitted,
        approved_events,
        dispatcher,
        run_id,
        turn_id,
        session_id,
        "sp_tool_approved",
      ),
    ) catch {
      error => Err(error)
    }
    match approved_cr {
      Err(error) => return StopWith(self.finalize_rejected(error~))
      Ok(_) => ()
    }
  }

  for rejection_index, input in hook_rejected_inputs {
    let folded : Result[FoldOutcome, PuppetError] = Ok(
      self.fold_effect_input(
        state,
        input,
        dispatcher,
        run_id,
        turn_id,
        session_id,
        "sp_tool_hook_\{rejection_index}",
        snap,
      ),
    ) catch {
      error => Err(error)
    }
    match folded {
      Err(error) => return StopWith(self.finalize_rejected(error~))
      Ok(Return(r)) => return StopWith(r)
      Ok(Continue(next_state)) => {
        self.fire_post_event_hooks(input, hook_scope)
        state = next_state
      }
    }
    if state.phase() == Terminal || state.phase() == Suspended {
      return ContinueWith(state)
    }
  }

  if executable_effects.is_empty() {
    return ContinueWith(state)
  }

  let wave_result : Result[Array[Array[Effect]], PuppetError] = Ok(
    scheduled_tool_effect_waves(
      executable_effects,
      self.config.catalog,
      state.catalog_version(),
    ),
  ) catch {
    error => Err(error)
  }
  let waves = match wave_result {
    Err(error) => return StopWith(self.finalize_rejected(error~))
    Ok(value) => value
  }
  for wave_index, wave in waves {
    if self.mailbox.abort_requested() {
      return ContinueWith(state)
    }
    if self.mailbox.steer_depth() > 0 {
      return self.pump_steering(
        state, dispatcher, run_id, turn_id, session_id, snap,
      )
    }
    let wave_calls : Array[@kernel.ToolCall] = []
    let mut wave_model_step : ModelStepId? = None
    for effect in wave {
      match effect {
        ExecuteTool(effect_id=_, payload~) => {
          wave_calls.push(payload.tool_call())
          wave_model_step = Some(payload.model_step_id)
        }
        _ =>
          return StopWith(
            self.finalize_rejected(
              error=ReducerInvariantViolation(
                category=IllegalPhase(
                  phase="AwaitingTools",
                  detail="wave effect is not ExecuteTool",
                ),
              ),
            ),
          )
      }
    }
    if !wave_calls.is_empty() {
      let wave_events : Array[KernelEvent] = [
        ToolWaveStarted(
          model_step_id=wave_model_step.unwrap(),
          calls=wave_calls,
        ),
      ]
      let wave_cr : Result[Unit, PuppetError] = Ok(
        self.commit_boundary(
          state,
          ToolCommitted,
          wave_events,
          dispatcher,
          run_id,
          turn_id,
          session_id,
          "sp_tool_wave_start_\{wave_index}",
        ),
      ) catch {
        error => Err(error)
      }
      match wave_cr {
        Err(error) => return StopWith(self.finalize_rejected(error~))
        Ok(_) => ()
      }
    }
    // A committed-start listener or a checkpoint may have submitted input.
    if self.mailbox.abort_requested() {
      return ContinueWith(state)
    }
    if self.mailbox.steer_depth() > 0 {
      return self.pump_steering(
        state, dispatcher, run_id, turn_id, session_id, snap,
      )
    }
    let executed = self.execute_tool_tree(
      wave, state, exec_ctx, dispatcher, turn_id, snap, hook_scope,
    ) catch {
      error => return StopWith(self.finalize_rejected(error~))
    }
    match executed {
      StopWith(result) => return StopWith(result)
      ContinueWith(next) => state = next
    }
    if state.phase() == Terminal ||
      state.phase() == Suspended ||
      self.mailbox.abort_requested() {
      break
    }
  }
  ContinueWith(state)
}
