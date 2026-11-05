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
  mut model_index : Int32
  mut model_call_count : Int32
  mut tool_call_count : Int32
  mut observed_definition_count : Int32
  observed_call_options : Array[Json]
  /// Effect ids received via `execute_tool`, in execution order. Used to
  /// verify the host receives the reducer-allocated effect identity.
  executed_effect_ids : Array[EffectId]
  /// Chunks to deliver through the live callback during a model call. Tests
  /// use this to exercise the executor's trust-boundary validation without
  /// involving a concrete provider adapter.
  mut stream_chunks : Array[@types.StreamChunk]
  /// Raise a host transport error after delivering any configured chunks.
  /// This models a provider that reports a transport/cancellation failure
  /// after an invalid callback, so executor error precedence is testable.
  mut raise_model_transport : Bool
  /// Optional compact result for standalone compact tests.
  mut compact_result : CompactResult?
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
    executed_effect_ids: [],
    stream_chunks: [],
    raise_model_transport: false,
    compact_result: None,
  }
}

///|
fn FixtureHost::with_stream_chunks(
  self : FixtureHost,
  chunks : Array[@types.StreamChunk],
) -> FixtureHost {
  self.stream_chunks = chunks.copy()
  self
}

///|
fn FixtureHost::with_model_transport_failure(self : FixtureHost) -> FixtureHost {
  self.raise_model_transport = true
  self
}

///|
fn FixtureHost::with_compact_result(
  self : FixtureHost,
  result : CompactResult,
) -> FixtureHost {
  self.compact_result = Some(result)
  self
}

///|
pub fn FixtureHost::model_call_count(self : FixtureHost) -> Int32 {
  self.model_call_count
}

///|
pub fn FixtureHost::tool_call_count(self : FixtureHost) -> Int32 {
  self.tool_call_count
}

///|
pub fn FixtureHost::observed_definition_count(self : FixtureHost) -> Int32 {
  self.observed_definition_count
}

///|
pub fn FixtureHost::observed_call_options(self : FixtureHost) -> Array[Json] {
  self.observed_call_options.copy()
}

///|
pub fn FixtureHost::executed_effect_ids(self : FixtureHost) -> Array[EffectId] {
  self.executed_effect_ids.copy()
}

///|
pub extend FixtureHost with @kernel_exec.HostRuntime::{
  execute_tool,
  cancel_effects,
  call_model,
  compact,
}

///|
pub impl @kernel_exec.HostRuntime for FixtureHost with fn call_model(
  self,
  _scope : InvocationScope,
  messages : ArrayView[Message],
  tool_definitions : Array[ToolDef],
  call_options : Json,
  on_chunk : HostChunkCallback?,
) -> Result[ModelCallResult, ModelFailure] {
  self.model_call_count = self.model_call_count + 1
  self.observed_definition_count = tool_definitions.length()
  self.observed_call_options.push(call_options)
  let index = self.model_index
  self.model_index = index + 1
  match on_chunk {
    Some(callback) =>
      for chunk in self.stream_chunks {
        callback(chunk)
      }
    None => ()
  }
  if self.raise_model_transport {
    raise @error.ModelError::Transport("fixture host transport failure")
  }
  if index >= self.model_results.length() {
    Err(Runtime(reason="fixture host exhausted model results"))
  } else {
    match self.model_results[index] {
      Ok(completion) =>
        Ok({ completion, processed_messages: messages.to_owned(), })
      Err(failure) => Err(failure)
    }
  }
}

