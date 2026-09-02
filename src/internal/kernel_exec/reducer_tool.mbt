/// Tool-turn branches and the source-position tool ledger / wave-commit helpers.

///|
fn reduce_awaiting_tools(
  state : RunState,
  _catalog : ToolCatalogSnapshot,
  input : RunInput,
) -> ReduceOutput raise KernelError {
  match input {
    ToolCompleted(payload~) => reduce_tool_completed(state, payload)
    ToolFailed(payload~) => reduce_tool_failed(state, payload)
    CancelRequested(payload~) =>
      reduce_cancel_with_pending(state, payload.detail)
    DeadlineReached(_) =>
      reduce_terminal_fail(state, FailureReason::DeadlineReached)
    BudgetExhausted(payload~) =>
      reduce_terminal_fail(state, BudgetExhausted(dimension=payload.dimension))
    SuspendRequested(_) =>
      reject_input(
        state, input, "AwaitingTools: tools in flight; cannot suspend",
      )
    TranscriptRewrite(payload~) => reduce_transcript_rewrite(state, payload)
    Start(_) | Resume(_) | ModelCompleted(_) | ModelFailed(_) =>
      reject_input(state, input, "AwaitingTools: input not legal here")
  }
}

///|
/// Fold a tool completion into state. When the last pending effect is
/// resolved, transition to ReadyForModel.
fn reduce_tool_completed(
  state : RunState,
  payload : ToolCompletedPayload,
) -> ReduceOutput raise KernelError {
  // Correlation: find the matching ExecuteTool in pending.
  let pending = state.pending_effects()
  let mut found = false
  let mut matched_tool_name : @kernel.ToolName? = None
  for e in pending {
    match e {
      ExecuteTool(effect_id~, payload=ep) =>
        if effect_id == payload.effect_id && ep.call_id == payload.call_id {
          found = true
          matched_tool_name = Some(ep.tool_name)
        }
      _ => ()
    }
  }
  if !found {
    return reduce_invariant_violation(
      state,
      StaleCorrelation(effect_id=payload.effect_id),
    )
  }
  let tool_name = match matched_tool_name {
    Some(n) => n
    None =>
      return reduce_invariant_violation(
        state,
        IllegalPhase(
          phase="AwaitingTools",
          detail="matched ExecuteTool had no tool name",
        ),
      )
  }
  let new_pending = remove_execute_tool_effect(pending, payload.effect_id)
  let position = match
    state.tool_call_positions.get(payload.call_id.to_string()) {
    Some(p) => p
    None => missing_tool_position
  }
  let staged = state.completed_tool_results.copy()
  staged[payload.call_id.to_string()] = (tool_name, payload.outcome, position)
  let event : KernelEvent = ToolCompleted(
    call_id=payload.call_id,
    outcome=payload.outcome,
  )
  let events = [event]
  if new_pending.is_empty() {
    // Wave boundary: commit all staged outcomes to the transcript and
    // tool-result ledger in one source-ordered rebuild, then return to
    // ReadyForModel. Tool consumption was already recorded atomically when
    // the reducer declared this batch's ExecuteTool effects.
    let (committed_transcript, committed_tool_results) = commit_tool_wave(
      state.transcript(),
      state.tool_call_positions,
      staged,
      state.tool_results_snapshot(),
    )
    let next_state = state.transition(
      phase=ReadyForModel,
      transcript=committed_transcript,
      pending_effects=[],
      next_event_sequence=advance_seq_by(state, events.length()),
      next_effect_id=state.next_effect_id(),
      current_model_step_id=state.current_model_step_id(),
      catalog_version=None,
      budget_consumed=state.budget_consumed(),
      outcome=None,
      completed_tool_results=Map::from_array([]),
      tool_call_positions=Map::from_array([]),
      suspension_requirement=None,
    )
    let next_state = next_state.with_tool_results(committed_tool_results)
    return reduce_output(next_state, [], events)
  }
  let next_state = state.transition(
    phase=AwaitingTools,
    transcript=state.transcript(),
    pending_effects=new_pending,
    next_event_sequence=advance_seq_by(state, events.length()),
    next_effect_id=state.next_effect_id(),
    current_model_step_id=state.current_model_step_id(),
    catalog_version=None,
    budget_consumed=state.budget_consumed(),
    outcome=None,
    completed_tool_results=staged,
    tool_call_positions=state.tool_call_positions.copy(),
    suspension_requirement=None,
  )
  reduce_output(next_state, [], events)
}

