// ──────────────────────────────────────────────────────────────────────────
// drive_run — the single long-lived pump
// ──────────────────────────────────────────────────────────────────────────

///|
/// Drive a run to terminal or suspended, returning the terminal outcome or a
/// typed failure. This is the ONLY loop in the product that drives RunState: it
/// loops over reducer transitions and reuses `execute_one` per pending effect,
/// never inferring termination from `tool_calls.is_empty()`.
async fn Puppet::drive_run(
  self : Puppet,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  initial_messages : Array[Message],
  snap : TurnSnapshot,
) -> PromptResult raise PuppetError {
  // Since async 0.22 a cancellation signal bypasses every catch below, so an
  // abnormal unwind would otherwise leave the phase gate Active forever and
  // wedge the next operation. Emergency-release the run binding on unwind;
  // every normal return has already finalized through reject/accept paths.
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
  let pre_compact_state : RunState = match
    self.check_auto_compact_pre_request(session_id, seeded_messages, snap) {
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
  let (initial_state, initial_boundary_events) = declare_model_effect_if_ready(
    pre_compact_state,
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
      if pre_compact_fired {
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
    // Safe point: fork. Fork is copy-on-write, so the original transcript is
    // never mutated; the current turn stops and the product layer may then
    // drive the new lineage session as a separate turn.
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
/// One pump step's outcome: keep driving with the next `RunState`, or stop
/// and return the given `PromptResult` (terminal, suspended, or rejected).
priv enum PumpStep {
  ContinueWith(RunState)
  StopWith(PromptResult)
}

///|
/// Abort safe point: feed `CancelRequested` into the reducer, propagate the
/// reducer-declared cancellations at their terminal boundary, and commit the
/// `RunTerminal` boundary. The caller checks `mailbox.abort_requested()`.
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
      let cr : Result[Unit, PuppetError] = Ok(
        self.commit_boundary(
          state,
          RunTerminal,
          out.events(),
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
/// Fork safe point: snapshot the transcript's first `fork_index` messages,
/// persist them as a new lineage session when a store is configured, release
/// the lease, and stop the turn with `ForkCompleted`. Fork is copy-on-write:
/// the original transcript is never mutated. Always stops the pump.
async fn Puppet::pump_fork(
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
  // Persist the new session if a session_store is configured. The
  // new session carries `parent_thread_id` lineage so callers can
  // walk the DAG.
  match self.config.session_store {
    Some(store) => {
      let new_session : @types.Session = {
        messages: forked_messages.copy(),
        metadata: Map::from_array([]),
      }
      let with_lineage = new_session.with_parent_thread_id(parent_session_id)
      store.save(new_session_id, with_lineage) catch {
        error =>
          return self.finalize_rejected(
            error=EffectExecutionFailed(
              phase="fork",
              cause="session save failed: " + error.to_string(),
            ),
          )
      }
    }
    None => ()
  }
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
/// Manual-compact safe point: apply one consumed compact command. The
/// rewrite events are journaled here before the loop continues; the
/// rewritten transcript is the durable fact the next model step builds on.
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
/// ReadyForModel step: run the before_model hook chain, fold any hook
/// transcript rewrite through the reducer, declare the next model intent,
/// and commit both in one durable boundary.
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
  // Fold the hook-rewritten transcript through the reducer — the sole
  // transcript writer — so the rewrite is journaled as a TranscriptRewritten
  // event in the same boundary as the next model intent. Comparison is by
  // content, not length: a same-length rewrite (e.g. system-prompt
  // replacement) is real and must not be dropped. A physical-equality check
  // first skips the O(N) comparison when no hook allocated a new array.
  let rewrite_events : Array[KernelEvent] = []
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
          rewrite_events.push(event)
        }
      }
    }
  }
  // The auto-compact threshold check lives in `fold_effect_input`, not here:
  // ReadyForModel only fires on the very first model step, so a check here
  // would never see post-tool usage observations. Folding is where the
  // reducer's budget update is observable before the next model effect.
  let declared : Result[(RunState, Array[KernelEvent]), PuppetError] = Ok(
    declare_model_effect_if_ready(
      state,
      rewrite_events,
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
          AssistantCommitted,
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
/// AwaitingModel step: execute the single pending model effect and fold its
/// completion through the reducer and the durable boundary.
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
    // Abort landed while the model call was in flight. The effect result is
    // discarded; the loop top's abort check feeds CancelRequested to the
    // reducer, which declares CancelOutstanding for the still-pending effect.
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
/// AwaitingTools step: finalize every pending tool call through the complete
/// pre_tool hook chain, validate and reschedule the final calls, then execute
/// their parallel waves and fold every completion. Later waves are not
/// launched once the run reached terminal/suspended or an abort was requested.

///|
/// Hook inputs and consent records own independent JSON trees. A hook is
/// allowed to retain and mutate its input, but that mutation must never reach
/// reducer-owned pending effects or an earlier consent snapshot.
fn snapshot_tool_call(call : ToolCall) -> ToolCall {
  {
    call_id: call.call_id,
    name: call.name,
    arguments: snapshot_json(call.arguments),
  }
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
          {
            call_id: payload.call_id,
            name: payload.tool_name,
            arguments: payload.arguments,
          },
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
          arguments: snapshot_json(final_call.arguments),
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
              arguments: snapshot_json(final_call.arguments),
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

  // The reducer correlates completions against its pending effect payload.
  // Replace that payload before folding hook outcomes or executing tools so
  // the final name/arguments/owner remain canonical all the way through the
  // transcript and correlation checks. Rejected effects stay present until
  // their explicit NotExecuted input is folded.
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

  // Publish approvals for every call the chain finalized as executable.
  // Each event carries the final canonical call and the surviving consent
  // scope (None for plain approval). One durable boundary per batch keeps
  // the fact ordered before any wave-start or completion event.
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

  // Resolve explicit hook rejections before launching side effects. This
  // keeps the pending-effect correlation valid while making the rejection
  // durable through the normal reducer path.
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
    // Announce the launch before the wave driver starts: one durable
    // boundary per wave, one event per wave, expanded per call by the
    // projection. Observers therefore see execution begin instead of
    // inferring it from a later completion.
    let wave_calls : Array[@kernel.ToolCall] = []
    let mut wave_model_step : ModelStepId? = None
    for effect in wave {
      match effect {
        ExecuteTool(effect_id=_, payload~) => {
          wave_calls.push({
            call_id: payload.call_id,
            name: payload.tool_name,
            arguments: payload.arguments,
          })
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
    // The wave driver receives child requests while roots wait, and folds
    // root outcomes in source order. On abort it returns the latest state,
    // including pending children, for the normal CancelRequested boundary.
    let executed = self.execute_tool_tree(
      wave, state, exec_ctx, dispatcher, turn_id, snap, hook_scope,
    ) catch {
      error => return StopWith(self.finalize_rejected(error~))
    }
    match executed {
      StopWith(result) => return StopWith(result)
      ContinueWith(next) => state = next
    }
    // Abort is observed at a side-effect boundary. Do not launch a later
    // wave after it was requested; the next pump iteration feeds
    // CancelRequested into the reducer.
    if state.phase() == Terminal ||
      state.phase() == Suspended ||
      self.mailbox.abort_requested() {
      break
    }
  }
  ContinueWith(state)
}
