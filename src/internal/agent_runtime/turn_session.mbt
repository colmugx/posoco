///|
fn AgentRuntime::current_run_policy(self : AgentRuntime) -> @puppetry.RunPolicy {
  let live = self.model.provider_config()
  {
    model_id: "agent",
    call_options: self.config.to_call_options_json(),
    budget: {
      max_model_steps: None,
      max_tool_rounds: self.config.max_tool_rounds,
      max_tool_calls: self.config.max_tool_calls,
      max_total_tokens: None,
    },
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
}

///|
fn sanitize_child_metadata(metadata : Map[String, Json]) -> Map[String, Json] {
  let copy = @message_snapshot.snapshot_metadata(metadata)
  copy.remove(@types.CONTEXT_STATE_METADATA_KEY)
  copy.remove("posoco.task.applied_ids")
  copy.remove(@types.PARENT_THREAD_ID_KEY)
  copy.remove(@types.PARENT_FORK_INDEX_KEY)
  copy
}

///|
async fn AgentRuntime::persist_derived_session(
  self : AgentRuntime,
  scope : @types.EventScope,
  parent_session_id : String,
  new_session_id : String,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
  save_label : String,
  fork_at_index~ : Int32? = None,
) -> Unit raise @error.AgentError {
  match
    self.core_facts.record_new_thread(
      scope.run_id.to_string(),
      parent_session_id,
      new_session_id,
      messages,
      metadata,
    ) {
    Ok(_) => ()
    Err(detail) => {
      self.core_facts.mark_missing_provenance(new_session_id)
      raise Runtime(InvocationFailed("core child fact failed: " + detail))
    }
  }
  self.core_facts.stop(parent_session_id, scope.run_id.to_string(), "diversion")
  self.session_output.stage_new_thread(
    scope,
    parent_session_id,
    new_session_id,
    messages,
    metadata,
    save_label,
    fork_at_index~,
  )
  self.session_output.execute_new_thread(new_session_id, async fn(
    pending,
  ) -> Unit raise @error.AgentError {
    self.write_new_thread_output(pending)
  })
}

///|
async fn AgentRuntime::persist_new_thread_session(
  self : AgentRuntime,
  scope : @types.EventScope,
  parent_session_id : String,
  new_session_id : String,
  messages : Array[@kernel.Message],
  save_label : String,
) -> Unit raise @error.AgentError {
  let new_session : @types.Session = {
    messages: @message_snapshot.snapshot_messages(messages),
    metadata: Map::from_array([]),
  }
  let with_lineage = new_session.with_parent_thread_id(parent_session_id)
  self.persist_derived_session(
    scope,
    parent_session_id,
    new_session_id,
    with_lineage.messages,
    with_lineage.metadata,
    save_label,
  )
}

///|
async fn AgentRuntime::persist_fork_session(
  self : AgentRuntime,
  scope : @types.EventScope,
  parent_session_id : String,
  new_session_id : String,
  fork_index : Int32,
  can_cow_fork : Bool,
  messages : Array[@kernel.Message],
  base_metadata : Map[String, Json],
  save_label : String,
) -> Unit raise @error.AgentError {
  let new_session : @types.Session = {
    messages: @message_snapshot.snapshot_messages(messages),
    metadata: sanitize_child_metadata(base_metadata),
  }
  let with_lineage = new_session.with_fork_lineage(
    parent_session_id, fork_index,
  )
  self.persist_derived_session(
    scope,
    parent_session_id,
    new_session_id,
    with_lineage.messages,
    with_lineage.metadata,
    save_label,
    fork_at_index=if can_cow_fork { Some(fork_index) } else { None },
  )
}

///|
async fn AgentRuntime::write_new_thread_output(
  self : AgentRuntime,
  pending : @session_output.NewThreadOutput,
) -> Unit raise @error.AgentError {
  match pending.fork_at_index {
    Some(at_index) =>
      @session_output.fork_all(
        self.sessions,
        pending.child_session_id,
        pending.parent_session_id,
        at_index,
        pending.messages,
        pending.metadata,
        pending.save_label,
      )
    None =>
      @session_output.save_all(
        self.sessions,
        pending.child_session_id,
        pending.messages,
        pending.metadata,
        pending.save_label,
      )
  }
  if !self.sessions.is_empty() {
    self.progress.set_cursor(
      pending.child_session_id,
      pending.messages.length(),
    )
  }
  let redirect : @types.TurnEvent = SessionRedirect(
    from=pending.parent_session_id,
    to=pending.child_session_id,
    messages_before=pending.messages.length(),
    messages_after=pending.messages.length(),
  )
  self.events.emit_core(Some(pending.scope), redirect)
}

///|
async fn AgentRuntime::drain_body_recovery_outputs(
  self : AgentRuntime,
  session_id : String,
) -> Unit raise @error.AgentError {
  self.session_output.recover_body(session_id, async fn(
    pending,
  ) -> Unit raise @error.AgentError {
    @session_output.save_all(
      self.sessions,
      session_id,
      pending.messages,
      pending.metadata,
      "compact_recovery_save",
    )
    if !self.sessions.is_empty() {
      self.progress.set_cursor(session_id, pending.messages.length())
    }
  })
}

///|
async fn AgentRuntime::drain_pending_new_thread_outputs(
  self : AgentRuntime,
) -> Unit raise @error.AgentError {
  self.session_output.recover_new_threads(async fn(
    pending,
  ) -> Unit raise @error.AgentError {
    self.write_new_thread_output(pending)
  })
}

///|
async fn AgentRuntime::complete_fork_turn(
  self : AgentRuntime,
  identity : TurnIdentity,
  parent_session_id : String,
  new_session_id : String,
  fork_index : Int32,
  forked_messages : Array[@kernel.Message],
  input : @kernel.Message,
) -> @types.TurnResult raise @error.AgentError {
  let can_cow_fork = fork_index > 0 &&
    !self.progress.is_dirty(parent_session_id) &&
    self.progress.cursor_or_zero(parent_session_id) >= fork_index
  self.persist_fork_session(
    identity.scope(),
    parent_session_id,
    new_session_id,
    fork_index,
    can_cow_fork,
    forked_messages,
    Map::from_array([]),
    "fork_save",
  )
  let result : @types.TurnResult = {
    message: input,
    tool_results: [],
    final_session_id: parent_session_id,
  }
  result
}

///|
async fn AgentRuntime::complete_compact_turn(
  self : AgentRuntime,
  identity : TurnIdentity,
  session_id : String,
  mode : @kernel.CompactMode,
  new_session_id : String?,
  compacted_messages : Array[@kernel.Message],
  input : @kernel.Message,
  current_metadata : Map[String, Json],
) -> @types.TurnResult raise @error.AgentError {
  match mode {
    NewThread =>
      match new_session_id {
        Some(new_sid) => {
          self.persist_new_thread_session(
            identity.scope(),
            session_id,
            new_sid,
            compacted_messages,
            "compact_newthread_save",
          )
          let result : @types.TurnResult = {
            message: input,
            tool_results: [],
            final_session_id: new_sid,
          }
          return result
        }
        None => {
          self.core_facts.stop(
            session_id,
            identity.run_id.to_string(),
            "missing_new_thread_id",
          )
          raise Runtime(
            InvocationFailed(
              "CompactCompleted::NewThread without new_session_id",
            ),
          )
        }
      }
    Replace => {
      // Save the model-supplied body. The product caller stays on the same
      // session id.
      let updated_session : @types.Session = {
        messages: @message_snapshot.snapshot_messages(compacted_messages),
        metadata: @message_snapshot.snapshot_metadata(current_metadata),
      }
      match
        self.core_facts.record_terminal(
          session_id,
          identity.run_id.to_string(),
          updated_session.messages,
          updated_session.metadata,
        ) {
        Ok(_) => ()
        Err(detail) =>
          emit_secondary_failure(self.events, "core_shadow_terminal", detail)
      }
      @session_output.save_all(
        self.sessions,
        session_id,
        updated_session.messages,
        updated_session.metadata,
        "compact_replace_save",
      )
      if !self.sessions.is_empty() {
        self.progress.set_cursor(session_id, updated_session.messages.length())
      }
      let result : @types.TurnResult = {
        message: input,
        tool_results: [],
        final_session_id: session_id,
      }
      return result
    }
  }
}

///|
async fn AgentRuntime::checkpoint_sessions_all(
  self : AgentRuntime,
  session_id : String,
  from_index : Int32,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json]?,
  operation : String,
) -> Unit raise @error.AgentError {
  if self.sessions.is_empty() {
    return
  }
  @session_output.checkpoint_all(
    self.sessions,
    session_id,
    from_index,
    messages,
    metadata,
    operation,
  )
  self.progress.set_cursor(session_id, from_index + messages.length())
}

