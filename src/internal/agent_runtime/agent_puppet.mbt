///|

///|
priv struct TurnIdentity {
  seq : Int32
  run_id : @kernel.RunId
  turn_id : @kernel.TurnId
  session_id : @kernel.SessionId
}

///|
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
fn TurnIdentity::scope(self : TurnIdentity) -> @types.EventScope {
  { session_id: self.session_id, run_id: self.run_id, turn_id: self.turn_id, }
}
