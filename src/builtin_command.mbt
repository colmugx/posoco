///|
/// Built-in slash command port for `/compact` and `/fork-here`.
/// `invoke` enqueues a signal on the ControlMailbox for the pump's safe points.
/// The BuiltinCommandPort holds a reference to the Puppet's ControlMailbox.
/// It is constructed once by `Agent::Agent` from the long-lived mailbox
/// reference, then merged with extension commands when the one PuppetConfig
/// is assembled. Extension commands with the same id
/// (`compact` / `fork-here`) take precedence — the product layer can
/// override the builtins by declaring a command with that id.

///|
/// Built-in command processor. Holds a borrowed `&Mailbox` so `/compact`
/// and `/fork-here` can enqueue fork/compact signals. The mailbox
/// reference is shared with the Puppet and the Agent: one `ControlMailbox`
/// instance, three views. The Agent owns the concrete composition.
priv struct BuiltinCommandPort {
  mailbox : &@puppetry.Mailbox
  runtime : Ref[AgentRuntime?]
  /// Monotonic counter for command ids. Lives on the port so successive
  /// invokes produce distinct ids without needing wall-clock time.
  mut seq : Int
  mut compact_enabled : Bool
  mut fork_enabled : Bool
}

///|
fn BuiltinCommandPort::BuiltinCommandPort(
  mailbox : &@puppetry.Mailbox,
) -> BuiltinCommandPort {
  {
    mailbox,
    runtime: Ref(None),
    seq: 0,
    compact_enabled: true,
    fork_enabled: true,
  }
}

///|
/// Helper: mint a unique command id. Combines a stable prefix with the
/// port's monotonic counter so the same id is never returned twice.
fn BuiltinCommandPort::next_command_id(
  self : BuiltinCommandPort,
  prefix : String,
) -> @puppetry.CommandId {
  self.seq = self.seq + 1
  @puppetry.CommandId::unchecked("\{prefix}_\{self.seq}")
}

///|
impl @port.CommandPort for BuiltinCommandPort with fn commands(
  self : BuiltinCommandPort,
) -> Array[@port.CommandDef] {
  let definitions : Array[@port.CommandDef] = []
  if self.compact_enabled {
    definitions.push({
      id: "compact",
      label: "Compact",
      description: "Compact the conversation (the modelport decides the strategy)",
      category: "session",
      ctype: Action,
      params: [],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    })
  }
  if self.fork_enabled {
    definitions.push({
      id: "fork-here",
      label: "Fork Here",
      description: "Fork the conversation at the given message index (0-based)",
      category: "session",
      ctype: Action,
      params: [
        {
          name: "index",
          label: "Message Index",
          description: "The 0-based transcript index at which to split the new thread",
          ptype: Int,
          required: false,
          default: None,
          choices: None,
          positional: true,
        },
      ],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    })
  }
  definitions
}

///|
/// Normalized command ids for `invoke`, so the enable guard is written once
/// per builtin and the enqueue skeleton below stays id-agnostic.
priv enum BuiltinCommandKind {
  Compact
  ForkHere
}

///|
fn BuiltinCommandPort::resolve_command(
  self : BuiltinCommandPort,
  id : String,
) -> BuiltinCommandKind raise @error.CommandError {
  match id {
    "compact" if self.compact_enabled => Compact
    "compact" => raise NotFound(id)
    "fork-here" if self.fork_enabled => ForkHere
    "fork-here" => raise NotFound(id)
    other => raise NotFound(other)
  }
}

///|
/// Shared enqueue → CommandOutcome skeleton for `/compact` and `/fork-here`.
fn enqueue_outcome(
  name : String,
  accepted_feedback : String,
  result : @puppetry.EnqueueResult,
) -> @port.CommandOutcome {
  match result {
    Accepted(_) =>
      Success(feedback=accepted_feedback, structured=None, ui_hint=Some(Toast))
    RejectedStale(reason~, ..) => Failure(reason=name + " rejected: " + reason)
    RejectedQueueFull(depth~, ..) =>
      Failure(reason="\{name} queue full (depth=\{depth})")
    _ => Failure(reason="\{name} already requested")
  }
}

///|
async fn BuiltinCommandPort::invoke_idle_compact(
  self : BuiltinCommandPort,
  args : Json,
) -> @port.CommandOutcome {
  let session_id = match args {
    Object(fields) =>
      match fields.get("session_id") {
        Some(String(s)) => s
        _ => ""
      }
    String(s) => s
    _ => ""
  }
  if session_id == "" {
    return Failure(
      reason="compact requires a \"session_id\" argument when no run is active",
    )
  }
  match self.runtime.val {
    Some(runtime) => {
      let attempted : Result[@types.CompactOutcome, @error.AgentError] = Ok(
        runtime.compact_session(session_id),
      ) catch {
        error => Err(error)
      }
      match attempted {
        Err(error) =>
          Failure(
            reason="compact failed: " + safe_error_label(error.to_string()),
          )
        Ok(outcome) =>
          Success(
            feedback="compact completed (\{outcome.mode.to_string()}, session '\{outcome.final_session_id}', \{outcome.messages_after} messages)",
            structured=None,
            ui_hint=Some(Toast),
          )
      }
    }
    None =>
      Failure(
        reason="no active run and no agent runtime bound: compact unavailable",
      )
  }
}

