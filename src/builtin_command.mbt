///|
/// Agent command facade over the `@command` port.
using @command {type BuiltinCommandPort, compose_agent_commands}

///|
pub fn Agent::commands(self : Agent) -> Array[&@port.CommandPort] {
  compose_agent_commands(
    self.runtime.commands,
    self.runtime.builtin_command_port,
  )
}
