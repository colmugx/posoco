///|
/// Per-turn execution: policy assembly, the Puppet prompt call, terminal
/// translation (fork / compact / failure), and transcript persistence.

///|
/// Format a quota verdict's scheduling data (`ModelFailure::RateLimited`
/// shape) in the `ModelError::RateLimited` label style, so the AgentError
/// message carries the provider code and reset time verbatim.
fn quota_error_detail(
  message : String,
  reset_at_ms : Int64?,
  provider_code : String?,
) -> String {
  let code_label = match provider_code {
    Some(code) => code
    None => "none"
  }
  let reset_label = match reset_at_ms {
    Some(at) => "\{at}"
    None => "none"
  }
  "code=\{code_label}, reset_at_ms=\{reset_label}, message=\{message}"
}

///|
/// True when `left` and `right` share the same first `len` messages.
fn messages_prefix_equal(
  left : Array[@kernel.Message],
  right : Array[@kernel.Message],
  len : Int,
) -> Bool {
  if left.length() < len || right.length() < len {
    return false
  }
  for i in 0..<len {
    if left[i] != right[i] {
      return false
    }
  }
  true
}

///|
/// Memory inbound injection: on a session's first turn (empty loaded
/// transcript) every memory source gets exactly one `inbound` read; the
/// attempt is spent even when nothing comes back (freeze-even-if-empty),
/// and any bodies freeze as ONE user message placed before the input — so
/// the input stays at index `current_turn_start`, keeping the pure-append
/// save math and fork/compact slicing intact.
async fn AgentRuntime::inject_memory_inbound(
  self : AgentRuntime,
  session : @types.Session,
  session_id : String,
  input : @kernel.Message,
  messages : Array[@kernel.Message],
) -> Unit noraise {
  if session.messages.length() == 0 &&
    !self.memory.is_empty() &&
    !self.memory_inbound_attempted.contains(session_id) {
    self.memory_inbound_attempted[session_id] = true
    let request = match input {
      UserMessage(content~) => {
        let parts : Array[String] = []
        for item in content {
          match item {
            Text(t) => parts.push(t)
            _ => ()
          }
        }
        parts.join("")
      }
      _ => ""
    }
    let bodies = collect_memory_inbound(
      self.memory,
      session_id,
      request,
      self.config.memory_inbound_timeout_ms,
      fn(reason) {
        emit_secondary_failure(self.observers, "memory_inbound", reason)
      },
    )
    if !bodies.is_empty() {
      messages.push(memory_inbound_message(bodies))
    }
  }
}

