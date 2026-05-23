///|
/// ShellToolProvider — provides shell/command execution tools
pub(all) struct ShellToolProvider {}

///|
pub impl @posoco.ToolProvider for ShellToolProvider with list_tools(_self) {
  [
    @posoco.ToolDef::{
      name: "bash",
      description: "Execute a shell command and return its output",
      input_schema: Json::object(
        Map::from_array([("cmd", Json::string("the command to execute"))]),
      ),
    },
    @posoco.ToolDef::{
      name: "shell",
      description: "Execute a shell command (alias for bash)",
      input_schema: Json::object(
        Map::from_array([("cmd", Json::string("the command to execute"))]),
      ),
    },
  ]
}

///|
/// ShellToolRuntime — executes shell commands via system subprocess
pub(all) struct ShellToolRuntime {}

///|
pub fn ShellToolRuntime::new() -> ShellToolRuntime {
  ShellToolRuntime::{  }
}

///|
pub impl @posoco.ToolRuntime for ShellToolRuntime with execute(
  _self,
  name : String,
  call : @posoco.ToolCall,
) {
  let cmd = extract_command(call.arguments)
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

///|
/// Extract command string from ToolCall arguments JSON
fn extract_command(args : Json) -> String {
  match args {
    Json::Object(map) =>
      if map.contains("cmd") {
        match map["cmd"] {
          Json::String(s) => s
          _ => args.to_string()
        }
      } else if map.contains("command") {
        match map["command"] {
          Json::String(s) => s
          _ => args.to_string()
        }
      } else {
        args.to_string()
      }
    _ => args.to_string()
  }
}
