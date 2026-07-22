///|
/// Canonical HostRuntime fixture and end-to-end Harness contract cases.
///
/// These fixtures deliberately use only the Kernel host contract.  They are
/// not legacy-port adapters: production compatibility conversion lives at the
/// root boundary, while Puppetry receives canonical messages and outcomes.

///|
pub(all) struct FixtureHost {
  model_results : Array[Result[AssistantCompletion, ModelFailure]]
  tool_results : Map[String, ToolOutcome]
  mut model_index : Int
  mut model_call_count : Int
  mut tool_call_count : Int
  mut observed_definition_count : Int
}

///|
pub fn FixtureHost::new(
  model_results : Array[Result[AssistantCompletion, ModelFailure]],
  tool_results : Map[String, ToolOutcome],
) -> FixtureHost {
  {
    model_results: model_results.copy(),
    tool_results,
    model_index: 0,
    model_call_count: 0,
    tool_call_count: 0,
    observed_definition_count: -1,
  }
}

///|
pub fn FixtureHost::model_call_count(self : FixtureHost) -> Int {
  self.model_call_count
}

///|
pub fn FixtureHost::tool_call_count(self : FixtureHost) -> Int {
  self.tool_call_count
}

///|
pub fn FixtureHost::observed_definition_count(self : FixtureHost) -> Int {
  self.observed_definition_count
}

///|
pub impl @kernel.HostRuntime for FixtureHost with fn call_model(
  self,
  _messages : Array[CanonicalMessage],
  tool_definitions : Array[CanonicalToolDef],
  _call_options : Json,
  _on_chunk : HostChunkCallback,
) -> Result[AssistantCompletion, ModelFailure] {
  self.model_call_count = self.model_call_count + 1
  self.observed_definition_count = tool_definitions.length()
  let index = self.model_index
  self.model_index = index + 1
  if index >= self.model_results.length() {
    Err(Runtime(reason="fixture host exhausted model results"))
  } else {
    self.model_results[index]
  }
}

///|
pub impl @kernel.HostRuntime for FixtureHost with fn execute_tool(
  self,
  _owner_id : OwnerId,
  call_id : CallId,
  _tool_name : ToolName,
  _arguments : Json,
) -> ToolOutcome {
  self.tool_call_count = self.tool_call_count + 1
  match self.tool_results.get(call_id.to_string()) {
    Some(outcome) => outcome
    None =>
      RuntimeFailure(
        error_category="FixtureMissingOutcome",
        message="fixture host has no outcome for call " + call_id.to_string(),
      )
  }
}

///|
pub impl @kernel.HostRuntime for FixtureHost with fn cancel_effects(
  _self,
  effect_ids : Array[EffectId],
  _reason : CancelReason,
) -> Array[(EffectId, CancelDisposition)] {
  let results : Array[(EffectId, CancelDisposition)] = []
  for effect_id in effect_ids {
    results.push((effect_id, NotPropagated))
  }
  results
}

///|
fn fixture_stop(text : String) -> AssistantCompletion {
  AssistantCompletion::new(
    content=[Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
    usage=None,
  )
}

///|
fn fixture_tool_calls(calls : Array[CanonicalToolCall]) -> AssistantCompletion {
  AssistantCompletion::new(
    content=[],
    tool_calls=calls,
    reasoning=None,
    finish_reason=ToolCalls,
    usage=None,
  )
}

///|
fn fixture_call(name : String, id : String) -> CanonicalToolCall {
  {
    call_id: CallId::unchecked(id),
    name: ToolName::unchecked(name),
    arguments: Json::object(Map::from_array([])),
  }
}

///|
fn fixture_empty_catalog() -> ToolCatalogSnapshot raise CatalogCompositionError {
  ToolCatalogBuilder::new().finish(version=CatalogVersion::new(1))
}

///|
fn fixture_tool_catalog(
  name : String,
) -> ToolCatalogSnapshot raise CatalogCompositionError {
  let schema = Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      ("properties", Json::object(Map::from_array([]))),
    ]),
  )
  let builder = ToolCatalogBuilder::new()
  ignore(
    builder.add(
      CanonicalToolDef::new(
        name=ToolName::unchecked(name),
        description="fixture tool",
        input_schema=schema,
        owner=OwnerId::unchecked("fixture"),
        policy=Parallel,
        provenance=Some("fixture"),
      ),
    ),
  )
  builder.finish(version=CatalogVersion::new(1))
}

