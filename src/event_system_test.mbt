///|
extenum @posoco.Event += {
  ResourceNotice(String)
}

///|
struct PrecomposedPublisherModel {
  events : @posoco.Events
}

///|
fn PrecomposedPublisherModel::PrecomposedPublisherModel(
  events : @posoco.Events,
) -> PrecomposedPublisherModel raise {
  guard events.publish(ResourceNotice("constructed")) is Ok(_) else {
    fail("publisher could not publish during construction")
  }
  { events, }
}

///|
impl @posoco.ModelPort for PrecomposedPublisherModel with fn chat(
  self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  guard self.events.publish(ResourceNotice("chat")) is Ok(_) else {
    raise Transport("publisher was revoked while the Agent was active")
  }
  stop_response("ok")
}

///|
impl @posoco.ModelPort for PrecomposedPublisherModel with fn compact(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise ResponseParse("no compaction in this test")
}

///|
impl @posoco.ModelPort for PrecomposedPublisherModel with fn provider_config(
  _self,
) {
  @posoco.ProviderConfig::empty()
}

///|
async test "event system: plain port publishes before composition and inside the same Agent" {
  let system = @posoco.EventSystem()
  let seen : Array[(String, @posoco.EventNamespace)] = []
  let subscription = system
    .subscribe(fn(envelope) {
      if envelope.event is ResourceNotice(value) {
        seen.push((value, envelope.namespace_))
      }
    })
    .unwrap()
  defer subscription.cancel()
  let publisher = system.publisher(owner="provider").unwrap()
  let model = PrecomposedPublisherModel(publisher)
  assert_eq(seen, [("constructed", Extension("provider"))])
  let agent = @posoco.Agent(
    exts=[@test_support.tk_ext(id="model", model=Some(model))],
    config=@posoco.agent_config(),
    events=system,
  )
  let host_seen : Array[String] = []
  let host = agent
    .subscribe_events(fn(envelope) {
      if envelope.event is ResourceNotice(value) {
        host_seen.push(value)
      }
    })
    .unwrap()
  defer host.cancel()
  ignore(agent.run_turn(user_msg("hello"), "precomposed-publisher"))
  assert_eq(seen, [
    ("constructed", Extension("provider")),
    ("chat", Extension("provider")),
  ])
  assert_eq(host_seen, ["chat"])
  agent.shutdown()
  assert_true(publisher.publish(ResourceNotice("closed")) is Err(Closed))
}

///|
test "event system: owners are explicit and an unclaimed resource has a complete lifetime" {
  let system = @posoco.EventSystem()
  for owner in ["", " ", "\t\n"] {
    assert_true(system.publisher(owner~) is Err(InvalidOwner))
  }
  let publisher = system.publisher(owner=" provider ").unwrap()
  assert_true(
    publisher.publish(@events.Core(TurnStarted)) is Err(ReservedEvent),
  )
  assert_true(publisher.publish(ResourceNotice("no history")) is Ok(_))
  let seen : Array[(@posoco.EventNamespace, @posoco.EventScope?)] = []
  let subscription = system
    .subscribe(
      fn(envelope) {
        if envelope.event is ResourceNotice(_) {
          seen.push((envelope.namespace_, envelope.scope))
        }
      },
      namespace_=Some(Extension(" provider ")),
    )
    .unwrap()
  assert_eq(seen.length(), 0)
  let scope : @posoco.EventScope = {
    session_id: @posoco.SessionId::unchecked("s"),
    run_id: @posoco.RunId::unchecked("r"),
    turn_id: @posoco.TurnId::unchecked("t"),
  }
  assert_true(
    publisher.publish(ResourceNotice("scoped"), scope=Some(scope)) is Ok(_),
  )
  assert_eq(seen, [(Extension(" provider "), Some(scope))])
  assert_true(system.close() is Ok(_))
  assert_true(system.close() is Ok(_))
  assert_true(system.publisher(owner="late") is Err(Closed))
  assert_true(system.subscribe(fn(_) { () }) is Err(Closed))
  assert_true(publisher.publish(ResourceNotice("after close")) is Err(Closed))
  assert_true(publisher.subscribe(fn(_) { () }) is Err(Closed))
  subscription.cancel()
  subscription.cancel()
  try
    @posoco.Agent(exts=[], config=@posoco.agent_config(), events=system)
  catch {
    @posoco.CompositionError::EventSystemClosed => ()
    unexpected =>
      fail("unexpected composition error: " + unexpected.to_string())
  } noraise {
    _ => fail("closed resource admitted an Agent")
  }
}

