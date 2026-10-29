///|
async test "core_fact/journal_failure_does_not_publish" {
  let host = FixtureHost([Ok(fixture_stop("ignored"))], Map::from_array([]))
  let inner = InMemoryJournal()
  let failing = FailOnNthJournal(inner, 1)
  let puppet = Puppet(
    fixture_config(host, fixture_empty_catalog(), failing, [], []),
  )
  let published : Array[CoreFactCommit] = []
  puppet.set_core_fact_observer(Some(fn(fact) { published.push(fact) }))
  match fixture_prompt(puppet, "core_fact_journal") {
    Rejected(error=SavepointFailed(..)) => ()
    other => fail("expected a journal rejection, got " + other.to_string())
  }
  assert_eq(published.length(), 0)
  assert_eq(inner.revision(), 0)
}

///|
async test "core_fact/subscriber_failure_after_commit_still_publishes" {
  let host = FixtureHost([Ok(fixture_stop("ignored"))], Map::from_array([]))
  let journal = InMemoryJournal()
  let subscriber = FailingSubscriber("bad")
  let puppet = Puppet(
    fixture_config(host, fixture_empty_catalog(), journal, [subscriber], []),
  )
  let published : Array[CoreFactCommit] = []
  puppet.set_core_fact_observer(Some(fn(fact) { published.push(fact) }))
  match fixture_prompt(puppet, "core_fact_dispatch") {
    Rejected(error=SubscriberFailed(..)) => ()
    other => fail("expected a subscriber rejection, got " + other.to_string())
  }
  assert_eq(published.length(), 1)
  assert_eq(published[0].messages.length(), 1)
  guard published[0].messages[0] is UserMessage(content=[Text("hello")]) else {
    fail("expected the committed input message")
  }
  assert_false(published[0].is_terminal)
  assert_eq(journal.revision(), 1)
}

///|
priv struct ParkingSubscriber {
  entered : Ref[Bool]
}

///|
impl EventSubscriber for ParkingSubscriber with fn subscriber_id(_self) -> String {
  "parking"
}

///|
impl EventSubscriber for ParkingSubscriber with fn provenance(_self) -> String {
  "parking"
}

///|
impl EventSubscriber for ParkingSubscriber with fn on_event(self, _envelope) -> Unit raise SubscriberError {
  self.entered.val = true
  while true {
    @async.pause()
  }
}

///|
async test "core_fact/rewrite_dispatch_park_cancel_still_publishes" {
  let run_id = RunId::unchecked("run_park")
  let turn_id = TurnId::unchecked("turn_park")
  let session_id = SessionId::unchecked("session_park")
  let catalog = fixture_empty_catalog()
  let host = FixtureHost([], Map::from_array([]))
  let journal = InMemoryJournal()
  let puppet = Puppet(fixture_config(host, catalog, journal, [], []))
  let published : Ref[Array[CoreFactCommit]] = Ref([])
  puppet.set_core_fact_observer(Some(fn(fact) { published.val.push(fact) }))
  let initial = RunState::initial(
    run_id~,
    session_id~,
    budget=Budget::default_run(),
  )
  let started = reduce(
    initial,
    catalog,
    Start(payload={
      initial_messages: [@kernel.UserMessage(content=[@kernel.Text("hello")])],
      catalog_version: catalog.version(),
    }),
  )
  let rewritten = [@kernel.UserMessage(content=[@kernel.Text("rewritten")])]
  let out = reduce(
    started.next_state(),
    catalog,
    TranscriptRewrite(payload={ rewritten_messages: rewritten, reason: "test", }),
  )
  let parking = ParkingSubscriber::{ entered: Ref(false), }
  let dispatcher = EventDispatcher(run_id, turn_id, session_id)
  dispatcher.register(parking)
  ignore(
    @async.with_task_group(async fn(group) {
      let task = group.spawn(async fn() {
        puppet.commit_boundary(
          out.next_state(),
          AssistantCommitted,
          out.events(),
          dispatcher,
          run_id,
          turn_id,
          session_id,
          "sp_park",
        ) catch {
          _ => ()
        }
      })
      while !parking.entered.val {
        @async.pause()
      }
      task.cancel()
      let waited : Result[Unit, Error] = Ok(task.wait()) catch {
        _ => Err(Error::Failure("cancelled"))
      }
      ignore(waited)
    }),
  )
  assert_eq(published.val.length(), 1)
  assert_eq(published.val[0].messages.length(), 1)
  assert_true(
    published.val[0].messages[0] ==
    @kernel.UserMessage(content=[@kernel.Text("rewritten")]),
  )
  assert_eq(journal.revision(), 1)
}

///|
async test "core_fact/standalone_replace_commits_transcript_rewritten_only" {
  let source_messages : Array[@kernel.Message] = [
    @kernel.UserMessage(content=[@kernel.Text("one")]),
    @kernel.UserMessage(content=[@kernel.Text("two")]),
    @kernel.UserMessage(content=[@kernel.Text("three")]),
  ]
  let compacted : Array[@kernel.Message] = [
    @kernel.UserMessage(content=[@kernel.Text("summary-one")]),
    @kernel.UserMessage(content=[@kernel.Text("summary-two")]),
  ]
  let host = FixtureHost([], Map::from_array([])).with_compact_result({
    compacted_messages: compacted,
    mode: Replace,
  })
  let journal = InMemoryJournal()
  let subscriber = RecordingSubscriber("recording")
  let puppet = Puppet(
    fixture_config(host, fixture_empty_catalog(), journal, [subscriber], []),
  )
  let run_id = RunId::unchecked("run_replace_journal")
  let turn_id = TurnId::unchecked("turn_replace_journal")
  let session_id = SessionId::unchecked("session_replace_journal")
  let result = puppet.compact_standalone(
    run_id,
    turn_id,
    session_id,
    source_messages,
    fixture_run_policy("fixture-model", Json::null()),
    "op_replace_journal",
    Manual,
  )
  match result {
    CompactCompleted(mode=Replace, compacted_messages~, ..) => {
      assert_eq(compacted_messages.length(), 2)
      assert_true(
        compacted_messages[0] ==
        @kernel.UserMessage(content=[@kernel.Text("summary-one")]),
      )
      assert_true(
        compacted_messages[1] ==
        @kernel.UserMessage(content=[@kernel.Text("summary-two")]),
      )
    }
    other => fail("expected Replace CompactCompleted, got " + other.to_string())
  }
  let entries = journal.entries_for_run(run_id)
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].identity.kind, AssistantCommitted)
  match entries[0].payload {
    Object(fields) =>
      assert_eq(fields["kind"], Json::string("TranscriptRewritten"))
    _ => fail("expected the TranscriptRewritten journal payload")
  }
  let received = subscriber.received()
  assert_eq(received.length(), 1)
  match received[0].event() {
    TranscriptRewritten(messages_before~, messages_after~, reason~) => {
      assert_eq(messages_before, 3)
      assert_eq(messages_after, 2)
      assert_eq(reason, "compact_standalone")
    }
    other => fail("expected only TranscriptRewritten, got " + other.to_string())
  }
}
