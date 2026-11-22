///|
async fn AgentRuntime::run_turn_via_puppet(
  self : AgentRuntime,
  input : @kernel.Message,
  session_id : String,
  identity : TurnIdentity,
  resume_persisted_user : Bool,
  operation_id : String,
) -> @types.TurnResult raise @error.AgentError {
  let session = self.load_session_for_operation(session_id)
  let applied_task_ids = @task.parse_task_applied_ids(session.metadata)
  match @types.ContextState::from_metadata(session.metadata) {
    Some(state) =>
      match self.puppet.session_context_state(session_id) {
        Some(_) => ()
        None => self.puppet.adopt_context_state(session_id, state)
      }
    None => ()
  }
  self.project_context_state(Some(identity.scope()), session_id)

  let raw = @message_snapshot.snapshot_messages(session.messages)
  let messages = fixate_pending_tool_calls(raw)
  if !self.sessions.is_empty() && !@core_facts.messages_equal(raw, messages) {
    // Fixation inserts wire-only messages. The persisted prefix no longer
    // matches the core snapshot, so the next write must be a full alignment.
    self.progress.mark_dirty(session_id)
  }
  let mut has_peeked_task_outcomes = false
  if !resume_persisted_user {
    let pending = self.task_runtime.peek_outcomes(session_id)
    has_peeked_task_outcomes = !pending.is_empty()
    for outcome in pending {
      if !@task.task_outcome_is_applied(applied_task_ids, outcome) {
        messages.push(@task.task_outcome_message(outcome))
      }
    }
  }
  let (input, current_turn_start) = match messages.last() {
    Some(last) if resume_persisted_user && last is UserMessage(..) =>
      (@message_snapshot.snapshot_message(last), messages.length() - 1)
    _ => {
      self.inject_memory_inbound(session, session_id, input, messages)
      let current_turn_start = messages.length()
      messages.push(@message_snapshot.snapshot_message(input))
      (input, current_turn_start)
    }
  }
  // Session display state is admitted from the caller's real input before
  // memory/hooks can inject additional model-facing UserMessages.
  let mut current_metadata = session_metadata_for_admission(session, input)
  if has_peeked_task_outcomes {
    // Applied ids and the injected task messages are one core fact: record
    // them together before any boundary, not only after a successful save.
    current_metadata = self.task_runtime.metadata_with_applied_outcomes(
      session_id, current_metadata,
    )
  }
  // The core current is the loaded fact, so admission is a provenance check,
  // not a stale-store comparison.
  match
    self.core_facts.admit(
      session_id,
      messages,
      current_metadata,
      session.messages,
      identity.run_id.to_string(),
    ) {
    Ok(_) => ()
    Err(detail) =>
      raise Runtime(
        InvocationFailed(
          "core admission failed: " + @diagnostic.safe_error_label(detail),
        ),
      )
  }
  let admission_metadata : Map[String, Json]? = if session_metadata_equal(
      current_metadata,
      session.metadata,
    ) {
    None
  } else {
    Some(current_metadata)
  }
  let cursor = self.progress.cursor_or_zero(session_id)
  let admission_tail = if cursor < messages.length() {
    @message_snapshot.snapshot_messages(messages[cursor:].to_owned())
  } else {
    []
  }
  if !self.sessions.is_empty() {
    if self.progress.is_dirty(session_id) {
      // Initialization sampled only one store. The first projection must align
      // every store with the complete core window and its matching metadata.
      @session_output.save_all(
        self.sessions,
        session_id,
        messages,
        current_metadata,
        "input_checkpoint",
      )
      self.progress.set_cursor(session_id, messages.length())
      self.progress.mark_clean(session_id)
    } else if !admission_tail.is_empty() || admission_metadata is Some(_) {
      self.checkpoint_sessions_all(
        session_id, cursor, admission_tail, admission_metadata, "input_checkpoint",
      )
    }
  }

  let budget : @kernel_exec.Budget = {
    max_model_steps: None,
    max_tool_rounds: self.config.max_tool_rounds,
    max_tool_calls: self.config.max_tool_calls,
    max_total_tokens: None,
  }
  let live = self.model.provider_config()
  let policy : @puppetry.RunPolicy = {
    model_id: "agent",
    call_options: self.config.to_call_options_json(),
    budget,
    context_window: match self.config.model_context_window {
      Some(window) => Some(window)
      None => live.context_window
    },
    compact_threshold: match self.config.compact_threshold {
      Some(threshold) => threshold
      None =>
        match live.compact_threshold {
          Some(threshold) => threshold
          None => 0.88
        }
    },
  }
  let request : @puppetry.PromptRequest = {
    run_id: identity.run_id,
    turn_id: identity.turn_id,
    session_id: identity.session_id,
    initial_messages: messages,
    operation_id,
    policy,
  }

  let dispatcher = @chunk_dispatch.ChunkDispatcher(
    self.events,
    identity.scope(),
  )
  let dispatcher_generation = self.install_chunk_dispatcher(dispatcher)
  let turn_error : Ref[@error.AgentError?] = Ref(None)
  // `with_task_group` is `Unit`-valued: the turn result crosses in a cell.
  let turn_outcome : Ref[@types.TurnResult?] = Ref(None)
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() { dispatcher.drain_loop() })
    errdefer self.release_chunk_dispatcher(dispatcher, dispatcher_generation)
    let outcome : Result[@types.TurnResult, @error.AgentError]? = @async.handle_cancellation(async fn() {
        let typed : Result[@types.TurnResult, @error.AgentError] = Ok(
          self.run_puppet_turn_body(
            request, identity, session_id, input, current_turn_start, current_metadata,
          ),
        ) catch {
          e => Err(e)
        }
        typed
      },
    )
    let turn_result = match outcome {
      Some(Ok(r)) => r
      Some(Err(e)) => {
        turn_error.val = Some(e)
        raise e
      }
      None => {
        let cancelled : @error.AgentError = Cancelled("turn cancelled")
        turn_error.val = Some(cancelled)
        raise cancelled
      }
    }
    self.release_chunk_dispatcher(dispatcher, dispatcher_generation)
    turn_outcome.val = Some(turn_result)
  }) catch {
    _ => {
      self.clear_chunk_dispatcher(dispatcher_generation)
      let original : @error.AgentError = match turn_error.val {
        Some(ae) => ae
        // Cancellation is translated inside the group closure, so any error
        // reaching here is an ordinary defect with no typed classification.
        None => Runtime(InvocationFailed("turn body: unclassified error"))
      }
      raise original
    }
  }
  self.clear_chunk_dispatcher(dispatcher_generation)
  match turn_outcome.val {
    Some(result) => result
    None =>
      raise Runtime(InvocationFailed("turn body: completed without a result"))
  }
}