///|
async test "event system: exclusive claim and late grants retain the original Agent" {
  let system = @posoco.EventSystem()
  let early = system.publisher(owner="provider").unwrap()
  let model = MockModelPort::{ responses: [stop_response("ok")], index: 0, }
  let agent = @posoco.Agent(
    exts=[@test_support.tk_ext(id="model", model=Some(model))],
    config=@posoco.agent_config(),
    events=system,
  )
  assert_true(system.close() is Err(Owned))
  try
    @posoco.Agent(exts=[], config=@posoco.agent_config(), events=system)
  catch {
    @posoco.CompositionError::EventSystemAlreadyOwned => ()
    unexpected =>
      fail("unexpected composition error: " + unexpected.to_string())
  } noraise {
    _ => fail("event resource was taken by two Agents")
  }
  let late = system.publisher(owner="late").unwrap()
  let seen : Array[@posoco.EventNamespace] = []
  let subscription = agent
    .subscribe_events(fn(envelope) {
      if envelope.event is ResourceNotice(_) {
        seen.push(envelope.namespace_)
      }
    })
    .unwrap()
  defer subscription.cancel()
  assert_true(early.publish(ResourceNotice("early")) is Ok(_))
  assert_true(late.publish(ResourceNotice("late")) is Ok(_))
  assert_eq(seen, [Extension("provider"), Extension("late")])
  ignore(agent.run_turn(user_msg("hello"), "exclusive-resource"))
  agent.shutdown()
  assert_true(early.publish(ResourceNotice("closed")) is Err(Closed))
  assert_true(late.publish(ResourceNotice("closed")) is Err(Closed))
  assert_true(system.close() is Ok(_))
}

///|
async test "event system: with_runtime owns and revokes the supplied resource" {
  let system = @posoco.EventSystem()
  let publisher = system.publisher(owner="runtime-provider").unwrap()
  let model = MockModelPort::{
    responses: [stop_response("runtime")],
    index: 0,
  }
  let runtime = @runtime.PortRuntime(model~)
  let agent = @posoco.Agent::with_runtime(
    exts=[@test_support.tk_ext(id="model", model=Some(model))],
    config=@posoco.agent_config(),
    events=system,
    runtime~,
  )
  let seen : Array[String] = []
  let subscription = agent
    .subscribe_events(fn(envelope) {
      if envelope.event is ResourceNotice(value) {
        seen.push(value)
      }
    })
    .unwrap()
  defer subscription.cancel()
  try
    @posoco.Agent::with_runtime(
      exts=[],
      config=@posoco.agent_config(),
      events=system,
      runtime~,
    )
  catch {
    @posoco.CompositionError::EventSystemAlreadyOwned => ()
    unexpected =>
      fail("unexpected composition error: " + unexpected.to_string())
  } noraise {
    _ => fail("with_runtime accepted an owned resource")
  }
  assert_true(publisher.publish(ResourceNotice("connected")) is Ok(_))
  assert_eq(seen, ["connected"])
  ignore(agent.run_turn(user_msg("hello"), "explicit-runtime"))
  agent.shutdown()
  assert_resource_revoked(system, publisher)
  let failed = @posoco.EventSystem()
  let failed_publisher = failed.publisher(owner="runtime-provider").unwrap()
  try
    @posoco.Agent::with_runtime(
      exts=[],
      config=@posoco.agent_config(),
      events=failed,
      runtime~,
    )
  catch {
    @posoco.CompositionError::EmptyManifests => ()
    unexpected =>
      fail("unexpected composition error: " + unexpected.to_string())
  } noraise {
    _ => fail("with_runtime accepted empty manifests")
  }
  assert_resource_revoked(failed, failed_publisher)
}

///|
async test "event system: equal owner names in separate Agents never share a runtime" {
  let left = @posoco.EventSystem()
  let right = @posoco.EventSystem()
  let left_seen : Array[String] = []
  let right_seen : Array[String] = []
  let record = fn(target : Array[String], envelope : @posoco.EventEnvelope) {
    match envelope.event {
      ResourceNotice(value) => target.push(value)
      @events.Core(TurnStarted) => target.push("turn")
      _ => ()
    }
  }
  let lsub = left.subscribe(e => record(left_seen, e)).unwrap()
  let rsub = right.subscribe(e => record(right_seen, e)).unwrap()
  defer lsub.cancel()
  defer rsub.cancel()
  let lpub = left.publisher(owner="provider").unwrap()
  let rpub = right.publisher(owner="provider").unwrap()
  let lagent = @posoco.Agent(
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(MockModelPort::{
          responses: [stop_response("left")],
          index: 0,
        }),
      ),
    ],
    config=@posoco.agent_config(),
    events=left,
  )
  let ragent = @posoco.Agent(
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(MockModelPort::{
          responses: [stop_response("right")],
          index: 0,
        }),
      ),
    ],
    config=@posoco.agent_config(),
    events=right,
  )
  assert_true(lpub.publish(ResourceNotice("left")) is Ok(_))
  ignore(lagent.run_turn(user_msg("hello"), "left"))
  assert_eq(left_seen, ["left", "turn"])
  assert_eq(right_seen, [])
  lagent.shutdown()
  assert_true(rpub.publish(ResourceNotice("right")) is Ok(_))
  ignore(ragent.run_turn(user_msg("hello"), "right"))
  assert_eq(left_seen, ["left", "turn"])
  assert_eq(right_seen, ["right", "turn"])
  ragent.shutdown()
}

