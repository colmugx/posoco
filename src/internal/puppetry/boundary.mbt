///|
async fn Puppet::commit_boundary(
  self : Puppet,
  state : RunState,
  kind : SavepointKind,
  events : Array[KernelEvent],
  dispatcher : EventDispatcher,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  boundary_id_prefix : String,
) -> Unit raise PuppetError {
  if kind is RunTerminal {
    self.mailbox.message_inbox().close_step()
  }
  let pre_commit_rev = self.config.journal.revision()
  let savepoint_id = "\{boundary_id_prefix}_r\{pre_commit_rev}"
  let entry = boundary_entry(
    state,
    kind,
    events,
    run_id,
    turn_id,
    session_id,
    savepoint_id,
    initial_command=if events.any(fn(event) { event is RunStarted(_) }) {
      self.mailbox.message_inbox().initial_command()
    } else {
      None
    },
  )
  let ctx : PreCommitContext = {
    run_id,
    turn_id,
    session_id,
    savepoint_id,
    savepoint_kind: kind,
    base_entries: [entry],
    current_revision: pre_commit_rev,
    catalog_version: state.catalog_version(),
  }
  let batch = prepare_batch(ctx, self.config.contributors)
  let committed_rev = commit_batch(self.config.journal, batch)
  self.publish_core_fact({
    run_id,
    turn_id,
    session_id: session_id.to_string(),
    committed_revision: committed_rev,
    savepoint_id,
    is_terminal: kind is RunTerminal,
    messages: state.transcript().messages_snapshot(),
  })
  // Confirm before any subscriber can suspend or submit more input.
  let inbox = self.mailbox.message_inbox()
  defer inbox.flush_step_deliveries()
  for event in events {
    match event {
      UserMessageAppended(command_id~, ..) => inbox.confirm(command_id)
      SteerUndelivered(command_id~, reason~) =>
        inbox.discard(command_id, reason)
      RunStarted(..) => inbox.confirm_initial()
      _ => ()
    }
  }
  // Every event is published after the one boundary commit. They share its
  // committed revision while EventDispatcher preserves a strict event seq.
  for event in events {
    dispatcher.dispatch(event, committed_rev)
  }
}

///|
fn boundary_kind_for_events(events : Array[KernelEvent]) -> SavepointKind {
  let mut best_rank = -1
  let mut best_kind = AssistantCommitted
  for event in events {
    let (rank, kind) : (Int32, SavepointKind) = match event {
      RunCompleted(..) | RunFailed(..) | RunCancelled(..) => (4, RunTerminal)
      RunSuspended(..) => (3, RunSuspended)
      ToolCompleted(..) | ToolCallsPreRejected(..) => (2, ToolCommitted)
      ModelStepCompleted(..) => (1, AssistantCommitted)
      RunStarted(..) | UserMessageAppended(..) | SteerUndelivered(..) =>
        (0, InputAccepted)
      _ => (-1, AssistantCommitted)
    }
    if rank > best_rank {
      best_rank = rank
      best_kind = kind
    }
  }
  best_kind
}

///|
fn event_to_boundary_kind(event : KernelEvent) -> SavepointKind {
  match event {
    RunStarted(..) => InputAccepted
    UserMessageAppended(..) | SteerUndelivered(..) => InputAccepted
    ModelStepCompleted(..) => AssistantCommitted
    ToolCompleted(..) | ToolCallsPreRejected(..) => ToolCommitted
    ToolChildDeclared(..) | ToolCallApproved(..) | ToolWaveStarted(..) =>
      ToolCommitted
    RunSuspended(..) => RunSuspended
    RunCompleted(..) | RunFailed(..) | RunCancelled(..) => RunTerminal
    _ => AssistantCommitted
  }
}

