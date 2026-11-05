///|
/// The fixed model must preserve the input transcript when it does not
/// preprocess messages. This catches regressions where an empty
/// `processed_messages` array drops the user message at the persistence
/// boundary.
async test "quickstart_persists_user_and_assistant_history" {
  let extension = QuickstartExtension()
  let agent = @posoco.Agent(
    exts=[extension],
    config=@posoco.agent_config(max_tool_rounds=Some(0)),
    events=@posoco.EventSystem(),
  )
  let input : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("Say hello"),
  ])
  let result = agent.run_turn(input, "quickstart-test-session")
  match result.message {
    @posoco.Message::AssistantMessage(content~, ..) =>
      assert_eq(content, [
        @posoco.Content::Text("Hello from the Posoco quickstart."),
      ])
    _ => fail("expected AssistantMessage")
  }
  let saved = @port.SessionPort::load(
    extension.sessions,
    "quickstart-test-session",
  )
  assert_eq(saved.messages.length(), 2)
  assert_true(saved.messages[0] is @posoco.Message::UserMessage(..))
  assert_true(saved.messages[1] is @posoco.Message::AssistantMessage(..))
  agent.shutdown()
}

///|
async test "quickstart_typed_events_follow_agent_lifecycle" {
  let extension = QuickstartExtension()
  let agent = @posoco.Agent(
    exts=[extension],
    config=@posoco.agent_config(max_tool_rounds=Some(0)),
    events=@posoco.EventSystem(),
  )
  guard extension.events.val is Some(events) else {
    fail("on_compose did not deliver Events")
  }
  let received : Array[@posoco.EventEnvelope] = []
  guard agent.subscribe_events(
      envelope => received.push(envelope),
      namespace_=Some(@posoco.EventNamespace::Extension("quickstart")),
    )
    is Ok(subscription) else {
    fail("host subscription failed")
  }
  let core_count = Ref(0)
  guard agent.subscribe_events(
      _ => core_count.val += 1,
      namespace_=Some(@posoco.EventNamespace::Posoco),
    )
    is Ok(core_subscription) else {
    fail("core subscription failed")
  }
  assert_eq(received.length(), 0)
  let input : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("Say hello"),
  ])
  ignore(agent.run_turn(input, "quickstart-events"))
  ignore(agent.run_turn(input, "quickstart-events"))
  assert_eq(received.length(), 1) // on_start runs once, not once per turn.
  assert_eq(
    received[0].namespace_of(),
    @posoco.EventNamespace::Extension("quickstart"),
  )
  assert_true(received[0].event is QuickstartChanged(Started))
  assert_true(core_count.val > 0)
  let late_received = Ref(0)
  guard agent.subscribe_events(
      _ => late_received.val += 1,
      namespace_=Some(@posoco.EventNamespace::Extension("quickstart")),
    )
    is Ok(late_subscription) else {
    fail("late subscription failed")
  }
  assert_eq(late_received.val, 0) // No replay of the startup event.
  subscription.cancel()
  subscription.cancel()
  assert_true(events.publish(QuickstartChanged(Started)) is Ok(_))
  assert_eq(received.length(), 1)
  assert_eq(late_received.val, 1)
  late_subscription.cancel()
  core_subscription.cancel()
  agent.shutdown()
  assert_true(events.publish(QuickstartChanged(Started)) is Err(Closed))
  assert_true(agent.subscribe_events(_ => ()) is Err(Closed))
  subscription.cancel() // Cancellation is also safe after shutdown.
}

///|
/// A plain object can hold an owner-bound `Events` before the Agent exists.
/// The grant survives the takeover, and `shutdown` closes it together with the
/// Agent's own capabilities.
async test "quickstart_plain_publisher_spans_composition" {
  let system = @posoco.EventSystem()
  let received : Array[@posoco.EventEnvelope] = []
  guard system.subscribe(
      envelope => received.push(envelope),
      namespace_=Some(@posoco.EventNamespace::Extension("quickstart_reporter")),
    )
    is Ok(system_subscription) else {
    fail("an untaken EventSystem accepts subscribers")
  }
  let reporter = match QuickstartReporter::new(system) {
    Ok(reporter) => reporter
    Err(_) => fail("an untaken EventSystem grants owner-bound publishers")
  }
  assert_true(reporter.report_started())
  assert_eq(received.length(), 1) // Delivered before any Agent exists.
  let agent = @posoco.Agent(
    exts=[QuickstartExtension()],
    config=@posoco.agent_config(max_tool_rounds=Some(0)),
    events=system,
  )
  assert_true(reporter.report_started()) // The grant survives the takeover.
  assert_eq(received.length(), 2)
  assert_eq(
    received[0].namespace_of(),
    @posoco.EventNamespace::Extension("quickstart_reporter"),
  )
  assert_true(received[1].event is QuickstartChanged(Started))
  // One resource has one owner: a second Agent is rejected by name and the
  // first Agent keeps publishing.
  try {
    ignore(
      @posoco.Agent(
        exts=[QuickstartExtension()],
        config=@posoco.agent_config(max_tool_rounds=Some(0)),
        events=system,
      ),
    )
    fail("a second Agent must not take over an owned event system")
  } catch {
    @posoco.CompositionError::EventSystemAlreadyOwned => ()
    error => fail("expected EventSystemAlreadyOwned, got \{error.to_string()}")
  }
  assert_true(reporter.report_started())
  assert_eq(received.length(), 3)
  agent.shutdown()
  assert_false(reporter.report_started()) // Closed after shutdown.
  assert_true(system.publisher(owner="late") is Err(Closed))
  assert_true(system.subscribe(_ => ()) is Err(Closed))
  system_subscription.cancel()
}
