///|
/// Compiled public-API fixture for README.mbt.md and docs/01-quickstart.md.
/// Keep the documentation aligned with this black-box test instead of copying
/// signatures from memory.
struct QuickstartFixedModel {}

///|
pub impl @port.ModelPort for QuickstartFixedModel with fn chat(
  _self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  let completion : @kernel.Completion = @kernel.Completion(
    content=[@kernel.Text("Hello from Posoco")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@kernel.Stop,
    usage=None,
  )
  { completion, processed_messages: [] }
}

///|
pub impl @port.ModelPort for QuickstartFixedModel with fn compact(
  _self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  raise @error.ModelError::ResponseParse(
    "QuickstartFixedModel does not implement compact",
  )
}

///|
pub impl @port.ModelPort for QuickstartFixedModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
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
) -> @types.Session {
  match self.sessions.get(id) {
    Some(session) => copy_quickstart_session(session)
    None => { messages: [], metadata: Map::from_array([]) }
  }
}

///|
pub impl @port.SessionStore for QuickstartMemoryStore with fn save(
  self,
  id : String,
  session : @types.Session,
) -> Unit {
  self.sessions[id] = copy_quickstart_session(session)
}

///|
async test "quickstart_fixture_uses_current_public_api" {
  let model = QuickstartFixedModel::{  }
  let store = QuickstartMemoryStore::{ sessions: Map::from_array([]) }
  let agent = @posoco.Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config={
      max_tool_rounds: Some(10),
      temperature: None,
      max_output_tokens: None,
      model_context_window: None,
      compact_threshold: None,
      system_prompt: None,
    },
  )
  let input : @kernel.Message = @kernel.UserMessage(content=[
    @kernel.Text("hello"),
  ])
  let result = agent.run_turn(input, "quickstart-session")
  assert_eq(result.final_session_id, "quickstart-session")
  match result.message {
    @kernel.AssistantMessage(content~, ..) =>
      assert_eq(content, [@kernel.Text("Hello from Posoco")])
    _ => fail("expected AssistantMessage")
  }
}