///|
fn fixture_config(
  host : &@kernel.HostRuntime,
  catalog : ToolCatalogSnapshot,
  journal : &RunJournal,
  subscribers : Array[&EventSubscriber],
  contributors : Array[&JournalContributor],
) -> HarnessConfig {
  {
    host,
    model_id: ModelId::unchecked("fixture-model"),
    catalog,
    journal,
    contributors,
    subscribers,
    lifecycle_nodes: [],
    default_budget: Budget::default_run(),
    max_iterations: 50,
  }
}

///|
async fn fixture_prompt(
  harness : Harness,
  suffix : String,
) -> PromptResult raise HarnessError {
  harness.prompt(
    RunId::unchecked("run_" + suffix),
    TurnId::unchecked("turn_" + suffix),
    SessionId::unchecked("session_" + suffix),
    [UserMessage(content=[Text("hello")])],
    "operation_" + suffix,
  )
}

///|
fn first_revision_matching(
  entries : Array[JournalEntry],
  kind : SavepointKind,
) -> Int {
  for entry in entries {
    if entry.identity().kind() == kind {
      return entry.revision()
    }
  }
  0
}

///|
async test "harness/C-HAPPY-NO-TOOLS" {
  let host = FixtureHost::new([Ok(fixture_stop("hi"))], Map::from_array([]))
  let journal = InMemoryJournal::new()
  let harness = Harness::new(
    fixture_config(host, fixture_empty_catalog(), journal, [], []),
  )
  match fixture_prompt(harness, "happy") {
    Accepted(..) => ()
    other => fail("expected accepted prompt, got " + other.to_string())
  }
  let entries = journal.entries_for_run(RunId::unchecked("run_happy"))
  assert_true(harness.phase() == Idle)
  assert_eq(host.model_call_count(), 1)
  assert_true(first_revision_matching(entries, InputAccepted) > 0)
  assert_true(
    first_revision_matching(entries, InputAccepted) <
    first_revision_matching(entries, RunTerminal),
  )
  match entries[0].payload() {
    Object(fields) => assert_eq(fields["kind"], Json::string("InputAccepted"))
    _ => fail("InputAccepted journal payload must be structured JSON")
  }
  let mut has_terminal_payload = false
  for entry in entries {
    if entry.identity().kind() == RunTerminal {
      match entry.payload() {
        Object(fields) => {
          assert_eq(fields["kind"], Json::string("RunCompleted"))
          has_terminal_payload = true
        }
        _ => fail("RunTerminal journal payload must be structured JSON")
      }
    }
  }
  assert_true(has_terminal_payload)
}

///|
async test "harness/C-SINGLE-TOOL" {
  let host = FixtureHost::new(
    [
      Ok(fixture_tool_calls([fixture_call("echo", "one")])),
      Ok(fixture_stop("done")),
    ],
    Map::from_array([("one", Success(content="ok", structured=None))]),
  )
  let journal = InMemoryJournal::new()
  let harness = Harness::new(
    fixture_config(host, fixture_tool_catalog("echo"), journal, [], []),
  )
  assert_true(fixture_prompt(harness, "single") is Accepted(_))
  assert_eq(host.tool_call_count(), 1)
  assert_eq(host.model_call_count(), 2)
  assert_eq(host.observed_definition_count(), 1)
  assert_true(
    first_revision_matching(
      journal.entries_for_run(RunId::unchecked("run_single")),
      ToolCommitted,
    ) >
    0,
  )
}

