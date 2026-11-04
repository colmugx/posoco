///|
extenum @events.Event += {
  AcceptanceNotice(String)
}

///|
priv struct EventCapabilityProbe {
  seen : Ref[@events.Events?]
  publish_shutdown : Bool
}

///|
fn event_probe(publish_shutdown~ : Bool = false) -> EventCapabilityProbe {
  { seen: Ref(None), publish_shutdown, }
}

///|
impl @port.Lifecycle for EventCapabilityProbe with fn on_compose(self, view) {
  self.seen.val = view.events()
}

///|
impl @port.Lifecycle for EventCapabilityProbe with fn on_shutdown(self) {
  if self.publish_shutdown {
    guard self.seen.val is Some(events) else { fail("missing Events") }
    guard events.publish(AcceptanceNotice("shutdown")) is Ok(_) else {
      fail("Events must remain usable during lifecycle cleanup")
    }
  }
}

///|
fn probe_events(probe : EventCapabilityProbe) -> @events.Events raise {
  guard probe.seen.val is Some(events) else { fail("Events not delivered") }
  events
}

///|
async test "events: manifest gating, owner binding, host filtering and Agent isolation" {
  let first = event_probe()
  let undeclared = event_probe()
  let second = event_probe()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      scripted_model_ext([]),
      @test_support.tk_ext(id="publisher", lifecycle=[first], requires=[Events]),
      @test_support.tk_ext(id="undeclared", lifecycle=[undeclared]),
    ],
    config=agent_config(),
  )
  let other = Agent(
    events=EventSystem(),
    exts=[
      scripted_model_ext([]),
      @test_support.tk_ext(id="publisher", lifecycle=[second], requires=[Events]),
    ],
    config=agent_config(),
  )
  assert_true(undeclared.seen.val is None)
  let received : Array[String] = []
  let unrelated : Array[String] = []
  let isolated : Array[String] = []
  guard agent.subscribe_events(
      envelope => {
        match (envelope.namespace_of(), envelope.event) {
          (Extension(owner), AcceptanceNotice(value)) =>
            received.push(owner + ":" + value)
          _ => ()
        }
      },
      namespace_=Some(Extension("publisher")),
    )
    is Ok(subscription) else {
    fail("subscribe failed")
  }
  guard agent.subscribe_events(
      envelope => {
        if envelope.event is AcceptanceNotice(value) {
          unrelated.push(value)
        }
      },
      namespace_=Some(Extension("other")),
    )
    is Ok(_) else {
    fail("subscribe failed")
  }
  guard other.subscribe_events(envelope => {
      if envelope.event is AcceptanceNotice(value) {
        isolated.push(value)
      }
    })
    is Ok(_) else {
    fail("subscribe failed")
  }
  let publisher = probe_events(first)
  guard publisher.publish(AcceptanceNotice("one")) is Ok(_) else {
    fail("publish failed")
  }
  assert_eq(received, ["publisher:one"])
  assert_eq(unrelated, [])
  assert_eq(isolated, [])
  subscription.cancel()
  subscription.cancel()
  guard publisher.publish(AcceptanceNotice("two")) is Ok(_) else {
    fail("publish failed")
  }
  assert_eq(received, ["publisher:one"])
  guard publisher.publish(@events.Core(TurnStarted)) is Err(ReservedEvent) else {
    fail("extension published a reserved core event")
  }
  agent.shutdown()
  other.shutdown()
  guard publisher.publish(AcceptanceNotice("closed")) is Err(Closed) else {
    fail("closed publisher remained usable")
  }
  guard agent.subscribe_events(_ => ()) is Err(Closed) else {
    fail("closed Agent accepted a listener")
  }
}

///|
async test "events: old Observer and host each receive core once, not community notices" {
  let probe = event_probe()
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      scripted_model_ext([
        @test_support.ScriptedModelStep::Respond(
          @test_support.tk_stop_response("ok"),
        ),
      ]),
      @test_support.tk_ext(id="io", observers=[observer]),
      @test_support.tk_ext(id="publisher", lifecycle=[probe], requires=[Events]),
    ],
    config=agent_config(),
  )
  let core : Array[@types.TurnEvent] = []
  let scopes : Array[@types.EventScope?] = []
  guard agent.subscribe_events(
      envelope => {
        if envelope.event is @events.Core(event) {
          core.push(event)
          scopes.push(envelope.scope)
        }
      },
      namespace_=Some(Posoco),
    )
    is Ok(_) else {
    fail("subscribe failed")
  }
  let publisher = probe_events(probe)
  guard publisher.publish(AcceptanceNotice("not a TurnEvent")) is Ok(_) else {
    fail("publish failed")
  }
  assert_eq(observer.events(), [])
  ignore(agent.run_turn(@test_support.tk_user_msg("hello"), "typed-events"))
  assert_eq(core, observer.events())
  assert_eq(core.filter(event => event is TurnStarted).length(), 1)
  assert_eq(core.filter(event => event is TurnCompleted).length(), 1)
  guard core.search_by(event => event is TurnStarted) is Some(index) else {
    fail("TurnStarted missing")
  }
  guard scopes[index] is Some(scope) else { fail("run scope missing") }
  assert_eq(scope.session_id.to_string(), "typed-events")
  agent.shutdown()
}

