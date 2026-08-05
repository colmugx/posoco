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
/// All tools are pinned to `Parallel` execution policy (matching the legacy
/// `@async.all`-every-batch behaviour). Owner is derived from the ToolDef's
/// own `owner` field if it is non-placeholder, else from provenance, else
/// `legacy_provider`.
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
          policy=@kernel.Parallel,
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
}

///|
fn AgentEventSubscriber::AgentEventSubscriber(
  observers : Array[&@port.Observer],
) -> AgentEventSubscriber {
  { observers, pending_calls: Map::from_array([]) }
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
  event : @types.TurnEvent,
) -> Unit {
  for observer in self.observers {
    observer.on_event(agent_snapshot_turn_event(event))
  }
}

///|
impl @puppetry.EventSubscriber for AgentEventSubscriber with fn on_event(
  self : AgentEventSubscriber,
  envelope : @puppetry.EventEnvelope,
) -> Unit raise @puppetry.SubscriberError {
  let event = envelope.event()
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
      self.emit(@types.ModelResponseReceived(message~, usage=completion.usage))
    }
    @kernel_exec.ToolBatchStarted(calls~, ..) =>
      for call in calls {
        let snapshot = agent_snapshot_tool_call(call)
        self.pending_calls[snapshot.call_id.to_string()] = snapshot
        self.emit(@types.ToolCallPending(snapshot))
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
      self.emit(@types.TurnEvent::tool_call_result(call, outcome))
    }
    _ => ()
  }
}

