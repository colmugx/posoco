///|
extenum @posoco.Event += {
  PublicProgress(Int32)
}

///|
struct PublicEventExtension {
  model : MockModelPort
  events : Ref[@posoco.Events?]
  subscription : Ref[@posoco.Subscription?]
  received : Array[Int32]
}

///|
impl @posoco.Extension for PublicEventExtension with fn extension_id(_self) {
  "public-events"
}

///|
impl @posoco.Extension for PublicEventExtension with fn manifest(self) {
  @posoco.ExtensionManifest(
    id="public-events",
    models=[self.model],
    lifecycle=[self],
    requires=[Events],
  )
}

///|
impl @posoco.Lifecycle for PublicEventExtension with fn on_compose(self, view) raise @posoco.CompositionError {
  guard view.events() is Some(events) else {
    raise @posoco.CompositionError::ExtensionComposeFailed(
      manifest_id="public-events",
      detail="missing declared Events capability",
    )
  }
  self.events.val = Some(events)
  match
    events.subscribe(
      envelope => {
        if envelope.event is PublicProgress(value) {
          self.received.push(value)
        }
      },
      namespace_=Some(@posoco.EventNamespace::Extension("public-events")),
    ) {
    Ok(subscription) => self.subscription.val = Some(subscription)
    Err(_) =>
      raise @posoco.CompositionError::ExtensionComposeFailed(
        manifest_id="public-events",
        detail="event runtime already closed during composition",
      )
  }
}

///|
impl @posoco.Lifecycle for PublicEventExtension with fn on_start(self) {
  guard self.events.val is Some(events) else { fail("missing Events") }
  guard events.publish(PublicProgress(1)) is Ok(_) else {
    fail("startup publication failed")
  }
}

///|
impl @posoco.Lifecycle for PublicEventExtension with fn on_shutdown(self) {
  if self.subscription.val is Some(subscription) {
    subscription.cancel()
  }
}

///|
async test "events public facade: extension registers, publishes and listens without runtime factories" {
  let extension = PublicEventExtension::{
    model: MockModelPort::{ responses: [stop_response("ok")], index: 0, },
    events: Ref(None),
    subscription: Ref(None),
    received: [],
  }
  let agent = @posoco.Agent(exts=[extension], config=@posoco.agent_config())
  assert_eq(extension.received, [])
  let host_received : Array[Int32] = []
  guard agent.subscribe_events(envelope => {
      if envelope.event is PublicProgress(value) {
        host_received.push(value)
      }
    })
    is Ok(host_subscription) else {
    fail("host subscription failed")
  }
  ignore(agent.run_turn(user_msg("hello"), "public-events"))
  assert_eq(extension.received, [1])
  assert_eq(host_received, [1])
  host_subscription.cancel()
  guard extension.events.val is Some(events) else { fail("missing Events") }
  guard events.publish(PublicProgress(2)) is Ok(_) else {
    fail("publish failed")
  }
  assert_eq(extension.received, [1, 2])
  assert_eq(host_received, [1])
  agent.shutdown()
  guard events.publish(PublicProgress(3)) is Err(Closed) else {
    fail("shutdown left publication rights alive")
  }
}

///|
async test "events public facade: closed Agent operations report typed errors before any notification" {
  let extension = PublicEventExtension::{
    model: MockModelPort::{ responses: [], index: 0, },
    events: Ref(None),
    subscription: Ref(None),
    received: [],
  }
  let agent = @posoco.Agent(exts=[extension], config=@posoco.agent_config())
  agent.shutdown()
  for operation in ["turn", "compact", "resume"] {
    let result : Result[Unit, @posoco.AgentError] = Ok(
      match operation {
        "turn" => ignore(agent.run_turn(user_msg("late"), "closed"))
        "compact" => ignore(agent.compact_session("closed"))
        _ => ignore(agent.resume_turn("closed"))
      },
    ) catch {
      error => Err(error)
    }
    match result {
      Err(Runtime(InvocationFailed(message))) =>
        assert_eq(message, "agent is shut down")
      _ => fail("closed Agent did not reject \{operation} with its typed error")
    }
  }
  assert_eq(extension.model.index, 0)
}
