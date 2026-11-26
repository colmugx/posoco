///|
pub fn Puppet::estimate_session_context(
  self : Puppet,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  messages : Array[Message],
  policy : RunPolicy,
) -> Unit {
  if messages.is_empty() {
    self.context_states.remove(session_id.to_string())
    return
  }
  let snap_result : Result[TurnSnapshot, PuppetError] = Ok(
    TurnSnapshot::capture({
      run_id,
      turn_id,
      session_id,
      catalog: self.config.catalog,
      policy,
      deadline: None,
      hook_provenance: [],
      lifecycle_provenance: [],
      subscriber_provenance: [],
    }),
  ) catch {
    e => Err(e)
  }
  match snap_result {
    Ok(snap) => self.record_context_estimate(session_id, messages, snap)
    Err(_) => ()
  }
}

///|
pub async fn Puppet::rewind_standalone(
  self : Puppet,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  original_messages : Array[Message],
  rewound_messages : Array[Message],
  policy : RunPolicy,
  operation_id : String,
) -> Unit raise PuppetError {
  let (gate_with_lease, _) = self.phase_gate.acquire_prompt(
    operation_id, run_id, turn_id,
  )
  self.phase_gate = gate_with_lease
  self.last_completed_transcript = None
  errdefer {
    self.release_run_binding()
    self.mailbox.set_quiescent(Idle)
  }
  let snap : TurnSnapshot = TurnSnapshot::capture({
    run_id,
    turn_id,
    session_id,
    catalog: self.config.catalog,
    policy,
    deadline: None,
    hook_provenance: [],
    lifecycle_provenance: [],
    subscriber_provenance: [],
  })
  self.mailbox.bind_run(run_id, turn_id)
  self.phase_gate = self.phase_gate.transition(Active)
  let initial_state : RunState = RunState::initial(
    run_id~,
    session_id~,
    budget=snap.budget(),
  ) catch {
    e =>
      raise ReducerInvariantViolation(
        category=IllegalPhase(phase="rewind_session", detail=e.to_string()),
      )
  }
  let start_out : ReduceOutput = reduce(
    initial_state,
    self.config.catalog,
    Start(payload={
      initial_messages: original_messages.copy(),
      catalog_version: snap.catalog_version(),
    }),
  ) catch {
    e =>
      raise ReducerInvariantViolation(
        category=IllegalPhase(phase="rewind_session", detail=e.to_string()),
      )
  }
  let out : ReduceOutput = reduce(
    start_out.next_state(),
    self.config.catalog,
    TranscriptRewrite(payload={
      rewritten_messages: rewound_messages.copy(),
      reason: "rewind_standalone",
    }),
  ) catch {
    e =>
      raise ReducerInvariantViolation(
        category=IllegalPhase(phase="rewind_session", detail=e.to_string()),
      )
  }
  let dispatcher = EventDispatcher(run_id, turn_id, session_id)
  for sub in self.config.subscribers {
    dispatcher.register(sub)
  }
  self.commit_boundary(
    out.next_state(),
    boundary_kind_for_events(out.events()),
    out.events(),
    dispatcher,
    run_id,
    turn_id,
    session_id,
    "sp_rewind_standalone",
  )
  if rewound_messages.is_empty() {
    self.context_states.remove(session_id.to_string())
  } else {
    self.record_context_estimate(session_id, rewound_messages, snap)
  }
  self.mailbox.set_quiescent(Idle)
  self.release_run_binding()
}
