///|
/// Agent ↔ Harness compatibility adapter (M2-T07).
///
/// Provides `Agent::run_turn_via_harness`: an OPT-IN entry point that
/// drives a turn through the M2 Harness instead of the M0 while-true loop.
/// Legacy `Agent::run_turn` is preserved unchanged (ADR §1 goal 9 —
/// finite migration window).
///
/// Known limitations vs M0 `run_turn`:
/// - No PipelineHook / Compressor / MemoryPort integration.
/// - No streaming chunk support.
/// - Suspended runs return UnsupportedSuspension (legacy has no concept).
/// - Observer events are not projected from KernelEvents (T08 work).
/// - The complete committed canonical transcript is projected into the
///   legacy session on successful terminal completion. Observer projection,
///   streaming and suspension remain explicit gaps.

// ──────────────────────────────────────────────────────────────────────────
// Unified error type for the facade
// ──────────────────────────────────────────────────────────────────────────

///|
pub(all) suberror HarnessFacadeError {
  /// Legacy session load/save error.
  SessionLoad(detail~ : String)
  SessionSave(detail~ : String)
  /// Catalog build failed at composition.
  CatalogComposition(failure~ : @kernel.CatalogCompositionError)
  /// Harness rejected the prompt or the pump failed.
  HarnessRejected(error~ : @puppetry.HarnessError)
  /// Run ended in Suspended, which legacy TurnResult cannot express.
  UnsupportedSuspension(run_id~ : @kernel.RunId, suspension_id~ : String)
  /// Run ended in a non-Completed terminal (Failed/Cancelled).
  NonCompletedTerminal(outcome~ : @kernel.RunOutcome)
  /// Legacy ↔ canonical message conversion failed.
  ConversionFailed(detail~ : String)
}

