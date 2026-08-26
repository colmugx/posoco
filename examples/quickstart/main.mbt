///|
/// A deterministic model port for a runnable, offline quickstart.
struct QuickstartModel {}

///|
pub impl @posoco.ModelPort for QuickstartModel with fn chat(
  _self,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let completion : @posoco.Completion = @posoco.Completion(
    content=[@posoco.Content::Text("Hello from the Posoco quickstart.")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@posoco.FinishReason::Stop,
    usage=None,
  )
  // No preprocessing occurs in this fixed model. Return a fresh snapshot so
  // Posoco can persist the complete user+assistant transcript safely.
  { completion, processed_messages: messages.to_owned() }
}

///|
pub impl @posoco.ModelPort for QuickstartModel with fn compact(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  // This model is intentionally tiny. Unsupported capabilities are errors,
  // not silent fallbacks that could hide an invalid production configuration.
  raise @posoco.ModelError::ResponseParse(
    "QuickstartModel does not implement compact",
  )
}

///|
pub impl @posoco.ModelPort for QuickstartModel with fn provider_config(_self) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
/// An in-memory SessionStore keeps the example deterministic and offline.
/// Session values are copied at both boundaries so callers cannot mutate a
/// saved transcript through a shared array or map.
struct QuickstartSessionStore {
  sessions : Map[String, @posoco.Session]
}

///|
fn QuickstartSessionStore::QuickstartSessionStore() -> QuickstartSessionStore {
  { sessions: Map::from_array([]) }
}

///|
fn copy_session(session : @posoco.Session) -> @posoco.Session {
  { messages: session.messages.copy(), metadata: session.metadata.copy() }
}

///|
pub impl @posoco.SessionStore for QuickstartSessionStore with fn load(
  self,
  id : String,
) -> @posoco.Session {
  match self.sessions.get(id) {
    Some(session) => copy_session(session)
    None =>
      // A missing id starts a new conversation. Storage failures should raise
      // SessionError instead of being converted to an empty session.
      { messages: [], metadata: Map::from_array([]) }
  }
}

///|
pub impl @posoco.SessionStore for QuickstartSessionStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit {
  self.sessions[id] = copy_session(session)
}

///|
/// Production extensions self-report their public port contributions through
/// one manifest. No testkit or internal runtime type is needed here.
struct QuickstartExtension {
  model : QuickstartModel
  sessions : QuickstartSessionStore
}

///|
fn QuickstartExtension::QuickstartExtension() -> QuickstartExtension {
  { model: QuickstartModel::{  }, sessions: QuickstartSessionStore() }
}

///|
pub impl @posoco.Extension for QuickstartExtension with fn extension_id(_self) -> String {
  "quickstart"
}

///|
pub impl @posoco.Extension for QuickstartExtension with fn manifest(self) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::empty(id="quickstart")
  { ..manifest, models: [self.model], sessions: [self.sessions] }
}

///|
async fn main {
  let extension = QuickstartExtension()
  let agent = @posoco.Agent(exts=[extension], config={
    max_tool_rounds: Some(0),
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
    compact_threshold: None,
  })
  let input : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("Say hello"),
  ])
  let result = agent.run_turn(input, "quickstart-session")
  match result.message {
    @posoco.Message::AssistantMessage(content~, ..) =>
      for item in content {
        match item {
          @posoco.Content::Text(text) => println(text)
          @posoco.Content::Image(..) => ()
        }
      }
    _ => abort("quickstart expected an AssistantMessage response")
  }
  agent.shutdown()
}
