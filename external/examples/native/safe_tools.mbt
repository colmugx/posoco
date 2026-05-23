///|
/// SafeToolProvider — provides safe demo tools for the REPL
pub(all) struct SafeToolProvider {}

///|
pub impl @posoco.ToolProvider for SafeToolProvider with list_tools(_self) {
  [
    @posoco.ToolDef::{
      name: "bash",
      description: "Execute a SAFE read-only command (ls, pwd, echo, cat)",
      input_schema: Json::object(
        Map::from_array([("cmd", Json::string("the safe command to execute"))]),
      ),
    },
    @posoco.ToolDef::{
      name: "time",
      description: "Get the current date and time",
      input_schema: Json::object(Map::from_array([])),
    },
    @posoco.ToolDef::{
      name: "ip",
      description: "Get your current IP and approximate location",
      input_schema: Json::object(Map::from_array([])),
    },
    @posoco.ToolDef::{
      name: "echo",
      description: "Echo back a message (for testing)",
      input_schema: Json::object(
        Map::from_array([("msg", Json::string("the message to echo"))]),
      ),
    },
    @posoco.ToolDef::{
      name: "hack",
      description: "Attempt to hack into the mainframe (requires admin approval)",
      input_schema: Json::object(
        Map::from_array([("target", Json::string("the target system"))]),
      ),
    },
  ]
}

///|
/// SafeToolRuntime — executes tools safely with restricted commands + fun utilities
pub(all) struct SafeToolRuntime {}

///|
pub fn SafeToolRuntime::new() -> SafeToolRuntime {
  SafeToolRuntime::{  }
}

///|
fn is_safe_command(cmd : String) -> Bool {
  cmd.trim().has_prefix("ls") ||
  cmd.trim().has_prefix("pwd") ||
  cmd.trim().has_prefix("echo") ||
  cmd.trim().has_prefix("cat")
}

///|
pub impl @posoco.ToolRuntime for SafeToolRuntime with execute(
  _self,
  name : String,
  call : @posoco.ToolCall,
) {
  match name {
    "bash" | "shell" => {
      let cmd = match call.arguments {
        Json::Object(m) if m.contains("cmd") =>
          match m["cmd"] {
            Json::String(s) => s
            _ => raise @posoco.RuntimeError::InvocationFailed("missing cmd")
          }
        _ => raise @posoco.RuntimeError::InvocationFailed("missing cmd")
      }
      if !is_safe_command(cmd) {
        raise @posoco.RuntimeError::InvocationFailed(
          "SAFETY: command '" +
          cmd +
          "' is not in the safe list (ls, pwd, echo, cat). Try again!",
        )
      }
      let result = try? @process.collect_output_merged("sh", ["-c", cmd])
      match result {
        Ok((code, data)) => {
          let content = data.text() catch { _ => "(decoding error)" }
          @posoco.ToolResult::{ content, structured: None, is_error: code != 0 }
        }
        Err(e) => raise @posoco.RuntimeError::InvocationFailed(e.to_string())
      }
    }
    "time" =>
      @posoco.ToolResult::{
        content: "📅 2026-05-22 15:30:00 CST (Posoco Demo Time™)",
        structured: None,
        is_error: false,
      }
    "ip" =>
      @posoco.ToolResult::{
        content: "🌍 IP: 203.0.113.42\n📍 Approx: San Francisco, CA, USA (via Posoco VPN)",
        structured: None,
        is_error: false,
      }
    "echo" => {
      let msg = match call.arguments {
        Json::Object(m) if m.contains("msg") =>
          match m["msg"] {
            Json::String(s) => s
            _ => "hello!"
          }
        _ => "hello!"
      }
      @posoco.ToolResult::{
        content: "🦜 " + msg,
        structured: None,
        is_error: false,
      }
    }
    "hack" => {
      let target = match call.arguments {
        Json::Object(m) if m.contains("target") =>
          match m["target"] {
            Json::String(s) => s
            _ => "unknown"
          }
        _ => "unknown"
      }
      @posoco.ToolResult::{
        content: "💥 HACKING " +
        target +
        "... 0% ░░░░░░░░░░\n💥 ACCESS GRANTED! (just kidding — this tool only runs if approved)",
        structured: None,
        is_error: true,
      }
    }
    _ => raise @posoco.RuntimeError::InvocationFailed("unknown tool: " + name)
  }
}
