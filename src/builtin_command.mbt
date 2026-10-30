///|
/// Agent command facade; command-port implementation moved to @command.
using @command {
  type BuiltinCommandPort,
  compose_agent_commands,
  parse_fork_index,
}

///|
pub fn Agent::commands(self : Agent) -> Array[&@port.CommandPort] {
  compose_agent_commands(
    self.runtime.commands,
    self.runtime.builtin_command_port,
  )
}
