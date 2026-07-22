///|
/// Legacy-to-Kernel compatibility adapter (M1-T10).
///
/// ADR §5, §6: M1 does NOT delete the legacy `Agent::run_turn` (the M0
/// tutorial and supported extensions depend on it). Instead, this adapter
/// provides an OPT-IN path `run_turn_via_kernel` that drives a Run via the
/// pure reducer + scripted minimal driver.
///
/// What this adapter does NOT do (deferred to M2 / user sign-off):
/// - It does NOT replace `run_turn` as the default entry point.
/// - It does NOT preserve every M0 observer event shape (KNOWN gap — emits
///   only KernelEvents, ADR §7 open-question Q6.5).
/// - It does NOT yet map legacy @port.PipelineHook / @port.Compressor into the reducer.
///
/// The adapter unifies all error paths into a single `KernelFacadeError`
/// type because MoonBit functions can raise only one error type at a time.
/// Callers that need legacy @error.AgentError semantics can pattern-match on the
/// variants.

// ──────────────────────────────────────────────────────────────────────────
// Unified error type
// ──────────────────────────────────────────────────────────────────────────

///|
pub(all) suberror KernelFacadeError {
  /// Legacy session load/save error.
  SessionLoad(detail~ : String)
  SessionSave(detail~ : String)
  /// Catalog build failed at composition.
  CatalogComposition(failure~ : @kernel.CatalogCompositionError)
  /// Legacy ↔ canonical message conversion failed.
  ConversionFailed(detail~ : String)
  /// Kernel reducer declared an invariant that the adapter cannot translate.
  UntranslatedInvariant(category~ : @kernel.InvariantCategory)
  /// Driver exceeded its iteration safety bound.
  DriverLoopExceeded(iterations~ : Int)
  /// Kernel Run terminated in @kernel.Failed outcome.
  KernelFailed(reason~ : @kernel.FailureReason)
  /// Kernel Run terminated in @kernel.Cancelled outcome.
  KernelCancelled(reason~ : @kernel.CancelReason)
}