///|
async test "events: host attaching after construction receives streamed chunks without legacy Observers" {
  let agent = Agent(
    events=EventSystem(),
    exts=[
      scripted_model_ext([
        @test_support.ScriptedModelStep::Stream(
          chunks=[TextDelta(token="a"), TextDelta(token="b")],
          response=@test_support.tk_stop_response("ab"),
        ),
      ]),
    ],
    config=agent_config(),
  )
  let sequence : Array[String] = []
  guard agent.subscribe_events(envelope => {
      match envelope.event {
        @events.Core(StreamChunkReceived(chunk=TextDelta(token~))) =>
          sequence.push(token)
        @events.Core(TurnCompleted) => sequence.push("done")
        _ => ()
      }
    })
    is Ok(_) else {
    fail("subscribe failed")
  }
  ignore(agent.run_turn(@test_support.tk_user_msg("stream"), "events-stream"))
  assert_eq(sequence, ["a", "b", "done"])
  agent.shutdown()
}

///|
test "events: failed composition revokes capabilities already delivered" {
  let probe = event_probe()
  try
    Agent(
      events=EventSystem(),
      exts=[
        scripted_model_ext([]),
        @test_support.tk_ext(id="publisher", lifecycle=[probe], requires=[
          Events,
        ]),
        @test_support.tk_ext(id="bad", lifecycle=[FailCompose::{ id: "bad", }]),
      ],
      config=agent_config(),
    )
  catch {
    ExtensionComposeFailed(manifest_id~, ..) => assert_eq(manifest_id, "bad")
    error => fail("unexpected composition failure: \{error}")
  } noraise {
    _ => fail("expected composition failure")
  }
  let publisher = probe_events(probe)
  guard publisher.publish(AcceptanceNotice("leaked")) is Err(Closed) else {
    fail("failed composition left publication rights alive")
  }
  guard publisher.subscribe(_ => ()) is Err(Closed) else {
    fail("failed composition left subscriptions alive")
  }
}

///|
async test "events: shutdown publication is delivered before the runtime closes" {
  let probe = event_probe(publish_shutdown=true)
  let agent = Agent(
    events=EventSystem(),
    exts=[
      scripted_model_ext([]),
      @test_support.tk_ext(id="publisher", lifecycle=[probe], requires=[Events]),
    ],
    config=agent_config(),
  )
  let received : Array[String] = []
  guard agent.subscribe_events(envelope => {
      if envelope.event is AcceptanceNotice(value) {
        received.push(value)
      }
    })
    is Ok(_) else {
    fail("subscribe failed")
  }
  agent.shutdown()
  assert_eq(received, ["shutdown"])
  agent.shutdown()
  assert_eq(received, ["shutdown"])
  guard probe_events(probe).publish(AcceptanceNotice("late")) is Err(Closed) else {
    fail("shutdown did not revoke capability")
  }
}

///|
async test "events: cancelling one turn leaves the same Agent event capability usable" {
  let probe = event_probe()
  let entered : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let release : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let gate = TurnLoopGate::{ entered, release, }
  let agent = Agent(
    events=EventSystem(),
    exts=[
      scripted_model_ext([
        @test_support.ScriptedModelStep::Respond(
          @test_support.tk_stop_response("after cancel"),
        ),
      ]),
      @test_support.tk_ext(
        id="publisher",
        lifecycle=[probe],
        requires=[Events],
        hooks=[gate],
      ),
    ],
    config=agent_config(),
  )
  let received : Array[String] = []
  guard agent.subscribe_events(envelope => {
      if envelope.event is AcceptanceNotice(value) {
        received.push(value)
      }
    })
    is Ok(_) else {
    fail("subscribe failed")
  }
  @async.with_task_group(group => {
    let first = group.spawn(
      async fn() {
        let result : Result[@types.TurnResult, Error] = Ok(
          agent.run_turn(@test_support.tk_user_msg("cancel"), "events-cancel"),
        ) catch {
          error => Err(error)
        }
        result
      },
      allow_failure=true,
    )
    ignore(entered.get())
    first.cancel()
    guard first.wait() is Err(_) else { fail("turn was not cancelled") }
    guard probe_events(probe).publish(AcceptanceNotice("still alive")) is Ok(_) else {
      fail("turn cancellation closed Events")
    }
    release.put(1)
    ignore(agent.run_turn(@test_support.tk_user_msg("again"), "events-cancel"))
  })
  assert_eq(received, ["still alive"])
  agent.shutdown()
}

///|
async test "events: event namespace owners require unique manifest ids without changing legacy duplicates" {
  for
    (first_requires, second_requires) in [
      ([@port.Capability::Events], [@port.Capability::Events]),
      ([@port.Capability::Events], []),
      ([], [@port.Capability::Events]),
    ] {
    let probe = event_probe()
    let result : Result[Agent, @error.CompositionError] = Ok(
      Agent(
        events=EventSystem(),
        exts=[
          scripted_model_ext([]),
          @test_support.tk_ext(
            id="shared",
            lifecycle=[probe],
            requires=first_requires,
          ),
          @test_support.tk_ext(id="shared", requires=second_requires),
        ],
        config=agent_config(),
      ),
    ) catch {
      error => Err(error)
    }
    match result {
      Err(ManifestSchemaError(manifest_id~, detail~)) => {
        assert_eq(manifest_id, "shared")
        assert_eq(detail, "Events requires a unique manifest id")
      }
      Err(error) => fail("unexpected composition error: \{error}")
      Ok(agent) => {
        agent.shutdown()
        fail("two manifests shared an event namespace owner")
      }
    }
    assert_true(probe.seen.val is None)
  }
  let legacy = Agent(
    events=EventSystem(),
    exts=[
      scripted_model_ext([]),
      @test_support.tk_ext(id="shared"),
      @test_support.tk_ext(id="shared"),
    ],
    config=agent_config(),
  )
  legacy.shutdown()
}