///|
fn assert_resource_revoked(
  system : @posoco.EventSystem,
  publisher : @posoco.Events,
) -> Unit raise {
  assert_true(system.publisher(owner="late") is Err(Closed))
  assert_true(system.subscribe(fn(_) { () }) is Err(Closed))
  assert_true(publisher.publish(ResourceNotice("revoked")) is Err(Closed))
}

///|
test "event system: aggregation failure revokes precomposition capabilities" {
  let system = @posoco.EventSystem()
  let publisher = system.publisher(owner="preconstructed").unwrap()
  let subscription = system.subscribe(fn(_) { () }).unwrap()
  try
    @posoco.Agent(exts=[], config=@posoco.agent_config(), events=system)
  catch {
    @posoco.CompositionError::EmptyManifests => ()
    unexpected =>
      fail("unexpected composition error: " + unexpected.to_string())
  } noraise {
    _ => fail("expected aggregation failure")
  }
  assert_resource_revoked(system, publisher)
  subscription.cancel()
  try
    @posoco.Agent(exts=[], config=@posoco.agent_config(), events=system)
  catch {
    @posoco.CompositionError::EventSystemClosed => ()
    unexpected =>
      fail("unexpected composition error: " + unexpected.to_string())
  } noraise {
    _ => fail("failed composition resource was reused")
  }
}

///|
test "event system: invalid config revokes precomposition capabilities" {
  let system = @posoco.EventSystem()
  let publisher = system.publisher(owner="preconstructed").unwrap()
  let model = MockModelPort::{ responses: [], index: 0, }
  try
    @posoco.Agent(
      exts=[@test_support.tk_ext(id="model", model=Some(model))],
      config=@posoco.agent_config(max_tool_rounds=Some(-1)),
      events=system,
    )
  catch {
    @posoco.CompositionError::ManifestSchemaError(
      manifest_id="agent.config",
      ..
    ) => ()
    unexpected =>
      fail("unexpected composition error: " + unexpected.to_string())
  } noraise {
    _ => fail("expected config validation failure")
  }
  assert_resource_revoked(system, publisher)
}

///|
struct ResourceComposeGrant {
  granted : Ref[@posoco.Events?]
}

///|
impl @posoco.Lifecycle for ResourceComposeGrant with fn on_compose(self, view) raise @posoco.CompositionError {
  self.granted.val = view.events()
}

///|
struct ResourceOrderObserver(Array[String])

///|
impl @posoco.Observer for ResourceOrderObserver with fn on_event(
  self,
  _scope,
  event,
) {
  if event is TurnStarted {
    self.0.push("observer")
  }
}

///|
async test "event system: composition grants and Observers share the resource registration order" {
  let system = @posoco.EventSystem()
  let order : Array[String] = []
  let notices : Array[@posoco.EventNamespace] = []
  let early_sub = system
    .subscribe(fn(envelope) {
      match envelope.event {
        @events.Core(TurnStarted) => order.push("early")
        ResourceNotice(_) => notices.push(envelope.namespace_)
        _ => ()
      }
    })
    .unwrap()
  defer early_sub.cancel()
  let early_pub = system.publisher(owner="provider").unwrap()
  let lifecycle = ResourceComposeGrant::{ granted: Ref(None), }
  let agent = @posoco.Agent(
    exts=[
      @test_support.tk_ext(
        id="provider",
        model=Some(MockModelPort::{
          responses: [stop_response("ok")],
          index: 0,
        }),
        lifecycle=[lifecycle],
        requires=[Events],
        observers=[ResourceOrderObserver(order)],
      ),
    ],
    config=@posoco.agent_config(),
    events=system,
  )
  let composed_pub = lifecycle.granted.val.unwrap()
  let composed_sub = composed_pub
    .subscribe(fn(envelope) {
      if envelope.event is @events.Core(TurnStarted) {
        order.push("composed")
      }
    })
    .unwrap()
  defer composed_sub.cancel()
  let host_sub = agent
    .subscribe_events(fn(envelope) {
      if envelope.event is @events.Core(TurnStarted) {
        order.push("host")
      }
    })
    .unwrap()
  defer host_sub.cancel()
  assert_true(early_pub.publish(ResourceNotice("early")) is Ok(_))
  assert_true(composed_pub.publish(ResourceNotice("composed")) is Ok(_))
  assert_eq(notices, [Extension("provider"), Extension("provider")])
  ignore(agent.run_turn(user_msg("hello"), "resource-registration-order"))
  assert_eq(order, ["early", "observer", "composed", "host"])
  agent.shutdown()
  assert_resource_revoked(system, early_pub)
  assert_resource_revoked(system, composed_pub)
}

