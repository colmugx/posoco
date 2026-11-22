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
      reduce_terminal_fail_with_pending(state, DeadlineReached, DeadlineReached)
    BudgetExhausted(payload~) =>
      reduce_terminal_fail_with_pending(
        state,
        BudgetExhausted(dimension=payload.dimension),
        HostRequested(detail=Some("budget exhausted")),
      )
    SuspendRequested(_) =>
      reject_input(
        state, input, "AwaitingTools: tools in flight; cannot suspend",
      )
    TranscriptRewrite(payload~) => reduce_transcript_rewrite(state, payload)
    Start(_)
    | Resume(_)
    | ModelCompleted(_)
    | ModelCompletedContinue(_)
    | ModelFailed(_) =>
      reject_input(state, input, "AwaitingTools: input not legal here")
    SteerAppended(_) =>
      reject_input(
        state, input, "AwaitingTools: tools in flight; steer lands at the next step boundary",
      )
  }
}

///|
fn reduce_tool_completed(
  state : RunState,
  payload : ToolCompletedPayload,
) -> ReduceOutput raise KernelError {
  // A parent may not complete while children it started are still pending.
  let pending = state.pending_effects()
  for effect in pending {
    if effect is ExecuteTool(payload=child, ..) &&
      child.parent is Some((parent_id, _, _)) &&
      parent_id == payload.effect_id {
      return reduce_invariant_violation(
        state,
        IllegalPhase(
          phase="AwaitingTools",
          detail="parent completed with unjoined children",
        ),
      )
    }
  }
  if find_tool_effect(pending, payload.effect_id) is Some(matched) &&
    matched.parent is Some(_) {
    if matched.call_id != payload.call_id {
      return reduce_invariant_violation(
        state,
        StaleCorrelation(effect_id=payload.effect_id),
      )
    }
    let events : Array[KernelEvent] = [
      ToolCompleted(
        call={
          call_id: matched.call_id,
          name: matched.tool_name,
          arguments: matched.arguments,
        },
        outcome=payload.outcome,
        parent_effect_id=matched.parent.map(p => p.0),
      ),
    ]
    let next = state.transition(
      phase=AwaitingTools,
      transcript=state.transcript(),
      pending_effects=remove_execute_tool_effect(pending, payload.effect_id),
      next_event_sequence=advance_seq_by(state, events.length()),
      next_effect_id=state.next_effect_id(),
      current_model_step_id=state.current_model_step_id(),
      catalog_version=None,
      budget_consumed=state.budget_consumed(),
      outcome=None,
      suspension_requirement=None,
    )
    return reduce_output(next, [], events)
  }
  let mut found = false
  let mut matched_call : @kernel.ToolCall? = None
  for e in pending {
    match e {
      ExecuteTool(effect_id~, payload=ep) =>
        if effect_id == payload.effect_id && ep.call_id == payload.call_id {
          found = true
          matched_call = Some({
            call_id: ep.call_id,
            name: ep.tool_name,
            arguments: ep.arguments,
          })
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
  let canonical_call = match matched_call {
    Some(call) => call
    None =>
      return reduce_invariant_violation(
        state,
        IllegalPhase(
          phase="AwaitingTools",
          detail="matched ExecuteTool had no tool name",
        ),
      )
  }
  let tool_name = canonical_call.name
  let new_pending = remove_execute_tool_effect(pending, payload.effect_id)
  let position = match
    state.tool_call_positions.get(payload.call_id.to_string()) {
    Some(p) => p
    None => missing_tool_position
  }
  let staged = state.completed_tool_results.copy()
  staged[payload.call_id.to_string()] = (tool_name, payload.outcome, position)
  let event : KernelEvent = ToolCompleted(
    call=canonical_call,
    outcome=payload.outcome,
    parent_effect_id=None,
  )
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
      current_model_step_id=state.current_model_step_id().next(),
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
fn reduce_tool_failed(
  state : RunState,
  payload : ToolFailedPayload,
) -> ReduceOutput raise KernelError {
  let pending = state.pending_effects()
  for effect in pending {
    if effect is ExecuteTool(payload=child, ..) &&
      child.parent is Some((parent_id, _, _)) &&
      parent_id == payload.effect_id {
      return reduce_invariant_violation(
        state,
        IllegalPhase(
          phase="AwaitingTools",
          detail="parent failed with unjoined children",
        ),
      )
    }
  }
  let mut found = false
  let mut matched_call : @kernel.ToolCall? = None
  for e in pending {
    match e {
      ExecuteTool(effect_id~, payload=ep) =>
        if effect_id == payload.effect_id && ep.call_id == payload.call_id {
          found = true
          matched_call = Some({
            call_id: ep.call_id,
            name: ep.tool_name,
            arguments: ep.arguments,
          })
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
  match payload.invariant_failure {
    Some(category) =>
      return reduce_terminal_fail(state, InvariantViolation(category~))
    None => ()
  }
  let (cat, msg) = match payload.runtime {
    Some(f) =>
      match f {
        Transport(reason~) => ("Transport", reason)
        Runtime(reason~) => ("Runtime", reason)
        Parse(reason~) => ("Parse", reason)
        RequestBuild(reason~) => ("RequestBuild", reason)
        HostRejected(reason~) => ("HostRejected", reason)
        RateLimited(reason~, ..) => ("RateLimited", reason)
      }
    None =>
      (
        "Unknown",
        if payload.reason != "" {
          payload.reason
        } else {
          "no runtime detail supplied"
        },
      )
  }
  let outcome : @kernel.ToolOutcome = RuntimeFailure(
    error_category=cat,
    message=msg,
  )
  if find_tool_effect(pending, payload.effect_id) is Some(matched) &&
    matched.parent is Some(_) {
    return reduce_tool_completed(state, {
      effect_id: payload.effect_id,
      call_id: payload.call_id,
      tool_name: payload.tool_name,
      arguments: payload.arguments,
      outcome,
    })
  }
  let canonical_call = match matched_call {
    Some(call) => call
    None =>
      return reduce_invariant_violation(
        state,
        IllegalPhase(
          phase="AwaitingTools",
          detail="matched ExecuteTool had no tool name",
        ),
      )
  }
  let tool_name = canonical_call.name
  let new_pending = remove_execute_tool_effect(pending, payload.effect_id)
  let position = match
    state.tool_call_positions.get(payload.call_id.to_string()) {
    Some(p) => p
    None => missing_tool_position
  }
  let staged = state.completed_tool_results.copy()
  staged[payload.call_id.to_string()] = (tool_name, outcome, position)
  let event : KernelEvent = ToolCompleted(
    call=canonical_call,
    outcome~,
    parent_effect_id=None,
  )
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
      current_model_step_id=state.current_model_step_id().next(),
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
fn insert_tool_message_in_source_order(
  transcript : @kernel.Transcript,
  tool_call_positions : Map[String, Int32],
  call_id : @kernel.CallId,
  tool_name : @kernel.ToolName,
  outcome : @kernel.ToolOutcome,
) -> @kernel.Transcript {
  let target_position = match tool_call_positions.get(call_id.to_string()) {
    Some(position) => position
    None =>
      return transcript.append(ToolMessage(call_id~, tool_name~, outcome~))
  }
  let messages = transcript.messages_snapshot()
  let mut assistant_index : Int32? = None
  for i, message in messages {
    match message {
      AssistantMessage(tool_calls~, ..) =>
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
          ToolMessage(call_id=existing_call_id, ..) =>
            match tool_call_positions.get(existing_call_id.to_string()) {
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
fn insert_tool_result_in_source_order(
  tool_call_positions : Map[String, Int32],
  existing : Array[(@kernel.CallId, @kernel.ToolOutcome)],
  call_id : @kernel.CallId,
  outcome : @kernel.ToolOutcome,
) -> Array[(@kernel.CallId, @kernel.ToolOutcome)] {
  let target_position = match tool_call_positions.get(call_id.to_string()) {
    Some(position) => position
    None => existing.length()
  }
  let out : Array[(@kernel.CallId, @kernel.ToolOutcome)] = []
  let mut inserted = false
  for record in existing {
    let (existing_call_id, _) = record
    let existing_position = match
      tool_call_positions.get(existing_call_id.to_string()) {
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
let missing_tool_position : Int32 = 2147483647

///|
fn[T] sort_records_by_position(records : Array[T], key : (T) -> Int32) -> Unit {
  if records.length() <= 1 {
    return
  }
  let buckets : Map[Int32, Array[T]] = Map::from_array([])
  let unique_pos : Array[Int32] = []
  for rec in records {
    let p = key(rec)
    match buckets.get(p) {
      Some(bucket) => bucket.push(rec)
      None => {
        buckets[p] = [rec]
        unique_pos.push(p)
      }
    }
  }
  let sorted_pos = FixedArray::from_array(unique_pos)
  @proof_order.insertion_sort_positions(sorted_pos)
  let mut idx = 0
  for p in sorted_pos {
    match buckets.get(p) {
      Some(bucket) =>
        for rec in bucket {
          records[idx] = rec
          idx += 1
        }
      None => ()
    }
  }
}

///|
fn sort_tool_records_by_position(
  records : Array[
    (@kernel.CallId, @kernel.ToolName, @kernel.ToolOutcome, Int32),
  ],
) -> Unit {
  sort_records_by_position(records, fn(r) { r.3 })
}

///|
fn sort_result_records_by_position(
  records : Array[(@kernel.CallId, @kernel.ToolOutcome, Int32)],
) -> Unit {
  sort_records_by_position(records, fn(r) { r.2 })
}

///|
fn build_tool_call_ledger(
  transcript : @kernel.Transcript,
) -> Map[String, Int32] {
  let ledger = Map::from_array([])
  let mut position = 0
  for message in transcript.messages_snapshot() {
    match message {
      AssistantMessage(tool_calls~, ..) =>
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
fn find_owning_assistant_index(
  messages : Array[@kernel.Message],
  staged : Map[String, (@kernel.ToolName, @kernel.ToolOutcome, Int32)],
) -> Int32? {
  for i, message in messages {
    match message {
      AssistantMessage(tool_calls~, ..) => {
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
fn commit_tool_wave(
  transcript : @kernel.Transcript,
  ledger : Map[String, Int32],
  staged : Map[String, (@kernel.ToolName, @kernel.ToolOutcome, Int32)],
  existing_tool_results : Array[(@kernel.CallId, @kernel.ToolOutcome)],
) -> (@kernel.Transcript, Array[(@kernel.CallId, @kernel.ToolOutcome)]) {
  // Sort staged results by source position; missing positions sort to the end.
  let staged_records : Array[
    (@kernel.CallId, @kernel.ToolName, @kernel.ToolOutcome, Int32),
  ] = []
  for id_str, entry in staged {
    let (tool_name, outcome, position) = entry
    staged_records.push(
      (@kernel.CallId::unchecked(id_str), tool_name, outcome, position),
    )
  }
  sort_tool_records_by_position(staged_records)

  let messages = transcript.messages_snapshot()
  let new_messages : Array[@kernel.Message] = []
  match find_owning_assistant_index(messages, staged) {
    Some(idx) => {
      for i in 0..<=idx {
        new_messages.push(messages[i])
      }
      // Collect existing ToolMessages immediately after the assistant.
      let existing_tool_records : Array[
        (@kernel.CallId, @kernel.ToolName, @kernel.ToolOutcome, Int32),
      ] = []
      let mut remaining_start = idx + 1
      for i in (idx + 1)..<messages.length() {
        match messages[i] {
          ToolMessage(call_id~, tool_name~, outcome~) => {
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
      let combined = existing_tool_records.copy()
      for record in staged_records {
        combined.push(record)
      }
      sort_tool_records_by_position(combined)
      for record in combined {
        let (call_id, tool_name, outcome, _) = record
        new_messages.push(ToolMessage(call_id~, tool_name~, outcome~))
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
        new_messages.push(ToolMessage(call_id~, tool_name~, outcome~))
      }
    }
  }

  // Merge existing results with the staged ones in global source order.
  let combined_results : Array[(@kernel.CallId, @kernel.ToolOutcome, Int32)] = []
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
