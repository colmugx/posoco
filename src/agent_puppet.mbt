///|
/// M3.7 — Agent.run_turn Puppet wrapper (canonical-only).
///
/// R3 M3.7 reset: with ModelPort::chat returning `ModelCallResult` and
/// `Session.messages` carrying `@kernel.Message` directly, there is no more
/// legacy ↔ canonical conversion. The wrapper:
///   1. loads the session (canonical messages),
///   2. appends the input message,
///   3. builds the catalog (owner/policy synthesis happens here),
///   4. drives one Puppet prompt,
///   5. reconstructs the legacy observer event order from the final
///      transcript (ToolCallPending / ToolCallResult / ModelResponseReceived),
///   6. saves the session (write-all),
///   7. returns TurnResult.
///
/// Event projection: the wrapper translates the final transcript into the
/// `TurnEvent` stream observers depend on. `ModelResponseReceived` is
/// projected per AssistantMessage; tool calls are paired with subsequent
/// ToolMessage entries to emit ToolCallPending + ToolCallResult in legacy
/// order.

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
/// Build a `ToolCatalogSnapshot` from the agent's aggregated tool providers.
/// All tools are pinned to `Parallel` execution policy (matching the legacy
/// `@async.all`-every-batch behaviour). Owner is derived from the ToolDef's
/// own `owner` field if it is non-placeholder, else from provenance, else
/// `legacy_provider`.
fn Agent::build_catalog(
  self : Agent,
) -> @kernel.ToolCatalogSnapshot raise @error.AgentError {
  let builder = @kernel.ToolCatalogBuilder()
  for provider in self.tool_routing.providers {
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
      let def = @kernel.ToolDef(
        name=tool.name,
        description=tool.description,
        input_schema=normalize_tool_schema(tool.input_schema),
        owner~,
        policy=@kernel.Parallel,
        provenance=tool.provenance,
      )
      try {
        let _ = builder.add(def)
      } catch {
        e =>
          raise @error.AgentError::Runtime(
            @error.RuntimeError::InvocationFailed(
              "catalog add '\{tool.name.to_string()}': " +
              safe_error_label(e.to_string()),
            ),
          )
      }
    }
  }
  builder.finish(version=@kernel.CatalogVersion(1)) catch {
    e =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "catalog finish: " + safe_error_label(e.to_string()),
        ),
      )
  }
}

///|
/// Event subscriber placeholder. M3.6 reconstruction: the legacy event order
/// (MRR → ToolCallPending → ToolCallResult → MRR) cannot be preserved via
/// the kernel event stream because the reducer batches ModelStepCompleted +
/// ToolBatchStarted in one commit. So this subscriber is a no-op for event
/// projection; the wrapper reconstructs the full sequence from the final
/// transcript at turn end. It exists only to satisfy PuppetConfig.subscribers.
pub struct LegacyEventProjector {
  observers : Array[&@port.Observer]
}

///|
pub fn LegacyEventProjector::LegacyEventProjector(
  observers : Array[&@port.Observer],
) -> LegacyEventProjector {
  { observers, }
}

///|
pub impl @puppetry.EventSubscriber for LegacyEventProjector with fn subscriber_id(
  _self : LegacyEventProjector,
) -> String {
  "legacy_event_projector"
}

///|
pub impl @puppetry.EventSubscriber for LegacyEventProjector with fn provenance(
  _self : LegacyEventProjector,
) -> String {
  "m3_7_projection"
}

///|
pub impl @puppetry.EventSubscriber for LegacyEventProjector with fn on_event(
  _self : LegacyEventProjector,
  _envelope : @puppetry.EventEnvelope,
) -> Unit raise @puppetry.SubscriberError {
  ()
}