///|
fn transcript_save_operation(
  transcript : @kernel.Transcript,
  initial_messages : Array[@kernel.Message],
  current_turn_start : Int32,
) -> String {
  let final_messages = transcript.messages_snapshot()
  let initial_len = current_turn_start + 1
  if final_messages.length() >= initial_len &&
    messages_prefix_equal(final_messages, initial_messages, initial_len) {
    "final_append"
  } else {
    "final_save"
  }
}

///|
async fn AgentRuntime::save_turn_transcript(
  self : AgentRuntime,
  session_id : String,
  transcript : @kernel.Transcript,
  metadata : Map[String, Json],
  initial_messages : Array[@kernel.Message],
  current_turn_start : Int32,
  run_id : String,
) -> Unit raise @error.AgentError {
  let final_messages = @message_snapshot.snapshot_messages(
    transcript.messages_snapshot(),
  )
  let base_metadata = @message_snapshot.snapshot_metadata(metadata)
  let metadata = self.metadata_with_context_state(session_id, metadata)
  let metadata = self.task_runtime.metadata_with_applied_outcomes(
    session_id, metadata,
  )
  match
    self.core_facts.record_terminal(
      session_id, run_id, final_messages, metadata,
    ) {
    Ok(_) => ()
    Err(detail) =>
      emit_secondary_failure(self.events, "core_shadow_terminal", detail)
  }
  let metadata_checkpoint : Map[String, Json]? = if session_metadata_equal(
      metadata, base_metadata,
    ) {
    None
  } else {
    Some(metadata)
  }
  let cursor = self.progress.cursor_or_zero(session_id)
  let operation = if self.task_runtime.has_inflight(session_id) ||
    self.progress.is_dirty(session_id) {
    "final_save"
  } else {
    transcript_save_operation(transcript, initial_messages, current_turn_start)
  }
  if operation == "final_append" {
    let tail = if cursor < final_messages.length() {
      @message_snapshot.snapshot_messages(final_messages[cursor:].to_owned())
    } else {
      []
    }
    if !tail.is_empty() || metadata_checkpoint is Some(_) {
      self.checkpoint_sessions_all(
        session_id, cursor, tail, metadata_checkpoint, "final_append",
      )
    }
  } else {
    // Rewrite, fork, or compact: rewrite the whole persisted session.
    @session_output.save_all(
      self.sessions,
      session_id,
      final_messages,
      metadata,
      "final_save",
    )
    if !self.sessions.is_empty() {
      self.progress.set_cursor(session_id, final_messages.length())
    }
  }
  self.progress.mark_clean(session_id)
}