///|
pub impl Show for HarnessFacadeError with fn to_string(
  self : HarnessFacadeError,
) -> String {
  match self {
    SessionLoad(detail~) => "HarnessFacadeError::SessionLoad(\{detail})"
    SessionSave(detail~) => "HarnessFacadeError::SessionSave(\{detail})"
    CatalogComposition(failure~) =>
      "HarnessFacadeError::CatalogComposition(\{failure.to_string()})"
    HarnessRejected(error~) =>
      "HarnessFacadeError::HarnessRejected(\{error.to_string()})"
    UnsupportedSuspension(run_id~, suspension_id~) =>
      "HarnessFacadeError::UnsupportedSuspension(run=\{run_id.to_string()}, susp=\{suspension_id})"
    NonCompletedTerminal(outcome~) =>
      "HarnessFacadeError::NonCompletedTerminal(\{outcome.to_string()})"
    ConversionFailed(detail~) =>
      "HarnessFacadeError::ConversionFailed(\{detail})"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Local legacy → canonical conversion at the Harness boundary.
// ──────────────────────────────────────────────────────────────────────────

///|
/// Convert a legacy Message to its canonical form. Invalid legacy tool
/// metadata is rejected at the boundary; no placeholder call ids/names are
/// fabricated because they would make transcript correlation non-deterministic.
/// Mirrors `legacy_to_canonical_message` in legacy_agent_adapter.mbt but
/// keeps this file independent of the M1 facade's error type.
fn harness_legacy_to_canonical(
  m : @types.Message,
) -> @kernel.CanonicalMessage raise HarnessFacadeError {
  let content : Array[@kernel.CanonicalContent] = []
  for c in m.content {
    match c {
      Text(s) => content.push(@kernel.Text(s))
      Image(t, d) => content.push(@kernel.Image(media_type=t, data=d))
    }
  }
  match m.role {
    System => @kernel.SystemMessage(content~)
    User => @kernel.UserMessage(content~)
    Assistant => {
      let calls : Array[@kernel.CanonicalToolCall] = []
      for tc in m.tool_calls {
        calls.push({
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
        tool_calls=calls,
        reasoning~,
        finish_reason=@kernel.Stop,
      )
    }
    Tool => {
      let call_id_str = match m.tool_call_id {
        Some(s) => s
        None =>
          raise ConversionFailed(detail="Tool message missing tool_call_id")
      }
      let name_str = match m.name {
        Some(s) => s
        None => raise ConversionFailed(detail="Tool message missing name")
      }
      let call_id = match @kernel.CallId::new(call_id_str) {
        Ok(id) => id
        Err(detail) => raise ConversionFailed(detail~)
      }
      let name = match @kernel.ToolName::new(name_str) {
        Ok(tool_name) => tool_name
        Err(detail) => raise ConversionFailed(detail~)
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

// ──────────────────────────────────────────────────────────────────────────
// Public entry point
// ──────────────────────────────────────────────────────────────────────────

///|
/// Drive a single turn through the M2 Harness. Returns a legacy
/// `TurnResult` for compatibility with M0 callers.
pub async fn Agent::run_turn_via_harness(
  self : Agent,
  input : @types.Message,
  session_id : String,
) -> @types.TurnResult raise HarnessFacadeError {
  // Step 1: load session (matches M0 first-store semantics).
  let legacy_session = match self.sessions {
    [first, ..] => {
      let loaded : Result[@types.Session, @error.SessionError] = first.load(
        session_id,
      )
      match loaded {
        Ok(s) => s
        Err(error) =>
          raise SessionLoad(
            detail="session_id='\{safe_error_label(session_id)}', operation='load', cause='\{safe_error_label(error.to_string())}'",
          )
      }
    }
    [] => raise SessionLoad(detail="no session store configured")
  }
  // Step 2: build canonical messages from legacy session + input.
  let canonical_initial : Array[@kernel.CanonicalMessage] = []
  for m in legacy_session.messages {
    canonical_initial.push(harness_legacy_to_canonical(m))
  }
  canonical_initial.push(harness_legacy_to_canonical(input))
  // Step 3: build the immutable catalog and the root-owned host adapter.
  let catalog = build_agent_catalog_for_harness(self)
  let host = LegacyHostRuntime::from_agent(self)
  // Step 4: build HarnessConfig.
  let journal = @puppetry.InMemoryJournal::new()
  let noop_sub = @puppetry.NoopSubscriber::new()
  let config : @puppetry.HarnessConfig = {
    host,
    model_id: @puppetry.ModelId::unchecked("legacy_model"),
    catalog,
    journal,
    contributors: [],
    subscribers: [noop_sub],
    lifecycle_nodes: [],
    default_budget: @kernel.Budget::from_legacy_rounds(
      self.config.max_tool_rounds,
    ),
    max_iterations: 200,
  }
  // Step 5: build the Harness and prompt.
  let harness = @puppetry.Harness::new(config)
  let run_id = @kernel.RunId::unchecked("harness_" + session_id)
  let turn_id = @puppetry.TurnId::unchecked("turn_1")
  let sess_id = @kernel.SessionId::unchecked(session_id)
  let prompt_result : Result[@puppetry.PromptResult, @puppetry.HarnessError] = Ok(
    harness.prompt(run_id, turn_id, sess_id, canonical_initial, "harness_op"),
  ) catch {
    e => Err(e)
  }
  let result = match prompt_result {
    Err(e) => raise HarnessRejected(error=e)
    Ok(r) => r
  }
  // Step 6: project prompt result to legacy TurnResult.
  match result {
    @puppetry.Accepted(..) => {
      // wait_idle is async (implicitly raises Error); route any untyped
      // raise through HarnessRejected.
      let status_result : Result[@puppetry.QuiescentStatus, HarnessFacadeError] = Ok(
        harness.wait_idle(),
      ) catch {
        _ =>
          Err(
            HarnessFacadeError::ConversionFailed(
              detail="wait_idle raised untyped",
            ),
          )
      }
      let status = match status_result {
        Err(e) => raise e
        Ok(s) => s
      }
      match status {
        @puppetry.Terminal(outcome~) =>
          match outcome {
            @kernel.Completed(final_message~, tool_results~) => {
              let legacy_final = canonical_to_legacy_message(final_message)
              let transcript = match harness.last_completed_transcript() {
                Some(t) => t
                None =>
                  raise ConversionFailed(
                    detail="terminal outcome committed without transcript",
                  )
              }
              let new_messages = canonical_transcript_to_legacy_messages(
                transcript,
              )
              // The reducer's terminal outcome is the sole source for the
              // current turn's tool results. The transcript is used for
              // session materialization and correlation, not as a fallback
              // that could accidentally replay historical tool messages.
              let projected_tool_results = tool_results.map(
                outcome_to_legacy_tool_result,
              )
              save_session_all(self, session_id, legacy_session, new_messages)
              {
                message: legacy_final,
                tool_results: projected_tool_results,
                final_session_id: session_id,
              }
            }
            @kernel.Failed(..) | @kernel.Cancelled(..) =>
              raise NonCompletedTerminal(outcome~)
          }
        @puppetry.Suspended(run_id~, suspension_id~, ..) =>
          raise UnsupportedSuspension(run_id~, suspension_id~)
        @puppetry.Idle =>
          raise ConversionFailed(detail="harness returned Idle after Accepted")
        @puppetry.Shutdown =>
          raise ConversionFailed(detail="harness returned Shutdown during run")
      }
    }
    @puppetry.LeaseBusy(held_by~) =>
      raise HarnessRejected(
        error=@puppetry.LeaseHeld(operation_id="harness_op", held_by~),
      )
    @puppetry.Rejected(error~) => raise HarnessRejected(error~)
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Internal helpers
// ──────────────────────────────────────────────────────────────────────────

///|
/// Build a ToolCatalogSnapshot from the Agent's tool providers, matching
/// the M0 collision-detection semantics.
fn build_agent_catalog_for_harness(
  agent : Agent,
) -> @kernel.ToolCatalogSnapshot raise HarnessFacadeError {
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
      let add_result : Result[Unit, @kernel.CatalogCompositionError] = try {
        let _ = builder.add(def)
        Ok(())
      } catch {
        e => Err(e)
      }
      match add_result {
        Ok(_) => ()
        Err(e) => raise CatalogComposition(failure=e)
      }
    }
  }
  let finish_result : Result[
    @kernel.ToolCatalogSnapshot,
    @kernel.CatalogCompositionError,
  ] = Ok(builder.finish(version=@kernel.CatalogVersion::new(1))) catch {
    e => Err(e)
  }
  match finish_result {
    Ok(snap) => snap
    Err(e) => raise CatalogComposition(failure=e)
  }
}

///|
/// Project the complete committed canonical transcript to legacy messages.
/// This preserves intermediate assistant tool calls and correlated tool
/// outcomes; reconstructing a session from only the terminal assistant would
/// silently erase the causal transcript.
fn canonical_transcript_to_legacy_messages(
  transcript : @kernel.CanonicalTranscript,
) -> Array[@types.Message] {
  let out : Array[@types.Message] = []
  for message in transcript.messages_snapshot() {
    out.push(canonical_to_legacy_message(message))
  }
  out
}

///|
/// Save the session via write-all semantics (matches M0).
fn save_session_all(
  agent : Agent,
  session_id : String,
  legacy_session : @types.Session,
  new_messages : Array[@types.Message],
) -> Unit raise HarnessFacadeError {
  for store in agent.sessions {
    let saved_session : @types.Session = {
      messages: new_messages,
      metadata: legacy_session.metadata,
    }
    let saved : Result[Unit, @error.SessionError] = store.save(
      session_id, saved_session,
    )
    match saved {
      Ok(_) => ()
      Err(error) =>
        raise SessionSave(
          detail="session_id='\{safe_error_label(session_id)}', operation='final_save', cause='\{safe_error_label(error.to_string())}'",
        )
    }
  }
}