///|
fn boundary_entry(
  state : RunState,
  kind : SavepointKind,
  events : Array[KernelEvent],
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  savepoint_id : String,
  initial_command~ : String?,
) -> JournalEntry raise PuppetError {
  if events.is_empty() {
    raise ReducerInvariantViolation(
      category=IllegalPhase(
        phase="commit_boundary",
        detail="boundary has no events",
      ),
    )
  }
  let (summary, payload) : (String, Json) = if kind == InputAccepted {
    (
      "InputAccepted(run=\{run_id.to_string()})",
      {
        "kind": "InputAccepted",
        "run_id": run_id.to_string(),
        "turn_id": turn_id.to_string(),
        "session_id": session_id.to_string(),
        "catalog_version": state.catalog_version().to_int().to_double(),
      },
    )
  } else {
    let primary = boundary_primary_event(events, kind)
    (primary.to_string(), kernel_event_payload(primary))
  }
  let deliveries : Array[Json] = []
  for event in events {
    match event {
      UserMessageAppended(command_id~, ..) =>
        deliveries.push({
          "command_id": command_id,
          "delivery": "step",
          "outcome": "applied",
        })
      SteerUndelivered(command_id~, ..) =>
        deliveries.push({
          "command_id": command_id,
          "delivery": "step",
          "outcome": "undelivered",
        })
      _ => ()
    }
  }
  if initial_command is Some(command_id) {
    deliveries.push({
      "command_id": command_id,
      "delivery": "turn",
      "outcome": "applied",
    })
  }
  if !deliveries.is_empty() {
    match payload {
      Object(fields) => fields["message_deliveries"] = Json::array(deliveries)
      _ => abort("boundary payload is not an object")
    }
  }
  {
    identity: { run_id, turn_id, session_id, savepoint_id, kind, entry_seq: 0, },
    revision: 0,
    summary,
    payload,
  }
}

///|
fn boundary_primary_event(
  events : Array[KernelEvent],
  kind : SavepointKind,
) -> KernelEvent raise PuppetError {
  for event in events {
    if event_to_boundary_kind(event) == kind {
      return event
    }
  }
  if events.is_empty() {
    raise ReducerInvariantViolation(
      category=IllegalPhase(
        phase="commit_boundary",
        detail="boundary has no primary event",
      ),
    )
  }
  events[0]
}

///|
fn kernel_event_payload(event : KernelEvent) -> Json {
  match event {
    RunStarted(details~) =>
      {
        "kind": "RunStarted",
        "run_id": details.run_id.to_string(),
        "session_id": details.session_id.to_string(),
      }
    ModelStepStarted(model_step_id~, effect_id~) =>
      {
        "kind": "ModelStepStarted",
        "model_step_id": model_step_id.to_int().to_double(),
        "effect_id": effect_id.to_int().to_double(),
      }
    ModelStepCompleted(model_step_id~, ..) =>
      {
        "kind": "ModelStepCompleted",
        "model_step_id": model_step_id.to_int().to_double(),
        "summary": event.to_string(),
      }
    ToolBatchStarted(model_step_id~, calls~) =>
      {
        "kind": "ToolBatchStarted",
        "model_step_id": model_step_id.to_int().to_double(),
        "call_count": calls.length().to_double(),
      }
    ToolChildDeclared(
      effect_id~,
      parent_effect_id~,
      root_effect_id~,
      depth~,
      call~,
    ) =>
      {
        "kind": "ToolChildDeclared",
        "effect_id": effect_id.to_int().to_double(),
        "parent_effect_id": parent_effect_id.to_int().to_double(),
        "root_effect_id": root_effect_id.to_int().to_double(),
        "depth": depth.to_double(),
        "call_id": call.call_id.to_string(),
      }
    ToolChildAbandoned(call~, parent_effect_id~) =>
      {
        "kind": "ToolChildAbandoned",
        "call_id": call.call_id.to_string(),
        "parent_effect_id": parent_effect_id.to_int().to_double(),
      }
    ToolCompleted(call~, outcome~, parent_effect_id~) =>
      {
        "kind": "ToolCompleted",
        "call_id": call.call_id.to_string(),
        "outcome": outcome.summary(),
        "parent_effect_id": match parent_effect_id {
          Some(id) => Json::number(id.to_int().to_double())
          None => Json::null()
        },
      }
    ToolCallsPreRejected(model_step_id~, calls~, ..) =>
      {
        "kind": "ToolCallsPreRejected",
        "model_step_id": model_step_id.to_int().to_double(),
        "call_count": calls.length().to_double(),
      }
    ToolCallApproved(model_step_id~, call~, consent_scope~) =>
      {
        "kind": "ToolCallApproved",
        "model_step_id": model_step_id.to_int().to_double(),
        "call_id": call.call_id.to_string(),
        "consent_scope": match consent_scope {
          Some(scope) => Json::string(safe_label(scope))
          None => Json::null()
        },
      }
    ToolWaveStarted(model_step_id~, calls~) =>
      {
        "kind": "ToolWaveStarted",
        "model_step_id": model_step_id.to_int().to_double(),
        "call_count": calls.length().to_double(),
      }
    RunSuspended(requirement~, model_step_id~) =>
      {
        "kind": "RunSuspended",
        "requirement_kind": requirement.kind,
        "model_step_id": model_step_id.to_int().to_double(),
      }
    RunResumed(model_step_id~) =>
      {
        "kind": "RunResumed",
        "model_step_id": model_step_id.to_int().to_double(),
      }
    CancelRequested(effect_ids~, reason~) =>
      {
        "kind": "CancelRequested",
        "effect_count": effect_ids.length().to_double(),
        "reason": reason.to_string(),
      }
    BudgetExhausted(dimension~, consumed~, limit~) =>
      {
        "kind": "BudgetExhausted",
        "dimension": dimension.to_string(),
        "consumed": consumed.to_double(),
        "limit": limit.to_double(),
      }
    InputRejected(input_kind~, reason~) =>
      { "kind": "InputRejected", "input_kind": input_kind, "reason": reason }
    TranscriptRewritten(messages_before~, messages_after~, reason~) =>
      {
        "kind": "TranscriptRewritten",
        "messages_before": messages_before.to_double(),
        "messages_after": messages_after.to_double(),
        "reason": reason,
      }
    UserMessageAppended(command_id~, message~) =>
      {
        "kind": "UserMessageAppended",
        "command_id": command_id,
        "content_chars": message_body_chars(message).to_double(),
      }
    SteerUndelivered(command_id~, reason~) =>
      {
        "kind": "SteerUndelivered",
        "command_id": command_id,
        "reason": safe_label(reason),
      }
    RunCompleted(final_message_summary~, model_steps~, tool_calls~) =>
      {
        "kind": "RunCompleted",
        "summary": final_message_summary,
        "model_steps": model_steps.to_double(),
        "tool_calls": tool_calls.to_double(),
      }
    RunFailed(reason~) => { "kind": "RunFailed", "reason": reason.to_string() }
    RunCancelled(reason~) =>
      { "kind": "RunCancelled", "reason": reason.to_string() }
  }
}

