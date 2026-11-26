///|
pub async fn AgentRuntime::compact_session(
  self : AgentRuntime,
  session_id : String,
) -> @types.CompactOutcome raise @error.AgentError {
  self.run_admitted_operation(session_id, Compact, async fn(
    admission,
  ) -> @types.CompactOutcome raise @error.AgentError {
    self.run_compact_operation(admission)
  })
}

///|
#warnings("-fragile_catch_all")
async fn AgentRuntime::run_compact_operation(
  self : AgentRuntime,
  admission : OperationAdmission,
) -> @types.CompactOutcome raise @error.AgentError {
  let session_id = admission.session_id
  self.ensure_agent_running()
  self.notify_start_if_first()
  let identity = admission.identity
  defer self.core_facts.finish_run(
    session_id,
    identity.run_id.to_string(),
    "compact_ended_without_terminal",
  )
  defer self.drain_core_facts_errors()
  self.task_runtime.begin_operation(
    session_id,
    identity.run_id,
    identity.turn_id,
  )
  let scope = identity.scope()
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
  let raw = @message_snapshot.snapshot_messages(session.messages)
  let messages = fixate_pending_tool_calls(raw)
  if !self.sessions.is_empty() && !@core_facts.messages_equal(raw, messages) {
    self.progress.mark_dirty(session_id)
  }
  match
    self.core_facts.admit(
      session_id,
      messages,
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
  self.emit_turn_event(Some(scope), CompactStarted(trigger="manual"))
  let prompt_result = match
    (Ok(
      @async.handle_cancellation(async fn() {
        self.puppet.compact_standalone(
          identity.run_id,
          identity.turn_id,
          identity.session_id,
          messages,
          policy,
          admission.operation_id,
          Manual,
        )
      }),
    ) catch {
      e => Err(e)
    }) {
    Ok(Some(result)) => result
    Ok(None) => {
      // The compact operation itself was cancelled: project the cancelled
      // terminal and surface the structured outcome.
      self.emit_turn_event(
        Some(scope),
        OperationFinalized(
          operation="compact",
          outcome="cancelled",
          detail="compact cancelled",
        ),
      )
      raise Cancelled("compact cancelled")
    }
    Err(e) =>
      raise Runtime(
        InvocationFailed(
          "puppet compact: " + @diagnostic.safe_error_label(e.to_string()),
        ),
      )
  }
  match prompt_result {
    Rejected(error=EffectExecutionCancelled(..)) => {
      self.emit_turn_event(
        Some(scope),
        OperationFinalized(
          operation="compact",
          outcome="cancelled",
          detail="compact cancelled",
        ),
      )
      raise Cancelled("compact cancelled")
    }
    Rejected(error~) => {
      // Keep the sanitized bounded rendering; the ModelFailure category and
      // its safe label must survive to the observer event and the error.
      let detail = @diagnostic.bounded_error_label(error.to_string(), 512)
      self.emit_turn_event(
        Some(scope),
        OperationFinalized(operation="compact", outcome="failed", detail~),
      )
      raise Runtime(InvocationFailed("puppet rejected the compact: " + detail))
    }
    CompactCompleted(mode~, trigger~, new_session_id~, compacted_messages~, ..) =>
      match mode {
        NewThread =>
          match new_session_id {
            Some(new_sid) => {
              self.persist_new_thread_session(
                scope, session_id, new_sid, compacted_messages, "compact_newthread_save",
              )
              self.project_context_state(Some(scope), new_sid)
              self.emit_turn_event(
                Some(scope),
                CompactFinished(
                  trigger=trigger.to_string(),
                  mode="NewThread",
                  final_session_id=new_sid,
                  messages_after=compacted_messages.length(),
                ),
              )
              self.emit_turn_event(
                Some(scope),
                OperationFinalized(
                  operation="compact",
                  outcome="completed",
                  detail="",
                ),
              )
              let outcome : @types.CompactOutcome = {
                final_session_id: new_sid,
                mode: NewThread,
                messages_after: compacted_messages.length(),
              }
              outcome
            }
            None => {
              self.core_facts.stop(
                session_id,
                identity.run_id.to_string(),
                "missing_new_thread_id",
              )
              let detail = "CompactCompleted::NewThread without new_session_id"
              self.emit_turn_event(
                Some(scope),
                OperationFinalized(
                  operation="compact",
                  outcome="failed",
                  detail~,
                ),
              )
              raise Runtime(InvocationFailed(detail))
            }
          }
        Replace => {
          // Standalone replace gets a real terminal full-body mirror before
          // the output save. A save failure leaves the core terminal intact.
          let updated_metadata = self.metadata_with_context_state(
            session_id,
            session.metadata,
          )
          let updated_session : @types.Session = {
            messages: @message_snapshot.snapshot_messages(compacted_messages),
            metadata: updated_metadata,
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
              emit_secondary_failure(
                self.events,
                "core_shadow_terminal",
                detail,
              )
          }
          let saved : Result[Unit, Error] = Ok(
            @session_output.save_all(
              self.sessions,
              session_id,
              updated_session.messages,
              updated_session.metadata,
              "compact_body_save",
            ),
          ) catch {
            e => Err(e)
          }
          match saved {
            Err(_) => {
              self.session_output.stage_body(session_id, updated_session)
              self.emit_turn_event(
                Some(scope),
                OperationFinalized(
                  operation="compact",
                  outcome="failed",
                  detail="journal committed; body save failed; next operation repairs the projection",
                ),
              )
              raise @session_output.contextualize_session_error(
                Conflict(
                  "compact committed but body save failed; session needs recovery",
                ),
                session_id,
                "compact_body_save",
              )
            }
            Ok(_) => ()
          }
          if !self.sessions.is_empty() {
            self.progress.set_cursor(
              session_id,
              updated_session.messages.length(),
            )
          }
          self.project_context_state(Some(scope), session_id)
          self.emit_turn_event(
            Some(scope),
            CompactFinished(
              trigger=trigger.to_string(),
              mode=mode.to_string(),
              final_session_id=session_id,
              messages_after=updated_session.messages.length(),
            ),
          )
          self.emit_turn_event(
            Some(scope),
            OperationFinalized(
              operation="compact",
              outcome="completed",
              detail="",
            ),
          )
          let outcome : @types.CompactOutcome = {
            final_session_id: session_id,
            mode,
            messages_after: updated_session.messages.length(),
          }
          outcome
        }
      }
    Accepted(..) | ForkCompleted(..) | LeaseBusy(..) => {
      let detail = "unexpected prompt result from standalone compact"
      self.emit_turn_event(
        Some(scope),
        OperationFinalized(operation="compact", outcome="failed", detail~),
      )
      raise Runtime(InvocationFailed(detail))
    }
  }
}