///|
async test "harness/C-PARALLEL-TOOLS" {
  let host = FixtureHost::new(
    [
      Ok(
        fixture_tool_calls([
          fixture_call("echo", "one"),
          fixture_call("echo", "two"),
        ]),
      ),
      Ok(fixture_stop("done")),
    ],
    Map::from_array([
      ("one", Success(content="one", structured=None)),
      ("two", Success(content="two", structured=None)),
    ]),
  )
  let journal = InMemoryJournal::new()
  let harness = Harness::new(
    fixture_config(host, fixture_tool_catalog("echo"), journal, [], []),
  )
  assert_true(fixture_prompt(harness, "batch") is Accepted(_))
  assert_eq(host.tool_call_count(), 2)
  let entries = journal.entries_for_run(RunId::unchecked("run_batch"))
  let mut committed = 0
  for entry in entries {
    if entry.identity().kind() == ToolCommitted {
      committed = committed + 1
    }
  }
  assert_eq(committed, 2)
}

///|
async test "harness/C-MODEL-FAILURE" {
  let host = FixtureHost::new(
    [Err(Transport(reason="offline"))],
    Map::from_array([]),
  )
  let journal = InMemoryJournal::new()
  let harness = Harness::new(
    fixture_config(host, fixture_empty_catalog(), journal, [], []),
  )
  assert_true(fixture_prompt(harness, "model_failure") is Accepted(_))
  match harness.wait_idle() {
    Terminal(outcome=Failed(reason=ModelTransport(..))) => ()
    status =>
      fail(
        "expected terminal model transport failure, got " + status.to_string(),
      )
  }
}

///|
async test "harness/C-TOOL-BUSINESS-FAILURE" {
  let host = FixtureHost::new(
    [
      Ok(fixture_tool_calls([fixture_call("echo", "business")])),
      Ok(fixture_stop("done")),
    ],
    Map::from_array([
      ("business", ToolReportedError(content="bad input", structured=None)),
    ]),
  )
  let journal = InMemoryJournal::new()
  let harness = Harness::new(
    fixture_config(host, fixture_tool_catalog("echo"), journal, [], []),
  )
  assert_true(fixture_prompt(harness, "business") is Accepted(_))
  assert_eq(host.model_call_count(), 2)
  assert_eq(host.tool_call_count(), 1)
}

///|
async test "harness/C-TOOL-RUNTIME-FAILURE" {
  let host = FixtureHost::new(
    [
      Ok(fixture_tool_calls([fixture_call("echo", "runtime")])),
      Ok(fixture_stop("done")),
    ],
    Map::from_array([
      ("runtime", RuntimeFailure(error_category="Transport", message="offline")),
    ]),
  )
  let journal = InMemoryJournal::new()
  let harness = Harness::new(
    fixture_config(host, fixture_tool_catalog("echo"), journal, [], []),
  )
  assert_true(fixture_prompt(harness, "runtime") is Accepted(_))
  assert_eq(host.model_call_count(), 2)
  assert_eq(host.tool_call_count(), 1)
}

///|
async test "harness/C-MISSING-OWNER-IS-INVARIANT" {
  let host = FixtureHost::new(
    [Ok(fixture_tool_calls([fixture_call("echo", "missing_owner")]))],
    Map::from_array([
      (
        "missing_owner",
        RuntimeFailure(error_category="MissingOwner", message="stale owner"),
      ),
    ]),
  )
  let journal = InMemoryJournal::new()
  let harness = Harness::new(
    fixture_config(host, fixture_tool_catalog("echo"), journal, [], []),
  )
  assert_true(fixture_prompt(harness, "missing_owner") is Accepted(_))
  match harness.wait_idle() {
    Terminal(
      outcome=Failed(reason=InvariantViolation(category=MissingOwner(..)))
    ) => ()
    status =>
      fail(
        "expected terminal MissingOwner invariant, got " + status.to_string(),
      )
  }
}