///|
/// Drive one full turn through the Puppet. Steps:
/// 0. refresh the catalog when a CatalogSource's revision changed
/// 1. load session
/// 2. snapshot session.messages (deep copy) + append input
/// 3. (identity minted by the caller, before TurnStarted — see
///    `AgentRuntime::mint_turn_identity`)
/// 4. drive the Agent-owned long-lived Puppet
/// 5. translate non-Accepted PromptResult → AgentError
/// 6. materialize and save the canonical terminal transcript (write-all)
/// 7. return TurnResult
async fn AgentRuntime::run_turn_via_puppet(
  self : AgentRuntime,
  input : @kernel.Message,
  session_id : String,
  identity : TurnIdentity,
  resume_persisted_user : Bool,
) -> @types.TurnResult raise @error.AgentError {
  // Step 0: catalog refresh at the prompt boundary. No run is active yet,
  // so a swap cannot disturb an in-flight run; a failed rebuild keeps the
  // previous snapshot and is surfaced as a secondary failure.
  self.refresh_catalog_if_changed()

  let session = self.load_session_for_operation(session_id)
  // The loaded session is the authoritative persisted prefix for this turn.
  self.session_cursors[session_id] = session.messages.length()
  match @types.ContextState::from_metadata(session.metadata) {
    Some(state) =>
      match self.puppet.session_context_state(session_id) {
        Some(_) => ()
        None => self.puppet.adopt_context_state(session_id, state)
      }
    None => ()
  }
  self.project_context_state(Some(identity.scope()), session_id)

  // Step 2: snapshot + seed this turn. Recovery replays a persisted trailing
  // user message without appending it again; every other path appends the
  // supplied input. Deep-copy so callers cannot mutate recorded state.
  let messages = snapshot_messages(session.messages)
  let (input, current_turn_start) = match messages.last() {
    Some(last) if resume_persisted_user && last is UserMessage(..) =>
      (snapshot_message(last), messages.length() - 1)
    _ => {
      self.inject_memory_inbound(session, session_id, input, messages)
      let current_turn_start = messages.length()
      messages.push(snapshot_message(input))
      (input, current_turn_start)
    }
  }
  let current_metadata = snapshot_metadata(session.metadata)

  // Step 3: per-prompt policy on the caller-minted identity. The counter is
  // Agent-owned and monotonic, so two calls on the same Agent never share
  // run/turn ids while still using the same Puppet and journal.
  let budget : @kernel_exec.Budget = {
    max_model_steps: None,
    max_tool_rounds: self.config.max_tool_rounds,
    max_tool_calls: None,
    max_total_tokens: None,
  }
  // Live capability read: the modelport self-reports the active model's
  // context window / compact threshold (the router forwards the active
  // slot's values). Precedence is defined exactly once — host config >
  // provider report > core default (0.88) — and is read per turn so `/model`
  // switches take effect on the next turn without recomposing the Agent.
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
    operation_id: "agent_run_turn_\{identity.seq}",
    policy,
  }

  // Step 4: drive the already-started, Agent-owned Puppet. The chunk
  // dispatcher is per-turn: its drain task runs for the duration of the turn
  // and is reaped by `with_task_group` when the turn body returns or raises.
  // The queue MUST be closed inside the group closure: `with_task_group`
  // returns only after every child task (the drain loop included) has
  // terminated, and the drain loop terminates only when the queue closes —
  // closing after the group returns would deadlock.
  let dispatcher = ChunkDispatcher(self.observers)
  self.chunk_dispatcher.val = Some(dispatcher)
  // The typed error is captured inside the group closure and re-raised
  // after the boundary: `with_task_group`'s closure signature carries the
  // wide `Error` (no error type parameter), so capturing the typed value is
  // the only way the original `AgentError` variant — and its contextualized
  // messages — survives the crossing.
  let turn_error : Ref[@error.AgentError?] = Ref(None)
  let result = @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() { dispatcher.drain_loop() })
    errdefer {
      dispatcher.flush()
      dispatcher.close()
    }
    // The Ok/Err wrapper lets the typed AgentError escape the group closure
    // as data: catch + re-raise is fragile_catch_all and try? is deprecated.
    let turn_result = match
      (Ok(
        self.run_puppet_turn_body(
          request, identity, session_id, input, current_turn_start, current_metadata,
        ),
      ) catch {
        e => Err(e)
      }) {
      Ok(r) => r
      Err(e) => {
        turn_error.val = Some(e)
        raise e
      }
    }
    dispatcher.flush()
    dispatcher.close()
    turn_result
  }) catch {
    error => {
      self.chunk_dispatcher.val = None
      let original : @error.AgentError = match turn_error.val {
        Some(ae) => ae
        None =>
          if @async.is_cancellation_error(error) {
            @error.AgentError::Cancelled("turn cancelled")
          } else {
            Runtime(InvocationFailed("turn body: unclassified error"))
          }
      }
      raise original
    }
  }
  self.chunk_dispatcher.val = None
  result
}

