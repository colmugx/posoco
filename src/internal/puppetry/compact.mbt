// ──────────────────────────────────────────────────────────────────────────
// M3.5 — Fork + Compact safe-point handlers
// ──────────────────────────────────────────────────────────────────────────

///|
/// Outcome of `handle_compact`: either the pump should return the given
/// `PromptResult` (compact::NewThread stops the turn with CompactCompleted),
/// or it should adopt the new `RunState` and continue the loop (Replace /
/// Append), or it should reject the run (compact failed). `UpdatedState`
/// carries the reducer-emitted rewrite events; the CALLER commits them into
/// the next boundary so journal order stays causal (the rewrite follows the
/// facts that produced the pre-compact state).
priv enum CompactFlow {
  ReturnedResult(PromptResult)
  UpdatedState(RunState, Array[KernelEvent])
  Failed(PuppetError)
}

///|
/// Apply one compact command. Calls `HostRuntime::compact` (which forwards
/// to `ModelPort::compact`) and applies the result according to its
/// `CompactMode`:
/// - **NewThread**: write a new session with lineage, release lease, and
///   return `PromptResult::CompactCompleted(new_session_id=Some(...))`.
///   The current turn stops.
/// - **Replace**: rebuild the transcript from `compacted_messages` and
///   return `UpdatedState`. The loop continues on the same session id.
/// - **Append**: append `compacted_messages` to the current transcript and
///   return `UpdatedState`. The loop continues on the same session id.
///
/// Replace/Append fold the transcript change through the reducer — the sole
/// transcript writer — as a `TranscriptRewrite` input, so the compact is
/// journaled as a `TranscriptRewritten` event instead of an untracked
/// mutation. `commit_boundary` is NOT called here; the caller commits the
/// returned events at the next boundary.
async fn Puppet::handle_compact(
  self : Puppet,
  state : RunState,
  compact_cmd : CompactCommand,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  _dispatcher : EventDispatcher,
  snap : TurnSnapshot,
) -> CompactFlow raise PuppetError {
  let messages = state.transcript().messages_snapshot()
  // Compact is host-driven (a mailbox command), not a reducer-allocated
  // effect — hence `effect_id: None`. Run/session identity still applies.
  // The resolved window/threshold and the latest verified occupancy ride
  // along so modelports size their compact strategy from real numbers
  // instead of re-estimating from characters.
  let pressure : @kernel.ContextPressure = {
    window_tokens: snap.context_window(),
    occupancy_tokens: state.budget_consumed().last_context_tokens,
    compact_threshold: snap.compact_threshold(),
  }
  let scope : InvocationScope = {
    session_id,
    run_id,
    effect_id: None,
    pressure: Some(pressure),
  }
  let attempted : Result[Result[CompactResult, @kernel.ModelFailure], Error] = Ok(
    self.config.host.compact(
      scope,
      messages[:],
      snap.call_options(),
      compact_cmd.trigger(),
    ),
  ) catch {
    error => Err(error)
  }
  let compact_result = match attempted {
    Err(error) =>
      return Failed(
        EffectExecutionFailed(
          phase="compact",
          cause="host compact raised: " + error.to_string(),
        ),
      )
    Ok(Err(failure)) =>
      return Failed(
        EffectExecutionFailed(
          phase="compact",
          cause="modelport compact failed: " + failure.to_string(),
        ),
      )
    Ok(Ok(result)) => result
  }
  match compact_result.mode {
    NewThread => {
      let new_session_id = session_id.to_string() +
        "_compact_" +
        compact_cmd.command_id().to_string()
      // Persist the new session if configured.
      match self.config.session_store {
        Some(store) => {
          let new_session : @types.Session = {
            messages: compact_result.compacted_messages.copy(),
            metadata: Map::from_array([]),
          }
          let with_lineage = new_session.with_parent_thread_id(
            session_id.to_string(),
          )
          store.save(new_session_id, with_lineage) catch {
            error =>
              return Failed(
                EffectExecutionFailed(
                  phase="compact",
                  cause="session save failed: " + error.to_string(),
                ),
              )
          }
        }
        None => ()
      }
      let result : PromptResult = CompactCompleted(
        run_id~,
        turn_id~,
        mode=NewThread,
        trigger=compact_cmd.trigger(),
        new_session_id=Some(new_session_id),
        compacted_messages=compact_result.compacted_messages,
      )
      return ReturnedResult(self.finalize_run(ReleasedNoCommit(result~)))
    }
    Replace =>
      self.rewrite_transcript_for_compact(
        state,
        compact_result.compacted_messages,
        "compact_replace",
        "compact-replace",
      )
    Append => {
      let current = state.transcript().messages_snapshot()
      let combined : Array[@kernel.Message] = current +
        compact_result.compacted_messages
      self.rewrite_transcript_for_compact(
        state, combined, "compact_append", "compact-append",
      )
    }
  }
}

