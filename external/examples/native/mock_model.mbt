///|
/// MockModelPort — a simple mock LLM for the REPL demo
///
/// - "help" → lists available tools
/// - "time"/"date" → returns a tool call for time
/// - "ip"/"where" → returns a tool call for ip
/// - "hack"/"crack" → returns a hack tool call
/// - "echo" → returns an echo tool call
/// - "ls"/"list" → returns a safe bash tool call
/// - "pwd" → returns pwd tool call
/// - else → echoes back
pub(all) struct MockModelPort {}

///|
fn make_tool_call(
  name : String,
  args : Map[String, Json],
) -> @posoco.ModelResponse {
  let tool_call = @posoco.ToolCall::{
    id: "call_1",
    name,
    arguments: Json::object(args),
  }
  @posoco.ModelResponse::{
    message: @posoco.Message::{
      role: @posoco.Role::Assistant,
      content: [],
      tool_calls: [tool_call],
      tool_call_id: None,
      name: None,
    },
    tool_calls: [tool_call],
    finish_reason: @posoco.FinishReason::ToolCalls,
    usage: None,
    reasoning_summary: None,
  }
}

///|
fn make_text(text : String) -> @posoco.ModelResponse {
  @posoco.ModelResponse::{
    message: @posoco.Message::{
      role: @posoco.Role::Assistant,
      content: [@posoco.Content::Text(text)],
      tool_calls: [],
      tool_call_id: None,
      name: None,
    },
    tool_calls: [],
    finish_reason: @posoco.FinishReason::Stop,
    usage: None,
    reasoning_summary: None,
  }
}

///|
pub impl @posoco.ModelPort for MockModelPort with chat(
  _self,
  messages : Array[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
) {
  let last_msg = messages[messages.length() - 1]
  let input = match last_msg.content[0] {
    @posoco.Content::Text(t) => t
    _ => ""
  }

  if input.contains("help") || input == "" {
    make_text(
      "🐙 Posoco Demo Agent\n\nTools available:\n  • bash <cmd> — safe commands (ls, pwd, echo, cat)\n  • time — get current time\n  • ip — get your location\n  • echo <msg> — echo a message\n  • hack <target> — attempt hacking (requires approval!)\n\nTry: 'what time is it?' or 'hack the mainframe'",
    )
  } else if input.contains("time") ||
    input.contains("date") ||
    input.contains("when") {
    make_tool_call("time", Map::from_array([]))
  } else if input.contains("ip") ||
    input.contains("where") ||
    input.contains("location") ||
    input.contains("address") {
    make_tool_call("ip", Map::from_array([]))
  } else if input.contains("hack") ||
    input.contains("crack") ||
    input.contains("exploit") {
    let target = if input.contains("pentagon") {
      "PENTAGON.MIL"
    } else if input.contains("bank") {
      "SWISS-BANK.CH"
    } else {
      "NSA.GOV"
    }
    make_tool_call("hack", Map::from_array([("target", Json::string(target))]))
  } else if input.contains("echo") {
    let msg = input.find("echo ")
    let msg_text = match msg {
      Some(pos) => {
        let raw = input[pos + 5:]
        if raw == "" {
          "hello"
        } else {
          raw.to_owned()
        }
      }
      None => "hello"
    }
    make_tool_call("echo", Map::from_array([("msg", Json::string(msg_text))]))
  } else if input.contains("ls") ||
    input.contains("list") ||
    input.contains("show files") {
    make_tool_call("bash", Map::from_array([("cmd", Json::string("ls -la"))]))
  } else if input.contains("pwd") || input.contains("where am i") {
    make_tool_call("bash", Map::from_array([("cmd", Json::string("pwd"))]))
  } else if input.contains("cat") || input.contains("read file") {
    make_text("Which file would you like to read? Try 'cat /etc/hostname'")
  } else {
    make_text("You said: '" + input + "'. Try 'help' to see what I can do!")
  }
}