///|
/// Body of one Puppet turn: drive the Puppet, translate the result, and
/// materialize the `TurnResult`. Extracted from `run_turn_via_puppet` so the
/// dispatcher lifecycle (create / spawn drain / flush / close) can wrap it
/// uniformly on both the success and failure paths.
async fn AgentRuntime::run_puppet_turn_body(
  self : AgentRuntime,
  request : @puppetry.PromptRequest,
  identity : TurnIdentity,
  session_id : String,
  input : @kernel.Message,
  current_turn_start : Int,
  current_metadata : Map[String, Json],
) -> @types.TurnResult raise @error.AgentError {
  // Step 4: drive the already-started, Agent-owned Puppet.
  let prompt_result = self.puppet.prompt(request) catch {
    e =>
      if @async.is_cancellation_error(e) {
        raise @error.AgentError::Cancelled("puppet prompt cancelled")
      } else {
        raise Runtime(
          InvocationFailed("puppet prompt: " + safe_error_label(e.to_string())),
        )
      }
  }

  // Step 5: handle non-Accepted prompt results.
  match prompt_result {
    Rejected(error=HookRejected(reason~)) => raise PipelineAborted(reason)
    Rejected(error=PumpLoopExceeded(..)) =>
      // With a correctly sized backstop (2 * rounds + 1) the kernel budget
      // always fires first; reaching this branch means a livelock or an
      // internal accounting defect, not a budget hit.
      raise Runtime(
        InvocationFailed("pump loop exceeded (internal livelock guard)"),
      )
    Rejected(error=ReducerInvariantViolation(..)) =>
      raise Runtime(InvocationFailed("puppet invariant violation"))
    Rejected(error=EffectExecutionFailed(phase="auto_compact", cause~)) => {
      match self.puppet.last_completed_transcript() {
        Some(t) => {
          let operation = transcript_save_operation(
            t,
            request.initial_messages,
            current_turn_start,
          )
          self.save_turn_transcript(
            session_id,
            t,
            current_metadata,
            request.initial_messages,
            current_turn_start,
          ) catch {
            error =>
              emit_secondary_failure(
                self.observers,
                "failed_turn_transcript_save",
                "session_id=\{safe_error_label(session_id)};op=\{operation};cause=\{failed_save_cause_label(error)}",
              )
          }
        }
        None => ()
      }
      raise @error.AgentError::AutoCompactFailed(cause)
    }
    Rejected(error=EffectExecutionCancelled(phase~)) =>
      raise @error.AgentError::Cancelled(
        "effect execution cancelled in \{phase}",
      )
    Rejected(error=EffectExecutionFailed(cause~, ..)) =>
      raise Runtime(
        InvocationFailed("puppet effect execution: " + safe_error_label(cause)),
      )
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
          // A failed turn still owns its transcript: the user input and any
          // completed progress must reach the session store, or the next turn
          // reloads pre-turn state and the model loses the context of what it
          // was doing — and what the user asked.
          match self.puppet.last_completed_transcript() {
            Some(t) => {
              let operation = transcript_save_operation(
                t,
                request.initial_messages,
                current_turn_start,
              )
              self.save_turn_transcript(
                session_id,
                t,
                current_metadata,
                request.initial_messages,
                current_turn_start,
              ) catch {
                // The turn's own failure is the primary signal; a secondary
                // save failure must not mask it. Keep the persistence
                // failure observable without copying untrusted transcript
                // content into the event.
                error =>
                  emit_secondary_failure(
                    self.observers,
                    "failed_turn_transcript_save",
                    "session_id=\{safe_error_label(session_id)};op=\{operation};cause=\{failed_save_cause_label(error)}",
                  )
              }
            }
            None => ()
          }
          raise err
        }
        None => ()
      }
    }
    LeaseBusy(..) => raise Runtime(InvocationFailed("puppet lease busy"))
  }

  // Step 6: materialize the terminal transcript for persistence and the
  // TurnResult. Observer projection already happened from committed envelopes;
  // this traversal has no side effects and only selects this turn's result.
  let final_transcript = match self.puppet.last_completed_transcript() {
    Some(t) => t
    None =>
      raise Runtime(
        InvocationFailed("puppet did not produce a terminal transcript"),
      )
  }
  let transcript_msgs = final_transcript.messages_snapshot()
  let mut final_message : @kernel.Message = input
  let all_results : Array[@kernel.ToolOutcome] = []
  for i in current_turn_start..<transcript_msgs.length() {
    let message = transcript_msgs[i]
    match message {
      AssistantMessage(..) => final_message = message
      ToolMessage(outcome~, ..) => all_results.push(outcome)
      _ => ()
    }
  }

  // Save session (write-all, with carried metadata).
  self.save_turn_transcript(
    session_id,
    final_transcript,
    current_metadata,
    request.initial_messages,
    current_turn_start,
  )
  self.project_context_state(Some(identity.scope()), session_id)

  // Step 7: build TurnResult.
  let result : @types.TurnResult = {
    message: final_message,
    tool_results: all_results,
    final_session_id: session_id,
  }
  result
}