///|
test "harness/C-SUSPEND-RESUME-IN-PROCESS" {
  let catalog = fixture_empty_catalog()
  let initial = RunState::initial(
    run_id=RunId::unchecked("run_suspend"),
    session_id=SessionId::unchecked("session_suspend"),
    budget=Budget::default_run(),
  )
  let started = reduce(
    initial,
    catalog,
    Start(payload={
      initial_messages: [UserMessage(content=[Text("hello")])],
      catalog_version: catalog.version(),
    }),
  )
  let waiting = run_model_step(started.next_state(), catalog, Json::null())
  let suspended = reduce(
    waiting.next_state(),
    catalog,
    SuspendRequested(payload={
      requirement: { kind: "approval", payload: Json::null() },
    }),
  )
  assert_true(suspended.next_state().phase() == Suspended)
  assert_true(suspended.next_state().pending_effects().is_empty())
  let resumed = reduce(
    suspended.next_state(),
    catalog,
    Resume(payload={ payload: Json::null() }),
  )
  assert_true(resumed.next_state().phase() == ReadyForModel)
  assert_true(resumed.next_state().run_id() == RunId::unchecked("run_suspend"))
}

///|
test "harness/C-ABORT-DURING-MODEL" {
  let mailbox = ControlMailbox::new()
  let run = RunId::unchecked("run_abort_model")
  mailbox.bind_run(run, TurnId::unchecked("turn_abort_model"))
  let first = mailbox.enqueue_abort({
    command_id: CommandId::unchecked("abort_1"),
    target_run_id: run,
    detail: Some("operator"),
  })
  let repeated = mailbox.enqueue_abort({
    command_id: CommandId::unchecked("abort_2"),
    target_run_id: run,
    detail: None,
  })
  assert_true(first is Accepted(_))
  assert_true(repeated is AbortAlreadyRequested(_))
  assert_true(mailbox.abort_requested())
}

///|
test "harness/C-ABORT-DURING-TOOLS" {
  let gate = PhaseGate::idle()
  let run = RunId::unchecked("run_abort_tools")
  let (gate, _) = gate.acquire_prompt(
    "op",
    run,
    TurnId::unchecked("turn_abort_tools"),
  )
  let active = gate.transition(Active)
  match active.authorise(Structural) {
    Err(OperationNotAllowedInPhase(phase=Active, operation=Structural, ..)) =>
      ()
    _ => fail("mid-run structural control must fail with a typed phase error")
  }
}

///|
async test "harness/C-CONTRIBUTION-VALIDATION-FAIL" {
  let host = FixtureHost::new(
    [Ok(fixture_stop("ignored"))],
    Map::from_array([]),
  )
  let journal = InMemoryJournal::new()
  let bad = FailingContributor::new("bad")
  let harness = Harness::new(
    fixture_config(host, fixture_empty_catalog(), journal, [], [bad]),
  )
  match fixture_prompt(harness, "contribution") {
    Rejected(error=SavepointFailed(..)) => ()
    other =>
      fail("expected typed savepoint rejection, got " + other.to_string())
  }
}

///|
async test "harness/C-JOURNAL-APPEND-FAIL" {
  let host = FixtureHost::new(
    [Ok(fixture_stop("ignored"))],
    Map::from_array([]),
  )
  let inner = InMemoryJournal::new()
  let failing = FailOnNthJournal::new(inner, 1)
  let harness = Harness::new(
    fixture_config(host, fixture_empty_catalog(), failing, [], []),
  )
  match fixture_prompt(harness, "journal") {
    Rejected(error=SavepointFailed(cause=BarrierFailed(..), ..)) => ()
    other => fail("expected barrier rejection, got " + other.to_string())
  }
  assert_eq(inner.revision(), 0)
}

///|
async test "harness/C-SUBSCRIBER-FAIL" {
  let host = FixtureHost::new(
    [Ok(fixture_stop("ignored"))],
    Map::from_array([]),
  )
  let journal = InMemoryJournal::new()
  let subscriber = FailingSubscriber::new("bad")
  let harness = Harness::new(
    fixture_config(host, fixture_empty_catalog(), journal, [subscriber], []),
  )
  match fixture_prompt(harness, "subscriber") {
    Rejected(error=SubscriberFailed(..)) => ()
    other => fail("expected subscriber rejection, got " + other.to_string())
  }
  assert_true(
    journal.entries_for_run(RunId::unchecked("run_subscriber")).length() > 0,
  )
}

