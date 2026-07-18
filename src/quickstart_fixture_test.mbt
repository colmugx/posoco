///|
/// Compiled public-API fixture for README.mbt.md and docs/01-quickstart.md.
/// Keep the documentation aligned with this black-box test instead of copying
/// signatures from memory.
struct QuickstartFixedModel {}

///|
pub impl @posoco.ModelPort for QuickstartFixedModel with fn chat(
  _self,
  _messages : Array[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
) -> @posoco.ModelResponse {
  let message : @posoco.Message = {
    role: @posoco.Role::Assistant,
    content: [@posoco.Content::Text("Hello from Posoco")],
    tool_calls: [],
    tool_call_id: None,
    name: Some("assistant"),
    reasoning_content: None,
  }
  {
    message,
    tool_calls: [],
    finish_reason: @posoco.FinishReason::Stop,
    usage: None,
    reasoning_content: None,
  }
}

///|
struct QuickstartMemoryStore {
  sessions : Map[String, @posoco.Session]
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
fn copy_quickstart_session(session : @posoco.Session) -> @posoco.Session {
  {
    messages: session.messages.copy(),
    metadata: copy_quickstart_metadata(session.metadata),
  }
}

///|
pub impl @posoco.SessionStore for QuickstartMemoryStore with fn load(
  self,
  id : String,
) -> Result[@posoco.Session, @posoco.SessionError] {
  match self.sessions.get(id) {
    Some(session) => Ok(copy_quickstart_session(session))
    None => Ok({ messages: [], metadata: Map::from_array([]) })
  }
}

///|
pub impl @posoco.SessionStore for QuickstartMemoryStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Result[Unit, @posoco.SessionError] {
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
  let input : @posoco.Message = {
    role: @posoco.Role::User,
    content: [@posoco.Content::Text("hello")],
    tool_calls: [],
    tool_call_id: None,
    name: None,
    reasoning_content: None,
  }
  let result = agent.run_turn(input, "quickstart-session")
  assert_eq(result.final_session_id, "quickstart-session")
  assert_true(
    result.message.content == [@posoco.Content::Text("Hello from Posoco")],
  )
}
