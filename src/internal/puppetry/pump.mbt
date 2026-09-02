// ──────────────────────────────────────────────────────────────────────────
// drive_run — the single long-lived pump
// ──────────────────────────────────────────────────────────────────────────

///|
/// Drive a run to terminal or suspended. Returns a PromptResult carrying
/// the terminal outcome or a typed failure.
///
/// The pump loops over reducer transitions. Each iteration:
/// 1. If ReadyForModel: call `run_model_step` to declare CallModel.
/// 2. If AwaitingModel/AwaitingTools: for each pending effect, execute_one
///    and feed the resulting RunInput back to reduce.
/// 3. After each transition: commit savepoint entries, dispatch events.
/// 4. Check for abort: if mailbox.abort_requested, inject CancelRequested.
/// 5. If Suspended: stop the pump and wait for resume.
/// 6. If Terminal: dispatch terminal event, release lease, set quiescent.
///
/// This is the ONLY loop in the product that drives RunState. It reuses
/// `execute_one` (stateless single-effect executor) and never inspects
/// `tool_calls.is_empty()` to decide termination.
async fn Puppet::drive_run(
  self : Puppet,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  initial_messages : Array[Message],
  snap : TurnSnapshot,
) -> PromptResult raise PuppetError {
  // Build the initial RunState.
  let initial_result : Result[RunState, KernelError] = attempt(() => {
    RunState::initial(run_id~, session_id~, budget=snap.budget())
  })
  let initial_state = match initial_result {
    Err(e) =>
      return self.reject_run(
        error=ReducerInvariantViolation(
          category=IllegalPhase(phase="initial", detail=e.to_string()),
        ),
      )
    Ok(s) => s
  }
  // Build the execution context from the host runtime + catalog snapshot.
  // Puppetry forwards canonical values without product-specific conversion.
  // The Run identity is carried so CallModel effects can be scoped.
  let exec_ctx = ExecutionContext(
    self.config.host,
    catalog=self.config.catalog,
    run_id~,
    session_id~,
  )
  // Build the event dispatcher.
  let dispatcher = EventDispatcher(run_id, turn_id, session_id)
  for sub in self.config.subscribers {
    dispatcher.register(sub)
  }
  // Attribution scope for post-event hook dispatch: inside a run the
  // identity is always known, so hooks always see `Some`.
  let hook_scope : @types.EventScope = { session_id, run_id, turn_id, }
  // Seed the reducer with Start.
  // Run before_model hooks on the initial messages — they can modify or abort.
  let mut seeded_messages = initial_messages.copy()
  for hook in self.config.hooks {
    seeded_messages = hook.before_model(seeded_messages) catch {
      Aborted(reason~) =>
        return self.reject_run(
          error=HookRejected(reason="pre_model_hook: " + reason),
        )
    }
  }
  let start_input : RunInput = Start(payload={
    initial_messages: seeded_messages,
    catalog_version: snap.catalog_version(),
  })
  let mut state = initial_state
  let out0_result : Result[ReduceOutput, KernelError] = attempt(() => {
    reduce(state, self.config.catalog, start_input)
  })
  let out0 = match out0_result {
    Err(e) =>
      return self.reject_run(
        error=ReducerInvariantViolation(
          category=IllegalPhase(phase="Start", detail=e.to_string()),
        ),
      )
    Ok(o) => o
  }
  let initial_boundary : Result[(RunState, Array[KernelEvent]), PuppetError] = attempt(() => {
      declare_model_effect_if_ready(
        out0.next_state(),
        out0.events(),
        self.config.catalog,
        snap.call_options(),
      )
    },
  )
  let (initial_state, initial_events) = match initial_boundary {
    Err(error) => return self.reject_run(error~)
    Ok(value) => value
  }
  // The initial boundary durably accepts input, starts the run, and declares
  // the first model intent in one append before the effect can execute.
  let commit_result : Result[Unit, PuppetError] = Ok(
    self.commit_boundary(
      initial_state,
      InputAccepted,
      initial_events,
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
    Err(e) => return self.reject_run(error=e)
    Ok(_) => ()
  }
  state = initial_state
  // Drive the loop.
  let mut iter = 0
  let max_iter = self.config.max_iterations
  while state.phase() != Terminal && state.phase() != Suspended {
    iter = iter + 1
    match max_iter {
      Some(m) if iter > m =>
        return self.reject_run(error=PumpLoopExceeded(iterations=iter))
      _ => ()
    }
    // Check abort.
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
    // ── M3.5 SAFE POINT A2: fork.
    // Consume one fork command. Fork is copy-on-write: the original
    // transcript is never mutated. We snapshot the transcript's first
    // `fork_index` messages, write them as a new session (carrying
    // `parent_thread_id` lineage) if a session_store is configured, and
    // return PromptResult::ForkCompleted. The current turn stops; the
    // product layer may then drive the new session as a separate turn.
    match self.mailbox.consume_one_fork() {
      Some(fork_cmd) =>
        return self.pump_fork(state, fork_cmd, session_id, run_id, turn_id)
      None => ()
    }
    // ── M3.5 SAFE POINT A3: compact (manual).
    // Consume one compact command from the queue. Manual compacts come
    // from `/compact` (the BuiltinCommandPort enqueued them with
    // trigger=Manual). Auto compacts (trigger=Auto from context-window
    // pressure) are checked separately inside the ReadyForModel branch.
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
  // Handle terminal / suspended outcomes.
  match state.phase() {
    Terminal => {
      let outcome = match state.outcome() {
        Some(o) => o
        None =>
          return self.reject_run(
            error=ReducerInvariantViolation(
              category=IllegalPhase(
                phase="Terminal",
                detail="outcome is None at Terminal",
              ),
            ),
          )
      }
      self.mailbox.set_quiescent(Terminal(outcome~))
      self.last_completed_transcript = Some(state.transcript())
      self.last_outcome = Some(outcome)
      // Release lease + clear mailbox.
      self.phase_gate = self.phase_gate.transition(Terminalizing)
      self.phase_gate = self.phase_gate.transition(Idle)
      self.mailbox.clear_run()
      Accepted(run_id~, turn_id~)
    }
    Suspended => {
      let req = match state.suspension_requirement() {
        Some(r) => r
        None =>
          return self.reject_run(
            error=ReducerInvariantViolation(
              category=IllegalPhase(
                phase="Suspended",
                detail="requirement is None",
              ),
            ),
          )
      }
      // Generate a suspension_id (deterministic; M5 will use a durable id).
      let suspension_id = "susp_\{run_id.to_string()}_\{state.current_model_step_id().to_int()}"
      self.phase_gate = self.phase_gate.enter_suspended(suspension_id)
      self.mailbox.set_quiescent(
        Suspended(run_id~, suspension_id~, requirement_kind=req.kind),
      )
      // Lease is NOT released: resume will continue under the same lease.
      Accepted(run_id~, turn_id~)
    }
    _ =>
      // Pump exited without reaching terminal or suspended.
      self.reject_run(error=PumpLoopExceeded(iterations=iter))
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
        self.reject_run(
          error=ReducerInvariantViolation(
            category=IllegalPhase(phase="cancel", detail=e.to_string()),
          ),
        ),
      )
    Ok(out) => {
      state = out.next_state()
      let propagated : Result[Unit, PuppetError] = Ok(
        propagate_terminal_cancellations(out.effects(), exec_ctx),
      ) catch {
        error => Err(error)
      }
      match propagated {
        Err(error) => return StopWith(self.reject_run(error~))
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
        Err(e) => return StopWith(self.reject_run(error=e))
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
          return self.reject_run(
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
  self.phase_gate = self.phase_gate.transition(Terminalizing)
  self.phase_gate = self.phase_gate.transition(Idle)
  self.mailbox.clear_run()
  ForkCompleted(
    run_id~,
    turn_id~,
    parent_session_id~,
    new_session_id~,
    forked_messages~,
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
  iter : Int,
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
        Err(e) => StopWith(self.reject_run(error=e))
        Ok(_) => ContinueWith(new_state)
      }
    }
    Failed(error) => StopWith(self.reject_run(error~))
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
  iter : Int,
) -> PumpStep noraise {
  let mut state = state
  // Run before_model hooks — they can rewrite the transcript messages
  // or abort the turn before the model is called. Each hook sees the
  // previous hook's output (chained rewrite). The rewritten messages
  // replace the reducer state's transcript so the next CallModel
  // effect uses them.
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
      self.reject_run(
        error=HookRejected(reason="pre_model_hook: " + abort_reason),
      ),
    )
  }
  // Fold the hook-rewritten transcript through the reducer — the sole
  // transcript writer — so the rewrite is journaled as a
  // TranscriptRewritten event in the same boundary as the next model
  // intent. Comparison is by content, not length: a same-length
  // rewrite (e.g. system-prompt replacement) is a real rewrite and
  // must not be silently dropped. A cheap physical-equality check
  // first skips the O(N) content comparison when no hook allocated a
  // new array.
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
          self.reject_run(
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
  // M3.5: auto-compact threshold check runs INSIDE fold_effect_input
  // (the path the pump takes through AwaitingModel / AwaitingTools),
  // not here. The ReadyForModel branch only fires on the very first
  // model step (the Start input lands in ReadyForModel and
  // declare_model_effect_if_ready moves it to AwaitingModel before
  // the loop iterates), so a check here would never see post-tool
  // usage observations. Auto compact therefore lives in
  // fold_effect_input where the reducer's budget update is
  // observable before the next model effect is declared.
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
    Err(error) => return StopWith(self.reject_run(error~))
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
        Err(e) => return StopWith(self.reject_run(error=e))
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
  iter : Int,
  hook_scope : @types.EventScope,
) -> PumpStep noraise {
  let pending = state.pending_effects()
  if pending.length() != 1 {
    return StopWith(
      self.reject_run(
        error=ReducerInvariantViolation(
          category=IllegalPhase(
            phase="AwaitingModel",
            detail="expected exactly one pending model effect",
          ),
        ),
      ),
    )
  }
  let executed : Result[RunInput, PuppetError] = Ok(
    execute_model_effect(pending[0], exec_ctx, self.config.stream_chunks),
  ) catch {
    error => Err(error)
  }
  let input = match executed {
    Err(error) => return StopWith(self.reject_run(error~))
    Ok(value) => value
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
    Err(error) => return StopWith(self.reject_run(error~))
    Ok(Return(r)) => StopWith(r)
    Ok(Continue(next_state)) => {
      self.fire_post_event_hooks(input, hook_scope)
      ContinueWith(next_state)
    }
  }
}

///|
/// AwaitingTools step: schedule the pending tool effects into parallel
/// waves, run the pre_tool hook chain over each wave, execute the wave,
/// and fold every completion. Later waves are not launched once the run
/// reached terminal/suspended or an abort was requested.
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
  let mut state = state
  let wave_result : Result[Array[Array[Effect]], PuppetError] = Ok(
    scheduled_tool_effect_waves(
      state.pending_effects(),
      self.config.catalog,
      state.catalog_version(),
    ),
  ) catch {
    error => Err(error)
  }
  let waves = match wave_result {
    Err(error) => return StopWith(self.reject_run(error~))
    Ok(value) => value
  }
  for wave_index, wave in waves {
    // Run pre-tool hooks on each ExecuteTool effect in the wave.
    // Every hook is evaluated (no short-circuit on Reject); the
    // merge contract lives on ToolDecision in port/hook.mbt.
    let rewritten_wave : Array[Effect] = []
    let hook_rejected_inputs : Array[RunInput] = []
    for effect in wave {
      match effect {
        ExecuteTool(effect_id~, payload~) => {
          let mut current_call : ToolCall = {
            call_id: payload.call_id,
            name: payload.tool_name,
            arguments: payload.arguments,
          }
          let mut deferred_reason : String? = None
          let mut consent : String? = None
          let reject_reasons : Array[String] = []
          for hook in self.config.hooks {
            let attempted = Ok(hook.before_tool(current_call)) catch {
              err => Err(err)
            }
            let decision = match attempted {
              Err(err) => {
                // Keep the `execution_error` classification: a
                // cancellation raised inside the hook (e.g. the host
                // aborts an approval prompt) is NOT a hook defect.
                if @async.is_cancellation_error(err) {
                  return StopWith(
                    self.reject_run(
                      error=EffectExecutionCancelled(phase="AwaitingTools"),
                    ),
                  )
                }
                return StopWith(
                  self.reject_run(
                    error=HookRejected(
                      reason="pre_tool_hook raised: " + err.to_string(),
                    ),
                  ),
                )
              }
              Ok(decision) => decision
            }
            match decision {
              Approve(call~) => {
                current_call = call
                continue
              }
              ApproveAfterConsent(call~, consent_scope~) => {
                current_call = call
                if consent is None {
                  consent = Some(consent_scope)
                }
                continue
              }
              // Terminal until M5: stop polling further hooks.
              Defer(reason~) => {
                deferred_reason = Some(reason)
                break
              }
              // Keep polling: a later hook's consent outranks this.
              Reject(reason~) => {
                reject_reasons.push(reason)
                continue
              }
            }
          }
          match deferred_reason {
            // Frozen wording: extensions (e.g. posoco-ext-permission)
            // document this exact terminal-reject behavior; M5 will
            // replace it with real suspension.
            Some(reason) =>
              return StopWith(
                self.reject_run(
                  error=HookRejected(
                    reason="pre_tool_hook defer not yet supported: " + reason,
                  ),
                ),
              )
            None => ()
          }
          if consent is None && !reject_reasons.is_empty() {
            // Resolve the pending effect without dispatching, so the
            // journal stays causal and the model sees the joined
            // reasons on the next model step.
            hook_rejected_inputs.push(
              ToolCompleted(payload={
                effect_id,
                call_id: payload.call_id,
                tool_name: payload.tool_name,
                arguments: payload.arguments,
                outcome: NotExecuted(
                  reason=RejectedByHook(reason=reject_reasons.join("; ")),
                  original_call_id=payload.call_id,
                ),
              }),
            )
            continue
          }
          // Reconstruct the effect with the rewritten name/arguments.
          // call_id, owner, model_step_id, catalog_version are preserved.
          rewritten_wave.push(
            ExecuteTool(effect_id~, payload={
              call_id: payload.call_id,
              tool_name: current_call.name,
              arguments: current_call.arguments,
              owner: payload.owner,
              model_step_id: payload.model_step_id,
              catalog_version: payload.catalog_version,
            }),
          )
        }
        _ => rewritten_wave.push(effect)
      }
    }
    let wave = rewritten_wave
    // `@async.all` starts every effect in the reducer-approved wave,
    // waits at its barrier, and returns inputs in source order. The
    // reducer remains the sole owner of transcript/result ordering.
    let executed : Result[Array[RunInput], PuppetError] = Ok(
      execute_tool_wave(wave, exec_ctx),
    ) catch {
      error => Err(error)
    }
    let inputs = match executed {
      Err(error) => return StopWith(self.reject_run(error~))
      Ok(value) => value
    }
    // Reducer orders tool results by source call order; fold order
    // is irrelevant.
    for input in hook_rejected_inputs {
      inputs.push(input)
    }
    for input in inputs {
      let folded : Result[FoldOutcome, PuppetError] = Ok(
        self.fold_effect_input(
          state,
          input,
          dispatcher,
          run_id,
          turn_id,
          session_id,
          "sp_tool_wave_\{wave_index}",
          snap,
        ),
      ) catch {
        error => Err(error)
      }
      match folded {
        Err(error) => return StopWith(self.reject_run(error~))
        Ok(Return(r)) => return StopWith(r)
        Ok(Continue(next_state)) => {
          self.fire_post_event_hooks(input, hook_scope)
          state = next_state
        }
      }
      if state.phase() == Terminal || state.phase() == Suspended {
        break
      }
    }
    // Abort is observed at a side-effect boundary. Do not launch a
    // later wave after it was requested; the next pump iteration feeds
    // CancelRequested into the reducer.
    if state.phase() == Terminal ||
      state.phase() == Suspended ||
      self.mailbox.abort_requested() {
      break
    }
  }
  ContinueWith(state)
}
