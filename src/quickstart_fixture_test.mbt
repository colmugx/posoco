///|
/// Compiled public-API fixture for README.mbt.md and docs/01-quickstart.md.
/// Keep the documentation aligned with this black-box test instead of copying
/// signatures from memory.
struct QuickstartFixedModel {}

///|
pub impl @port.ModelPort for QuickstartFixedModel with fn chat(
  _self,
  _messages : Array[@types.Message],
  _tools : Array[@types.ToolDef],
  _options : @types.ChatOptions,
) -> @types.ModelResponse {
  let message : @types.Message = {
    role: @types.Role::Assistant,
    content: [@types.Content::Text("Hello from Posoco")],
    tool_calls: [],
    tool_call_id: None,
    name: Some("assistant"),
    reasoning_content: None,
  }
  {
    message,
    tool_calls: [],
    finish_reason: @types.FinishReason::Stop,
    usage: None,
    reasoning_content: None,
  }
}

///|
struct QuickstartMemoryStore {
  sessions : Map[String, @types.Session]
}

///|
fn copy_quickstart_metadata(metadata : Map[String, Json]) -> Map[String, Json] {
  let copied : Map[String, Json] = Map::from_array([])
  for key in metadata.keys() {
    copied[key] = metadata[key]
  }
  copied
}

///|
fn copy_quickstart_session(session : @types.Session) -> @types.Session {
  {
    messages: session.messages.copy(),
    metadata: copy_quickstart_metadata(session.metadata),
  }
}

///|
pub impl @port.SessionStore for QuickstartMemoryStore with fn load(
  self,
  id : String,
) -> Result[@types.Session, @error.SessionError] {
  match self.sessions.get(id) {
    Some(session) => Ok(copy_quickstart_session(session))
    None => Ok({ messages: [], metadata: Map::from_array([]) })
  }
}

///|
pub impl @port.SessionStore for QuickstartMemoryStore with fn save(
  self,
  id : String,
  session : @types.Session,
) -> Result[Unit, @error.SessionError] {
  self.sessions[id] = copy_quickstart_session(session)
  Ok(())
}

///|
async test "quickstart_fixture_uses_current_public_api" {
  let model = QuickstartFixedModel::{  }
  let store = QuickstartMemoryStore::{ sessions: Map::from_array([]) }
  let agent = @posoco.Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[@posoco.NoopCompressor::{  }],
    observers=[],
    sessions=[store],
    lifecycle=None,
    config={
      max_tool_rounds: 10,
      temperature: None,
      max_output_tokens: None,
      tool_choice: None,
      reasoning_effort: None,
      model_context_window: None,
    },
  )
  let input : @types.Message = {
    role: @types.Role::User,
    content: [@types.Content::Text("hello")],
    tool_calls: [],
    tool_call_id: None,
    name: None,
    reasoning_content: None,
  }
  let result = agent.run_turn(input, "quickstart-session")
  assert_eq(result.final_session_id, "quickstart-session")
  assert_true(
    result.message.content == [@types.Content::Text("Hello from Posoco")],
  )
}