///|
async fn AgentRuntime::save_failed_turn_transcript(
  self : AgentRuntime,
  session_id : String,
  initial_messages : Array[@kernel.Message],
  current_turn_start : Int32,
  current_metadata : Map[String, Json],
  run_id : String,
) -> Unit noraise {
  match self.puppet.last_completed_transcript() {
    Some(t) => {
      let operation = transcript_save_operation(
        t, initial_messages, current_turn_start,
      )
      let saved : Result[Unit, @error.AgentError] = Ok(
        self.save_turn_transcript(
          session_id, t, current_metadata, initial_messages, current_turn_start,
          run_id,
        ),
      ) catch {
        error => Err(error)
      }
      match saved {
        Ok(_) => self.task_runtime.commit_outcomes(session_id)
        Err(error) =>
          emit_secondary_failure(
            self.events,
            "failed_turn_transcript_save",
            "session_id=\{@diagnostic.safe_error_label(session_id)};op=\{operation};cause=\{failed_save_cause_label(error)}",
          )
      }
    }
    None => ()
  }
}

///|
fn is_compact_effect_phase(phase : String) -> Bool {
  phase == "compact" || phase == "compact_session" || phase == "auto_compact"
}

///|
fn failed_save_cause_label(error : @error.AgentError) -> String {
  match error {
    Session(_) => "SessionError::Save"
    Model(_) => "AgentError::Model"
    Runtime(_) => "AgentError::Runtime"
    ToolLoopExceeded(..) => "AgentError::ToolLoopExceeded"
    Busy(..) => "AgentError::Busy"
    PipelineAborted(_) => "AgentError::PipelineAborted"
    Cancelled(_) => "AgentError::Cancelled"
    AutoCompactFailed(_) => "AgentError::AutoCompactFailed"
  }
}