///|
pub impl Show for KernelFacadeError with fn to_string(self : KernelFacadeError) -> String {
  match self {
    SessionLoad(detail~) => "KernelFacadeError::SessionLoad(\{detail})"
    SessionSave(detail~) => "KernelFacadeError::SessionSave(\{detail})"
    CatalogComposition(failure~) =>
      "KernelFacadeError::CatalogComposition(\{failure.to_string()})"
    ConversionFailed(detail~) =>
      "KernelFacadeError::ConversionFailed(\{detail})"
    UntranslatedInvariant(category~) =>
      "KernelFacadeError::UntranslatedInvariant(\{category.to_string()})"
    DriverLoopExceeded(iterations~) =>
      "KernelFacadeError::DriverLoopExceeded(\{iterations})"
    KernelFailed(reason~) =>
      "KernelFacadeError::KernelFailed(\{reason.to_string()})"
    KernelCancelled(reason~) =>
      "KernelFacadeError::KernelCancelled(\{reason.to_string()})"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Public entry point
// ──────────────────────────────────────────────────────────────────────────

///|
/// Drive a single turn through the M1 Functional Kernel. Returns a legacy
/// `@types.TurnResult` for compatibility with M0 callers.
///
/// Known limitations vs M0 `run_turn`:
/// - No @port.PipelineHook / @port.Compressor / streaming chunk support.
/// - No @port.MemoryPort / @port.Lifecycle / @port.CommandPort integration.
/// - Tool execution is sequential via the scripted driver (not parallel).
/// - @port.Observer events are kernel-shaped (@kernel.RunStarted/@kernel.RunCompleted), not the
///   full M0 @types.TurnEvent set (see ADR §7 Q6.5 for the legacy-event question).
pub async fn Agent::run_turn_via_kernel(
  self : Agent,
  input : @types.Message,
  session_id : String,
) -> @types.TurnResult raise KernelFacadeError {
  // Step 1: load session (matches M0 first-store semantics).
  let legacy_session = match self.sessions {
    [first, ..] =>
      match first.load(session_id) {
        Ok(s) => s
        Err(error) =>
          raise SessionLoad(
            detail="session_id='\{safe_error_label(session_id)}', operation='load', cause='\{safe_error_label(error.to_string())}'",
          )
      }
    [] => raise SessionLoad(detail="no session store configured")
  }
  // Step 2: build canonical messages from legacy session + input.
  let canonical_initial : Array[@kernel.CanonicalMessage] = []
  for m in legacy_session.messages {
    canonical_initial.push(legacy_to_canonical_message(m))
  }
  canonical_initial.push(legacy_to_canonical_message(input))
  // Step 3: build catalog.
  let catalog = build_agent_catalog(self)
  // Step 4: build initial @kernel.RunState.
  let run_id = @kernel.RunId::unchecked("facade_" + session_id)
  let sess_id = @kernel.SessionId::unchecked(session_id)
  let budget = @kernel.Budget::from_legacy_rounds(self.config.max_tool_rounds)
  let initial_state = @kernel.RunState::initial(
    run_id~,
    session_id=sess_id,
    budget~,
  ) catch {
    e => raise ConversionFailed(detail="initial state: " + e.to_string())
  }
  // Step 5: drive with real executor.
  let final_state = drive_with_real_executor(
    self, initial_state, catalog, canonical_initial,
  )
  // Step 6: derive legacy result.
  let result = state_to_turn_result(final_state, session_id)
  // Step 7: save session(s) — write-all semantics.
  let new_messages = state_to_legacy_messages(final_state)
  for store in self.sessions {
    let saved_session : @types.Session = {
      messages: new_messages,
      metadata: copy_metadata(legacy_session.metadata),
    }

    match store.save(session_id, saved_session) {
      Ok(_) => ()
      Err(error) =>
        raise SessionSave(
          detail="session_id='\{safe_error_label(session_id)}', operation='final_save', cause='\{safe_error_label(error.to_string())}'",
        )
    }
  }
  result
}

// ──────────────────────────────────────────────────────────────────────────
// Internal helpers
// ──────────────────────────────────────────────────────────────────────────

///|
fn build_agent_catalog(
  agent : Agent,
) -> @kernel.ToolCatalogSnapshot raise KernelFacadeError {
  let builder = @kernel.ToolCatalogBuilder::new()
  for provider in agent.tool_routing.providers {
    for tool in provider.list_tools() {
      let owner_str = match tool.source {
        Some(s) if s != "" => s
        _ => "legacy_provider"
      }
      let def = @kernel.CanonicalToolDef::new(
        name=@kernel.ToolName::unchecked(tool.name),
        description=tool.description,
        input_schema=tool.input_schema,
        owner=@kernel.OwnerId::unchecked(owner_str),
        policy=@kernel.Parallel,
        provenance=tool.source,
      )
      try {
        let _ = builder.add(def)
      } catch {
        e => raise KernelFacadeError::CatalogComposition(failure=e)
      }
    }
  }
  builder.finish(version=@kernel.CatalogVersion::new(1)) catch {
    e => raise KernelFacadeError::CatalogComposition(failure=e)
  }
}

///|
async fn drive_with_real_executor(
  agent : Agent,
  initial_state : @kernel.RunState,
  catalog : @kernel.ToolCatalogSnapshot,
  initial_messages : Array[@kernel.CanonicalMessage],
) -> @kernel.RunState raise KernelFacadeError {
  let host = LegacyHostRuntime::from_agent(agent)
  let exec_ctx = @puppetry.ExecutionContext::new(
    host,
    model_id=@puppetry.ModelId::unchecked("legacy_model"),
    catalog~,
  )
  let start : @kernel.RunInput = @kernel.Start(payload=@kernel.StartPayload::{
    initial_messages: initial_messages.copy(),
    catalog_version: catalog.version(),
  })
  let out0 = @kernel.reduce(initial_state, catalog, start) catch {
    e => raise ConversionFailed(detail="reduce start: " + e.to_string())
  }
  let mut state = out0.next_state()
  emit_kernel_events(agent, out0.events(), state)
  let mut iter = 0
  let max_iter = 200
  while state.phase() != @kernel.Terminal && iter < max_iter {
    iter = iter + 1
    match state.phase() {
      @kernel.ReadyForModel => {
        let out_step : @kernel.ReduceOutput = @kernel.run_model_step(
          state,
          catalog,
          Json::null(),
        ) catch {
          e => raise ConversionFailed(detail="run_model_step: " + e.to_string())
        }
        state = out_step.next_state()
        emit_kernel_events(agent, out_step.events(), state)
        for eff in out_step.effects() {
          let input : @kernel.RunInput = @puppetry.execute_one(eff, exec_ctx, fn(
            _chunk : Json,
          ) {
            ()
          }) catch {
            e =>
              raise ConversionFailed(
                detail="execute_one post-effect: " + e.to_string(),
              )
          }
          // `input` already resolved above; @kernel.reduce() may raise, handle separately.
          let out_reduce : @kernel.ReduceOutput = @kernel.reduce(
            state, catalog, input,
          ) catch {
            e =>
              raise ConversionFailed(
                detail="reduce post-effect: " + e.to_string(),
              )
          }
          state = out_reduce.next_state()
          emit_kernel_events(agent, out_reduce.events(), state)
        }
      }
      @kernel.AwaitingModel | @kernel.AwaitingTools => {
        let pending = state.pending_effects()
        for eff in pending {
          let input : @kernel.RunInput = @puppetry.execute_one(eff, exec_ctx, fn(
            _chunk : Json,
          ) {
            ()
          }) catch {
            e =>
              raise ConversionFailed(
                detail="execute_one pending: " + e.to_string(),
              )
          }
          let out_reduce : @kernel.ReduceOutput = @kernel.reduce(
            state, catalog, input,
          ) catch {
            e =>
              raise ConversionFailed(detail="reduce pending: " + e.to_string())
          }
          state = out_reduce.next_state()
          emit_kernel_events(agent, out_reduce.events(), state)
        }
      }
      _ => break
    }
  }
  if state.phase() != @kernel.Terminal {
    raise DriverLoopExceeded(iterations=iter)
  }
  state
}

///|
fn emit_kernel_events(
  agent : Agent,
  events : Array[@kernel.KernelEvent],
  state : @kernel.RunState,
) -> Unit raise KernelFacadeError {
  for event in events {
    let legacy : @types.TurnEvent? = match event {
      @kernel.RunStarted(..) => Some(@types.TurnStarted)
      @kernel.RunCompleted(..) => Some(@types.TurnCompleted)
      @kernel.RunFailed(reason~) =>
        Some(@types.TurnFailed("kernel: " + reason.to_string()))
      @kernel.RunCancelled(reason~) =>
        Some(@types.TurnFailed("kernel cancelled: " + reason.to_string()))
      @kernel.ModelStepCompleted(..)
      | @kernel.ModelStepStarted(..)
      | @kernel.ToolBatchStarted(..)
      | @kernel.RunSuspended(..)
      | @kernel.RunResumed(..)
      | @kernel.CancelRequested(..)
      | @kernel.BudgetExhausted(..)
      | @kernel.InputRejected(..) => None
      @kernel.ToolCompleted(call_id~, outcome~) =>
        Some(
          @types.TurnEvent::tool_call_result(
            legacy_tool_call_for_event(state, call_id),
            outcome_to_legacy_tool_result(outcome),
          ),
        )
    }
    match legacy {
      Some(ev) =>
        for observer in agent.observers {
          observer.on_event(ev)
        }
      None => ()
    }
  }
}

///|
/// Resolve a ToolCompleted event back to the exact assistant call that
/// produced it. The Kernel event intentionally carries only call_id and
/// outcome; the transcript is the single source for name and arguments.
fn legacy_tool_call_for_event(
  state : @kernel.RunState,
  call_id : @kernel.CallId,
) -> @types.ToolCall raise KernelFacadeError {
  for message in state.transcript().messages_snapshot() {
    match message {
      @kernel.AssistantMessage(tool_calls~, ..) =>
        for call in tool_calls {
          if call.call_id == call_id {
            return {
              id: call.call_id.to_string(),
              name: call.name.to_string(),
              arguments: call.arguments,
            }
          }
        }
      _ => ()
    }
  }
  raise ConversionFailed(
    detail="ToolCompleted event has no matching assistant call: " +
      call_id.to_string(),
  )
}

///|
fn legacy_to_canonical_message(
  m : @types.Message,
) -> @kernel.CanonicalMessage raise KernelFacadeError {
  let content : Array[@kernel.CanonicalContent] = []
  for c in m.content {
    match c {
      @types.Text(s) => content.push(@kernel.Text(s))
      @types.Image(t, d) => content.push(@kernel.Image(media_type=t, data=d))
    }
  }
  match m.role {
    @types.System => @kernel.SystemMessage(content~)
    @types.User => @kernel.UserMessage(content~)
    @types.Assistant => {
      let tool_calls : Array[@kernel.CanonicalToolCall] = []
      for tc in m.tool_calls {
        tool_calls.push({
          call_id: @kernel.CallId::unchecked(tc.id),
          name: @kernel.ToolName::unchecked(tc.name),
          arguments: tc.arguments,
        })
      }
      let reasoning = match m.reasoning_content {
        Some(s) => Some(@kernel.Reasoning::{ content: s })
        None => None
      }
      @kernel.AssistantMessage(
        content~,
        tool_calls~,
        reasoning~,
        finish_reason=@kernel.Stop,
      )
    }
    @types.Tool => {
      let call_id = match m.tool_call_id {
        Some(s) =>
          match @kernel.CallId::new(s) {
            Ok(id) => id
            Err(detail) => raise ConversionFailed(detail~)
          }
        None =>
          raise ConversionFailed(detail="Tool message missing tool_call_id")
      }
      let name = match m.name {
        Some(s) =>
          match @kernel.ToolName::new(s) {
            Ok(tool_name) => tool_name
            Err(detail) => raise ConversionFailed(detail~)
          }
        None => raise ConversionFailed(detail="Tool message missing name")
      }
      let mut text = ""
      for block in content {
        match block {
          @kernel.Text(s) => text = text + s
          @kernel.Image(..) =>
            raise ConversionFailed(
              detail="Tool message contains non-text content",
            )
        }
      }
      @kernel.ToolMessage(
        call_id~,
        tool_name=name,
        outcome=@kernel.Success(content=text, structured=None),
      )
    }
  }
}

///|
fn state_to_turn_result(
  state : @kernel.RunState,
  session_id : String,
) -> @types.TurnResult raise KernelFacadeError {
  match state.outcome() {
    Some(@kernel.Completed(final_message~, tool_results~)) => {
      let legacy_message = canonical_message_to_legacy_for_result(final_message)
      let legacy_results : Array[@types.ToolResult] = []
      for outcome in tool_results {
        legacy_results.push(outcome_to_legacy_tool_result(outcome))
      }
      let final_msg = match legacy_message {
        Some(m) => m
        None => last_assistant_message(state.transcript())
      }
      {
        message: final_msg,
        tool_results: legacy_results,
        final_session_id: session_id,
      }
    }
    Some(@kernel.Failed(reason~)) => raise KernelFailed(reason~)
    Some(@kernel.Cancelled(reason~)) => raise KernelCancelled(reason~)
    None =>
      raise ConversionFailed(detail="RunState is not Terminal (no outcome)")
  }
}

///|
fn canonical_message_to_legacy_for_result(
  cm : @kernel.CanonicalMessage,
) -> @types.Message? {
  match cm {
    @kernel.AssistantMessage(content~, tool_calls~, reasoning~, ..) => {
      let legacy_content : Array[@types.Content] = []
      for c in content {
        match c {
          @kernel.Text(s) => legacy_content.push(@types.Text(s))
          @kernel.CanonicalContent::Image(media_type~, data~) =>
            legacy_content.push(@types.Image(media_type, data))
        }
      }
      let legacy_calls : Array[@types.ToolCall] = []
      for c in tool_calls {
        legacy_calls.push({
          id: c.call_id.to_string(),
          name: c.name.to_string(),
          arguments: c.arguments,
        })
      }
      Some({
        role: @types.Assistant,
        content: legacy_content,
        tool_calls: legacy_calls,
        tool_call_id: None,
        name: None,
        reasoning_content: match reasoning {
          Some(r) => Some(r.content)
          None => None
        },
      })
    }
    _ => None
  }
}

///|
fn last_assistant_message(
  transcript : @kernel.CanonicalTranscript,
) -> @types.Message {
  let msgs = transcript.messages_snapshot()
  let fallback : @types.Message = {
    role: @types.Assistant,
    content: [],
    tool_calls: [],
    tool_call_id: None,
    name: None,
    reasoning_content: None,
  }
  let mut last : @types.Message = fallback
  for m in msgs {
    match m {
      @kernel.AssistantMessage(content~, tool_calls~, reasoning~, ..) => {
        let legacy = canonical_message_to_legacy_for_result(
          @kernel.AssistantMessage(
            content~,
            tool_calls~,
            reasoning~,
            finish_reason=@kernel.Stop,
          ),
        )
        last = match legacy {
          Some(m) => m
          None => last
        }
      }
      _ => ()
    }
  }
  last
}

///|
fn state_to_legacy_messages(state : @kernel.RunState) -> Array[@types.Message] {
  let out : Array[@types.Message] = []
  for cm in state.transcript().messages_snapshot() {
    out.push(canonical_to_legacy_message(cm))
  }
  out
}

///|
fn copy_metadata(metadata : Map[String, Json]) -> Map[String, Json] {
  let out : Map[String, Json] = Map::from_array([])
  for k in metadata.keys() {
    out[k] = metadata[k]
  }
  out
}