///|
/// Fold a compact transcript change through the reducer — the sole
/// transcript writer — as a `TranscriptRewrite` input, so the compact is
/// journaled as a `TranscriptRewritten` event instead of an untracked
/// mutation. `commit_boundary` is NOT called here; the caller commits the
/// returned events at the next boundary.
fn Puppet::rewrite_transcript_for_compact(
  self : Puppet,
  state : RunState,
  rewritten_messages : Array[@kernel.Message],
  reason : String,
  phase : String,
) -> CompactFlow {
  let rewrite_input : RunInput = TranscriptRewrite(payload={
    rewritten_messages,
    reason,
  })
  let reduced : Result[ReduceOutput, KernelError] = Ok(
    reduce(state, self.config.catalog, rewrite_input),
  ) catch {
    e => Err(e)
  }
  match reduced {
    Err(e) =>
      Failed(
        ReducerInvariantViolation(
          category=IllegalPhase(phase~, detail=e.to_string()),
        ),
      )
    Ok(out) => UpdatedState(out.next_state(), out.events())
  }
}

///|
/// Check whether auto-compact should fire on this iteration. Returns
/// `Some(CompactCommand{trigger=Auto})` when the LATEST verified context
/// occupancy crossed `context_window * compact_threshold`. Returns `None`
/// when:
/// - `context_window` is `None` (auto-compact disabled), OR
/// - occupancy is unknown (no computable usage reading yet, or the
///   transcript was just rewritten by a compact), OR
/// - occupancy is below the threshold, OR
/// - this context version already spent its auto-compact attempt.
///
/// Occupancy is the latest call's own usage, NOT the run-wide cumulative
/// total: several large-but-far-from-full calls must not sum into a false
/// trigger, and `max_total_tokens` keeps policing the cumulative account.
///
/// The command_id is deterministic per (run_id, model_step_id) so two
/// checks in the same step cannot enqueue duplicates.
fn Puppet::check_auto_compact(
  self : Puppet,
  state : RunState,
  snap : TurnSnapshot,
) -> CompactCommand? {
  let context_window = match snap.context_window() {
    Some(w) => w
    None => return None
  }
  if context_window <= 0 {
    return None
  }
  let version = self.config.journal.revision()
  if self.auto_compact_attempt_version is Some(attempted) &&
    attempted == version {
    return None
  }
  // Without a verified occupancy reading we cannot honestly claim the
  // threshold has been crossed. The reducer maintains this account.
  let occupancy = match state.budget_consumed().last_context_tokens {
    Some(n) => n
    None => return None
  }
  // threshold * 100 rounded — compact_threshold is validated at capture.
  let threshold_units = (snap.compact_threshold() * 100.0).to_int()
  // total_units = context_window * threshold; floor at 0.
  let limit = context_window * threshold_units / 100
  if occupancy >= limit {
    self.auto_compact_attempt_version = Some(version)
    let cid = "auto_" +
      state.run_id().to_string() +
      "_" +
      state.current_model_step_id().to_int().to_string()
    Some({
      command_id: CommandId::unchecked(cid),
      target_run_id: state.run_id(),
      target_turn_id: match self.mailbox.active_turn_id() {
        Some(t) => t
        None =>
          // Defensive: if mailbox is unbound we cannot correlate. The
          // pump is inside drive_run so the mailbox MUST be bound; this
          // branch is unreachable in practice.
          return None
      },
      trigger: Auto,
    })
  } else {
    None
  }
}

///|
fn Puppet::check_auto_compact_pre_request(
  self : Puppet,
  session_id : SessionId,
  seeded_messages : Array[Message],
  snap : TurnSnapshot,
) -> CompactCommand? {
  let context_window = match snap.context_window() {
    Some(w) => w
    None => return None
  }
  if context_window <= 0 {
    return None
  }
  let version = self.config.journal.revision()
  if self.auto_compact_attempt_version is Some(attempted) &&
    attempted == version {
    return None
  }
  let state = match self.context_states.get(session_id.to_string()) {
    Some(state) => state
    None => return None
  }
  let measured = match state.last_measured_tokens {
    Some(n) => n
    None => return None
  }
  if state.source is Unknown {
    return None
  }
  if state.window_tokens != Some(context_window) {
    return None
  }
  let mut estimate = 0
  if seeded_messages.length() > state.reading_message_count {
    if state.reading_message_count >= 0 {
      let tail = seeded_messages[state.reading_message_count:]
      estimate = estimate_tokens_of_messages(tail)
    }
  }
  let threshold_units = (snap.compact_threshold() * 100.0).to_int()
  let limit = context_window * threshold_units / 100
  if measured + estimate >= limit {
    self.auto_compact_attempt_version = Some(version)
    let cid = "auto_pre_" + session_id.to_string() + "_" + version.to_string()
    Some({
      command_id: CommandId::unchecked(cid),
      target_run_id: snap.run_id(),
      target_turn_id: match self.mailbox.active_turn_id() {
        Some(t) => t
        None => return None
      },
      trigger: Auto,
    })
  } else {
    None
  }
}

