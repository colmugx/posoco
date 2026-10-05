///|
/// Agent operation lifecycle (plan step 2): one centralized admission point
/// for the existing single-operation guard, one release point that projects
/// `operation_started` / `operation_settled` exactly once per admission.
///
/// The lifecycle sits above the per-turn identity layer: one admitted
/// operation covers the initial turn plus every follow-up drained inside the
/// same call (ordinary operations drain all follow-ups before settling). The
/// projection is deliberately independent of `TurnCompleted` and the internal
/// `OperationFinalized` phase event — settled is emitted only after the
/// single-operation guard has been released, on the normal, failure, soft-,
/// and hard-cancel paths alike.

///|
/// What kind of host-visible operation holds the guard. Ordinary user input
/// is `Turn`; `Resume` replays a persisted interrupted turn; `Compact` is a
/// manual compaction; `Wakeup` is an extension-requested ordinary turn.
priv enum OperationOrigin {
  Turn
  Resume
  Compact
  Wakeup
}

///|
fn OperationOrigin::label(self : OperationOrigin) -> String {
  match self {
    Turn => "turn"
    Resume => "resume"
    Compact => "compact"
    Wakeup => "wakeup"
  }
}

///|
priv enum OperationOutcome {
  Completed
  Failed
  Cancelled
}

///|
fn OperationOutcome::label(self : OperationOutcome) -> String {
  match self {
    Completed => "completed"
    Failed => "failed"
    Cancelled => "cancelled"
  }
}

///|
/// Map a terminal `AgentError` onto the settled outcome: cancellation is a
/// first-class settled state, everything else is a failure.
fn AgentError::operation_outcome(self : @error.AgentError) -> OperationOutcome {
  match self {
    @error.AgentError::Cancelled(_) => Cancelled
    _ => Failed
  }
}

///|
/// Identity of one admitted operation. Minted at admission so even the busy
/// rejection path and the `operation_started` projection can name the
/// incumbent; `identity` is the first turn's per-turn identity and
/// `operation_id` labels that turn's Puppet request (`agent_run_turn_N`,
/// `agent_compact_session_N`, `agent_wakeup_N`).
priv struct OperationAdmission {
  operation_id : String
  origin : OperationOrigin
  identity : TurnIdentity
  session_id : String
}

///|
priv struct AgentOperations {
  mut current : OperationAdmission?
}

///|
fn AgentOperations::AgentOperations() -> AgentOperations {
  { current: None, }
}

///|
/// Emit a core-owned `Custom` projection to every observer. Operation-level
/// and wakeup-level events hold no per-turn identity, so `scope` is `None`
/// by design (session attribution travels in the event data).
fn emit_custom_event(
  observers : Array[&@port.Observer],
  scope : @types.EventScope?,
  source : String,
  label : String,
  fields : Array[(String, Json)],
) -> Unit {
  let event : @types.TurnEvent = Custom(
    source~,
    label~,
    data=Json::object(Map::from_array(fields)),
  )
  for observer in observers {
    observer.on_event_at(scope, snapshot_turn_event(event))
  }
}

///|
/// Admit the next single operation or reject the caller with the structured
/// `AgentError::Busy`. Sets the single-operation guard before the first
/// await, so a rejected concurrent call cannot mutate turn-scoped state.
/// The wakeup label override lets the wakeup pump name its operations
/// without reaching into the turn identity counter.
fn AgentRuntime::admit_operation(
  self : AgentRuntime,
  session_id : String,
  origin : OperationOrigin,
  operation_label? : String? = None,
) -> OperationAdmission raise @error.AgentError {
  match self.operations.current {
    Some(active) =>
      raise @error.AgentError::Busy(
        operation_id=active.operation_id,
        session=active.session_id,
      )
    None => ()
  }
  let identity = self.mint_turn_identity(session_id)
  let operation_id = match operation_label {
    Some(label) => label
    None =>
      match origin {
        Turn | Resume => "agent_run_turn_\{identity.seq}"
        Compact => "agent_compact_session_\{identity.seq}"
        Wakeup => "agent_wakeup_\{identity.seq}"
      }
  }
  let admission : OperationAdmission = {
    operation_id,
    origin,
    identity,
    session_id,
  }
  self.operations.current = Some(admission)
  self.turn_active = true
  emit_custom_event(
    self.observers,
    None,
    "posoco.operation",
    "operation_started",
    [
      ("operation_id", Json::string(admission.operation_id)),
      ("session", Json::string(session_id)),
      ("origin", Json::string(origin.label())),
    ],
  )
  admission
}

///|
/// Release the guard and project `operation_settled` exactly once. The
/// settled event fires after `turn_active` is already cleared, so observers
/// that react to it (the wakeup pump, hosts) can admit the next operation
/// immediately. Idempotent: a hard-cancel unwind racing the normal release
/// never duplicates the projection.
fn AgentRuntime::release_operation(
  self : AgentRuntime,
  admission : OperationAdmission,
  outcome : OperationOutcome,
) -> Unit {
  match self.operations.current {
    Some(active) if active.operation_id == admission.operation_id => {
      self.turn_active = false
      self.operations.current = None
      emit_custom_event(
        self.observers,
        None,
        "posoco.operation",
        "operation_settled",
        [
          ("operation_id", Json::string(admission.operation_id)),
          ("session", Json::string(admission.session_id)),
          ("origin", Json::string(admission.origin.label())),
          ("outcome", Json::string(outcome.label())),
        ],
      )
      // The wakeup pump waits for this notification when a host operation
      // holds the guard; wake it so a deferred wakeup ticket re-arms.
      self.wakeup.notify_operation_settled()
    }
    _ => ()
  }
}