///|
/// Tool failed (runtime or invariant failure). Runtime failures become a
/// `ToolOutcome::RuntimeFailure` and the Run continues. Invariant failures
/// terminate the Run with Failed.
fn reduce_tool_failed(
  state : RunState,
  payload : ToolFailedPayload,
) -> ReduceOutput raise KernelError {
  // Correlation check.
  let pending = state.pending_effects()
  let mut found = false
  let mut matched_tool_name : @kernel.ToolName? = None
  for e in pending {
    match e {
      ExecuteTool(effect_id~, payload=ep) =>
        if effect_id == payload.effect_id && ep.call_id == payload.call_id {
          found = true
          matched_tool_name = Some(ep.tool_name)
        }
      _ => ()
    }
  }
  if !found {
    return reduce_invariant_violation(
      state,
      StaleCorrelation(effect_id=payload.effect_id),
    )
  }
  // Invariant failure → terminal Failed.
  match payload.invariant_failure {
    Some(category) =>
      return reduce_terminal_fail(state, InvariantViolation(category~))
    None => ()
  }
  // Runtime failure: build RuntimeFailure outcome and continue.
  let (cat, msg) = match payload.runtime {
    Some(f) =>
      match f {
        @kernel.Transport(reason~) => ("Transport", reason)
        @kernel.Runtime(reason~) => ("Runtime", reason)
        @kernel.Parse(reason~) => ("Parse", reason)
        @kernel.RequestBuild(reason~) => ("RequestBuild", reason)
        @kernel.HostRejected(reason~) => ("HostRejected", reason)
        @kernel.RateLimited(reason~, ..) => ("RateLimited", reason)
      }
    None => ("Unknown", "no runtime detail supplied")
  }
  let outcome : @kernel.ToolOutcome = @kernel.RuntimeFailure(
    error_category=cat,
    message=msg,
  )
  let tool_name = match matched_tool_name {
    Some(n) => n
    None =>
      return reduce_invariant_violation(
        state,
        IllegalPhase(
          phase="AwaitingTools",
          detail="matched ExecuteTool had no tool name",
        ),
      )
  }
  let new_pending = remove_execute_tool_effect(pending, payload.effect_id)
  let position = match
    state.tool_call_positions.get(payload.call_id.to_string()) {
    Some(p) => p
    None => missing_tool_position
  }
  let staged = state.completed_tool_results.copy()
  staged[payload.call_id.to_string()] = (tool_name, outcome, position)
  let event : KernelEvent = ToolCompleted(call_id=payload.call_id, outcome~)
  let events = [event]
  if new_pending.is_empty() {
    let (committed_transcript, committed_tool_results) = commit_tool_wave(
      state.transcript(),
      state.tool_call_positions,
      staged,
      state.tool_results_snapshot(),
    )
    let next_state = state.transition(
      phase=ReadyForModel,
      transcript=committed_transcript,
      pending_effects=[],
      next_event_sequence=advance_seq_by(state, events.length()),
      next_effect_id=state.next_effect_id(),
      current_model_step_id=state.current_model_step_id(),
      catalog_version=None,
      budget_consumed=state.budget_consumed(),
      outcome=None,
      completed_tool_results=Map::from_array([]),
      tool_call_positions=Map::from_array([]),
      suspension_requirement=None,
    )
    let next_state = next_state.with_tool_results(committed_tool_results)
    return reduce_output(next_state, [], events)
  }
  let next_state = state.transition(
    phase=AwaitingTools,
    transcript=state.transcript(),
    pending_effects=new_pending,
    next_event_sequence=advance_seq_by(state, events.length()),
    next_effect_id=state.next_effect_id(),
    current_model_step_id=state.current_model_step_id(),
    catalog_version=None,
    budget_consumed=state.budget_consumed(),
    outcome=None,
    completed_tool_results=staged,
    tool_call_positions=state.tool_call_positions.copy(),
    suspension_requirement=None,
  )
  reduce_output(next_state, [], events)
}

