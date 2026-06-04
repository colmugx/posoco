///|
async fn main {
  println("🐙 Posoco Agent REPL")
  println("====================")
  println("Type natural language. The agent will echo and suggest tools.")
  println("Type 'exit' or 'quit' to stop. Ctrl+D also works.")
  println("")

  // Setup shell tools (unified ToolProvider: list_tools + execute)
  let shell_tools = ShellTools::{  }

  // Setup model (mock — echoes input + suggests bash)
  let model = EchoModelPort::{  }

  // Session + observer
  let session_store = InMemorySessionStore::new()
  let observer = ConsoleObserver::{  }

  let agent_config : @posoco.AgentConfig = {
    max_tool_rounds: 5,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    thinking: None,
    model_context_window: None,
  }

  let agent = @posoco.Agent::new(
    model,
    tools=[shell_tools],
    hooks=[],
    memory=[],
    compressors=[@posoco.NoopCompressor::{  }],
    observers=[observer],
    sessions=[session_store],
    lifecycle=None,
    config=agent_config,
  )

  // Check for tool routing warnings
  let warnings = agent.tool_collisions()
  for w in warnings {
    println("⚠️  Tool collision: " + w)
  }

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

    let msg : @posoco.Message = {
      role: @posoco.Role::User,
      content: [@posoco.Content::Text(input)],
      tool_calls: [],
      tool_call_id: None,
      name: None,
    }

    let run_result = try? agent.run_turn(msg, session_id)
    match run_result {
      Ok(result) => {
        // Print assistant response
        for c in result.message.content {
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
      }
      Err(e) => println("💥 Error: " + e.to_string())
    }
    println("")
  }

  agent.shutdown()
  println("Bye! Session '" + session_id + "' saved.")
}

// ——— Inline Shell Tools ———

///|
/// ShellTools — unified shell tool provider (list + execute).
pub(all) struct ShellTools {}

///|
pub impl @posoco.ToolProvider for ShellTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  [
    @posoco.ToolDef::{
      name: "bash",
      description: "Execute a shell command and return its output",
      input_schema: Json::object(
        Map::from_array([("cmd", Json::string("the command to execute"))]),
      ),
      metadata: None,
      source: Some("host"),
    },
  ]
}

///|
pub impl @posoco.ToolProvider for ShellTools with fn execute(
  _self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  let cmd = match call.arguments {
    Json::Object(map) =>
      match map.get("cmd") {
        Some(Json::String(s)) => s
        _ => call.arguments.to_string()
      }
    _ => call.arguments.to_string()
  }
  if cmd == "" {
    raise @posoco.RuntimeError::InvocationFailed("empty command")
  }
  let (exit_code, output_data) = @process.collect_output_merged("sh", [
    "-c", cmd,
  ]) catch {
    e => raise @posoco.RuntimeError::InvocationFailed(e.to_string())
  }
  let content = output_data.text() catch { _ => "(decoding error)" }
  @posoco.ToolResult::{ content, structured: None, is_error: exit_code != 0 }
}

// ——— Mock Model ———

///|
/// EchoModelPort — a mock model that echoes user input and suggests tool use.
/// If the user input looks like a command (starts with $ or known cmd),
/// it returns a tool call for bash. Otherwise echoes as text.
pub(all) struct EchoModelPort {}

///|
pub impl @posoco.ModelPort for EchoModelPort with fn chat(
  self : EchoModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
) -> @posoco.ModelResponse {
  // Get last user message
  let user_text = match messages {
    [.., msg] if msg.role == @posoco.Role::User =>
      match msg.content {
        [@posoco.Content::Text(t), ..] => t
        _ => "Hello!"
      }
    _ => "Hello!"
  }

  // If it looks like a shell command, make a tool call
  if user_text.has_prefix("$ ") || user_text.has_prefix("run ") {
    let cmd = if user_text.has_prefix("$ ") {
      user_text["$ ".length():].to_owned()
    } else {
      user_text["run ".length():].to_owned()
    }
    let tool_call : @posoco.ToolCall = {
      id: "call_1",
      name: "bash",
      arguments: Json::object(Map::from_array([("cmd", Json::string(cmd))])),
    }
    let msg : @posoco.Message = {
      role: @posoco.Role::Assistant,
      content: [],
      tool_calls: [tool_call],
      tool_call_id: None,
      name: None,
    }
    @posoco.ModelResponse::{
      message: msg,
      tool_calls: [tool_call],
      finish_reason: @posoco.FinishReason::ToolCalls,
      usage: None,
      reasoning_summary: None,
    }
  } else {
    // Echo as text response
    let response_text = "You said: \"" +
      user_text +
      "\"\nTry: $ <command> or run <command> to execute shell commands."
    let msg : @posoco.Message = {
      role: @posoco.Role::Assistant,
      content: [@posoco.Content::Text(response_text)],
      tool_calls: [],
      tool_call_id: None,
      name: None,
    }
    @posoco.ModelResponse::{
      message: msg,
      tool_calls: [],
      finish_reason: @posoco.FinishReason::Stop,
      usage: None,
      reasoning_summary: None,
    }
  }
}
