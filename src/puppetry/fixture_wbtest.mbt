///|
/// Canonical HostRuntime fixture and end-to-end Puppet contract cases.
///
/// These fixtures deliberately use only the Kernel host contract and canonical
/// messages/outcomes.

///|
pub(all) struct FixtureHost {
  model_results : Array[Result[@kernel.Completion, ModelFailure]]
  tool_results : Map[String, @kernel.ToolOutcome]
  mut definitions : Array[ToolDef]
  mut model_index : Int
  mut model_call_count : Int
  mut tool_call_count : Int
  mut observed_definition_count : Int
  observed_call_options : Array[Json]
}

///|
pub fn FixtureHost::FixtureHost(
  model_results : Array[Result[@kernel.Completion, ModelFailure]],
  tool_results : Map[String, @kernel.ToolOutcome],
) -> FixtureHost {
  {
    model_results: model_results.copy(),
    tool_results,
    definitions: [],
    model_index: 0,
    model_call_count: 0,
    tool_call_count: 0,
    observed_definition_count: -1,
    observed_call_options: [],
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
pub fn FixtureHost::observed_call_options(self : FixtureHost) -> Array[Json] {
  self.observed_call_options.copy()
}

///|
pub impl @kernel.HostRuntime for FixtureHost with fn call_model(
  self,
  messages : Array[Message],
  tool_definitions : Array[ToolDef],
  call_options : Json,
  _on_chunk : HostChunkCallback?,
) -> Result[ModelCallResult, ModelFailure] {
  self.model_call_count = self.model_call_count + 1
  self.observed_definition_count = tool_definitions.length()
  self.observed_call_options.push(call_options)
  let index = self.model_index
  self.model_index = index + 1
  if index >= self.model_results.length() {
    Err(Runtime(reason="fixture host exhausted model results"))
  } else {
    match self.model_results[index] {
      Ok(completion) =>
        Ok(ModelCallResult::{ completion, processed_messages: messages })
      Err(failure) => Err(failure)
    }
  }
}

///|
pub impl @kernel.HostRuntime for FixtureHost with fn execute_tool(
  self,
  _owner_id : OwnerId,
  call_id : CallId,
  _tool_name : ToolName,
  _arguments : Json,
) -> @kernel.ToolOutcome {
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
  self : FixtureHost,
  effect_ids : Array[EffectId],
  _reason : CancelReason,
) -> Array[(EffectId, CancelDisposition)] {
  ignore(self)
  effect_ids.map(id => (id, NotPropagated))
}

///|
/// M3.5: compact stub — FixtureHost does not exercise compact.
pub impl @kernel.HostRuntime for FixtureHost with fn compact(
  self : FixtureHost,
  _messages : Array[Message],
  _call_options : Json,
  _trigger : @kernel.CompactTrigger,
) -> Result[CompactResult, ModelFailure] {
  ignore(self)
  Err(ModelFailure::Parse(reason="FixtureHost does not implement compact"))
}

///|
fn FixtureHost::wire_definitions(
  self : FixtureHost,
  catalog : ToolCatalogSnapshot,
) -> Unit {
  self.definitions = catalog.definitions()
}

///|
fn fixture_stop(text : String) -> @kernel.Completion {
  Completion(
    content=[Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
    usage=None,
  )
}

///|
fn fixture_tool_calls(calls : Array[ToolCall]) -> @kernel.Completion {
  Completion(
    content=[],
    tool_calls=calls,
    reasoning=None,
    finish_reason=ToolCalls,
    usage=None,
  )
}

///|
fn fixture_call(name : String, id : String) -> ToolCall {
  {
    call_id: CallId::unchecked(id),
    name: ToolName::unchecked(name),
    arguments: Json::object(Map::from_array([])),
  }
}

///|
fn fixture_empty_catalog() -> ToolCatalogSnapshot raise CatalogCompositionError {
  ToolCatalogBuilder().finish(version=CatalogVersion(1))
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
  let builder = ToolCatalogBuilder()
  ignore(
    builder.add(
      ToolDef(
        name=ToolName::unchecked(name),
        description="fixture tool",
        input_schema=schema,
        owner=OwnerId::unchecked("fixture"),
        policy=Parallel,
        provenance=Some("fixture"),
      ),
    ),
  )
  builder.finish(version=CatalogVersion(1))
}

///|
fn canonical_puppet_config(
  host : &@kernel.HostRuntime,
  model_id : String,
  catalog : ToolCatalogSnapshot,
  journal : &RunJournal,
  subscribers : Array[&EventSubscriber],
  contributors : Array[&JournalContributor],
  stream_chunks : HostChunkCallback?,
  call_options : Json,
) -> PuppetConfig {
  // D1: fresh mailbox per config. The mailbox must outlive the Puppet
  // built from this config; tests that need to inject signals grab the
  // reference back via `puppet.mailbox()` after construction.
  let mailbox_instance = ControlMailbox()
  let mailbox : &Mailbox = mailbox_instance as &Mailbox
  {
    host,
    model_id,
    catalog,
    journal,
    contributors,
    subscribers,
    observers: [],
    lifecycle_nodes: [],
    stream_chunks,
    call_options,
    pre_model_hooks: [],
    pre_tool_hooks: [],
    post_event_hooks: [],
    default_budget: Budget::default_run(),
    max_iterations: 50,
    commands: [],
    session_store: None,
    context_window: None,
    compact_threshold: 0.9,
    mailbox,
  }
}

///|
fn fixture_config(
  host : FixtureHost,
  catalog : ToolCatalogSnapshot,
  journal : &RunJournal,
  subscribers : Array[&EventSubscriber],
  contributors : Array[&JournalContributor],
) -> PuppetConfig {
  host.wire_definitions(catalog)
  canonical_puppet_config(
    host as &@kernel.HostRuntime,
    "fixture-model",
    catalog,
    journal,
    subscribers,
    contributors,
    None,
    Json::null(),
  )
}

///|
async fn fixture_prompt(
  puppet : Puppet,
  suffix : String,
) -> PromptResult raise PuppetError {
  puppet.prompt(
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
async test "puppet/C-HAPPY-NO-TOOLS" {
  let host = FixtureHost([Ok(fixture_stop("hi"))], Map::from_array([]))
  let journal = InMemoryJournal()
  let puppet = Puppet(
    fixture_config(host, fixture_empty_catalog(), journal, [], []),
  )
  match fixture_prompt(puppet, "happy") {
    Accepted(..) => ()
    other => fail("expected accepted prompt, got " + other.to_string())
  }
  let entries = journal.entries_for_run(RunId::unchecked("run_happy"))
  assert_true(puppet.phase() == Idle)
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
async test "puppet/C-SINGLE-TOOL" {
  let host = FixtureHost(
    [
      Ok(fixture_tool_calls([fixture_call("echo", "one")])),
      Ok(fixture_stop("done")),
    ],
    Map::from_array([("one", Success(content="ok", structured=None))]),
  )
  let journal = InMemoryJournal()
  let puppet = Puppet(
    fixture_config(host, fixture_tool_catalog("echo"), journal, [], []),
  )
  assert_true(fixture_prompt(puppet, "single") is Accepted(_))
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
async test "puppet/C-PARALLEL-TOOLS" {
  let host = FixtureHost(
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
  let journal = InMemoryJournal()
  let puppet = Puppet(
    fixture_config(host, fixture_tool_catalog("echo"), journal, [], []),
  )
  assert_true(fixture_prompt(puppet, "batch") is Accepted(_))
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
async test "puppet/C-MODEL-FAILURE" {
  let host = FixtureHost(
    [Err(Transport(reason="offline"))],
    Map::from_array([]),
  )
  let journal = InMemoryJournal()
  let puppet = Puppet(
    fixture_config(host, fixture_empty_catalog(), journal, [], []),
  )
  assert_true(fixture_prompt(puppet, "model_failure") is Accepted(_))
  match puppet.wait_idle() {
    Terminal(outcome=Failed(reason=ModelTransport(..))) => ()
    status =>
      fail(
        "expected terminal model transport failure, got " + status.to_string(),
      )
  }
}

///|
async test "puppet/C-TOOL-BUSINESS-FAILURE" {
  let host = FixtureHost(
    [
      Ok(fixture_tool_calls([fixture_call("echo", "business")])),
      Ok(fixture_stop("done")),
    ],
    Map::from_array([
      ("business", ToolReportedError(content="bad input", structured=None)),
    ]),
  )
  let journal = InMemoryJournal()
  let puppet = Puppet(
    fixture_config(host, fixture_tool_catalog("echo"), journal, [], []),
  )
  assert_true(fixture_prompt(puppet, "business") is Accepted(_))
  assert_eq(host.model_call_count(), 2)
  assert_eq(host.tool_call_count(), 1)
}

///|
async test "puppet/C-TOOL-RUNTIME-FAILURE" {
  let host = FixtureHost(
    [
      Ok(fixture_tool_calls([fixture_call("echo", "runtime")])),
      Ok(fixture_stop("done")),
    ],
    Map::from_array([
      ("runtime", RuntimeFailure(error_category="Transport", message="offline")),
    ]),
  )
  let journal = InMemoryJournal()
  let puppet = Puppet(
    fixture_config(host, fixture_tool_catalog("echo"), journal, [], []),
  )
  assert_true(fixture_prompt(puppet, "runtime") is Accepted(_))
  assert_eq(host.model_call_count(), 2)
  assert_eq(host.tool_call_count(), 1)
}

///|
async test "puppet/C-MISSING-OWNER-IS-INVARIANT" {
  let host = FixtureHost(
    [Ok(fixture_tool_calls([fixture_call("echo", "missing_owner")]))],
    Map::from_array([
      (
        "missing_owner",
        RuntimeFailure(error_category="MissingOwner", message="stale owner"),
      ),
    ]),
  )
  let journal = InMemoryJournal()
  let puppet = Puppet(
    fixture_config(host, fixture_tool_catalog("echo"), journal, [], []),
  )
  assert_true(fixture_prompt(puppet, "missing_owner") is Accepted(_))
  match puppet.wait_idle() {
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
test "puppet/C-SUSPEND-RESUME-IN-PROCESS" {
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
test "puppet/C-ABORT-DURING-MODEL" {
  let mailbox = ControlMailbox()
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
test "puppet/C-ABORT-DURING-TOOLS" {
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
async test "puppet/C-CONTRIBUTION-VALIDATION-FAIL" {
  let host = FixtureHost([Ok(fixture_stop("ignored"))], Map::from_array([]))
  let journal = InMemoryJournal()
  let bad = FailingContributor("bad")
  let puppet = Puppet(
    fixture_config(host, fixture_empty_catalog(), journal, [], [bad]),
  )
  match fixture_prompt(puppet, "contribution") {
    Rejected(error=SavepointFailed(..)) => ()
    other =>
      fail("expected typed savepoint rejection, got " + other.to_string())
  }
}

///|
async test "puppet/C-JOURNAL-APPEND-FAIL" {
  let host = FixtureHost([Ok(fixture_stop("ignored"))], Map::from_array([]))
  let inner = InMemoryJournal()
  let failing = FailOnNthJournal(inner, 1)
  let puppet = Puppet(
    fixture_config(host, fixture_empty_catalog(), failing, [], []),
  )
  match fixture_prompt(puppet, "journal") {
    Rejected(error=SavepointFailed(cause=BarrierFailed(..), ..)) => ()
    other => fail("expected barrier rejection, got " + other.to_string())
  }
  assert_eq(inner.revision(), 0)
}

///|
async test "puppet/C-SUBSCRIBER-FAIL" {
  let host = FixtureHost([Ok(fixture_stop("ignored"))], Map::from_array([]))
  let journal = InMemoryJournal()
  let subscriber = FailingSubscriber("bad")
  let puppet = Puppet(
    fixture_config(host, fixture_empty_catalog(), journal, [subscriber], []),
  )
  match fixture_prompt(puppet, "subscriber") {
    Rejected(error=SubscriberFailed(..)) => ()
    other => fail("expected subscriber rejection, got " + other.to_string())
  }
  assert_true(
    journal.entries_for_run(RunId::unchecked("run_subscriber")).length() > 0,
  )
}

///|
test "puppet/C-LATE-COMPLETION" {
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
      processed_messages: waiting.next_state().transcript().messages_snapshot(),
    }),
  )
  let rejected = reduce(
    completed.next_state(),
    catalog,
    ModelCompleted(payload={
      effect_id: effect.effect_id(),
      model_step_id: ModelStepId::first(),
      completion: fixture_stop("late"),
      processed_messages: completed
      .next_state()
      .transcript()
      .messages_snapshot(),
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
test "puppet/C-DOUBLE-TERMINAL-REJECTION" {
  let mailbox = ControlMailbox()
  let result = mailbox.enqueue_abort({
    command_id: CommandId::unchecked("late_abort"),
    target_run_id: RunId::unchecked("completed"),
    detail: None,
  })
  assert_true(result is RejectedStale(_))
}

///|
test "puppet/C-SEQ-MONOTONIC-ACROSS-SUSPEND" {
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
test "puppet/C-LEASE-EXCLUSIVE" {
  let gate = PhaseGate::idle()
  let run = RunId::unchecked("run_lease")
  let (gate, _) = gate.acquire_prompt(
    "first",
    run,
    TurnId::unchecked("turn_lease"),
  )
  let result : Result[(PhaseGate, OperationLease), PuppetError] = Ok(
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
test "puppet/C-SNAPSHOT-IMMUTABLE" {
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
    ToolDef(
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
test "puppet/C-FOLLOW-UP-SAME-RUN" {
  let mailbox = ControlMailbox()
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
test "puppet/C-STEER-SAFE-POINT" {
  let mailbox = ControlMailbox()
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
test "puppet/C-RESUME-WRONG-SUSPENSION" {
  let gate = PhaseGate::idle()
  let (gate, _) = gate.acquire_prompt(
    "prompt",
    RunId::unchecked("run_resume"),
    TurnId::unchecked("turn_resume"),
  )
  let suspended = gate.transition(Active).enter_suspended("expected")
  let result : Result[(PhaseGate, OperationLease), PuppetError] = Ok(
    suspended.acquire_resume("resume", "wrong"),
  ) catch {
    error => Err(error)
  }
  assert_true(result is Err(SuspensionIdMismatch(..)))
}

///|
async test "puppet/C-LIFECYCLE-ROLLBACK" {
  let log = LifecycleSpyLog()
  let collection = LifecycleCollection()
  collection.register(SpyLifecycleNode("a", "a", log))
  collection.register(SpyLifecycleNode("b", "b", log).fail_on_shutdown_at(1))
  collection.register(SpyLifecycleNode("c", "c", log).fail_on_startup_at(1))
  let result : Result[Unit, PuppetError] = try {
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
test "puppet/C-COMPOSITE-LIFECYCLE" {
  let log = LifecycleSpyLog()
  let collection = LifecycleCollection()
  collection.register(SpyLifecycleNode("host", "host", log))
  let duplicate : Result[Unit, PuppetError] = try {
    collection.register(SpyLifecycleNode("host", "other", log))
    Ok(())
  } catch {
    error => Err(error)
  }
  assert_true(duplicate is Err(LifecycleDuplicate(..)))
}