///|
impl @port.CommandPort for BuiltinCommandPort with fn invoke(
  self : BuiltinCommandPort,
  id : String,
  args : Json,
) -> @port.CommandOutcome raise @error.CommandError {
  match self.resolve_command(id) {
    Compact =>
      match (self.mailbox.active_run_id(), self.mailbox.active_turn_id()) {
        (Some(run_id), Some(turn_id)) => {
          // Manual compact: trigger=Manual. The modelport can pick a
          // thorough strategy (LLM summary, OpenAI compat compact endpoint).
          let command_id = self.next_command_id("compact")
          let cmd : @puppetry.CompactCommand = {
            command_id,
            target_run_id: run_id,
            target_turn_id: turn_id,
            trigger: Manual,
          }
          enqueue_outcome(
            "compact",
            "compact queued, will execute at the next safe point",
            self.mailbox.enqueue_compact(cmd),
          )
        }
        _ => {
          let attempted : Result[@port.CommandOutcome, @error.AgentError] = Ok(
            self.invoke_idle_compact(args),
          ) catch {
            error => Err(Runtime(InvocationFailed(error.to_string())))
          }
          let outcome : @port.CommandOutcome = match attempted {
            Ok(value) => value
            Err(error) =>
              Failure(
                reason="compact failed: " + safe_error_label(error.to_string()),
              )
          }
          outcome
        }
      }
    ForkHere =>
      match (self.mailbox.active_run_id(), self.mailbox.active_turn_id()) {
        (Some(run_id), Some(turn_id)) => {
          // Parse optional `index` from args. Default is the current
          // transcript length (fork at the tail).
          let index = parse_fork_index(args)
          let command_id = self.next_command_id("fork")
          let cmd : @puppetry.ForkCommand = {
            command_id,
            target_run_id: run_id,
            target_turn_id: turn_id,
            fork_index: index,
          }
          enqueue_outcome(
            "fork",
            "fork queued at index \{index}, will execute at the next safe point",
            self.mailbox.enqueue_fork(cmd),
          )
        }
        _ =>
          Failure(
            reason="no active run: " +
              id +
              " can only be invoked while a turn is in flight",
          )
      }
  }
}

///|
#warnings("-unused_value")
extend BuiltinCommandPort with @port.CommandPort::{commands, invoke}

///|
/// Parse the optional `index` argument for `/fork-here`. Recognises:
/// - `{"index": N}` (object form)
/// - `N` (bare number, used by positional slash parsers)
/// Defaults to `0` when absent or unparseable (the caller can override
/// by passing a positive index). A future iteration can return the
/// current transcript length when omitted, but that requires the
/// transcript reference the BuiltinCommandPort does not hold today.
fn parse_fork_index(args : Json) -> Int {
  match args {
    Object(map) =>
      if map.contains("index") {
        match map["index"] {
          Number(n, ..) => n.to_int()
          _ => 0
        }
      } else {
        0
      }
    Number(n, ..) => n.to_int()
    _ => 0
  }
}

///|
/// Build the agent's full command list: the builtins
/// (`/compact`, `/fork-here`) registered first, followed by the extension
/// commands. Extensions that declare a command with id `compact` or
/// `fork-here` are dropped from the list — they override the builtins by
/// being the only one with that id (D5.4). This keeps the BuiltinCommandPort
/// as a sensible default that products can replace.
///
/// D3-Q1: the builtin port is a per-Agent singleton (constructed once in
/// `Agent::Agent`), so its `seq` counter stays monotonic across turns.
/// This method merely borrows it into the per-turn command list — it does
/// NOT reconstruct the port.
fn compose_agent_commands(
  commands : Array[&@port.CommandPort],
  builtin_command_port : BuiltinCommandPort,
) -> Array[&@port.CommandPort] {
  let builtin : &@port.CommandPort = builtin_command_port as &@port.CommandPort
  let extension_ids : Map[String, Unit] = Map::from_array([])
  for cmd_port in commands {
    for def in cmd_port.commands() {
      extension_ids[def.id] = ()
    }
  }
  // If any extension declares `compact` or `fork-here`, the builtin is
  // skipped — the extension version wins. Otherwise the builtin is the
  // default.
  builtin_command_port.compact_enabled = !extension_ids.contains("compact")
  builtin_command_port.fork_enabled = !extension_ids.contains("fork-here")
  let result : Array[&@port.CommandPort] = []
  if builtin_command_port.compact_enabled || builtin_command_port.fork_enabled {
    result.push(builtin)
  }
  for cmd in commands {
    result.push(cmd)
  }
  result
}

///|
pub fn Agent::commands(self : Agent) -> Array[&@port.CommandPort] {
  compose_agent_commands(
    self.runtime.commands,
    self.runtime.builtin_command_port,
  )
}
