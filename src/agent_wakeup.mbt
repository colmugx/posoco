///|
/// Root-side host bridge for the wakeup ledger: the only wakeup code that
/// knows `AgentRuntime`. A wakeup ticket is an ordinary turn through the
/// single-operation lifecycle and nothing else.
impl @wakeup.WakeupHost for AgentRuntime with fn wakeup_idle(
  self : AgentRuntime,
) -> Bool {
  !self.turn_active
}

///|
impl @wakeup.WakeupHost for AgentRuntime with fn run_wakeup_turn(
  self : AgentRuntime,
  input : @kernel.Message,
  session_id : String,
  operation_id : String,
  on_admitted : () -> Unit,
) -> Unit raise @error.AgentError {
  ignore(
    self.run_turn_with_mode(
      input,
      session_id,
      false,
      origin=Wakeup,
      operation_label=Some(operation_id),
      on_admitted=Some(fn(admission) {
        ignore(admission)
        on_admitted()
      }),
    ),
  )
}