///|
test "harness/C-LATE-COMPLETION" {
  let catalog = fixture_empty_catalog()
  let state = RunState::initial(
    run_id=RunId::unchecked("run_late"),
    session_id=SessionId::unchecked("session_late"),
    budget=Budget::default_run(),
  )
  let started = reduce(
    state,
    catalog,
    Start(payload={
      initial_messages: [UserMessage(content=[Text("hi")])],
      catalog_version: catalog.version(),
    }),
  )
  let waiting = run_model_step(started.next_state(), catalog, Json::null())
  let effect = waiting.next_state().pending_effects()[0]
  let completed = reduce(
    waiting.next_state(),
    catalog,
    ModelCompleted(payload={
      effect_id: effect.effect_id(),
      model_step_id: ModelStepId::first(),
      completion: fixture_stop("done"),
    }),
  )
  let rejected = reduce(
    completed.next_state(),
    catalog,
    ModelCompleted(payload={
      effect_id: effect.effect_id(),
      model_step_id: ModelStepId::first(),
      completion: fixture_stop("late"),
    }),
  )
  // Rejections preserve the terminal result and transcript; only the event
  // sequence advances to record the observable InputRejected diagnostic.
  assert_true(rejected.next_state().phase() == Terminal)
  assert_true(
    rejected.next_state().outcome() == completed.next_state().outcome(),
  )
  assert_true(
    rejected.next_state().transcript() == completed.next_state().transcript(),
  )
  assert_true(
    rejected.next_state().next_event_sequence().to_int() ==
    completed.next_state().next_event_sequence().to_int() + 1,
  )
  assert_true(rejected.events().length() == 1)
  assert_true(rejected.events()[0] is InputRejected(..))
}

///|
test "harness/C-DOUBLE-TERMINAL-REJECTION" {
  let mailbox = ControlMailbox::new()
  let result = mailbox.enqueue_abort({
    command_id: CommandId::unchecked("late_abort"),
    target_run_id: RunId::unchecked("completed"),
    detail: None,
  })
  assert_true(result is RejectedStale(_))
}

///|
test "harness/C-SEQ-MONOTONIC-ACROSS-SUSPEND" {
  let catalog = fixture_empty_catalog()
  let state = RunState::initial(
    run_id=RunId::unchecked("run_seq"),
    session_id=SessionId::unchecked("session_seq"),
    budget=Budget::default_run(),
  )
  let started = reduce(
    state,
    catalog,
    Start(payload={ initial_messages: [], catalog_version: catalog.version() }),
  )
  let waiting = run_model_step(started.next_state(), catalog, Json::null())
  let suspended = reduce(
    waiting.next_state(),
    catalog,
    SuspendRequested(payload={
      requirement: { kind: "approval", payload: Json::null() },
    }),
  )
  let resumed = reduce(
    suspended.next_state(),
    catalog,
    Resume(payload={ payload: Json::null() }),
  )
  assert_true(
    started.next_state().next_event_sequence().to_int() <
    suspended.next_state().next_event_sequence().to_int(),
  )
  assert_true(
    suspended.next_state().next_event_sequence().to_int() <
    resumed.next_state().next_event_sequence().to_int(),
  )
}

///|
test "harness/C-LEASE-EXCLUSIVE" {
  let gate = PhaseGate::idle()
  let run = RunId::unchecked("run_lease")
  let (gate, _) = gate.acquire_prompt(
    "first",
    run,
    TurnId::unchecked("turn_lease"),
  )
  let result : Result[(PhaseGate, OperationLease), HarnessError] = Ok(
    gate.acquire_prompt("second", run, TurnId::unchecked("turn_other")),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(LeaseHeld(operation_id="second", held_by="first")) => ()
    _ => fail("expected lease held")
  }
}

