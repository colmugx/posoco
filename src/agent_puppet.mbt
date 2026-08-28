///|
/// Agent-owned Puppet composition and per-prompt projection.
///
/// Composition-static state is built exactly once in `Agent::Agent`: catalog,
/// HostRuntime adapter, journal, committed-event subscriber, mailbox and
/// Puppet. This file only creates per-prompt identities and `RunPolicy` data.

///|
/// Normalise a tool schema into the canonical form the Kernel catalog
/// accepts. The Kernel requires a JSON object (`{"type":"object",...}`) or a
/// boolean at the top level; providers often pass `Json::null()` to signal
/// "no schema". We convert `null` → empty object so providers keep working
/// without each one having to construct `{}`.
fn normalize_tool_schema(schema : Json) -> Json {
  match schema {
    Json::Null => Json::object(Map::from_array([]))
    other => other
  }
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
/// Build a `ToolCatalogSnapshot` from canonical definitions. Used both for
/// the port-derived catalog (at composition) and for `CatalogSource`
/// refreshes (at prompt boundaries, with a bumped version). The schema is
/// normalised into the Kernel's required object/boolean form; `owner` and
/// `policy` are taken verbatim from each definition.
fn build_catalog_from_defs(
  defs : Array[@kernel.ToolDef],
  version : @kernel.CatalogVersion,
) -> @kernel_exec.ToolCatalogSnapshot raise @error.CompositionError {
  let builder = @kernel_exec.ToolCatalogBuilder()
  for tool in defs {
    let def = @kernel.ToolDef(
      name=tool.name,
      description=tool.description,
      input_schema=normalize_tool_schema(tool.input_schema),
      owner=tool.owner,
      policy=tool.policy,
      provenance=tool.provenance,
    )
    try {
      let _ = builder.add(def)
    } catch {
      e =>
        raise @error.CompositionError::ManifestSchemaError(
          manifest_id="agent.catalog",
          detail="catalog add '\{tool.name.to_string()}': " +
            safe_error_label(e.to_string()),
        )
    }
  }
  builder.finish(version~) catch {
    e =>
      raise @error.CompositionError::ManifestSchemaError(
        manifest_id="agent.catalog",
        detail="catalog finish: " + safe_error_label(e.to_string()),
      )
  }
}

///|
/// Build a `ToolCatalogSnapshot` from the agent's aggregated tool providers.
/// Each tool's declared `policy` is honored as-is (M1-T06: declarations
/// select behavior through stable composition contracts); providers that do
/// not care declare `Parallel`, the legacy `@async.all`-every-batch default.
/// Owner is derived from the ToolDef's own `owner` field if it is
/// non-placeholder, else from provenance, else `legacy_provider`.
fn build_agent_catalog(
  providers : Array[&@port.ToolProvider],
) -> @kernel_exec.ToolCatalogSnapshot raise @error.CompositionError {
  let defs : Array[@kernel.ToolDef] = []
  for provider in providers {
    for tool in provider.list_tools() {
      let owner_str = tool.owner.to_string()
      let owner : @kernel.OwnerId = if owner_str == "placeholder" ||
        owner_str == "" {
        match tool.provenance {
          Some(p) if p != "" => @kernel.OwnerId::unchecked(p)
          _ => @kernel.OwnerId::unchecked("legacy_provider")
        }
      } else {
        tool.owner
      }
      defs.push(
        @kernel.ToolDef(
          name=tool.name,
          description=tool.description,
          input_schema=tool.input_schema,
          owner~,
          policy=tool.policy,
          provenance=tool.provenance,
        ),
      )
    }
  }
  build_catalog_from_defs(defs, @kernel.CatalogVersion(1))
}

///|
/// Agent-facing projection of committed Puppet envelopes. It never scans a
/// final transcript. The pending call cache is correlation state populated by
/// `ToolBatchStarted` and consumed by `ToolCompleted`.
priv struct AgentEventSubscriber {
  observers : Array[&@port.Observer]
  pending_calls : Map[String, @kernel.ToolCall]
  chunk_dispatcher : Ref[ChunkDispatcher?]
}

///|
fn AgentEventSubscriber::AgentEventSubscriber(
  observers : Array[&@port.Observer],
  chunk_dispatcher : Ref[ChunkDispatcher?],
) -> AgentEventSubscriber {
  { observers, pending_calls: Map::from_array([]), chunk_dispatcher, }
}

///|
impl @puppetry.EventSubscriber for AgentEventSubscriber with fn subscriber_id(
  _self : AgentEventSubscriber,
) -> String {
  "agent_committed_event_projection"
}

///|
impl @puppetry.EventSubscriber for AgentEventSubscriber with fn provenance(
  _self : AgentEventSubscriber,
) -> String {
  "posoco.agent"
}

///|
fn AgentEventSubscriber::emit(
  self : AgentEventSubscriber,
  scope : @types.EventScope?,
  event : @types.TurnEvent,
) -> Unit {
  // Piggyback flush: catch up buffered chunk telemetry before every committed
  // event so observers see chunks before ModelResponseReceived, ToolCallPending,
  // etc., and so they catch up at boundaries during an unbroken SSE burst.
  match self.chunk_dispatcher.val {
    Some(dispatcher) => dispatcher.flush()
    None => ()
  }
  for observer in self.observers {
    observer.on_event_at(scope, agent_snapshot_turn_event(event))
  }
}

///|
impl @puppetry.EventSubscriber for AgentEventSubscriber with fn on_event(
  self : AgentEventSubscriber,
  envelope : @puppetry.EventEnvelope,
) -> Unit raise @puppetry.SubscriberError {
  let event = envelope.event()
  // Envelope-projected events always carry the envelope's run identity as
  // their attribution scope.
  let scope : @types.EventScope = {
    session_id: envelope.session_id(),
    run_id: envelope.run_id(),
    turn_id: envelope.turn_id(),
  }
  match event {
    @kernel_exec.RunStarted(..) => self.pending_calls.clear()
    @kernel_exec.ModelStepCompleted(completion~, ..) => {
      let payload = completion.message
      let message : @kernel.Message = @kernel.AssistantMessage(
        content=payload.content,
        tool_calls=payload.tool_calls,
        reasoning=payload.reasoning,
        finish_reason=payload.finish_reason,
      )
      self.emit(
        Some(scope),
        @types.ModelResponseReceived(message~, usage=completion.usage),
      )
    }
    @kernel_exec.ToolBatchStarted(calls~, ..) =>
      for call in calls {
        let snapshot = agent_snapshot_tool_call(call)
        self.pending_calls[snapshot.call_id.to_string()] = snapshot
        self.emit(Some(scope), @types.ToolCallPending(snapshot))
      }
    @kernel_exec.ToolCompleted(call_id~, outcome~) => {
      let key = call_id.to_string()
      let call = match self.pending_calls.get(key) {
        Some(call) => call
        None =>
          raise @puppetry.SubscriberError::ContractViolation(
            subscriber_id="agent_committed_event_projection",
            detail="ToolCompleted without committed ToolBatchStarted for call " +
              key,
          )
      }
      self.pending_calls.remove(key)
      self.emit(Some(scope), @types.TurnEvent::tool_call_result(call, outcome))
    }
    _ => ()
  }
}

///|
/// Wrap the puppet's `HostChunkCallback` so each `StreamChunk` is re-emitted
/// to observers as `StreamChunkReceived`. The chunk is already the canonical
/// typed shape; no JSON decoding is needed here.
fn create_agent_stream_callback(
  observers : Array[&@port.Observer],
  dispatcher_ref : Ref[ChunkDispatcher?],
) -> @kernel_exec.HostChunkCallback? {
  if observers.is_empty() {
    return None
  }
  let cb = fn(chunk : @types.StreamChunk) {
    // Route to the active turn's dispatcher. If no turn is active (should not
    // happen for chunks produced by the Puppet), drop silently.
    match dispatcher_ref.val {
      Some(dispatcher) => dispatcher.enqueue(chunk)
      None => ()
    }
  }
  Some(cb)
}

///|
/// Catalog refresh at a prompt boundary (experimental runtime seam). With
/// no `CatalogSource` wired this is a no-op and the catalog stays the
/// static composition snapshot. Otherwise a changed `revision()` triggers
/// exactly one rebuild attempt:
/// - success → the new snapshot (next monotonic catalog version) is swapped
///   into the Puppet; subsequent runs see it, in-flight runs never do;
/// - validation failure or a busy pump → the previous snapshot stays in
///   effect and the failure is surfaced as a `secondary_failure` observer
///   event. The turn is never aborted by a catalog problem.
/// The revision tracker advances on every attempt, so a deterministically
/// bad definition set is not re-validated (and re-reported) on every turn;
/// the source retries by changing `revision()` again.
fn AgentRuntime::refresh_catalog_if_changed(self : AgentRuntime) -> Unit {
  match self.catalog_source {
    None => ()
    Some(source) => {
      let revision = source.revision()
      if revision == self.last_catalog_revision {
        return
      }
      self.last_catalog_revision = revision
      let version = @kernel.CatalogVersion(self.next_catalog_version)
      let snapshot = build_catalog_from_defs(source.tools(), version) catch {
        error => {
          emit_secondary_failure(
            self.observers,
            "catalog_refresh",
            "catalog revision \{revision} rejected: " +
            safe_error_label(error.to_string()),
          )
          return
        }
      }
      if self.puppet.replace_catalog(snapshot) {
        self.next_catalog_version = self.next_catalog_version + 1
      } else {
        emit_secondary_failure(
          self.observers,
          "catalog_refresh",
          "catalog revision \{revision} deferred: a run is active",
        )
      }
    }
  }
}

///|
/// Per-turn identity minted by the Agent before `TurnStarted` is projected,
/// so every turn event — including the first — carries attribution scope.
/// The same identity drives the Puppet prompt request.
priv struct TurnIdentity {
  seq : Int
  run_id : @kernel.RunId
  turn_id : @kernel.TurnId
  session_id : @kernel.SessionId
}

///|
/// Allocate the next unique run/turn identity. The counter is Agent-owned
/// and monotonic, so two calls on the same Agent never share run/turn ids
/// while still using the same Puppet and journal.
fn AgentRuntime::mint_turn_identity(
  self : AgentRuntime,
  session_id : String,
) -> TurnIdentity {
  let seq = self.next_run_seq
  self.next_run_seq = seq + 1
  {
    seq,
    run_id: @kernel.RunId::unchecked("agent_run_\{seq}"),
    turn_id: @kernel.TurnId::unchecked("agent_turn_\{seq}"),
    session_id: @kernel.SessionId::unchecked(session_id),
  }
}

///|
/// The attribution scope projected onto this turn's observer events.
fn TurnIdentity::scope(self : TurnIdentity) -> @types.EventScope {
  { session_id: self.session_id, run_id: self.run_id, turn_id: self.turn_id, }
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
) -> @types.TurnResult raise @error.AgentError {
  // Step 0: catalog refresh at the prompt boundary. No run is active yet,
  // so a swap cannot disturb an in-flight run; a failed rebuild keeps the
  // previous snapshot and is surfaced as a secondary failure.
  self.refresh_catalog_if_changed()

  // Step 1: load session.
  let session = match self.sessions {
    [first, ..] =>
      first.load(session_id) catch {
        error => raise contextualize_session_error(error, session_id, "load")
      }
    [] =>
      raise contextualize_session_error(
        @error.SessionError::Load("no session store configured"),
        session_id,
        "load",
      )
  }
  // The loaded session is the authoritative persisted prefix for this turn.
  self.session_cursors[session_id] = session.messages.length()

  // Step 2: snapshot + append input. Deep-copy so callers cannot mutate
  // recorded state via the recorded arrays.
  let messages = agent_snapshot_messages(session.messages)
  let current_turn_start = messages.length()
  messages.push(agent_snapshot_message(input))
  let current_metadata = agent_snapshot_metadata(session.metadata)

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
    call_options: self.config.to_chat_options_to_json(),
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
  let dispatcher = ChunkDispatcher::new(self.observers)
  self.chunk_dispatcher.val = Some(dispatcher)
  // The typed error is captured inside the group closure and re-raised
  // after the boundary: `with_task_group`'s closure signature carries the
  // wide `Error` (no error type parameter), so capturing the typed value is
  // the only way the original `AgentError` variant — and its contextualized
  // messages — survives the crossing.
  let turn_error : Ref[@error.AgentError?] = Ref::Ref(None)
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
    _ => {
      self.chunk_dispatcher.val = None
      let original : @error.AgentError = match turn_error.val {
        Some(ae) => ae
        None =>
          @error.AgentError::Runtime(
            @error.RuntimeError::InvocationFailed(
              "turn body: unclassified error",
            ),
          )
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
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "puppet prompt: " + safe_error_label(e.to_string()),
        ),
      )
  }

  // A best-effort auto-compact that fired but failed (e.g. the modelport
  // does not implement compact) already let the turn continue; surface the
  // skip to observers here as a secondary failure.
  match self.puppet.take_last_auto_compact_failure() {
    Some(reason) =>
      emit_secondary_failure(self.observers, "auto_compact", reason)
    None => ()
  }

  // Step 5: handle non-Accepted prompt results.
  match prompt_result {
    @puppetry.Rejected(error=@puppetry.HookRejected(reason~)) =>
      raise @error.AgentError::PipelineAborted(reason)
    @puppetry.Rejected(error=@puppetry.PumpLoopExceeded(..)) =>
      // With a correctly sized backstop (2 * rounds + 1) the kernel budget
      // always fires first; reaching this branch means a livelock or an
      // internal accounting defect, not a budget hit.
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "pump loop exceeded (internal livelock guard)",
        ),
      )
    @puppetry.Rejected(error=@puppetry.ReducerInvariantViolation(..)) =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed("puppet invariant violation"),
      )
    @puppetry.Rejected(error=@puppetry.EffectExecutionFailed(cause~, ..)) =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "puppet effect execution: " + safe_error_label(cause),
        ),
      )
    @puppetry.Rejected(error~) =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "puppet rejected the prompt: " + error.to_string(),
        ),
      )
    @puppetry.ForkCompleted(
      run_id~,
      turn_id~,
      parent_session_id~,
      new_session_id~,
      forked_messages~
    ) => {
      // M3.5: fork creates a new session and stops the current turn. The
      // original thread is untouched; product code switches its active
      // thread to `new_session_id`. We persist the new session to every
      // configured store (write-all) and return a TurnResult whose
      // `final_session_id` is the ORIGINAL session — the caller stays on
      // the original thread because this `run_turn` was for the original.
      // The forked session is a sibling the caller can switch to next.
      let _ = run_id
      let _ = turn_id
      let forked_session : @types.Session = {
        messages: agent_snapshot_messages(forked_messages),
        metadata: Map::from_array([]),
      }
      let with_lineage = forked_session.with_parent_thread_id(parent_session_id)
      let fork_save_results : Array[Result[Unit, @error.SessionError]] = @async.all(
        self.sessions.map(fn(store) {
          () => {
            let session = agent_snapshot_session(
              with_lineage.messages,
              with_lineage.metadata,
            )
            Ok(store.save(new_session_id, session)) catch {
              error => Err(error)
            }
          }
        }),
      ) catch {
        error => raise save_error_context(error, new_session_id, "fork_save")
      }
      for result in fork_save_results {
        match result {
          Err(error) =>
            raise contextualize_session_error(
              error, new_session_id, "fork_save",
            )
          Ok(_) => ()
        }
      }
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
        observer.on_event_at(
          Some(identity.scope()),
          agent_snapshot_turn_event(redirect),
        )
      }
      let result : @types.TurnResult = {
        message: input,
        tool_results: [],
        final_session_id: parent_session_id,
      }
      return result
    }
    @puppetry.CompactCompleted(
      run_id~,
      turn_id~,
      mode~,
      trigger~,
      new_session_id~,
      compacted_messages~
    ) => {
      // M3.5: compact applied the modelport's CompactResult.
      // - NewThread: persist the new session, return TurnResult with the
      //   NEW final_session_id (the caller should switch active thread).
      // - Replace / Append: persist the current session with the updated
      //   transcript body, return TurnResult with the ORIGINAL
      //   final_session_id.
      let _ = run_id
      let _ = turn_id
      let _ = trigger
      match mode {
        @kernel.NewThread =>
          match new_session_id {
            Some(new_sid) => {
              let new_session : @types.Session = {
                messages: agent_snapshot_messages(compacted_messages),
                metadata: Map::from_array([]),
              }
              let with_lineage = new_session.with_parent_thread_id(session_id)
              let compact_save_results : Array[
                Result[Unit, @error.SessionError],
              ] = @async.all(
                self.sessions.map(fn(store) {
                  () => {
                    let session = agent_snapshot_session(
                      with_lineage.messages,
                      with_lineage.metadata,
                    )
                    Ok(store.save(new_sid, session)) catch {
                      error => Err(error)
                    }
                  }
                }),
              ) catch {
                error =>
                  raise save_error_context(
                    error, new_sid, "compact_newthread_save",
                  )
              }
              for result in compact_save_results {
                match result {
                  Err(error) =>
                    raise contextualize_session_error(
                      error, new_sid, "compact_newthread_save",
                    )
                  Ok(_) => ()
                }
              }
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
                  agent_snapshot_turn_event(redirect),
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
              raise @error.AgentError::Runtime(
                @error.RuntimeError::InvocationFailed(
                  "CompactCompleted::NewThread without new_session_id",
                ),
              )
          }
        @kernel.Replace | @kernel.Append => {
          // Save the updated original session body. The product caller
          // stays on the same session id.
          let updated_session : @types.Session = {
            messages: agent_snapshot_messages(compacted_messages),
            metadata: agent_snapshot_metadata(current_metadata),
          }
          let compact_save_results : Array[Result[Unit, @error.SessionError]] = @async.all(
            self.sessions.map(fn(store) {
              () => {
                let session = agent_snapshot_session(
                  updated_session.messages,
                  updated_session.metadata,
                )
                Ok(store.save(session_id, session)) catch {
                  error => Err(error)
                }
              }
            }),
          ) catch {
            error =>
              raise save_error_context(
                error, session_id, "compact_replace_save",
              )
          }
          for result in compact_save_results {
            match result {
              Err(error) =>
                raise contextualize_session_error(
                  error, session_id, "compact_replace_save",
                )
              Ok(_) => ()
            }
          }
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
    @puppetry.Accepted(..) => {
      // Check terminal outcome for model failures.
      let failure : @error.AgentError? = match
        self.puppet.last_terminal_outcome() {
        Some(@kernel_exec.Failed(reason=@kernel_exec.ModelTransport(detail~))) =>
          Some(@error.AgentError::Model("model transport: " + detail))
        Some(
          @kernel_exec.Failed(reason=@kernel_exec.ModelParseFailure(detail~))
        ) => Some(@error.AgentError::Model("model parse failure: " + detail))
        Some(@kernel_exec.Failed(reason=@kernel_exec.ModelRuntime(detail~))) =>
          Some(@error.AgentError::Model("model runtime failure: " + detail))
        Some(
          @kernel_exec.Failed(
            reason=@kernel_exec.BudgetExhausted(
              dimension=@kernel_exec.BudgetDimension::ToolRounds
            )
          )
        ) =>
          // The reducer rejects exactly the batch that would push consumed
          // to limit + 1, so consumed is derivable; Agent only ever wires
          // the ToolRounds dimension (other budget dims are None here).
          match self.config.max_tool_rounds {
            Some(limit) =>
              Some(
                @error.AgentError::ToolLoopExceeded(consumed=limit + 1, limit~),
              )
            None =>
              Some(
                @error.AgentError::Runtime(
                  @error.RuntimeError::InvocationFailed(
                    "tool-round budget exhausted without a configured limit",
                  ),
                ),
              )
          }
        Some(@kernel_exec.Failed(reason=@kernel_exec.BudgetExhausted(..))) =>
          Some(
            @error.AgentError::Runtime(
              @error.RuntimeError::InvocationFailed("budget exhausted"),
            ),
          )
        Some(@kernel_exec.Failed(..)) =>
          Some(
            @error.AgentError::Runtime(
              @error.RuntimeError::InvocationFailed("run failed"),
            ),
          )
        _ => None
      }
      match failure {
        Some(err) => {
          // A failed turn still owns its transcript: the user input and any
          // completed progress must reach the session store, or the next turn
          // reloads pre-turn state and the model loses the context of what it
          // was doing — and what the user asked.
          match self.puppet.last_completed_transcript() {
            Some(t) =>
              self.save_turn_transcript(
                session_id,
                t,
                current_metadata,
                request.initial_messages,
                current_turn_start,
              ) catch {
                // The turn's own failure is the primary signal; a secondary
                // save failure must not mask it.
                _ => ()
              }
            None => ()
          }
          raise err
        }
        None => ()
      }
    }
    @puppetry.LeaseBusy(..) =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed("puppet lease busy"),
      )
  }

  // Step 6: materialize the terminal transcript for persistence and the
  // TurnResult. Observer projection already happened from committed envelopes;
  // this traversal has no side effects and only selects this turn's result.
  let final_transcript = match self.puppet.last_completed_transcript() {
    Some(t) => t
    None =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "puppet did not produce a terminal transcript",
        ),
      )
  }
  let transcript_msgs = final_transcript.messages_snapshot()
  let mut final_message : @kernel.Message = input
  let all_results : Array[@kernel.ToolOutcome] = []
  for i in current_turn_start..<transcript_msgs.length() {
    let message = transcript_msgs[i]
    match message {
      @kernel.AssistantMessage(..) => final_message = message
      @kernel.ToolMessage(outcome~, ..) => all_results.push(outcome)
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

  // Step 7: build TurnResult.
  let result : @types.TurnResult = {
    message: final_message,
    tool_results: all_results,
    final_session_id: session_id,
  }
  result
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
  let final_messages = agent_snapshot_messages(transcript.messages_snapshot())
  let cursor = match self.session_cursors.get(session_id) {
    Some(n) => n
    None => 0
  }
  let initial_len = current_turn_start + 1
  let is_pure_append = final_messages.length() >= initial_len &&
    messages_prefix_equal(final_messages, initial_messages, initial_len)
  if is_pure_append {
    // Append tail from cursor. Each store receives its own deep snapshot of
    // the tail so a misbehaving store cannot mutate another store's payload.
    let save_results : Array[Result[Unit, @error.SessionError]] = @async.all(
      self.sessions.map(fn(store) {
        () => {
          let tail = agent_snapshot_messages(final_messages[cursor:].to_owned())
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
    let save_results : Array[Result[Unit, @error.SessionError]] = @async.all(
      self.sessions.map(fn(store) {
        () => {
          // Each store receives its own deep snapshot so a misbehaving store
          // cannot mutate another store's persisted state.
          let session = agent_snapshot_session(final_messages, metadata)
          Ok(store.save(session_id, session)) catch {
            error => Err(error)
          }
        }
      }),
    ) catch {
      error => raise save_error_context(error, session_id, "final_save")
    }
    for result in save_results {
      match result {
        Err(error) =>
          raise contextualize_session_error(error, session_id, "final_save")
        Ok(_) => ()
      }
    }
  }
  self.session_cursors[session_id] = final_messages.length()
}