///|
struct ResourceComposeFailure {
  granted : Ref[@posoco.Events?]
}

///|
impl @posoco.Lifecycle for ResourceComposeFailure with fn on_compose(self, view) raise @posoco.CompositionError {
  self.granted.val = view.events()
  raise @posoco.CompositionError::ExtensionComposeFailed(
    manifest_id="bad-compose",
    detail="deliberate",
  )
}

///|
test "event system: on_compose failure revokes early and composition grants together" {
  let system = @posoco.EventSystem()
  let publisher = system.publisher(owner="preconstructed").unwrap()
  let hook = ResourceComposeFailure::{ granted: Ref(None), }
  let model = MockModelPort::{ responses: [], index: 0, }
  try
    @posoco.Agent(
      exts=[
        @test_support.tk_ext(
          id="bad-compose",
          model=Some(model),
          lifecycle=[hook],
          requires=[Events],
        ),
      ],
      config=@posoco.agent_config(),
      events=system,
    )
  catch {
    @posoco.CompositionError::ExtensionComposeFailed(
      manifest_id="bad-compose",
      ..
    ) => ()
    unexpected =>
      fail("unexpected composition error: " + unexpected.to_string())
  } noraise {
    _ => fail("expected on_compose failure")
  }
  assert_resource_revoked(system, publisher)
  assert_true(
    hook.granted.val.unwrap().publish(ResourceNotice("revoked too"))
    is Err(Closed),
  )
}

///|
async test "event system: turn failure does not revoke resource capabilities" {
  let system = @posoco.EventSystem()
  let publisher = system.publisher(owner="provider").unwrap()
  let model = @test_support.ScriptedModel([
    Fail(@posoco.ModelError::Transport("deliberate model failure")),
    Respond(stop_response("recovered")),
  ])
  let agent = @posoco.Agent(
    exts=[@test_support.tk_ext(id="model", model=Some(model))],
    config=@posoco.agent_config(),
    events=system,
  )
  try agent.run_turn(user_msg("first"), "failed-turn") catch {
    error => assert_true(error.to_string().contains("deliberate model failure"))
  } noraise {
    _ => fail("expected model failure")
  }
  assert_true(publisher.publish(ResourceNotice("still open")) is Ok(_))
  assert_true(system.publisher(owner="after failure") is Ok(_))
  ignore(agent.run_turn(user_msg("retry"), "failed-turn"))
  agent.shutdown()
  assert_resource_revoked(system, publisher)
}

///|
async test "event system: turn cancellation leaves the Agent resource open" {
  let system = @posoco.EventSystem()
  let publisher = system.publisher(owner="provider").unwrap()
  let model = @test_support.ScriptedModel([
    Respond(stop_response("after cancel")),
  ])
  let agent = @posoco.Agent(
    exts=[@test_support.tk_ext(id="model", model=Some(model))],
    config=@posoco.agent_config(),
    events=system,
  )
  let requested = Ref(false)
  let accepted : Array[Bool] = []
  let subscription = agent
    .subscribe_events(fn(envelope) {
      if envelope.event is @events.Core(ModelRequestStarted) && !requested.val {
        requested.val = true
        accepted.push(
          agent.control().abort_active(Some("cancel this turn")) is Accepted(_),
        )
      }
    })
    .unwrap()
  defer subscription.cancel()
  try agent.run_turn(user_msg("cancel"), "cancelled-turn") catch {
    @posoco.AgentError::Cancelled(_) => ()
    unexpected => fail("unexpected turn failure: " + unexpected.to_string())
  } noraise {
    _ => fail("expected turn cancellation")
  }
  assert_eq(accepted, [true])
  assert_true(publisher.publish(ResourceNotice("still open")) is Ok(_))
  assert_true(system.publisher(owner="after cancellation") is Ok(_))
  ignore(agent.run_turn(user_msg("next"), "cancelled-turn"))
  agent.shutdown()
  assert_resource_revoked(system, publisher)
}
