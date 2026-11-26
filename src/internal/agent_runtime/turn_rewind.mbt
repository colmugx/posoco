///|
pub async fn AgentRuntime::rewind_session(
  self : AgentRuntime,
  session_id : String,
  to_message_index : Int32,
) -> @types.RewindOutcome raise @error.AgentError {
  self.run_admitted_operation(session_id, Rewind, async fn(
    admission,
  ) -> @types.RewindOutcome raise @error.AgentError {
    self.run_rewind_operation(admission, to_message_index)
  })
}

///|
#warnings("-fragile_catch_all")
async fn AgentRuntime::run_rewind_operation(
  self : AgentRuntime,
  admission : OperationAdmission,
  to_message_index : Int32,
) -> @types.RewindOutcome raise @error.AgentError {
  let session_id = admission.session_id
  self.ensure_agent_running()
  self.notify_start_if_first()
  let identity = admission.identity
  defer self.core_facts.finish_run(
    session_id,
    identity.run_id.to_string(),
    "rewind_ended_without_terminal",
  )
  defer self.drain_core_facts_errors()
  self.task_runtime.begin_operation(
    session_id,
    identity.run_id,
    identity.turn_id,
  )
  let scope = identity.scope()
  let was_hydrated = self.core_facts.has_session(session_id)
  let session = self.load_session_for_operation(session_id)
  let was_dirty = self.progress.is_dirty(session_id)
  let freshly_loaded_single = !was_hydrated && self.sessions.length() == 1
  let can_truncate_in_place = !was_dirty || freshly_loaded_single
  match @types.ContextState::from_metadata(session.metadata) {
    Some(state) =>
      match self.puppet.session_context_state(session_id) {
        Some(_) => ()
        None => self.puppet.adopt_context_state(session_id, state)
      }
    None => ()
  }
  let messages_before = session.messages.length()
  let keep = if to_message_index < 0 {
    0
  } else if to_message_index > messages_before {
    messages_before
  } else {
    to_message_index
  }
  let kept_messages = @message_snapshot.snapshot_messages(
    session.messages[:keep].to_owned(),
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
    Err(detail) =>
      raise Runtime(
        InvocationFailed(
          "core admission failed: " + @diagnostic.safe_error_label(detail),
        ),
      )
  }
  let policy = self.current_run_policy()
  let rewind_result = match
    (Ok(
      @async.handle_cancellation(async fn() -> Result[
        Unit,
        @puppetry.PuppetError,
      ] {
        Ok(
          self.puppet.rewind_standalone(
            identity.run_id,
            identity.turn_id,
            identity.session_id,
            session.messages,
            kept_messages,
            policy,
            admission.operation_id,
          ),
        ) catch {
          e => Err(e)
        }
      }),
    ) catch {
      e => Err(e)
    }) {
    Ok(Some(result)) => result
    Ok(None) => {
      self.emit_turn_event(
        Some(scope),
        OperationFinalized(
          operation="rewind",
          outcome="cancelled",
          detail="rewind cancelled",
        ),
      )
      raise Cancelled("rewind cancelled")
    }
    Err(e) =>
      raise Runtime(
        InvocationFailed(
          "puppet rewind: " + @diagnostic.safe_error_label(e.to_string()),
        ),
      )
  }
  match rewind_result {
    Err(EffectExecutionCancelled(..)) => {
      self.emit_turn_event(
        Some(scope),
        OperationFinalized(
          operation="rewind",
          outcome="cancelled",
          detail="rewind cancelled",
        ),
      )
      raise Cancelled("rewind cancelled")
    }
    Err(error) => {
      let detail = @diagnostic.bounded_error_label(error.to_string(), 512)
      self.emit_turn_event(
        Some(scope),
        OperationFinalized(operation="rewind", outcome="failed", detail~),
      )
      raise Runtime(InvocationFailed("puppet rejected the rewind: " + detail))
    }
    Ok(_) => ()
  }
  let mut updated_metadata = @message_snapshot.snapshot_metadata(
    session.metadata,
  )
  if keep == 0 {
    updated_metadata.remove(@types.CONTEXT_STATE_METADATA_KEY)
    updated_metadata.remove(@types.SESSION_TITLE_METADATA_KEY)
    self.memory_inbound_attempted.remove(session_id)
  } else {
    updated_metadata = self.metadata_with_context_state(
      session_id, updated_metadata,
    )
  }
  match
    self.core_facts.record_terminal(
      session_id,
      identity.run_id.to_string(),
      kept_messages,
      updated_metadata,
    ) {
    Ok(_) => ()
    Err(detail) =>
      emit_secondary_failure(self.events, "core_shadow_terminal", detail)
  }
  if !self.sessions.is_empty() {
    let meta_changed = !session_metadata_equal(
      updated_metadata,
      session.metadata,
    )
    let saved : Result[Unit, Error] = Ok(
      if can_truncate_in_place {
        @session_output.truncate_all(
          self.sessions,
          session_id,
          keep,
          "rewind_truncate",
        )
        if meta_changed {
          @session_output.checkpoint_all(
            self.sessions,
            session_id,
            keep,
            [],
            Some(updated_metadata),
            "rewind_metadata_checkpoint",
          )
        }
      } else {
        @session_output.save_all(
          self.sessions,
          session_id,
          kept_messages,
          updated_metadata,
          "rewind_body_save",
        )
      },
    ) catch {
      e => Err(e)
    }
    match saved {
      Err(_) => {
        self.session_output.stage_body(session_id, {
          messages: kept_messages,
          metadata: updated_metadata,
        })
        self.emit_turn_event(
          Some(scope),
          OperationFinalized(
            operation="rewind",
            outcome="failed",
            detail="journal committed; body save failed; next operation repairs the projection",
          ),
        )
        raise @session_output.contextualize_session_error(
          Conflict(
            "rewind committed but body save failed; session needs recovery",
          ),
          session_id,
          "rewind_body_save",
        )
      }
      Ok(_) => ()
    }
    self.progress.set_cursor(session_id, keep)
    self.progress.mark_clean(session_id)
  }
  if keep > 0 {
    self.project_context_state(Some(scope), session_id)
  }
  self.emit_turn_event(
    Some(scope),
    SessionRewound(session_id~, messages_before~, messages_after=keep),
  )
  self.emit_turn_event(
    Some(scope),
    OperationFinalized(operation="rewind", outcome="completed", detail=""),
  )
  { session_id, messages_before, messages_after: keep, }
}