///|
fn remove_execute_tool_effect(
  effects : Array[Effect],
  effect_id : EffectId,
) -> Array[Effect] {
  let out : Array[Effect] = []
  for e in effects {
    let keep = match e {
      ExecuteTool(effect_id=eid, ..) => eid != effect_id
      _ => true
    }
    if keep {
      out.push(e)
    }
  }
  out
}

///|
/// Return the stable source position of a tool call in the canonical
/// transcript. Positions span all assistant messages in the Run, so results
/// from multiple tool rounds remain deterministic as well as results within a
/// parallel batch.
fn tool_call_position(
  transcript : @kernel.Transcript,
  call_id : @kernel.CallId,
) -> Int? {
  let mut position = 0
  let mut found : Int? = None
  for message in transcript.messages_snapshot() {
    match message {
      @kernel.AssistantMessage(tool_calls~, ..) =>
        for call in tool_calls {
          if call.call_id == call_id {
            found = Some(position)
          }
          position = position + 1
        }
      _ => ()
    }
  }
  found
}

///|
/// Insert a completed tool message next to the assistant message that
/// requested it, ordered by the model's source call order rather than host
/// completion order.
fn insert_tool_message_in_source_order(
  transcript : @kernel.Transcript,
  call_id : @kernel.CallId,
  tool_name : @kernel.ToolName,
  outcome : @kernel.ToolOutcome,
) -> @kernel.Transcript {
  let messages = transcript.messages_snapshot()
  let target_position = match tool_call_position(transcript, call_id) {
    Some(position) => position
    None =>
      return transcript.append(
        @kernel.ToolMessage(call_id~, tool_name~, outcome~),
      )
  }
  let mut assistant_index : Int? = None
  for i, message in messages {
    match message {
      @kernel.AssistantMessage(tool_calls~, ..) =>
        for call in tool_calls {
          if call.call_id == call_id {
            assistant_index = Some(i)
          }
        }
      _ => ()
    }
  }
  let insert_at = match assistant_index {
    None => messages.length()
    Some(index) => {
      let mut position = index + 1
      for i in (index + 1)..<messages.length() {
        match messages[i] {
          @kernel.ToolMessage(call_id=existing_call_id, ..) =>
            match tool_call_position(transcript, existing_call_id) {
              Some(existing_position) if existing_position < target_position =>
                position = i + 1
              _ => ()
            }
          _ => ()
        }
      }
      position
    }
  }
  let next_message = @kernel.ToolMessage(call_id~, tool_name~, outcome~)
  let out : Array[@kernel.Message] = []
  for i, message in messages {
    if i == insert_at {
      out.push(next_message)
    }
    out.push(message)
  }
  if insert_at == messages.length() {
    out.push(next_message)
  }
  @kernel.Transcript::from_array(out)
}

