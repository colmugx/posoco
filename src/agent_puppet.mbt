///|
/// Agent-owned Puppet composition and per-prompt projection.
///
/// Composition-static state is built exactly once in `Agent::Agent`: catalog,
/// HostRuntime adapter, journal, committed-event subscriber, mailbox and
/// Puppet. Per-turn execution lives in `agent_turn.mbt`; this file keeps the
/// per-prompt identity minted before `TurnStarted` is projected.

///|
/// Per-turn identity minted by the Agent before `TurnStarted` is projected,
/// so every turn event — including the first — carries attribution scope.
/// The same identity drives the Puppet prompt request.
priv struct TurnIdentity {
  seq : Int
  run_id : @kernel.RunId
  turn_id : @kernel.TurnId
  session_id : @kernel.SessionId
}

///|
/// Allocate the next unique run/turn identity. The counter is Agent-owned
/// and monotonic, so two calls on the same Agent never share run/turn ids
/// while still using the same Puppet and journal.
fn AgentRuntime::mint_turn_identity(
  self : AgentRuntime,
  session_id : String,
) -> TurnIdentity {
  let seq = self.next_run_seq
  self.next_run_seq = seq + 1
  {
    seq,
    run_id: @kernel.RunId::unchecked("agent_run_\{seq}"),
    turn_id: @kernel.TurnId::unchecked("agent_turn_\{seq}"),
    session_id: @kernel.SessionId::unchecked(session_id),
  }
}

///|
/// The attribution scope projected onto this turn's observer events.
fn TurnIdentity::scope(self : TurnIdentity) -> @types.EventScope {
  { session_id: self.session_id, run_id: self.run_id, turn_id: self.turn_id, }
}