///|
fn AgentRuntime::metadata_with_context_state(
  self : AgentRuntime,
  session_id : String,
  metadata : Map[String, Json],
) -> Map[String, Json] {
  let metadata = @message_snapshot.snapshot_metadata(metadata)
  match self.puppet.session_context_state(session_id) {
    Some(state) =>
      metadata[@types.CONTEXT_STATE_METADATA_KEY] = state.to_metadata_json()
    None => ()
  }
  metadata
}

///|
fn AgentRuntime::project_context_state(
  self : AgentRuntime,
  scope : @types.EventScope?,
  session_id : String,
) -> Unit {
  match self.puppet.session_context_state(session_id) {
    Some(state) => self.emit_turn_event(scope, ContextStateUpdated(state~))
    None => ()
  }
}

///|
async fn AgentRuntime::load_session_for_operation(
  self : AgentRuntime,
  session_id : String,
) -> @types.Session raise @error.AgentError {
  // A confirmed core snapshot is the only source after initialization. Normal
  // operation termination (diversion/cancel) does not make it unreadable.
  let read : Result[@types.Session, @core_facts.CoreReadError] = Ok(
    self.core_facts.read_session(session_id),
  ) catch {
    error => Err(error)
  }
  match read {
    Ok(session) => return session
    Err(UnknownSession(..)) => ()
    Err(Unreadable(reason~, ..)) =>
      raise Runtime(
        InvocationFailed(
          "core session is unreadable: " +
          @diagnostic.safe_error_label(session_id) +
          "; reason=" +
          @diagnostic.safe_error_label(reason),
        ),
      )
  }
  // Unknown session: perform the one external seed. A configured store is
  // read once; without a store the empty core is initialized in memory.
  let loaded : @types.Session = match self.sessions {
    [first, ..] =>
      first.load(session_id) catch {
        error =>
          raise @session_output.contextualize_session_error(
            error, session_id, "load",
          )
      }
    [] => { messages: [], metadata: Map::from_array([]), }
  }
  let hydrated : Result[Unit, String] = self.core_facts.hydrate(
    session_id,
    loaded.messages,
    loaded.metadata,
  )
  match hydrated {
    Ok(_) => ()
    Err(detail) =>
      raise Runtime(
        InvocationFailed(
          "core session initialization failed: " +
          @diagnostic.safe_error_label(session_id) +
          "; " +
          @diagnostic.safe_error_label(detail),
        ),
      )
  }
  if !self.sessions.is_empty() {
    // Only one store seeded the content. All-store alignment is unknown until
    // the next full write-all succeeds; the first output must not append.
    self.progress.mark_dirty(session_id)
  }
  let initialized : Result[@types.Session, @core_facts.CoreReadError] = Ok(
    self.core_facts.read_session(session_id),
  ) catch {
    error => Err(error)
  }
  match initialized {
    Ok(session) => session
    Err(UnknownSession(..)) =>
      raise Runtime(
        InvocationFailed(
          "core session initialization produced no fact: " +
          @diagnostic.safe_error_label(session_id),
        ),
      )
    Err(Unreadable(reason~, ..)) =>
      raise Runtime(
        InvocationFailed(
          "core session is unreadable after initialization: " +
          @diagnostic.safe_error_label(session_id) +
          "; reason=" +
          @diagnostic.safe_error_label(reason),
        ),
      )
  }
}

///|
fn fixate_pending_tool_calls(
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] {
  let answered : Map[String, Bool] = Map::from_array([])
  for message in messages {
    match message {
      ToolMessage(call_id~, ..) => answered[call_id.to_string()] = true
      _ => ()
    }
  }
  let out : Array[@kernel.Message] = []
  for message in messages {
    out.push(message)
    match message {
      AssistantMessage(tool_calls~, ..) =>
        for call in tool_calls {
          if !answered.contains(call.call_id.to_string()) {
            answered[call.call_id.to_string()] = true
            out.push(
              ToolMessage(
                call_id=call.call_id,
                tool_name=call.name,
                outcome=RuntimeFailure(
                  error_category="Interrupted",
                  message="tool call was pending when the previous operation ended; recorded as interrupted",
                ),
              ),
            )
          }
        }
      _ => ()
    }
  }
  out
}
