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
  { completion, processed_messages: messages.to_owned(), }
}

///|
pub impl @posoco.ModelPort for QuickstartModel with fn compact(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
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
/// An in-memory SessionPort keeps the example deterministic and offline.
/// Session values are copied at both boundaries so callers cannot mutate a
/// saved transcript through a shared array or map.
struct QuickstartSessionPort {
  sessions : Map[String, @posoco.Session]
}

///|
fn QuickstartSessionPort::QuickstartSessionPort() -> QuickstartSessionPort {
  { sessions: Map::from_array([]), }
}

///|
fn copy_session(session : @posoco.Session) -> @posoco.Session {
  { messages: session.messages.copy(), metadata: session.metadata.copy(), }
}

///|
pub impl @posoco.SessionPort for QuickstartSessionPort with fn load(
  self,
  id : String,
) -> @posoco.Session {
  match self.sessions.get(id) {
    Some(session) => copy_session(session)
    None =>
      // A missing id starts a new conversation. Storage failures should raise
      // SessionError instead of being converted to an empty session.
      { messages: [], metadata: Map::from_array([]), }
  }
}

///|
pub impl @posoco.SessionPort for QuickstartSessionPort with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Unit {
  self.sessions[id] = copy_session(session)
}

///|
/// Production extensions self-report their public port contributions through
/// one manifest. No test support or internal runtime type is needed here.
struct QuickstartExtension {
  model : QuickstartModel
  sessions : QuickstartSessionPort
  events : Ref[@posoco.Events?]
}

///|
fn QuickstartExtension::QuickstartExtension() -> QuickstartExtension {
  {
    model: QuickstartModel::{ },
    sessions: QuickstartSessionPort(),
    events: Ref(None),
  }
}

///|
pub impl @posoco.Extension for QuickstartExtension with fn extension_id(_self) -> String {
  "quickstart"
}

///|
pub impl @posoco.Extension for QuickstartExtension with fn manifest(self) -> @posoco.ExtensionManifest {
  let manifest = @posoco.ExtensionManifest::default(id="quickstart")
  {
    ..manifest,
    models: [self.model],
    sessions: [self.sessions],
    lifecycle: [self],
    requires: [@posoco.Capability::Events],
  }
}

///|
/// A plain object that reports progress without being an extension. The host
/// hands it an owner-bound `Events` value, so it needs no `Lifecycle` and no
/// reference to the Agent.
struct QuickstartReporter {
  publisher : @posoco.Events
}

///|
fn QuickstartReporter::new(
  system : @posoco.EventSystem,
) -> Result[QuickstartReporter, @posoco.EventError] {
  match system.publisher(owner="quickstart_reporter") {
    Ok(publisher) => Ok({ publisher, })
    Err(error) => Err(error)
  }
}

///|
fn QuickstartReporter::report_started(self : QuickstartReporter) -> Bool {
  self.publisher.publish(QuickstartChanged(Started)) is Ok(_)
}

///|
async fn main {
  // The host owns one event resource per Agent and creates it before the ports.
  let system = @posoco.EventSystem()
  // Listen before composition: an untaken system already delivers.
  let delivered = Ref(0)
  guard system.subscribe(
      envelope => {
        match envelope.event {
          QuickstartChanged(Started) => delivered.val += 1
          _ => () // Event is open: other protocols may add constructors.
        }
      },
      namespace_=Some(@posoco.EventNamespace::Extension("quickstart_reporter")),
    )
    is Ok(system_subscription) else {
    abort("quickstart could not subscribe before composing the Agent")
  }
  // A plain object gets its own publisher before the Agent exists.
  let reporter = match QuickstartReporter::new(system) {
    Ok(reporter) => reporter
    Err(_) => abort("quickstart could not obtain an owner-bound publisher")
  }
  if !reporter.report_started() {
    abort("quickstart could not publish before composing the Agent")
  }
  let extension = QuickstartExtension()
  // The same resource is handed to exactly one Agent.
  let agent = @posoco.Agent(
    exts=[extension],
    config=@posoco.agent_config(max_tool_rounds=Some(0)),
    events=system,
  )
  // Subscribe before the first turn: events are live notifications, not replayed state.
  let started = Ref(false)
  guard agent.subscribe_events(
      envelope => {
        match envelope.event {
          QuickstartChanged(Started) => started.val = true
          _ => () // Event is open: other protocols may add constructors.
        }
      },
      namespace_=Some(@posoco.EventNamespace::Extension("quickstart")),
    )
    is Ok(subscription) else {
    abort("quickstart could not subscribe to events")
  }
  // A capability granted before takeover keeps working afterwards.
  if !reporter.report_started() {
    abort("quickstart publisher stopped working after the Agent took over")
  }
  let input : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("Say hello"),
  ])
  let result = agent.run_turn(input, "quickstart-session")
  if !started.val {
    abort("quickstart did not receive its startup event")
  }
  if delivered.val != 2 {
    abort("quickstart pre-Agent subscriber saw \{delivered.val} events, want 2")
  }
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
  subscription.cancel()
  system_subscription.cancel()
  agent.shutdown()
  if reporter.report_started() {
    abort("quickstart publisher stayed open after shutdown")
  }
}