///|
/// Wrap the puppet's `HostChunkCallback` so each JSON chunk is decoded back
/// to a `@types.StreamChunk` and re-emitted to observers as
/// `StreamChunkReceived`. The JSON shape is a private contract between the
/// modelport and this wrapper; we recognise the same `{kind, token}` layout
/// PortHostAdapter and ScriptedModel emit.
fn Agent::create_stream_callback(self : Agent) -> @kernel.HostChunkCallback? {
  if self.observers.is_empty() {
    return None
  }
  let observers = self.observers
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
/// Drive one full turn through the Puppet. Steps:
/// 1. load session
/// 2. snapshot session.messages (deep copy) + append input
/// 3. build catalog (owner/policy synthesis)
/// 4. PortHostAdapter → HostRuntime
/// 5. construct Puppet, drive one prompt
/// 6. translate non-Accepted PromptResult → AgentError
/// 7. reconstruct observer event order from the final transcript
/// 8. save session (write-all)
/// 9. return TurnResult
async fn Agent::run_turn_via_puppet(
  self : Agent,
  input : @kernel.Message,
  session_id : String,
) -> @types.TurnResult raise @error.AgentError {
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
  messages.push(agent_snapshot_message(input))
  let current_metadata = agent_snapshot_metadata(session.metadata)

  // Step 3: catalog.
  let catalog = self.build_catalog()

  // Step 4: PortHostAdapter as HostRuntime.
  let host_adapter = PortHostAdapter::from_agent(self)
  let host : &@kernel.HostRuntime = host_adapter as &@kernel.HostRuntime

  // Step 5: journal + subscriber + Puppet.
  let journal = InMemoryJournal()
  let projector = LegacyEventProjector(self.observers)
  let call_options = self.config.to_chat_options_to_json()
  // M3.5: pass the agent's command ports (the BuiltinCommandPort and any
  // extension-provided commands) plus a session store reference so the
  // pump can fork/compact. The first session store (if any) is the
  // canonical persistence target — write-all semantics belong to the
  // agent wrapper, but the pump only needs ONE store for fork to write
  // the new session lineage.
  let session_store_ref : &@port.SessionStore? = match self.sessions {
    [first, ..] => Some(first)
    [] => None
  }
  let puppet_config : @puppetry.PuppetConfig = {
    host,
    model_id: "legacy_agent",
    catalog,
    journal,
    contributors: [],
    subscribers: [projector as &@puppetry.EventSubscriber],
    observers: self.observers,
    lifecycle_nodes: [],
    stream_chunks: self.create_stream_callback(),
    pre_model_hooks: self.pre_model_hooks,
    pre_tool_hooks: self.pre_tool_hooks,
    post_event_hooks: self.post_event_hooks,
    call_options,
    default_budget: @kernel.Budget::default_run(),
    max_iterations: self.config.max_tool_rounds + 1,
    commands: self.commands_with_builtins(),
    session_store: session_store_ref,
    context_window: self.config.model_context_window,
    compact_threshold: 0.9,
    mailbox: self.mailbox as &@puppetry.Mailbox,
  }
  let puppet = @puppetry.Puppet(puppet_config)
  puppet.startup() catch {
    e =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "puppet startup: " + safe_error_label(e.to_string()),
        ),
      )
  }

  // Step 6: drive one prompt.
  let run_id = @kernel.RunId::unchecked("agent_run")
  let turn_id = @puppetry.TurnId::unchecked("agent_turn")
  let session_id_kernel = @kernel.SessionId::unchecked(session_id)
  let prompt_result = puppet.prompt(
    run_id, turn_id, session_id_kernel, messages, "agent_run_turn",
  ) catch {
    e =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "puppet prompt: " + safe_error_label(e.to_string()),
        ),
      )
  }

  // Step 6b: handle non-Accepted prompt results.
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
      match puppet.last_terminal_outcome() {
        Some(@kernel.Failed(reason=@kernel.ModelTransport(detail~))) =>
          raise @error.AgentError::Model("model transport: " + detail)
        Some(@kernel.Failed(reason=@kernel.ModelParseFailure(detail~))) =>
          raise @error.AgentError::Model("model parse failure: " + detail)
        Some(@kernel.Failed(reason=@kernel.ModelRuntime(detail~))) =>
          raise @error.AgentError::Model("model runtime failure: " + detail)
        Some(@kernel.Failed(reason=@kernel.BudgetExhausted(..))) =>
          raise @error.AgentError::ToolLoopExceeded
        Some(@kernel.Failed(..)) =>
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

  // Step 7: reconstruct observer event order from the final transcript.
  //
  // Observer event sequence:
  //   TurnStarted (already emitted by outer run_turn)
  //   For each AssistantMessage:
  //     ModelResponseReceived (the assistant message)
  //     For each tool_call in the message:
  //       ToolCallPending
  //       ToolCallResult (matched to subsequent ToolMessage by call_id)
  //   TurnCompleted (already emitted by outer run_turn)
  let final_transcript = match puppet.last_completed_transcript() {
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
  let mut i = 0
  let n = transcript_msgs.length()
  while i < n {
    let cm = transcript_msgs[i]
    match cm {
      @kernel.AssistantMessage(content~, tool_calls~, reasoning~, ..) => {
        let _ = content
        let projected_mrr : @types.TurnEvent = ModelResponseReceived(
          message=cm,
          usage=None,
        )
        for observer in self.observers {
          observer.on_event(agent_snapshot_turn_event(projected_mrr))
        }
        final_message = cm
        // For each tool call, find the matching ToolMessage and emit
        // ToolCallPending + ToolCallResult in legacy order.
        for tc in tool_calls {
          let pending : @types.TurnEvent = ToolCallPending(tc)
          for observer in self.observers {
            observer.on_event(agent_snapshot_turn_event(pending))
          }
          let mut found_outcome : @kernel.ToolOutcome? = None
          let mut j = i + 1
          while j < n {
            match transcript_msgs[j] {
              @kernel.ToolMessage(call_id~, outcome~, ..) =>
                if call_id.to_string() == tc.call_id.to_string() {
                  found_outcome = Some(outcome)
                  break
                }
              _ => ()
            }
            j = j + 1
          }
          let outcome = match found_outcome {
            Some(o) => o
            None =>
              @kernel.RuntimeFailure(
                error_category="MissingToolOutcome",
                message="no ToolMessage for call " + tc.call_id.to_string(),
              )
          }
          let result_event : @types.TurnEvent = @types.TurnEvent::tool_call_result(
            tc, outcome,
          )
          for observer in self.observers {
            observer.on_event(agent_snapshot_turn_event(result_event))
          }
          all_results.push(outcome)
        }
        let _ = reasoning
      }
      @kernel.ToolMessage(..) => () // Already paired above.
      _ => ()
    }
    i = i + 1
  }

  // Step 8: save session (write-all, with carried metadata).
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

  // Step 9: build TurnResult.
  let result : @types.TurnResult = {
    message: final_message,
    tool_results: all_results,
    final_session_id: session_id,
  }
  result
}