///|
/// Translate the terminal outcome of an Accepted run into the turn's primary
/// AgentError, or None when the turn completed.
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
      Failed(reason=ModelQuotaExhausted(detail~, reset_at_ms~, provider_code~))
    ) =>
      // Provider quota/rate-limit verdict. The message keeps the provider
      // code and reset time so hosts can schedule a retry instead of
      // parsing the provider excerpt for scheduling data.
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
      // The reducer rejects exactly the batch that would push consumed
      // to limit + 1, so consumed is derivable; Agent only ever wires
      // the ToolRounds dimension (other budget dims are None here).
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
      Some(@error.AgentError::Cancelled("run cancelled: " + reason.to_string()))
    _ => None
  }
}

///|
/// Fork terminal state (M3.5): fork creates a new session and stops the
/// current turn. The original thread is untouched; product code switches its
/// active thread to `new_session_id`. We persist the new session to every
/// configured store (write-all) and return a TurnResult whose
/// `final_session_id` is the ORIGINAL session — the caller stays on the
/// original thread because this `run_turn` was for the original. The forked
/// session is a sibling the caller can switch to next.
async fn AgentRuntime::complete_fork_turn(
  self : AgentRuntime,
  identity : TurnIdentity,
  parent_session_id : String,
  new_session_id : String,
  forked_messages : Array[@kernel.Message],
  input : @kernel.Message,
) -> @types.TurnResult raise @error.AgentError {
  let forked_session : @types.Session = {
    messages: snapshot_messages(forked_messages),
    metadata: Map::from_array([]),
  }
  let with_lineage = forked_session.with_parent_thread_id(parent_session_id)
  self.save_sessions_all(
    new_session_id,
    with_lineage.messages,
    with_lineage.metadata,
    "fork_save",
  )
  self.session_cursors[new_session_id] = with_lineage.messages.length()
  // Emit a SessionRedirect so observers know a sibling thread was
  // created and can switch the UI.
  let redirect : @types.TurnEvent = SessionRedirect(
    from=parent_session_id,
    to=new_session_id,
    messages_before=forked_messages.length(),
    messages_after=forked_messages.length(),
  )
  for observer in self.observers {
    observer.on_event_at(Some(identity.scope()), snapshot_turn_event(redirect))
  }
  let result : @types.TurnResult = {
    message: input,
    tool_results: [],
    final_session_id: parent_session_id,
  }
  result
}