///|
fn estimate_tokens_of_messages(messages : ArrayView[Message]) -> Int {
  let mut chars = 0
  for message in messages {
    match message {
      SystemMessage(content~) =>
        for block in content {
          match block {
            Text(t) => chars = chars + t.length()
            Image(..) => chars = chars + 1024
          }
        }
      UserMessage(content~) =>
        for block in content {
          match block {
            Text(t) => chars = chars + t.length()
            Image(..) => chars = chars + 1024
          }
        }
      AssistantMessage(content~, tool_calls~, ..) => {
        for block in content {
          match block {
            Text(t) => chars = chars + t.length()
            Image(..) => chars = chars + 1024
          }
        }
        for call in tool_calls {
          chars = chars + call.arguments.stringify().length()
        }
      }
      ToolMessage(outcome~, ..) =>
        match outcome {
          Success(content~, ..) => chars = chars + content.length()
          ToolReportedError(content~, ..) => chars = chars + content.length()
          RuntimeFailure(message~, ..) => chars = chars + message.length()
          NotExecuted(..) => ()
        }
    }
  }
  chars / 4
}

///|
fn Puppet::record_context_reading(
  self : Puppet,
  session_id : SessionId,
  state : RunState,
  snap : TurnSnapshot,
) -> Unit {
  let occupancy = match state.budget_consumed().last_context_tokens {
    Some(n) => n
    None => return
  }
  let sid = session_id.to_string()
  let window = snap.context_window()
  let source : @types.ContextReadingSource = match
    self.context_states.get(sid) {
    Some(previous) =>
      if previous.window_tokens != window {
        @types.Estimated
      } else {
        @types.Measured
      }
    None => @types.Measured
  }
  self.context_states[sid] = {
    session_id: sid,
    model_id: snap.model_id(),
    context_version: self.config.journal.revision(),
    last_measured_tokens: Some(occupancy),
    estimated_added_tokens: 0,
    window_tokens: window,
    compact_threshold: snap.compact_threshold(),
    source,
    reading_message_count: state.transcript().messages_snapshot().length(),
  }
}

///|
fn Puppet::mark_context_awaiting_measurement(
  self : Puppet,
  session_id : SessionId,
  message_count : Int,
  snap : TurnSnapshot,
) -> Unit {
  let sid = session_id.to_string()
  let (model_id, window, threshold) = match self.context_states.get(sid) {
    Some(previous) =>
      (previous.model_id, previous.window_tokens, previous.compact_threshold)
    None => (snap.model_id(), snap.context_window(), snap.compact_threshold())
  }
  self.context_states[sid] = {
    session_id: sid,
    model_id,
    context_version: self.config.journal.revision(),
    last_measured_tokens: None,
    estimated_added_tokens: 0,
    window_tokens: window,
    compact_threshold: threshold,
    source: @types.Unknown,
    reading_message_count: message_count,
  }
}

///|
fn validate_standalone_compact(
  original : Array[Message],
  result : @kernel.CompactResult,
) -> PuppetError? {
  if !original.is_empty() &&
    result.mode is Replace &&
    result.compacted_messages.is_empty() {
    Some(
      EffectExecutionFailed(
        phase="compact_session",
        cause="modelport returned an empty replacement window for a non-empty session",
      ),
    )
  } else {
    None
  }
}