///|
/// Keep the terminal `RunOutcome` ordered by the same source positions as the
/// canonical transcript. The call id is internal bookkeeping; only outcomes
/// cross the public terminal boundary.
fn insert_tool_result_in_source_order(
  transcript : @kernel.Transcript,
  existing : Array[(@kernel.CallId, @kernel.ToolOutcome)],
  call_id : @kernel.CallId,
  outcome : @kernel.ToolOutcome,
) -> Array[(@kernel.CallId, @kernel.ToolOutcome)] {
  let target_position = match tool_call_position(transcript, call_id) {
    Some(position) => position
    None => existing.length()
  }
  let out : Array[(@kernel.CallId, @kernel.ToolOutcome)] = []
  let mut inserted = false
  for record in existing {
    let (existing_call_id, _) = record
    let existing_position = match
      tool_call_position(transcript, existing_call_id) {
      Some(position) => position
      None => target_position + existing.length() + 1
    }
    if !inserted && existing_position > target_position {
      out.push((call_id, outcome))
      inserted = true
    }
    out.push(record)
  }
  if !inserted {
    out.push((call_id, outcome))
  }
  out
}

///|
/// Fallback source position for call ids no longer present in the transcript
/// (e.g. after a rewrite that removed the owning assistant message). Sorts
/// to the end, matching the previous append-at-end behavior.
let missing_tool_position : Int = 2147483647

///|
/// Insertion-sort an array of staged tool records by source position. Used
/// instead of `Array::sort` because the tuple contains `CallId`, which does
/// not implement `Compare`.
fn sort_tool_records_by_position(
  records : Array[(@kernel.CallId, @kernel.ToolName, @kernel.ToolOutcome, Int)],
) -> Unit {
  for i = 1; i < records.length(); i = i + 1 {
    let key = records[i]
    let mut j = i - 1
    while j >= 0 && records[j].3 > key.3 {
      records[j + 1] = records[j]
      j = j - 1
    }
    records[j + 1] = key
  }
}

///|
/// Insertion-sort an array of tool-result records by source position.
fn sort_result_records_by_position(
  records : Array[(@kernel.CallId, @kernel.ToolOutcome, Int)],
) -> Unit {
  for i = 1; i < records.length(); i = i + 1 {
    let key = records[i]
    let mut j = i - 1
    while j >= 0 && records[j].2 > key.2 {
      records[j + 1] = records[j]
      j = j - 1
    }
    records[j + 1] = key
  }
}

///|
/// Build an incremental ledger mapping each call id in the transcript to its
/// stable source position among all assistant messages. Scans the transcript
/// once per wave declaration / rewrite, not once per result.
fn build_tool_call_ledger(transcript : @kernel.Transcript) -> Map[String, Int] {
  let ledger = Map::from_array([])
  let mut position = 0
  for message in transcript.messages_snapshot() {
    match message {
      @kernel.AssistantMessage(tool_calls~, ..) =>
        for call in tool_calls {
          ledger[call.call_id.to_string()] = position
          position = position + 1
        }
      _ => ()
    }
  }
  ledger
}

///|
/// Find the index of the assistant message that owns any of the staged call
/// ids. All staged results in one wave belong to the same assistant message.
fn find_owning_assistant_index(
  messages : Array[@kernel.Message],
  staged : Map[String, (@kernel.ToolName, @kernel.ToolOutcome, Int)],
) -> Int? {
  for i, message in messages {
    match message {
      @kernel.AssistantMessage(tool_calls~, ..) => {
        let mut matched = false
        for call in tool_calls {
          if staged.contains(call.call_id.to_string()) {
            matched = true
            break
          }
        }
        if matched {
          return Some(i)
        }
      }
      _ => ()
    }
  }
  None
}

