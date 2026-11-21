///|
priv enum CompactFlow {
  ReturnedResult(PromptResult)
  UpdatedState(RunState, Array[KernelEvent])
  Failed(PuppetError)
}

///|
async fn Puppet::handle_compact(
  self : Puppet,
  state : RunState,
  compact_cmd : CompactCommand,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  dispatcher : EventDispatcher,
  snap : TurnSnapshot,
) -> CompactFlow raise PuppetError {
  let messages = state.transcript().messages_snapshot()
  self.capture_source(
    run_id,
    session_id.to_string(),
    messages,
    messages.length(),
  )
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
      messages,
      snap.tool_definitions().filter(def => def.exposure is Direct),
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
          cause=compact_failure_cause(failure),
        ),
      )
    Ok(Ok(result)) => result
  }
  match compact_result.mode {
    NewThread => {
      let new_session_id = session_id.to_string() +
        "_compact_" +
        compact_cmd.command_id().to_string()
      let steer_events : Array[KernelEvent] = []
      self.drain_undelivered(
        steer_events, "turn stopped by compact before delivery",
      )
      if steer_events.length() > 0 {
        self.commit_boundary(
          state,
          boundary_kind_for_events(steer_events),
          steer_events,
          dispatcher,
          run_id,
          turn_id,
          session_id,
          "sp_compact_stop",
        )
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
  }
}

///|
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
        None => return None
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
fn estimate_tokens_of_messages(messages : ArrayView[Message]) -> Int32 {
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
          SuccessWithAttachments(content~, attachments~, ..) => {
            chars = chars + content.length()
            // Same block estimate as user/system content above.
            for block in attachments {
              match block {
                Text(t) => chars = chars + t.length()
                Image(..) => chars = chars + 1024
              }
            }
          }
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
        Estimated
      } else {
        Measured
      }
    None => Measured
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
fn has_provider_replay_state(messages : ArrayView[Message]) -> Bool {
  for message in messages {
    if message is AssistantMessage(reasoning=Some({ raw: Some(raw), .. }), ..) {
      let nonempty = match raw {
        Null => false
        Array(items) => !items.is_empty()
        Object(fields) => !fields.is_empty()
        String(text) => !text.is_empty()
        _ => true
      }
      if nonempty {
        return true
      }
    }
  }
  false
}

///|
fn Puppet::record_context_estimate(
  self : Puppet,
  session_id : SessionId,
  messages : Array[Message],
  snap : TurnSnapshot,
) -> Unit {
  let sid = session_id.to_string()
  let (model_id, window, threshold) = match self.context_states.get(sid) {
    Some(previous) =>
      (previous.model_id, previous.window_tokens, previous.compact_threshold)
    None => (snap.model_id(), snap.context_window(), snap.compact_threshold())
  }
  let (tokens, source) = if has_provider_replay_state(messages) {
    (None, @types.Unknown)
  } else {
    (Some(estimate_tokens_of_messages(messages)), Estimated)
  }
  self.context_states[sid] = {
    session_id: sid,
    model_id,
    context_version: self.config.journal.revision(),
    last_measured_tokens: tokens,
    estimated_added_tokens: 0,
    window_tokens: window,
    compact_threshold: threshold,
    source,
    reading_message_count: messages.length(),
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
  let (gate_with_lease, _) = self.phase_gate.acquire_prompt(
    operation_id, run_id, turn_id,
  ) catch {
    e => return Rejected(error=e)
  }
  self.phase_gate = gate_with_lease
  self.last_completed_transcript = None
  errdefer {
    self.release_run_binding()
    self.mailbox.set_quiescent(Idle)
  }
  let snap : TurnSnapshot = TurnSnapshot::capture({
    run_id,
    turn_id,
    session_id,
    catalog: self.config.catalog,
    policy,
    deadline: None,
    hook_provenance: [],
    lifecycle_provenance: [],
    subscriber_provenance: [],
  }) catch {
    e => return self.finalize_rejected(error=e)
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
  // Freeze the standalone compact source before the model call. The supplied
  // array is the exact content the model sees.
  self.capture_source(
    run_id,
    session_id.to_string(),
    messages,
    messages.length(),
  )
  let attempted : Result[Result[CompactResult, @kernel.ModelFailure], Error] = Ok(
    self.config.host.compact(
      scope,
      messages,
      snap.tool_definitions().filter(def => def.exposure is Direct),
      snap.call_options(),
      trigger,
    ),
  ) catch {
    error => Err(error)
  }
  let compact_result = match attempted {
    Err(error) =>
      return self.finalize_rejected(
        error=EffectExecutionFailed(
          phase="compact_session",
          cause="host compact raised: " + error.to_string(),
        ),
      )
    Ok(Err(failure)) =>
      return self.finalize_rejected(
        error=EffectExecutionFailed(
          phase="compact_session",
          cause=compact_failure_cause(failure),
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
      self.record_context_estimate(
        @kernel.SessionId::unchecked(new_session_id),
        compact_result.compacted_messages,
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
  }
  let final_messages : Array[Message] = compact_result.compacted_messages.copy()
  let initial_state : RunState = RunState::initial(
    run_id~,
    session_id~,
    budget=snap.budget(),
  ) catch {
    e =>
      return self.finalize_rejected(
        error=ReducerInvariantViolation(
          category=IllegalPhase(phase="compact_session", detail=e.to_string()),
        ),
      )
  }
  // The reducer requires Start before TranscriptRewrite. This private seed is
  // not a published boundary; only the rewrite event is committed below.
  let started : Result[ReduceOutput, KernelError] = Ok(
    reduce(
      initial_state,
      self.config.catalog,
      Start(payload={
        initial_messages: messages.copy(),
        catalog_version: snap.catalog_version(),
      }),
    ),
  ) catch {
    e => Err(e)
  }
  let start_out = match started {
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
      start_out.next_state(),
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
  self.record_context_estimate(session_id, final_messages, snap)
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
pub fn Puppet::context_version(self : Puppet) -> Int32 {
  self.config.journal.revision()
}