///|
pub async fn Puppet::compact_standalone(
  self : Puppet,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  messages : Array[Message],
  policy : RunPolicy,
  operation_id : String,
  trigger : @kernel.CompactTrigger,
) -> PromptResult raise PuppetError {
  let acquire : Result[(PhaseGate, OperationLease), PuppetError] = attempt(() => {
    self.phase_gate.acquire_prompt(operation_id, run_id, turn_id)
  })
  let gate_with_lease = match acquire {
    Err(e) => return Rejected(error=e)
    Ok(pair) => pair.0
  }
  self.phase_gate = gate_with_lease
  self.last_completed_transcript = None
  let snap : TurnSnapshot = match
    attempt(() => {
      TurnSnapshot::capture({
        run_id,
        turn_id,
        session_id,
        catalog: self.config.catalog,
        policy,
        deadline: None,
        hook_provenance: [],
        lifecycle_provenance: [],
        subscriber_provenance: [],
      })
    }) {
    Err(e) => return self.finalize_rejected(error=e)
    Ok(value) => value
  }
  self.mailbox.bind_run(run_id, turn_id)
  self.phase_gate = self.phase_gate.transition(Active)
  let pressure : @kernel.ContextPressure = {
    window_tokens: snap.context_window(),
    occupancy_tokens: match self.context_states.get(session_id.to_string()) {
      Some(state) => state.last_measured_tokens
      None => None
    },
    compact_threshold: snap.compact_threshold(),
  }
  let scope : InvocationScope = {
    session_id,
    run_id,
    effect_id: None,
    pressure: Some(pressure),
  }
  let attempted : Result[Result[CompactResult, @kernel.ModelFailure], Error] = Ok(
    self.config.host.compact(scope, messages[:], snap.call_options(), trigger),
  ) catch {
    error => Err(error)
  }
  let compact_result = match attempted {
    Err(error) =>
      if @async.is_cancellation_error(error) {
        return self.finalize_rejected(
          error=EffectExecutionCancelled(phase="compact_session"),
        )
      } else {
        return self.finalize_rejected(
          error=EffectExecutionFailed(
            phase="compact_session",
            cause="host compact raised: " + error.to_string(),
          ),
        )
      }
    Ok(Err(failure)) =>
      return self.finalize_rejected(
        error=EffectExecutionFailed(
          phase="compact_session",
          cause="modelport compact failed: " + failure.to_string(),
        ),
      )
    Ok(Ok(result)) =>
      match validate_standalone_compact(messages, result) {
        Some(error) => return self.finalize_rejected(error~)
        None => result
      }
  }
  match compact_result.mode {
    NewThread => {
      let new_session_id = session_id.to_string() + "_compact_" + operation_id
      match self.config.session_store {
        Some(store) => {
          let new_session : @types.Session = {
            messages: compact_result.compacted_messages.copy(),
            metadata: Map::from_array([]),
          }
          let with_lineage = new_session.with_parent_thread_id(
            session_id.to_string(),
          )
          store.save(new_session_id, with_lineage) catch {
            error =>
              return self.finalize_rejected(
                error=EffectExecutionFailed(
                  phase="compact_session",
                  cause="session save failed: " + error.to_string(),
                ),
              )
          }
        }
        None => ()
      }
      self.mark_context_awaiting_measurement(
        @kernel.SessionId::unchecked(new_session_id),
        compact_result.compacted_messages.length(),
        snap,
      )
      let result : PromptResult = CompactCompleted(
        run_id~,
        turn_id~,
        mode=NewThread,
        trigger~,
        new_session_id=Some(new_session_id),
        compacted_messages=compact_result.compacted_messages,
      )
      return self.finalize_run(ReleasedNoCommit(result~))
    }
    Replace => ()
    Append => ()
  }
  let final_messages : Array[Message] = match compact_result.mode {
    Append => messages + compact_result.compacted_messages
    _ => compact_result.compacted_messages.copy()
  }
  let initial_state : RunState = match
    attempt(() => RunState::initial(run_id~, session_id~, budget=snap.budget())) {
    Err(e) =>
      return self.finalize_rejected(
        error=ReducerInvariantViolation(
          category=IllegalPhase(phase="compact_session", detail=e.to_string()),
        ),
      )
    Ok(value) => value
  }
  let reduced : Result[ReduceOutput, KernelError] = Ok(
    reduce(
      initial_state,
      self.config.catalog,
      TranscriptRewrite(payload={
        rewritten_messages: final_messages,
        reason: "compact_standalone",
      }),
    ),
  ) catch {
    e => Err(e)
  }
  let out = match reduced {
    Err(e) =>
      return self.finalize_rejected(
        error=ReducerInvariantViolation(
          category=IllegalPhase(phase="compact_session", detail=e.to_string()),
        ),
      )
    Ok(value) => value
  }
  let dispatcher = EventDispatcher(run_id, turn_id, session_id)
  for sub in self.config.subscribers {
    dispatcher.register(sub)
  }
  let committed : Result[Unit, PuppetError] = Ok(
    self.commit_boundary(
      out.next_state(),
      boundary_kind_for_events(out.events()),
      out.events(),
      dispatcher,
      run_id,
      turn_id,
      session_id,
      "sp_compact_standalone",
    ),
  ) catch {
    e => Err(e)
  }
  match committed {
    Err(e) => return self.finalize_rejected(error=e)
    Ok(_) => ()
  }
  self.mark_context_awaiting_measurement(
    session_id,
    final_messages.length(),
    snap,
  )
  self.mailbox.set_quiescent(Idle)
  self.release_run_binding()
  CompactCompleted(
    run_id~,
    turn_id~,
    mode=compact_result.mode,
    trigger~,
    new_session_id=None,
    compacted_messages=compact_result.compacted_messages,
  )
}

///|
pub fn Puppet::context_version(self : Puppet) -> Int {
  self.config.journal.revision()
}