///|
/// Commit all staged tool outcomes to the transcript and tool-result ledger
/// in a single wave-boundary rebuild. Returns the new transcript and the new
/// tool-result array. This is O(N) once per wave instead of O(K·N) per result.
fn commit_tool_wave(
  transcript : @kernel.Transcript,
  ledger : Map[String, Int],
  staged : Map[String, (@kernel.ToolName, @kernel.ToolOutcome, Int)],
  existing_tool_results : Array[(@kernel.CallId, @kernel.ToolOutcome)],
) -> (@kernel.Transcript, Array[(@kernel.CallId, @kernel.ToolOutcome)]) {
  // Sort staged results by source position; missing positions sort to the end.
  let staged_records : Array[
    (@kernel.CallId, @kernel.ToolName, @kernel.ToolOutcome, Int),
  ] = []
  for id_str, entry in staged {
    let (tool_name, outcome, position) = entry
    staged_records.push(
      (@kernel.CallId::unchecked(id_str), tool_name, outcome, position),
    )
  }
  sort_tool_records_by_position(staged_records)

  // Build new transcript.
  let messages = transcript.messages_snapshot()
  let new_messages : Array[@kernel.Message] = []
  match find_owning_assistant_index(messages, staged) {
    Some(idx) => {
      // Messages up to and including the owning assistant.
      for i in 0..<=idx {
        new_messages.push(messages[i])
      }
      // Collect existing ToolMessages immediately after the assistant.
      let existing_tool_records : Array[
        (@kernel.CallId, @kernel.ToolName, @kernel.ToolOutcome, Int),
      ] = []
      let mut remaining_start = idx + 1
      for i in (idx + 1)..<messages.length() {
        match messages[i] {
          @kernel.ToolMessage(call_id~, tool_name~, outcome~) => {
            let pos = match ledger.get(call_id.to_string()) {
              Some(p) => p
              None => missing_tool_position
            }
            existing_tool_records.push((call_id, tool_name, outcome, pos))
            // Collected messages are re-emitted via `combined` below; the
            // remaining-append loop must not re-append them.
            remaining_start = i + 1
          }
          _ => {
            remaining_start = i
            break
          }
        }
      }
      // Combine and sort all tool records for this wave by source position.
      let combined = existing_tool_records.copy()
      for record in staged_records {
        combined.push(record)
      }
      sort_tool_records_by_position(combined)
      for record in combined {
        let (call_id, tool_name, outcome, _) = record
        new_messages.push(@kernel.ToolMessage(call_id~, tool_name~, outcome~))
      }
      // Append remaining messages (e.g. rewrites after the assistant).
      for i in remaining_start..<messages.length() {
        new_messages.push(messages[i])
      }
    }
    None => {
      // Owning assistant not found: append staged results at the end.
      for msg in messages {
        new_messages.push(msg)
      }
      for record in staged_records {
        let (call_id, tool_name, outcome, _) = record
        new_messages.push(@kernel.ToolMessage(call_id~, tool_name~, outcome~))
      }
    }
  }

  // Build new tool-result ledger by merging existing results with staged ones
  // in global source order.
  let combined_results : Array[(@kernel.CallId, @kernel.ToolOutcome, Int)] = []
  for record in existing_tool_results {
    let (call_id, outcome) = record
    let pos = match ledger.get(call_id.to_string()) {
      Some(p) => p
      None => missing_tool_position
    }
    combined_results.push((call_id, outcome, pos))
  }
  for record in staged_records {
    let (call_id, tool_name, outcome, pos) = record
    ignore(tool_name)
    combined_results.push((call_id, outcome, pos))
  }
  sort_result_records_by_position(combined_results)
  let new_tool_results : Array[(@kernel.CallId, @kernel.ToolOutcome)] = []
  for record in combined_results {
    let (call_id, outcome, _) = record
    new_tool_results.push((call_id, outcome))
  }
  (@kernel.Transcript::from_array(new_messages), new_tool_results)
}

///|
/// Project the run-local ledger into the public terminal result shape.
fn tool_outcomes(
  records : FixedArray[(@kernel.CallId, @kernel.ToolOutcome)],
) -> FixedArray[@kernel.ToolOutcome] {
  let out : Array[@kernel.ToolOutcome] = []
  for i in 0..<records.length() {
    let (_, outcome) = records[i]
    out.push(outcome)
  }
  FixedArray::from_array(out)
}

///|
fn is_unknown_tool_diagnostic(diag : @kernel.SchemaDiagnostic) -> Bool {
  diag.actual.contains("unknown tool")
}