///|
fn AgentRuntime::install_chunk_dispatcher(
  self : AgentRuntime,
  dispatcher : @chunk_dispatch.ChunkDispatcher,
) -> Int32 {
  self.chunk_dispatcher_generation = self.chunk_dispatcher_generation + 1
  self.chunk_dispatcher.val = Some(dispatcher)
  self.chunk_dispatcher_generation
}

///|
fn AgentRuntime::clear_chunk_dispatcher(
  self : AgentRuntime,
  generation : Int32,
) -> Unit {
  if self.chunk_dispatcher_generation == generation {
    self.chunk_dispatcher.val = None
  }
}

///|
fn AgentRuntime::release_chunk_dispatcher(
  self : AgentRuntime,
  dispatcher : @chunk_dispatch.ChunkDispatcher,
  generation : Int32,
) -> Unit {
  dispatcher.flush()
  dispatcher.close()
  self.clear_chunk_dispatcher(generation)
}

///|
async fn AgentRuntime::run_puppet_turn_body(
  self : AgentRuntime,
  request : @puppetry.PromptRequest,
  identity : TurnIdentity,
  session_id : String,
  input : @kernel.Message,
  current_turn_start : Int32,
  current_metadata : Map[String, Json],
) -> @types.TurnResult raise @error.AgentError {
  let applied_task_ids = @task.parse_task_applied_ids(current_metadata)
  self.puppet.set_step_context_source(
    Some(
      (
        fn() { self.wakeup.has_step_wakeup(session_id) },
        fn() {
          self.snapshot_step_wakeup(
            session_id, current_metadata, applied_task_ids,
          )
        },
      ),
    ),
  )
  defer self.puppet.set_step_context_source(None)
  let prompt_result = self.puppet.prompt(request) catch {
    e =>
      // A cancellation inside the prompt travels as a runtime signal and is
      // translated at the turn boundary; only ordinary defects land here.
      raise Runtime(
        InvocationFailed(
          "puppet prompt: " + @diagnostic.safe_error_label(e.to_string()),
        ),
      )
  }

  match prompt_result {
    Rejected(error=HookRejected(reason~)) => raise PipelineAborted(reason)
    Rejected(error=PumpLoopExceeded(..)) =>
      raise Runtime(
        InvocationFailed("pump loop exceeded (internal livelock guard)"),
      )
    Rejected(error=ReducerInvariantViolation(..)) =>
      raise Runtime(InvocationFailed("puppet invariant violation"))
    Rejected(error=EffectExecutionFailed(phase="auto_compact", cause~)) => {
      self.save_failed_turn_transcript(
        session_id,
        request.initial_messages,
        current_turn_start,
        current_metadata,
        identity.run_id.to_string(),
      )
      raise AutoCompactFailed(cause)
    }
    Rejected(error=EffectExecutionCancelled(phase~)) =>
      raise Cancelled("effect execution cancelled in \{phase}")
    Rejected(error=EffectExecutionFailed(cause~, phase~)) => {
      // Compact causes are the adapter's safe bounded label;
      let cause_label = if is_compact_effect_phase(phase) {
        @diagnostic.bounded_error_label(cause, 512)
      } else {
        @diagnostic.safe_error_label(cause)
      }
      raise Runtime(InvocationFailed("puppet effect execution: " + cause_label))
    }
    Rejected(error~) =>
      raise Runtime(
        InvocationFailed("puppet rejected the prompt: " + error.to_string()),
      )
    ForkCompleted(parent_session_id~, new_session_id~, forked_messages~, ..) =>
      return self.complete_fork_turn(
        identity, parent_session_id, new_session_id, forked_messages, input,
      )
    CompactCompleted(mode~, new_session_id~, compacted_messages~, ..) =>
      return self.complete_compact_turn(
        identity, session_id, mode, new_session_id, compacted_messages, input, current_metadata,
      )
    Accepted(..) => {
      // Check terminal outcome for model failures.
      let failure : @error.AgentError? = self.terminal_failure_to_agent_error()
      match failure {
        Some(err) => {
          self.save_failed_turn_transcript(
            session_id,
            request.initial_messages,
            current_turn_start,
            current_metadata,
            identity.run_id.to_string(),
          )
          raise err
        }
        None => ()
      }
    }
    LeaseBusy(..) => raise Runtime(InvocationFailed("puppet lease busy"))
  }

  let final_transcript = match self.puppet.last_completed_transcript() {
    Some(t) => t
    None =>
      raise Runtime(
        InvocationFailed("puppet did not produce a terminal transcript"),
      )
  }
  guard self.puppet.last_terminal_outcome()
    is Some(Completed(final_message~, tool_results~)) else {
    raise Runtime(
      InvocationFailed("puppet did not produce a completed run outcome"),
    )
  }

  // Save session (write-all, with carried metadata).
  self.save_turn_transcript(
    session_id,
    final_transcript,
    current_metadata,
    request.initial_messages,
    current_turn_start,
    identity.run_id.to_string(),
  )
  self.task_runtime.commit_outcomes(session_id)
  self.project_context_state(Some(identity.scope()), session_id)

  let result : @types.TurnResult = {
    message: @message_snapshot.snapshot_message(final_message),
    tool_results: Array::from_iter(
      tool_results.iter().map(@message_snapshot.snapshot_tool_outcome),
    ),
    final_session_id: session_id,
  }
  result
}

