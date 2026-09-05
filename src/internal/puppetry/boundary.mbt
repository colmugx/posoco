// ──────────────────────────────────────────────────────────────────────────
// commit_boundary — the deterministic pre-commit → freeze → commit → dispatch
// ──────────────────────────────────────────────────────────────────────────

///|
/// Commit one fixed side-effect boundary. The boundary emits every KernelEvent
/// only after the single journal barrier succeeds, but persists only its
/// recovery-relevant primary fact. This keeps append count proportional to
/// side effects rather than the number of observer events.
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
  let pre_commit_rev = self.config.journal.revision()
  let savepoint_id = "\{boundary_id_prefix}_r\{pre_commit_rev}"
  let entry = boundary_entry(
    state, kind, events, run_id, turn_id, session_id, savepoint_id,
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
  // Every event is published after the one boundary commit. They share its
  // committed revision while EventDispatcher preserves a strict event seq.
  for event in events {
    dispatcher.dispatch(event, committed_rev)
  }
}

///|
/// Select the one boundary category for a reducer transition in a single
/// pass over the events. Priority is terminal → suspension → tool outcome
/// → assistant completion → input; events with no natural category (intents
/// such as `ModelStepStarted`) never win, and the assistant fallback applies
/// only when nothing else matched. This is a fixed runtime rule, not an
/// extension-selectable policy.
fn boundary_kind_for_events(events : Array[KernelEvent]) -> SavepointKind {
  let mut best_rank = -1
  let mut best_kind = AssistantCommitted
  for event in events {
    let (rank, kind) : (Int, SavepointKind) = match event {
      RunCompleted(..) | RunFailed(..) | RunCancelled(..) => (4, RunTerminal)
      RunSuspended(..) => (3, RunSuspended)
      ToolCompleted(..) => (2, ToolCommitted)
      ModelStepCompleted(..) => (1, AssistantCommitted)
      RunStarted(..) => (0, InputAccepted)
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
/// Map one event to its natural boundary category. Used solely to choose the
/// persisted primary fact within a multi-event boundary.
fn event_to_boundary_kind(event : KernelEvent) -> SavepointKind {
  match event {
    RunStarted(..) => InputAccepted
    ModelStepCompleted(..) => AssistantCommitted
    ToolCompleted(..) => ToolCommitted
    RunSuspended(..) => RunSuspended
    RunCompleted(..) | RunFailed(..) | RunCancelled(..) => RunTerminal
    _ => AssistantCommitted
  }
}

///|
/// Construct the one durable entry for a boundary. The entry kind describes
/// the recovery boundary; event payloads retain their exact event kind for
/// inspection without forcing a durability barrier per observer event.
fn boundary_entry(
  state : RunState,
  kind : SavepointKind,
  events : Array[KernelEvent],
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  savepoint_id : String,
) -> JournalEntry raise PuppetError {
  if events.is_empty() {
    raise ReducerInvariantViolation(
      category=IllegalPhase(
        phase="commit_boundary",
        detail="boundary has no events",
      ),
    )
  }
  let (summary, payload) = if kind == InputAccepted {
    (
      "InputAccepted(run=\{run_id.to_string()})",
      Json::object(
        Map::from_array([
          ("kind", Json::string("InputAccepted")),
          ("run_id", Json::string(run_id.to_string())),
          ("turn_id", Json::string(turn_id.to_string())),
          ("session_id", Json::string(session_id.to_string())),
          (
            "catalog_version",
            Json::number(state.catalog_version().to_int().to_double()),
          ),
        ]),
      ),
    )
  } else {
    let primary = boundary_primary_event(events, kind)
    (primary.to_string(), kernel_event_payload(primary))
  }
  {
    identity: { run_id, turn_id, session_id, savepoint_id, kind, entry_seq: 0, },
    revision: 0,
    summary,
    payload,
  }
}

///|
/// Find the event that represents the durable fact for its boundary.
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
/// Convert a committed domain event into a bounded, machine-readable journal
/// payload. This intentionally carries event facts and safe summaries only;
/// prompts, tool arguments, image data and tool result bodies remain outside
/// the journal payload.
fn kernel_event_payload(event : KernelEvent) -> Json {
  match event {
    RunStarted(details~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("RunStarted")),
          ("run_id", Json::string(details.run_id.to_string())),
          ("session_id", Json::string(details.session_id.to_string())),
        ]),
      )
    ModelStepStarted(model_step_id~, effect_id~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("ModelStepStarted")),
          ("model_step_id", Json::number(model_step_id.to_int().to_double())),
          ("effect_id", Json::number(effect_id.to_int().to_double())),
        ]),
      )
    ModelStepCompleted(model_step_id~, ..) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("ModelStepCompleted")),
          ("model_step_id", Json::number(model_step_id.to_int().to_double())),
          // KernelEvent::Show intentionally excludes message/provider payloads.
          ("summary", Json::string(event.to_string())),
        ]),
      )
    ToolBatchStarted(model_step_id~, calls~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("ToolBatchStarted")),
          ("model_step_id", Json::number(model_step_id.to_int().to_double())),
          ("call_count", Json::number(calls.length().to_double())),
        ]),
      )
    ToolCompleted(call~, outcome~) =>
      // The committed call is available to in-memory subscribers, but this
      // durable diagnostic payload intentionally excludes its arguments.
      Json::object(
        Map::from_array([
          ("kind", Json::string("ToolCompleted")),
          ("call_id", Json::string(call.call_id.to_string())),
          ("outcome", Json::string(outcome.summary())),
        ]),
      )
    RunSuspended(requirement~, model_step_id~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("RunSuspended")),
          ("requirement_kind", Json::string(requirement.kind)),
          ("model_step_id", Json::number(model_step_id.to_int().to_double())),
        ]),
      )
    RunResumed(model_step_id~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("RunResumed")),
          ("model_step_id", Json::number(model_step_id.to_int().to_double())),
        ]),
      )
    CancelRequested(effect_ids~, reason~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("CancelRequested")),
          ("effect_count", Json::number(effect_ids.length().to_double())),
          ("reason", Json::string(reason.to_string())),
        ]),
      )
    BudgetExhausted(dimension~, consumed~, limit~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("BudgetExhausted")),
          ("dimension", Json::string(dimension.to_string())),
          ("consumed", Json::number(consumed.to_double())),
          ("limit", Json::number(limit.to_double())),
        ]),
      )
    InputRejected(input_kind~, reason~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("InputRejected")),
          ("input_kind", Json::string(input_kind)),
          ("reason", Json::string(reason)),
        ]),
      )
    TranscriptRewritten(messages_before~, messages_after~, reason~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("TranscriptRewritten")),
          ("messages_before", Json::number(messages_before.to_double())),
          ("messages_after", Json::number(messages_after.to_double())),
          ("reason", Json::string(reason)),
        ]),
      )
    RunCompleted(final_message_summary~, model_steps~, tool_calls~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("RunCompleted")),
          ("summary", Json::string(final_message_summary)),
          ("model_steps", Json::number(model_steps.to_double())),
          ("tool_calls", Json::number(tool_calls.to_double())),
        ]),
      )
    RunFailed(reason~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("RunFailed")),
          ("reason", Json::string(reason.to_string())),
        ]),
      )
    RunCancelled(reason~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("RunCancelled")),
          ("reason", Json::string(reason.to_string())),
        ]),
      )
  }
}

///|
/// Put the Puppet back into a quiescent, retryable state on a host-level
/// failure that prevents the reducer from producing a terminal outcome. The
/// typed error remains the caller-visible diagnostic; cleanup must not leave a
/// stale lease or an active mailbox behind.
fn Puppet::reject_run(self : Puppet, error~ : PuppetError) -> PromptResult {
  self.phase_gate = PhaseGate::idle()
  self.mailbox.clear_run()
  self.mailbox.set_quiescent(Idle)
  Rejected(error~)
}