///|
/// Wrap the puppet's `HostChunkCallback` so each JSON chunk is decoded back
/// to a `@types.StreamChunk` and re-emitted to observers as
/// `StreamChunkReceived`. The JSON shape is a private contract between the
/// modelport and this wrapper; we recognise the same `{kind, token}` layout
/// `PortRuntime` and ScriptedModel emit.
fn create_agent_stream_callback(
  observers : Array[&@port.Observer],
) -> @kernel_exec.HostChunkCallback? {
  if observers.is_empty() {
    return None
  }
  let cb = fn(json_chunk : Json) {
    let chunk : @types.StreamChunk = match json_chunk {
      Json::Object(map) =>
        if map.contains("kind") {
          let kind = map["kind"]
          match kind {
            Json::String(v) if v == "text" =>
              if map.contains("token") {
                match map["token"] {
                  Json::String(t) => @types.TextDelta(token=t)
                  _ => @types.TextDelta(token="")
                }
              } else {
                @types.TextDelta(token="")
              }
            Json::String(v) if v == "reasoning" =>
              if map.contains("token") {
                match map["token"] {
                  Json::String(t) => @types.ReasoningDelta(token=t)
                  _ => @types.ReasoningDelta(token="")
                }
              } else {
                @types.ReasoningDelta(token="")
              }
            _ =>
              // ToolCallDelta, Usage, Finish — lossy serialization;
              // emit as generic TextDelta for observer event count.
              @types.TextDelta(token="")
          }
        } else {
          @types.TextDelta(token="")
        }
      _ => @types.TextDelta(token="")
    }
    let event : @types.TurnEvent = @types.StreamChunkReceived(chunk~)
    for observer in observers {
      observer.on_event(event)
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
/// Drive one full turn through the Puppet. Steps:
/// 0. refresh the catalog when a CatalogSource's revision changed
/// 1. load session
/// 2. snapshot session.messages (deep copy) + append input
/// 3. allocate unique run/turn identities and capture a per-prompt RunPolicy
/// 4. drive the Agent-owned long-lived Puppet
/// 5. translate non-Accepted PromptResult → AgentError
/// 6. materialize and save the canonical terminal transcript (write-all)
/// 7. return TurnResult
async fn AgentRuntime::run_turn_via_puppet(
  self : AgentRuntime,
  input : @kernel.Message,
  session_id : String,
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

  // Step 2: snapshot + append input. Deep-copy so callers cannot mutate
  // recorded state via the recorded arrays.
  let messages = agent_snapshot_messages(session.messages)
  let current_turn_start = messages.length()
  messages.push(agent_snapshot_message(input))
  let current_metadata = agent_snapshot_metadata(session.metadata)

  // Step 3: per-prompt identity and policy. The counter is Agent-owned and
  // monotonic, so two calls on the same Agent never share run/turn ids while
  // still using the same Puppet and journal.
  let seq = self.next_run_seq
  self.next_run_seq = seq + 1
  let run_id = @kernel.RunId::unchecked("agent_run_\{seq}")
  let turn_id = @kernel.TurnId::unchecked("agent_turn_\{seq}")
  let session_id_kernel = @kernel.SessionId::unchecked(session_id)
  let budget : @kernel_exec.Budget = {
    max_model_steps: None,
    max_tool_rounds: Some(self.config.max_tool_rounds),
    max_tool_calls: None,
    max_total_tokens: None,
  }
  let policy : @puppetry.RunPolicy = {
    model_id: "agent",
    call_options: self.config.to_chat_options_to_json(),
    budget,
    context_window: self.config.model_context_window,
    compact_threshold: 0.9,
  }
  let request : @puppetry.PromptRequest = {
    run_id,
    turn_id,
    session_id: session_id_kernel,
    initial_messages: messages,
    operation_id: "agent_run_turn_\{seq}",
    policy,
  }

  // Step 4: drive the already-started, Agent-owned Puppet.
  let prompt_result = self.puppet.prompt(request) catch {
    e =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "puppet prompt: " + safe_error_label(e.to_string()),
        ),
      )
  }

  // Step 5: handle non-Accepted prompt results.
  match prompt_result {
    @puppetry.Rejected(error=@puppetry.HookRejected(reason~)) =>
      raise @error.AgentError::HookAborted(reason)
    @puppetry.Rejected(error=@puppetry.PumpLoopExceeded(..)) =>
      raise @error.AgentError::ToolLoopExceeded
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
    @puppetry.Rejected(..) =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed("puppet rejected the prompt"),
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
      for store in self.sessions {
        store.save(new_session_id, with_lineage) catch {
          error =>
            raise contextualize_session_error(
              error, new_session_id, "fork_save",
            )
        }
      }
      // Emit a SessionRedirect so observers know a sibling thread was
      // created and can switch the UI.
      let redirect : @types.TurnEvent = SessionRedirect(
        from=parent_session_id,
        to=new_session_id,
        messages_before=forked_messages.length(),
        messages_after=forked_messages.length(),
      )
      for observer in self.observers {
        observer.on_event(agent_snapshot_turn_event(redirect))
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
              for store in self.sessions {
                store.save(new_sid, with_lineage) catch {
                  error =>
                    raise contextualize_session_error(
                      error, new_sid, "compact_newthread_save",
                    )
                }
              }
              let redirect : @types.TurnEvent = SessionRedirect(
                from=session_id,
                to=new_sid,
                messages_before=compacted_messages.length(),
                messages_after=compacted_messages.length(),
              )
              for observer in self.observers {
                observer.on_event(agent_snapshot_turn_event(redirect))
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
          for store in self.sessions {
            store.save(session_id, updated_session) catch {
              error =>
                raise contextualize_session_error(
                  error, session_id, "compact_replace_save",
                )
            }
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
    @puppetry.Accepted(..) =>
      // Check terminal outcome for model failures.
      match self.puppet.last_terminal_outcome() {
        Some(@kernel_exec.Failed(reason=@kernel_exec.ModelTransport(detail~))) =>
          raise @error.AgentError::Model("model transport: " + detail)
        Some(
          @kernel_exec.Failed(reason=@kernel_exec.ModelParseFailure(detail~))
        ) => raise @error.AgentError::Model("model parse failure: " + detail)
        Some(@kernel_exec.Failed(reason=@kernel_exec.ModelRuntime(detail~))) =>
          raise @error.AgentError::Model("model runtime failure: " + detail)
        Some(@kernel_exec.Failed(reason=@kernel_exec.BudgetExhausted(..))) =>
          raise @error.AgentError::ToolLoopExceeded
        Some(@kernel_exec.Failed(..)) =>
          raise @error.AgentError::Runtime(
            @error.RuntimeError::InvocationFailed("run failed"),
          )
        _ => ()
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
  let saved_messages = agent_snapshot_messages(transcript_msgs)
  for store in self.sessions {
    store.save(
      session_id,
      agent_snapshot_session(saved_messages, current_metadata),
    ) catch {
      error =>
        raise contextualize_session_error(error, session_id, "final_save")
    }
  }

  // Step 7: build TurnResult.
  let result : @types.TurnResult = {
    message: final_message,
    tool_results: all_results,
    final_session_id: session_id,
  }
  result
}