///|
pub impl @kernel_exec.HostRuntime for FixtureHost with fn execute_tool(
  self,
  effect_id : EffectId,
  _owner_id : OwnerId,
  call_id : CallId,
  _tool_name : ToolName,
  _arguments : Json,
  _scope,
) -> @kernel.ToolOutcome {
  self.tool_call_count = self.tool_call_count + 1
  self.executed_effect_ids.push(effect_id)
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
pub impl @kernel_exec.HostRuntime for FixtureHost with fn cancel_effects(
  self : FixtureHost,
  run_id~,
  effect_ids : Array[EffectId],
  _reason : CancelReason,
) -> Array[(EffectId, CancelDisposition)] {
  let _ = run_id

  ignore(self)
  effect_ids.map(id => (id, NotPropagated))
}

///|
/// Compact stub — FixtureHost does not exercise compact.
pub impl @kernel_exec.HostRuntime for FixtureHost with fn compact(
  self : FixtureHost,
  _scope : InvocationScope,
  _messages : ArrayView[Message],
  _tools : Array[ToolDef],
  _call_options : Json,
  _trigger : @kernel.CompactTrigger,
) -> Result[CompactResult, ModelFailure] {
  match self.compact_result {
    Some(result) => Ok(result)
    None => Err(Parse(reason="FixtureHost does not implement compact"))
  }
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
fn fixture_stop_with_usage(
  text : String,
  usage : @kernel.Usage,
) -> @kernel.Completion {
  Completion(
    content=[Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
    usage=Some(usage),
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
  host : &@kernel_exec.HostRuntime,
  catalog : ToolCatalogSnapshot,
  journal : &RunJournal,
  subscribers : Array[&EventSubscriber],
  contributors : Array[&JournalContributor],
  stream_chunks : HostChunkCallback?,
) -> PuppetConfig {
  // Fresh mailbox per config. The mailbox must outlive the Puppet
  // built from this config; tests that need to inject signals grab the
  // reference back via `puppet.mailbox()` after construction.
  let mailbox_instance = ControlMailbox()
  let mailbox : &Mailbox = mailbox_instance as &Mailbox
  {
    host,
    catalog,
    journal,
    contributors,
    subscribers,
    stream_chunks,
    hooks: [],
    tool_call_owners: Map::from_array([]),
    max_tool_depth: None,
    max_iterations: Some(50),
    commands: [],
    mailbox,
  }
}

///|
fn fixture_run_policy(model_id : String, call_options : Json) -> RunPolicy {
  {
    model_id,
    call_options,
    budget: Budget::default_run(),
    context_window: None,
    compact_threshold: 0.9,
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
    host as &@kernel_exec.HostRuntime,
    catalog,
    journal,
    subscribers,
    contributors,
    None,
  )
}

///|
async fn fixture_prompt(
  puppet : Puppet,
  suffix : String,
) -> PromptResult raise PuppetError {
  puppet.prompt({
    run_id: RunId::unchecked("run_" + suffix),
    turn_id: TurnId::unchecked("turn_" + suffix),
    session_id: SessionId::unchecked("session_" + suffix),
    initial_messages: [UserMessage(content=[Text("hello")])],
    operation_id: "operation_" + suffix,
    policy: fixture_run_policy("fixture-model", Json::null()),
  })
}

///|
/// The host must receive the reducer-allocated effect identity with each
/// `execute_tool` call. Allocation is deterministic per run: CallModel is
/// effect 1, the tool batch follows as effects 2..N. Hosts that propagate
/// cancellation correlate `cancel_effects` with these ids, so a wrong or
/// missing id here would break the cancel seam end to end.
async test "puppet/C-EFFECT-ID-PROPAGATION" {
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
  assert_true(fixture_prompt(puppet, "effect_ids") is Accepted(_))
  let ids = host.executed_effect_ids().map(id => id.to_int())
  ids.sort()
  assert_eq(ids, [2, 3])
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
    // The host's `Transport("offline")` reason must survive verbatim to the
    // terminal outcome's detail.
    Terminal(outcome=Failed(reason=ModelTransport(detail~))) =>
      assert_eq(detail, "offline")
    status =>
      fail(
        "expected terminal model transport failure, got " + status.to_string(),
      )
  }
}

///|
async test "puppet/C-NEGATIVE-USAGE-FAILS-BEFORE-MODEL-COMPLETED" {
  let invalid_usage : @kernel.Usage = {
    input_tokens: Some(100),
    output_tokens: Some(-1),
    total_tokens: Some(99),
    cached_input_tokens: None,
    uncached_input_tokens: None,
  }
  let host = FixtureHost(
    [Ok(fixture_stop_with_usage("must fail", invalid_usage))],
    Map::from_array([]),
  )
  let journal = InMemoryJournal()
  let puppet = Puppet(
    fixture_config(host, fixture_empty_catalog(), journal, [], []),
  )
  assert_true(fixture_prompt(puppet, "negative_usage") is Accepted(_))
  match puppet.wait_idle() {
    Terminal(outcome=Failed(reason=ModelParseFailure(detail~))) =>
      assert_true(detail.contains("model usage validation failed"))
    status =>
      fail(
        "expected terminal model parse failure for negative usage, got " +
        status.to_string(),
      )
  }
}

///|
async test "puppet/C-INVALID-STREAM-CHUNK-NOT-BROADCAST" {
  let host = FixtureHost([Ok(fixture_stop("must fail"))], Map::from_array([])).with_stream_chunks([
      @types.StreamChunk::ToolCallDelta(
        index=3,
        id=Some("sparse"),
        name=Some("echo"),
        arguments_delta=Some("{}"),
      ),
    ],
  )
  let journal = InMemoryJournal()
  let seen : Array[@types.StreamChunk] = []
  let sink = fn(chunk : @types.StreamChunk) { seen.push(chunk) }
  let puppet = Puppet(
    canonical_puppet_config(
      host as &@kernel_exec.HostRuntime,
      fixture_empty_catalog(),
      journal,
      [],
      [],
      Some(sink),
    ),
  )
  assert_true(fixture_prompt(puppet, "invalid_stream") is Accepted(_))
  assert_eq(seen.length(), 0)
  match puppet.wait_idle() {
    Terminal(outcome=Failed(reason=ModelParseFailure(detail~))) =>
      assert_true(detail.contains("stream chunk validation failed"))
    status =>
      fail(
        "expected terminal model parse failure for invalid stream chunk, got " +
        status.to_string(),
      )
  }
}

///|
async test "puppet/C-INVALID-STREAM-CHUNK-HOST-RAISE-PRIMARY" {
  let host = FixtureHost(
      [Ok(fixture_stop("host must fail"))],
      Map::from_array([]),
    )
    .with_stream_chunks([
      @types.StreamChunk::ToolCallDelta(
        index=3,
        id=Some("sparse"),
        name=Some("echo"),
        arguments_delta=Some("{}"),
      ),
    ])
    .with_model_transport_failure()
  let journal = InMemoryJournal()
  let seen : Array[@types.StreamChunk] = []
  let sink = fn(chunk : @types.StreamChunk) { seen.push(chunk) }
  let puppet = Puppet(
    canonical_puppet_config(
      host as &@kernel_exec.HostRuntime,
      fixture_empty_catalog(),
      journal,
      [],
      [],
      Some(sink),
    ),
  )
  match fixture_prompt(puppet, "invalid_stream_host_failure") {
    Rejected(error=EffectExecutionFailed(phase~, cause~)) => {
      assert_eq(phase, "AwaitingModel")
      assert_true(cause.contains("fixture host transport failure"))
      assert_false(cause.contains("stream chunk validation failed"))
    }
    other =>
      fail(
        "expected host EffectExecutionFailed to remain primary, got " +
        other.to_string(),
      )
  }
  // The callback ABI cannot stop the provider, but the invalid chunk must
  // never cross Posoco's observer boundary.
  assert_eq(seen.length(), 0)
}

///|
async test "puppet/C-INVALID-STREAM-CHUNK-RETURNED-RATE-LIMITED-PRIMARY" {
  let host = FixtureHost(
    [
      Err(
        RateLimited(
          reason="fixture returned rate limit",
          reset_at_ms=Some(1234L),
          provider_code=Some("429"),
        ),
      ),
    ],
    Map::from_array([]),
  ).with_stream_chunks([
    @types.StreamChunk::ToolCallDelta(
      index=3,
      id=Some("sparse"),
      name=Some("echo"),
      arguments_delta=Some("{}"),
    ),
  ])
  let journal = InMemoryJournal()
  let seen : Array[@types.StreamChunk] = []
  let sink = fn(chunk : @types.StreamChunk) { seen.push(chunk) }
  let puppet = Puppet(
    canonical_puppet_config(
      host as &@kernel_exec.HostRuntime,
      fixture_empty_catalog(),
      journal,
      [],
      [],
      Some(sink),
    ),
  )
  assert_true(
    fixture_prompt(puppet, "invalid_stream_returned_rate_limit") is Accepted(_),
  )
  assert_eq(seen.length(), 0)
  match puppet.wait_idle() {
    Terminal(
      outcome=Failed(
        reason=ModelQuotaExhausted(detail~, reset_at_ms~, provider_code~)
      )
    ) => {
      assert_true(detail.contains("fixture returned rate limit"))
      assert_false(detail.contains("stream chunk validation failed"))
      assert_eq(reset_at_ms, Some(1234L))
      assert_eq(provider_code, Some("429"))
    }
    status =>
      fail(
        "expected returned ModelQuotaExhausted to remain primary, got " +
        status.to_string(),
      )
  }
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
struct AbortProbeHost {
  model_results : Array[Result[@kernel.Completion, ModelFailure]]
  mut model_index : Int32
  tool_delays_ms : Map[String, Int32]
  started_calls : Array[String]
  tool_started_signal : @aqueue.Queue[String]
  model_started_signal : @aqueue.Queue[Unit]
  /// Per-model-call release gates. When a gate exists for the call at
  /// index i, `call_model` parks on it (cancellably) until the test
  /// releases it. This replaces fixed sleep margins: an unreleased gate
  /// proves the abort landed mid-call.
  model_gates : Array[@aqueue.Queue[Unit]]
  /// Per-call-id release gates for `execute_tool`. When a gate exists for
  /// a call id, the tool parks on it instead of sleeping `tool_delays_ms`.
  tool_gates : Map[String, @aqueue.Queue[Unit]]
  /// Every `cancel_effects` delivery as (effect_ids, reason), in order.
  cancel_log : Array[(Array[EffectId], CancelReason)]
}

///|
fn AbortProbeHost::AbortProbeHost(
  model_results : Array[Result[@kernel.Completion, ModelFailure]],
  tool_delays_ms : Map[String, Int32],
  tool_started_signal : @aqueue.Queue[String],
  model_gates~ : Array[@aqueue.Queue[Unit]] = [],
  tool_gates~ : Map[String, @aqueue.Queue[Unit]] = Map::from_array([]),
) -> AbortProbeHost {
  {
    model_results: model_results.copy(),
    model_index: 0,
    tool_delays_ms,
    started_calls: [],
    tool_started_signal,
    model_started_signal: Queue(kind=Unbounded),
    model_gates,
    tool_gates,
    cancel_log: [],
  }
}

///|
pub extend AbortProbeHost with @kernel_exec.HostRuntime::{
  execute_tool,
  cancel_effects,
  call_model,
  compact,
}

///|
pub impl @kernel_exec.HostRuntime for AbortProbeHost with fn call_model(
  self,
  _scope : InvocationScope,
  messages : ArrayView[Message],
  _tool_definitions : Array[ToolDef],
  _call_options : Json,
  _on_chunk : HostChunkCallback?,
) -> Result[ModelCallResult, ModelFailure] {
  self.model_started_signal.put(())
  let index = self.model_index
  self.model_index = index + 1
  // Queue gate: a call with a configured gate parks here until the test
  // releases it or the pump cancels the effect task on abort. `Queue::get`
  // is a cancellation point, so a parked call can never "win" the race.
  match self.model_gates.get(index) {
    Some(gate) => gate.get()
    None => ()
  }
  if index >= self.model_results.length() {
    Err(Runtime(reason="abort probe exhausted model results"))
  } else {
    match self.model_results[index] {
      Ok(completion) =>
        Ok({ completion, processed_messages: messages.to_owned(), })
      Err(failure) => Err(failure)
    }
  }
}

///|
pub impl @kernel_exec.HostRuntime for AbortProbeHost with fn execute_tool(
  self,
  _effect_id : EffectId,
  _owner_id : OwnerId,
  call_id : CallId,
  _tool_name : ToolName,
  _arguments : Json,
  _scope,
) -> @kernel.ToolOutcome {
  let id = call_id.to_string()
  self.started_calls.push(id)
  self.tool_started_signal.put(id)
  // Queue gate first: a configured gate parks the tool (cancellably) so the
  // abort provably lands mid-wave. Only ungated calls fall back to the
  // fixed delay.
  match self.tool_gates.get(id) {
    Some(gate) => gate.get()
    None => {
      let delay = match self.tool_delays_ms.get(id) {
        Some(d) => d
        None => 10
      }
      @async.sleep(delay)
    }
  }
  Success(content=id + "-done", structured=None)
}

///|
pub impl @kernel_exec.HostRuntime for AbortProbeHost with fn cancel_effects(
  self : AbortProbeHost,
  run_id~,
  effect_ids : Array[EffectId],
  reason : CancelReason,
) -> Array[(EffectId, CancelDisposition)] {
  let _ = run_id

  // Record-only seam: the disposition contract stays NotPropagated (this
  // fixture does not propagate), but every delivery is logged so the abort
  // tests can assert which in-flight ids reached the host and why.
  self.cancel_log.push((effect_ids.copy(), reason))
  effect_ids.map(id => (id, NotPropagated))
}

///|
/// Compact stub — AbortProbeHost does not exercise compact.
pub impl @kernel_exec.HostRuntime for AbortProbeHost with fn compact(
  self : AbortProbeHost,
  _scope : InvocationScope,
  _messages : ArrayView[Message],
  _tools : Array[ToolDef],
  _call_options : Json,
  _trigger : @kernel.CompactTrigger,
) -> Result[CompactResult, ModelFailure] {
  ignore(self)
  Err(Parse(reason="AbortProbeHost does not implement compact"))
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
    // The raising contributor's id must survive into the typed cause.
    Rejected(
      error=SavepointFailed(cause=ContributorRaised(contributor_id~, ..), ..)
    ) => assert_eq(contributor_id, "bad")
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
    // The journal adapter's injected barrier failure detail must survive
    // into the typed cause verbatim.
    Rejected(error=SavepointFailed(cause=BarrierFailed(detail~), ..)) =>
      assert_true(detail.contains("injected failure on append #1"))
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
    // The failing subscriber's id must be attributed in the rejection.
    Rejected(error=SubscriberFailed(subscriber_id~, ..)) =>
      assert_eq(subscriber_id, "bad")
    other => fail("expected subscriber rejection, got " + other.to_string())
  }
  assert_true(
    journal.entries_for_run(RunId::unchecked("run_subscriber")).length() > 0,
  )
}

///|
// C-DOUBLE-TERMINAL-REJECTION removed: stale abort on an unbound mailbox is
// covered by `puppet_control/abort_no_active_run_rejected` (control_wbtest).

///|
// C-LEASE-EXCLUSIVE removed: lease exclusivity is covered by
// `puppet_phase/lease_held_rejects_second_prompt` (phase_wbtest).

///|
// C-SNAPSHOT-IMMUTABLE removed: snapshot copy semantics are covered by
// `puppet_snapshot/mutation_of_original_array_does_not_affect_snapshot`
// (snapshot_wbtest).

///|
// C-FOLLOW-UP-SAME-RUN removed: follow-up enqueue/consume is covered by
// `puppet_control/follow_up_enqueue_accepted` +
// `puppet_control/follow_up_consume_one_at_a_time` (control_wbtest).

///|
// C-STEER-SAFE-POINT removed: steer enqueue/consume is covered by
// `puppet_control/steer_enqueue_accepted` +
// `puppet_control/steer_consume_drains_queue` (control_wbtest).

///|
// C-RESUME-WRONG-SUSPENSION removed: resume with a mismatched suspension id
// is covered by `puppet_phase/resume_wrong_suspension_id` (phase_wbtest).

///|
async test "puppet/C-WAIT-IDLE-REPORTS-THE-CURRENT-RUN" {
  let released : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  released.put(())
  let held : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let host = AbortProbeHost(
    [Ok(fixture_stop("first")), Err(Transport(reason="second-offline"))],
    Map::from_array([]),
    Queue(kind=Unbounded),
    model_gates=[released, held],
  )
  let journal = InMemoryJournal()
  let puppet = Puppet(
    canonical_puppet_config(
      host as &@kernel_exec.HostRuntime,
      fixture_empty_catalog(),
      journal,
      [],
      [],
      None,
    ),
  )
  assert_true(fixture_prompt(puppet, "first") is Accepted(_))
  match puppet.wait_idle() {
    Terminal(outcome=Completed(_)) => ()
    status =>
      fail("run 1 must report its own terminal, got " + status.to_string())
  }
  // Drain run 1's model-start signal so the next take belongs to run 2.
  ignore(host.model_started_signal.get())
  let blocked : Ref[Bool] = Ref(false)
  @async.with_task_group(async fn(group) {
    let run_two = group.spawn(async fn() { fixture_prompt(puppet, "second") })
    ignore(host.model_started_signal.get())
    // Run 2 is parked inside its model call: the barrier must not hand back
    // run 1's terminal outcome.
    let probe : Result[QuiescentStatus, Error] = Ok(
      @async.with_timeout(60, () => puppet.wait_idle()),
    ) catch {
      error => Err(error)
    }
    match probe {
      Ok(status) =>
        fail("wait_idle returned stale \{status.to_string()} mid-run")
      Err(_) => blocked.val = true
    }
    assert_true(puppet.mailbox().quiescent_status() is Active)
    held.put(())
    assert_true(run_two.wait() is Accepted(_))
  })
  assert_true(blocked.val)
  match puppet.wait_idle() {
    Terminal(outcome=Failed(reason=ModelTransport(detail~))) =>
      assert_eq(detail, "second-offline")
    status => fail("expected run 2's terminal, got " + status.to_string())
  }
}