///|
fn message_body_chars(message : Message) -> Int32 {
  let content = match message {
    SystemMessage(content~) => content
    UserMessage(content~) => content
    AssistantMessage(content~, ..) => content
    ToolMessage(..) => return 0
  }
  let mut total = 0
  for item in content {
    match item {
      Text(text) => total = total + text.length()
      Image(..) => ()
    }
  }
  total
}

///|
priv enum RunExitDisposition {
  Terminated(
    run_id~ : RunId,
    turn_id~ : TurnId,
    outcome~ : RunOutcome,
    transcript~ : Transcript,
  )
  Suspended(
    run_id~ : RunId,
    turn_id~ : TurnId,
    suspension_id~ : String,
    requirement_kind~ : String,
  )
  ReleasedNoCommit(result~ : PromptResult)
}

///|
fn Puppet::finalize_run(
  self : Puppet,
  disposition : RunExitDisposition,
) -> PromptResult raise PuppetError {
  match disposition {
    Terminated(run_id~, turn_id~, outcome~, transcript~) => {
      self.mailbox.set_quiescent(Terminal(outcome~))
      self.last_completed_transcript = Some(transcript)
      self.last_outcome = Some(outcome)
      self.release_run_binding()
      Accepted(run_id~, turn_id~)
    }
    Suspended(run_id~, turn_id~, suspension_id~, requirement_kind~) => {
      self.phase_gate = self.phase_gate.enter_suspended(suspension_id)
      self.mailbox.set_quiescent(
        Suspended(run_id~, suspension_id~, requirement_kind~),
      )
      Accepted(run_id~, turn_id~)
    }
    ReleasedNoCommit(result~) => {
      self.release_run_binding()
      self.mailbox.set_quiescent(Idle)
      result
    }
  }
}

///|
fn Puppet::finalize_rejected(
  self : Puppet,
  error~ : PuppetError,
) -> PromptResult {
  self.reject_run(error~)
}

///|
fn Puppet::release_run_binding(self : Puppet) -> Unit {
  match (self.launch_gate, self.mailbox.active_run_id()) {
    (Some(gate), Some(run_id)) => gate.clear_run(run_id.to_string())
    _ => ()
  }
  self.phase_gate = PhaseGate::idle()
  self.mailbox.clear_run()
}

///|
fn Puppet::reject_run(self : Puppet, error~ : PuppetError) -> PromptResult {
  self.release_run_binding()
  self.mailbox.set_quiescent(Idle)
  Rejected(error~)
}
