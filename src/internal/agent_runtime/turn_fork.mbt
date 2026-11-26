///|
pub async fn AgentRuntime::fork_session(
  self : AgentRuntime,
  session_id : String,
  new_session_id~ : String? = None,
  at_message_index~ : Int32? = None,
  metadata~ : Map[String, Json] = Map::from_array([]),
) -> @types.ForkOutcome raise @error.AgentError {
  self.run_admitted_operation(session_id, Fork, async fn(
    admission,
  ) -> @types.ForkOutcome raise @error.AgentError {
    self.run_fork_operation(
      admission, new_session_id, at_message_index, metadata,
    )
  })
}

///|
#warnings("-fragile_catch_all")
async fn AgentRuntime::run_fork_operation(
  self : AgentRuntime,
  admission : OperationAdmission,
  new_session_id : String?,
  at_message_index : Int32?,
  metadata : Map[String, Json],
) -> @types.ForkOutcome raise @error.AgentError {
  let session_id = admission.session_id
  self.ensure_agent_running()
  self.notify_start_if_first()
  let identity = admission.identity
  defer self.core_facts.finish_run(
    session_id,
    identity.run_id.to_string(),
    "fork_ended_without_terminal",
  )
  defer self.drain_core_facts_errors()
  self.task_runtime.begin_operation(
    session_id,
    identity.run_id,
    identity.turn_id,
  )
  let scope = identity.scope()
  let target_sid = match new_session_id {
    Some(id) => id
    None => "\{session_id}_fork_\{admission.operation_id}"
  }
  if target_sid == "" ||
    target_sid == session_id ||
    self.core_facts.has_session(target_sid) {
    let reason = if target_sid == "" || target_sid == session_id {
      "invalid fork target session id"
    } else {
      "target session already exists"
    }
    self.emit_turn_event(
      Some(scope),
      OperationFinalized(operation="fork", outcome="failed", detail=reason),
    )
    raise @session_output.contextualize_session_error(
      Conflict(reason),
      target_sid,
      "fork_session",
    )
  }
  let was_hydrated = self.core_facts.has_session(session_id)
  let session = self.load_session_for_operation(session_id)
  match @types.ContextState::from_metadata(session.metadata) {
    Some(state) =>
      match self.puppet.session_context_state(session_id) {
        Some(_) => ()
        None => self.puppet.adopt_context_state(session_id, state)
      }
    None => ()
  }
  self.project_context_state(Some(scope), session_id)
  let len = session.messages.length()
  let raw_index = at_message_index.unwrap_or(len)
  let fork_index = if raw_index < 0 {
    0
  } else if raw_index > len {
    len
  } else {
    raw_index
  }
  let freshly_loaded_single = !was_hydrated && self.sessions.length() == 1
  let can_cow_fork = fork_index > 0 &&
    (
      (
        !self.progress.is_dirty(session_id) &&
        self.progress.cursor_or_zero(session_id) >= fork_index
      ) ||
      (freshly_loaded_single && fork_index <= len)
    )
  match
    self.core_facts.admit(
      session_id,
      session.messages,
      session.metadata,
      session.messages,
      identity.run_id.to_string(),
    ) {
    Ok(_) => ()
    Err(detail) => {
      let msg = "core admission failed: " + @diagnostic.safe_error_label(detail)
      self.emit_turn_event(
        Some(scope),
        OperationFinalized(operation="fork", outcome="failed", detail=msg),
      )
      raise Runtime(InvocationFailed(msg))
    }
  }
  self.core_facts.capture_source(
    identity.run_id.to_string(),
    session_id,
    session.messages,
    fork_index,
  )
  let forked_messages = @message_snapshot.snapshot_messages(
    session.messages[:fork_index].to_owned(),
  )
  let persisted : Result[Unit, @error.AgentError] = Ok(
    self.persist_fork_session(
      scope, session_id, target_sid, fork_index, can_cow_fork, forked_messages, metadata,
      "fork_save",
    ),
  ) catch {
    error => Err(error)
  }
  match persisted {
    Ok(_) => ()
    Err(error) => {
      let detail = @diagnostic.bounded_error_label(error.to_string(), 512)
      self.emit_turn_event(
        Some(scope),
        OperationFinalized(operation="fork", outcome="failed", detail~),
      )
      raise error
    }
  }
  self.puppet.estimate_session_context(
    identity.run_id,
    identity.turn_id,
    @kernel.SessionId::unchecked(target_sid),
    forked_messages,
    self.current_run_policy(),
  )
  self.project_context_state(Some(scope), target_sid)
  self.emit_turn_event(
    Some(scope),
    OperationFinalized(operation="fork", outcome="completed", detail=""),
  )
  {
    parent_session_id: session_id,
    new_session_id: target_sid,
    fork_index,
    messages_after: fork_index,
  }
}
