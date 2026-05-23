///|
/// main.mbt — Posoco REPL Agent Demo
///
/// An interactive REPL that showcases:
/// - Async ModelPort (MockModelPort)
/// - PipelineHook for dangerous command approval (DangerousCommandHook)
/// - Observer for event logging (ConsoleObserver)
/// - Session persistence (InMemorySessionStore)
/// - Safe tool execution (SafeToolProvider + SafeToolRuntime)
async fn main {
  println("🐙 Posoco Agent REPL")
  println("====================")
  println("Try: help, time, ip, echo <msg>, ls, pwd, hack <target>")
  println("The 'hack' tool requires admin approval (demo of approval flow).")
  println("")

  // Setup all ports
  let model = MockModelPort::{  }
  let tool_provider = SafeToolProvider::{  }
  let tool_runtime = SafeToolRuntime::new()
  let session_store = InMemorySessionStore::new()
  let observer = ConsoleObserver::{  }
  let dangerous_hook = DangerousCommandHook::{  }

  let agent = @posoco.Agent::new(
    model,
    tool_provider,
    tool_runtime,
    session_store,
    observer,
    @posoco.NoopCompressor::{  },
    Some(dangerous_hook),
    None,
    @posoco.AgentConfig::{
      max_tool_rounds: 5,
      temperature: None,
      max_output_tokens: None,
      tool_choice: None,
      thinking: None,
      model_context_window: None,
    },
  )

  // REPL loop
  let session_id = "demo-session"
  while true {
    @stdio.stdout.write("> ")
    let input_op = @stdio.stdin.read_until("\n")
    let input_raw = match input_op {
      None => break
      Some(line) => line
    }
    let input = input_raw.trim().to_owned()

    if input == "exit" || input == "quit" {
      break
    }
    if input == "" {
      continue
    }

    let msg = @posoco.Message::{
      role: @posoco.Role::User,
      content: [@posoco.Content::Text(input)],
      tool_calls: [],
      tool_call_id: None,
      name: None,
    }

    let run_result = try? agent.run_turn(msg, session_id)
    let result = match run_result {
      Ok(r) => {
        println("")
        r
      }
      Err(e) => {
        println("")
        println("Error: " + e.to_string())
        continue
      }
    }

    // Print LLM response text
    let last_msg = result.message
    for c in last_msg.content {
      match c {
        @posoco.Content::Text(t) => println("🤖 " + t)
        _ => ()
      }
    }

    // Print tool results
    for r in result.tool_results {
      if r.is_error {
        println("  ❌ " + r.content)
      } else {
        println("  ✓ " + r.content)
      }
    }
    println("")
  }

  println("Bye! Session '" + session_id + "' saved.")
}