///|
fn AgentRuntime::terminal_failure_to_agent_error(
  self : AgentRuntime,
) -> @error.AgentError? {
  match self.puppet.last_terminal_outcome() {
    Some(Failed(reason=ModelTransport(detail~))) =>
      Some(Model("model transport: " + detail))
    Some(Failed(reason=ModelParseFailure(detail~))) =>
      Some(Model("model parse failure: " + detail))
    Some(Failed(reason=ModelRuntime(detail~))) =>
      Some(Model("model runtime failure: " + detail))
    Some(
      Failed(reason=ModelQuotaExhausted(detail~, reset_at_ms~, provider_code~)),
    ) =>
      Some(
        Model(
          "model quota exhausted: " +
          quota_error_detail(detail, reset_at_ms, provider_code),
        ),
      )
    Some(Failed(reason=HostRejected(detail~))) =>
      Some(Runtime(InvocationFailed("host rejected: " + detail)))
    Some(Failed(reason=InvariantViolation(category~))) =>
      Some(
        Runtime(
          InvocationFailed(
            "kernel invariant violation: " + category.to_string(),
          ),
        ),
      )
    Some(Failed(reason=DeadlineReached)) =>
      Some(Runtime(InvocationFailed("deadline reached")))
    Some(Failed(reason=BudgetExhausted(dimension=ToolRounds))) =>
      match self.config.max_tool_rounds {
        Some(limit) => Some(ToolLoopExceeded(consumed=limit + 1, limit~))
        None =>
          Some(
            Runtime(
              InvocationFailed(
                "tool-round budget exhausted without a configured limit",
              ),
            ),
          )
      }
    Some(Failed(reason=BudgetExhausted(..))) =>
      Some(Runtime(InvocationFailed("budget exhausted")))
    Some(Cancelled(reason~)) =>
      Some(Cancelled("run cancelled: " + reason.to_string()))
    _ => None
  }
}