///|
/// Compact terminal state (M3.5): compact applied the modelport's
/// CompactResult.
/// - NewThread: persist the new session, return TurnResult with the NEW
///   final_session_id (the caller should switch active thread).
/// - Replace / Append: persist the current session with the updated
///   transcript body, return TurnResult with the ORIGINAL final_session_id.
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
          let new_session : @types.Session = {
            messages: snapshot_messages(compacted_messages),
            metadata: Map::from_array([]),
          }
          let with_lineage = new_session.with_parent_thread_id(session_id)
          self.save_sessions_all(
            new_sid,
            with_lineage.messages,
            with_lineage.metadata,
            "compact_newthread_save",
          )
          self.session_cursors[new_sid] = with_lineage.messages.length()
          let redirect : @types.TurnEvent = SessionRedirect(
            from=session_id,
            to=new_sid,
            messages_before=compacted_messages.length(),
            messages_after=compacted_messages.length(),
          )
          for observer in self.observers {
            observer.on_event_at(
              Some(identity.scope()),
              snapshot_turn_event(redirect),
            )
          }
          let result : @types.TurnResult = {
            message: input,
            tool_results: [],
            final_session_id: new_sid,
          }
          return result
        }
        None =>
          raise Runtime(
            InvocationFailed(
              "CompactCompleted::NewThread without new_session_id",
            ),
          )
      }
    Replace | Append => {
      // Save the updated original session body. The product caller
      // stays on the same session id.
      let updated_session : @types.Session = {
        messages: snapshot_messages(compacted_messages),
        metadata: snapshot_metadata(current_metadata),
      }
      self.save_sessions_all(
        session_id,
        updated_session.messages,
        updated_session.metadata,
        "compact_replace_save",
      )
      self.session_cursors[session_id] = updated_session.messages.length()
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
/// Save one session body to every configured store (write-all). Each store
/// receives its own deep snapshot so a misbehaving store cannot mutate
/// another store's payload; `operation` labels both error contexts verbatim.
async fn AgentRuntime::save_sessions_all(
  self : AgentRuntime,
  session_id : String,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
  operation : String,
) -> Unit raise @error.AgentError {
  let save_results : Array[Result[Unit, @error.SessionError]] = @async.all(
    self.sessions.map(fn(store) {
      () => {
        let session = snapshot_session(messages, metadata)
        Ok(store.save(session_id, session)) catch {
          error => Err(error)
        }
      }
    }),
  ) catch {
    error => raise save_error_context(error, session_id, operation)
  }
  for result in save_results {
    match result {
      Err(error) =>
        raise contextualize_session_error(error, session_id, operation)
      Ok(_) => ()
    }
  }
}

///|
/// Select the persistence operation from the same prefix invariant used by
/// `save_turn_transcript`, so failure diagnostics identify the actual path.
fn transcript_save_operation(
  transcript : @kernel.Transcript,
  initial_messages : Array[@kernel.Message],
  current_turn_start : Int,
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
/// Persist a terminal transcript to every session store (write-all, with
/// carried metadata). Shared by the completed and failed turn paths — a
/// failed turn's progress is exactly the context the next turn needs.
///
/// Uses `append_messages` when the turn was a pure append (final transcript
/// starts with the same prefix that was loaded plus the new input); otherwise
/// falls back to a full save and resets the per-session cursor. The cursor is
/// always advanced to the final transcript length on success.
async fn AgentRuntime::save_turn_transcript(
  self : AgentRuntime,
  session_id : String,
  transcript : @kernel.Transcript,
  metadata : Map[String, Json],
  initial_messages : Array[@kernel.Message],
  current_turn_start : Int,
) -> Unit raise @error.AgentError {
  let final_messages = snapshot_messages(transcript.messages_snapshot())
  let metadata = self.metadata_with_context_state(session_id, metadata)
  let cursor = match self.session_cursors.get(session_id) {
    Some(n) => n
    None => 0
  }
  let operation = transcript_save_operation(
    transcript, initial_messages, current_turn_start,
  )
  if operation == "final_append" {
    // Append tail from cursor. Each store receives its own deep snapshot of
    // the tail so a misbehaving store cannot mutate another store's payload.
    let save_results : Array[Result[Unit, @error.SessionError]] = @async.all(
      self.sessions.map(fn(store) {
        () => {
          let tail = snapshot_messages(final_messages[cursor:].to_owned())
          Ok(store.append_messages(session_id, cursor, tail[:])) catch {
            error => Err(error)
          }
        }
      }),
    ) catch {
      error => raise save_error_context(error, session_id, "final_append")
    }
    for result in save_results {
      match result {
        Err(error) =>
          raise contextualize_session_error(error, session_id, "final_append")
        Ok(_) => ()
      }
    }
  } else {
    // Rewrite, fork, or compact: rewrite the whole persisted session.
    self.save_sessions_all(session_id, final_messages, metadata, "final_save")
  }
  self.session_cursors[session_id] = final_messages.length()
}

///|
fn failed_save_cause_label(error : @error.AgentError) -> String {
  match error {
    Session(_) => "SessionError::Save"
    Model(_) => "AgentError::Model"
    Runtime(_) => "AgentError::Runtime"
    ToolLoopExceeded(..) => "AgentError::ToolLoopExceeded"
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
  let metadata = snapshot_metadata(metadata)
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
  match self.body_recovery.get(session_id) {
    Some(pending) => {
      self.save_sessions_all(
        session_id,
        pending.messages,
        pending.metadata,
        "compact_recovery_save",
      )
      self.body_recovery.remove(session_id)
      pending
    }
    None =>
      match self.sessions {
        [first, ..] =>
          first.load(session_id) catch {
            error =>
              raise contextualize_session_error(error, session_id, "load")
          }
        [] =>
          raise contextualize_session_error(
            Load("no session store configured"),
            session_id,
            "load",
          )
      }
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
  let out = messages.copy()
  for message in messages {
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
                  message="tool call was pending when the operation ended; recorded as interrupted before compaction",
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

///|
async fn AgentRuntime::compact_session(
  self : AgentRuntime,
  session_id : String,
) -> @types.CompactOutcome raise @error.AgentError {
  if self.turn_active {
    raise Runtime(InvocationFailed("agent turn busy"))
  }
  self.turn_active = true
  let result : Result[@types.CompactOutcome, @error.AgentError] = Ok(
    self.run_compact_operation(session_id),
  ) catch {
    error => Err(error)
  }
  self.turn_active = false
  match result {
    Ok(value) => value
    Err(error) => raise error
  }
}

///|
#warnings("-fragile_catch_all")
async fn AgentRuntime::run_compact_operation(
  self : AgentRuntime,
  session_id : String,
) -> @types.CompactOutcome raise @error.AgentError {
  self.ensure_agent_running()
  self.notify_start_if_first()
  let identity = self.mint_turn_identity(session_id)
  let scope = identity.scope()
  let session = self.load_session_for_operation(session_id)
  self.session_cursors[session_id] = session.messages.length()
  match @types.ContextState::from_metadata(session.metadata) {
    Some(state) =>
      match self.puppet.session_context_state(session_id) {
        Some(_) => ()
        None => self.puppet.adopt_context_state(session_id, state)
      }
    None => ()
  }
  self.project_context_state(Some(scope), session_id)
  let messages = fixate_pending_tool_calls(snapshot_messages(session.messages))
  let live = self.model.provider_config()
  let policy : @puppetry.RunPolicy = {
    model_id: "agent",
    call_options: self.config.to_call_options_json(),
    budget: {
      max_model_steps: None,
      max_tool_rounds: self.config.max_tool_rounds,
      max_tool_calls: None,
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
  self.emit_turn_event(Some(scope), CompactStarted(trigger="manual"))
  let prompt_result = self.puppet.compact_standalone(
    identity.run_id,
    identity.turn_id,
    identity.session_id,
    messages,
    policy,
    "agent_compact_session_\{identity.seq}",
    Manual,
  ) catch {
    e =>
      if @async.is_cancellation_error(e) {
        self.emit_turn_event(
          Some(scope),
          OperationFinalized(
            operation="compact",
            outcome="cancelled",
            detail="compact cancelled",
          ),
        )
        raise @error.AgentError::Cancelled("compact cancelled")
      } else {
        raise Runtime(
          InvocationFailed("puppet compact: " + safe_error_label(e.to_string())),
        )
      }
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
      raise @error.AgentError::Cancelled("compact cancelled")
    }
    Rejected(error~) => {
      let detail = safe_error_label(error.to_string())
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
              let new_session : @types.Session = {
                messages: snapshot_messages(compacted_messages),
                metadata: Map::from_array([]),
              }
              let with_lineage = new_session.with_parent_thread_id(session_id)
              self.save_sessions_all(
                new_sid,
                with_lineage.messages,
                with_lineage.metadata,
                "compact_newthread_save",
              )
              self.session_cursors[new_sid] = with_lineage.messages.length()
              let redirect : @types.TurnEvent = SessionRedirect(
                from=session_id,
                to=new_sid,
                messages_before=compacted_messages.length(),
                messages_after=compacted_messages.length(),
              )
              for observer in self.observers {
                observer.on_event_at(Some(scope), snapshot_turn_event(redirect))
              }
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
        Replace | Append => {
          let updated_metadata = self.metadata_with_context_state(
            session_id,
            session.metadata,
          )
          let updated_session : @types.Session = {
            messages: snapshot_messages(compacted_messages),
            metadata: updated_metadata,
          }
          let saved : Result[Unit, Error] = Ok(
            self.save_sessions_all(
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
              self.body_recovery[session_id] = updated_session
              self.emit_turn_event(
                Some(scope),
                OperationFinalized(
                  operation="compact",
                  outcome="failed",
                  detail="journal committed; body save failed; next operation repairs the projection",
                ),
              )
              raise contextualize_session_error(
                @error.Conflict(
                  "compact committed but body save failed; session needs recovery",
                ),
                session_id,
                "compact_body_save",
              )
            }
            Ok(_) => ()
          }
          self.body_recovery.remove(session_id)
          self.session_cursors[session_id] = updated_session.messages.length()
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