///|
test "harness/C-SNAPSHOT-IMMUTABLE" {
  let catalog = fixture_empty_catalog()
  let snapshot = TurnSnapshot::capture({
    run_id: RunId::unchecked("run_snapshot"),
    turn_id: TurnId::unchecked("turn_snapshot"),
    session_id: SessionId::unchecked("session_snapshot"),
    catalog,
    model_id: "model",
    call_options: Json::null(),
    budget: Budget::default_run(),
    deadline: None,
    hook_provenance: [],
    lifecycle_provenance: [],
    subscriber_provenance: [],
  })
  let definitions = snapshot.tool_definitions()
  definitions.push(
    CanonicalToolDef::new(
      name=ToolName::unchecked("mutated"),
      description="",
      input_schema=Json::null(),
      owner=OwnerId::unchecked("fixture"),
      policy=Sequential,
      provenance=None,
    ),
  )
  assert_eq(snapshot.tool_definitions().length(), 0)
}

///|
test "harness/C-FOLLOW-UP-SAME-RUN" {
  let mailbox = ControlMailbox::new()
  let run = RunId::unchecked("run_follow")
  let turn = TurnId::unchecked("turn_follow")
  mailbox.bind_run(run, turn)
  let queued = mailbox.enqueue_follow_up({
    command_id: CommandId::unchecked("follow_1"),
    target_run_id: run,
    source_turn_id: turn,
    payload: Json::null(),
  })
  assert_true(queued is Accepted(_))
  match mailbox.consume_one_follow_up() {
    Some(command) => assert_eq(command.target_run_id(), run)
    None => fail("accepted follow-up must be consumable")
  }
}

///|
test "harness/C-STEER-SAFE-POINT" {
  let mailbox = ControlMailbox::new()
  let run = RunId::unchecked("run_steer")
  let turn = TurnId::unchecked("turn_steer")
  mailbox.bind_run(run, turn)
  let queued = mailbox.enqueue_steer({
    command_id: CommandId::unchecked("steer_1"),
    target_run_id: run,
    target_turn_id: turn,
    observed_tool_batch_id: "batch",
    observed_model_step_id: ModelStepId::first(),
    payload: Json::null(),
  })
  assert_true(queued is Accepted(_))
  assert_eq(mailbox.consume_steers().length(), 1)
}

///|
test "harness/C-RESUME-WRONG-SUSPENSION" {
  let gate = PhaseGate::idle()
  let (gate, _) = gate.acquire_prompt(
    "prompt",
    RunId::unchecked("run_resume"),
    TurnId::unchecked("turn_resume"),
  )
  let suspended = gate.transition(Active).enter_suspended("expected")
  let result : Result[(PhaseGate, OperationLease), HarnessError] = Ok(
    suspended.acquire_resume("resume", "wrong"),
  ) catch {
    error => Err(error)
  }
  assert_true(result is Err(SuspensionIdMismatch(..)))
}

///|
async test "harness/C-LIFECYCLE-ROLLBACK" {
  let log = LifecycleSpyLog::new()
  let collection = LifecycleCollection::new()
  collection.register(SpyLifecycleNode::new("a", "a", log))
  collection.register(
    SpyLifecycleNode::new("b", "b", log).fail_on_shutdown_at(1),
  )
  collection.register(
    SpyLifecycleNode::new("c", "c", log).fail_on_startup_at(1),
  )
  let result : Result[Unit, HarnessError] = try {
    collection.startup_all()
    Ok(())
  } catch {
    error => Err(error)
  }
  match result {
    Err(LifecycleStartupFailed(node_id="c", rollback_failures~, ..)) =>
      assert_eq(rollback_failures.length(), 1)
    _ => fail("expected startup rollback failure")
  }
}

///|
test "harness/C-COMPOSITE-LIFECYCLE" {
  let log = LifecycleSpyLog::new()
  let collection = LifecycleCollection::new()
  collection.register(SpyLifecycleNode::new("host", "host", log))
  let duplicate : Result[Unit, HarnessError] = try {
    collection.register(SpyLifecycleNode::new("host", "other", log))
    Ok(())
  } catch {
    error => Err(error)
  }
  assert_true(duplicate is Err(LifecycleDuplicate(..)))
}
