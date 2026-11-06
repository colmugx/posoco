///|
/// Black-box contract tests for the operation-owned UI resource lifetime,
/// driven through the public `Agent` surface: an extension publishes a
/// transient panel inside the admitted operation, the release reclaims it,
/// and the owner-bound result card stays.

///|
/// Extension owning both kinds of presentation: a transient panel published
/// from `on_turn_begin` (inside the operation) and an optional final result
/// card published from `on_turn_end`.
struct OperationDesk {
  captured : Ref[@posoco.UiResources?]
  /// Handles captured while operations were live, in operation order.
  handles : Array[@posoco.UiResources]
  panel_publishes : Array[
    Result[@posoco.UiResourceSnapshot, @posoco.UiResourceError],
  ]
  card_publishes : Array[
    Result[@posoco.UiResourceSnapshot, @posoco.UiResourceError],
  ]
  /// Publications attempted with a handle captured by an earlier operation.
  stale_attempts : Array[
    Result[@posoco.UiResourceSnapshot, @posoco.UiResourceError],
  ]
  /// Re-acquisitions attempted with a handle captured by an earlier operation.
  stale_nested : Array[Result[@posoco.UiResources, @posoco.UiResourceError]]
  /// Host-support queries issued with an earlier operation's handle while the
  /// next operation's panel is live.
  stale_support : Array[
    Result[Array[@posoco.UiHostConnectionSupport], @posoco.UiResourceError],
  ]
  /// Withdrawals attempted with an earlier operation's handle.
  stale_removals : Array[Result[Int32, @posoco.UiResourceError]]
  /// Replacements that would migrate the live panel's lifetime.
  migration_attempts : Array[
    Result[@posoco.UiResourceSnapshot, @posoco.UiResourceError],
  ]
  panel : Bool
  card : Bool
  probe_migration : Bool
  probe_stale : Bool
}

///|
fn OperationDesk::new(
  panel~ : Bool = true,
  card~ : Bool = false,
  probe_migration~ : Bool = false,
  probe_stale~ : Bool = false,
) -> OperationDesk {
  {
    captured: Ref(None),
    handles: [],
    panel_publishes: [],
    card_publishes: [],
    stale_attempts: [],
    stale_nested: [],
    stale_support: [],
    stale_removals: [],
    migration_attempts: [],
    panel,
    card,
    probe_migration,
    probe_stale,
  }
}

///|
impl @port.Lifecycle for OperationDesk with fn on_compose(self, ctx) {
  self.captured.val = ctx.ui_resources()
}

///|
impl @port.Extension for OperationDesk with fn extension_id(_self) -> String {
  "board"
}

///|
impl @port.Extension for OperationDesk with fn manifest(self) -> @port.ExtensionManifest {
  {
    id: "board",
    models: [],
    decisions: [],
    logs: [],
    tools: [],
    sessions: [],
    observers: [],
    hooks: [self],
    memory: [],
    lifecycle: [self],
    commands: [],
    ui: [],
    prompt_contributors: [],
    requires: [@port.Capability::Ui],
    tool_call_owners: [],
  }
}

///|
pub extend OperationDesk with @port.Extension::{extension_id, manifest}

///|
impl @port.PipelineHook for OperationDesk with fn on_turn_begin(self) {
  let resources = match self.captured.val {
    Some(resources) => resources
    None => return
  }
  let handle = match resources.operation() {
    Ok(handle) => handle
    Err(error) => {
      self.panel_publishes.push(Err(error))
      return
    }
  }
  // A handle captured by an earlier operation is dead.
  let stale = if self.handles.length() > 0 {
    let stale = self.handles[self.handles.length() - 1]
    // Re-acquiring from a dead handle must not capture this operation either.
    self.stale_nested.push(stale.operation())
    self.stale_attempts.push(
      stale.publish(draft=operation_panel_draft(key="stale", note="late")),
    )
    Some(stale)
  } else {
    None
  }
  self.handles.push(handle)
  if !self.panel {
    return
  }
  self.panel_publishes.push(
    handle.publish(draft=operation_panel_draft(key="panel", note="running")),
  )
  if self.probe_stale {
    match stale {
      Some(stale) =>
        match self.panel_publishes[self.panel_publishes.length() - 1] {
          Ok(snapshot) => {
            // The old handle can neither interrogate nor withdraw the live
            // panel.
            self.stale_support.push(
              stale.host_support(resource=snapshot.resource),
            )
            self.stale_removals.push(stale.remove(resource=snapshot.resource))
          }
          Err(_) => ()
        }
      None => ()
    }
  }
  if self.probe_migration {
    // Neither direction of a lifetime migration is a replacement.
    self.migration_attempts.push(
      handle.replace(
        draft=final_card_draft(key="panel", note="promoted"),
        expected=1,
      ),
    )
    self.migration_attempts.push(
      resources.replace(
        draft=final_card_draft(key="panel", note="hijacked"),
        expected=1,
      ),
    )
  }
}

///|
impl @port.PipelineHook for OperationDesk with fn on_turn_end(self) {
  if !self.card {
    return
  }
  match self.captured.val {
    Some(resources) =>
      self.card_publishes.push(
        resources.publish(draft=final_card_draft(key="result", note="done")),
      )
    None => ()
  }
}

///|
pub extend OperationDesk with @port.PipelineHook::{on_turn_begin, on_turn_end}

///|
/// A transient panel: only an admitted operation can publish it, and the
/// operation's settlement reclaims it.
fn operation_panel_draft(
  key~ : String,
  note~ : String,
) -> @posoco.UiResourceDraft {
  @posoco.UiResourceDraft::new(
    key~,
    kind=@posoco.UiResourceKind::standard(name="operation_panel"),
    body=@posoco.UiResourceBody::Text("进行中：\{note}"),
    scope=@posoco.UiResourceScope::OperationScope(id="turn"),
    lifetime=@posoco.UiResourceLifetime::OperationBound,
  )
}

///|
/// The final result card: owner-bound, so it survives operation settlement.
fn final_card_draft(key~ : String, note~ : String) -> @posoco.UiResourceDraft {
  @posoco.UiResourceDraft::new(
    key~,
    kind=@posoco.UiResourceKind::standard(name="review_board"),
    body=@posoco.UiResourceBody::Text("结论：\{note}"),
  )
}

///|
/// A tool that asks the host control mailbox to cancel the running operation,
/// so the cancelled release path can be observed from the outside.
struct CancellingTool {
  defs : Array[@kernel.ToolDef]
  mut control : @posoco.AgentControl?
}

///|
fn CancellingTool::new() -> CancellingTool {
  {
    defs: [@test_support.tk_tool_def("cancel_me", "cancel the operation")],
    control: None,
  }
}

///|
impl @port.ToolProvider for CancellingTool with fn list_tools(self) {
  self.defs.copy()
}

///|
impl @port.ToolProvider for CancellingTool with fn execute(
  self,
  _ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  let control = match self.control {
    Some(control) => control
    None =>
      raise @error.RuntimeError::InvocationFailed(
        "cancelling tool has no control handle",
      )
  }
  ignore(control.abort_active(Some("host cancelled the operation")))
  Success(content="cancelling", structured=None)
}

///|
fn operation_agent(
  desk : OperationDesk,
  steps : Array[@test_support.ScriptedModelStep],
  tools~ : Array[&@port.ToolProvider] = [],
) -> @posoco.Agent {
  try
    @posoco.Agent(
      exts=[
        @test_support.tk_ext(
          id="model",
          model=Some(@test_support.ScriptedModel(steps)),
        ),
        @test_support.tk_ext(
          id="board",
          hooks=[desk],
          lifecycle=[desk],
          tools~,
          requires=[@port.Capability::Ui],
        ),
      ],
      config=@posoco.agent_config(),
      events=@posoco.EventSystem(),
    )
  catch {
    error => abort("composition failed: \{error}")
  } noraise {
    value => value
  }
}

///|
fn desk_capability(desk : OperationDesk) -> @posoco.UiResources {
  match desk.captured.val {
    Some(capability) => capability
    None => abort("expected the composition to deliver the UI capability")
  }
}

///|
fn change_label(change : @posoco.UiResourceChange) -> String {
  match change {
    Published(_) => "published"
    Replaced(_) => "replaced"
    Withdrawn(..) => "withdrawn"
  }
}

///|
fn feed_labels(batch : @posoco.UiFeedBatch) -> String {
  match batch.change {
    @posoco.UiChange::Resource(change~) => change_label(change)
    @posoco.UiChange::Interaction(_) => "interaction"
  }
}

///|
fn subscribe_labels(
  host : @posoco.UiHost,
  delivered : Array[String],
) -> @posoco.UiObservation {
  match
    host.subscribe(
      listener=fn(batch) {
        delivered.push(feed_labels(batch))
        Ok(())
      },
      on_failure=fn(failure) { abort("listener failed: \{failure.detail}") },
    ) {
    Ok(observation) => observation
    Err(error) => abort("subscribe failed: \{error}")
  }
}

///|
fn pulled_labels(
  host : @posoco.UiHost,
  cursor : @posoco.UiCursor,
) -> Array[String] {
  match host.changes_since(cursor~) {
    Ok(changes) => changes.changes.map(change_label)
    Err(error) => abort("changes failed: \{error}")
  }
}

///|

///|
/// Run one turn and hand the typed outcome back as data, so a test can assert
/// on completion, failure and cancellation without hiding any of them.
async fn run_one_turn(
  agent : @posoco.Agent,
  session_id : String,
) -> @error.AgentError? {
  let outcome : Result[@types.TurnResult, @error.AgentError] = Ok(
    agent.run_turn(@test_support.tk_user_msg("review this"), session_id),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Ok(_) => None
    Err(error) => Some(error)
  }
}

///|
fn expect_snapshot(host : @posoco.UiHost) -> @posoco.UiBaseline {
  match host.snapshot() {
    Ok(baseline) => baseline
    Err(error) => abort("snapshot failed: \{error}")
  }
}

///|
async test "ui_operation/completed_turn_reclaims_the_panel_and_keeps_the_card" {
  let desk = OperationDesk::new(card=true)
  let agent = operation_agent(desk, [
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("published"),
    ),
  ])
  let host = agent.ui_host()
  let delivered : Array[String] = []
  let observation = subscribe_labels(host, delivered)
  assert_true(run_one_turn(agent, "session_op_complete") is None)
  // Panel and card publish while the operation runs; settlement withdraws the panel.
  assert_eq(delivered, ["published", "published", "withdrawn"])
  let baseline = expect_snapshot(host)
  assert_eq(baseline.resources.length(), 1)
  assert_eq(baseline.resources[0].resource.key, "result")
  assert_eq(baseline.resources[0].revision, 1)
  assert_eq(
    baseline.resources[0].lifetime,
    @posoco.UiResourceLifetime::OwnerBound,
  )
  // Push and pull agree on the same cut.
  assert_eq(pulled_labels(host, observation.baseline.cursor), delivered)
  // The handle that published the panel is gone.
  assert_eq(desk.handles.length(), 1)
  match
    desk.handles[0].publish(
      draft=operation_panel_draft(key="panel", note="late"),
    ) {
    Err(@posoco.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("agent_run_turn_1"))
    Ok(_) => abort("expected a settled operation handle to be refused")
    Err(other) => abort("expected InvalidInput, got \{other}")
  }
  assert_eq(expect_snapshot(host).resources.length(), 1)
  agent.shutdown()
}

///|
async test "ui_operation/failed_turn_reclaims_the_panel" {
  let desk = OperationDesk::new()
  let agent = operation_agent(desk, [
    @test_support.ScriptedModelStep::Fail(
      @error.ModelError::Transport("provider down"),
    ),
  ])
  let host = agent.ui_host()
  let delivered : Array[String] = []
  let observation = subscribe_labels(host, delivered)
  assert_true(run_one_turn(agent, "session_op_failed") is Some(_))
  // The failure settled the operation, so the transient panel is gone instead
  // of living on as a stale progress bar.
  assert_eq(delivered, ["published", "withdrawn"])
  assert_eq(expect_snapshot(host).resources.length(), 0)
  assert_eq(pulled_labels(host, observation.baseline.cursor), delivered)
  assert_eq(desk.panel_publishes.length(), 1)
  match desk.panel_publishes[0] {
    Ok(snapshot) =>
      assert_eq(snapshot.lifetime, @posoco.UiResourceLifetime::OperationBound)
    other => abort("expected one accepted panel publish, got \{repr(other)}")
  }
  agent.shutdown()
}

///|
async test "ui_operation/cancelled_turn_reclaims_the_panel" {
  let desk = OperationDesk::new()
  let tool = CancellingTool::new()
  let agent = operation_agent(
    desk,
    [
      @test_support.ScriptedModelStep::Respond(
        @test_support.tk_tool_call_response("cancel_me", "call_1", Json::null()),
      ),
      @test_support.ScriptedModelStep::Respond(
        @test_support.tk_stop_response("unused"),
      ),
    ],
    tools=[tool],
  )
  tool.control = Some(agent.control())
  let host = agent.ui_host()
  let delivered : Array[String] = []
  let observation = subscribe_labels(host, delivered)
  match run_one_turn(agent, "session_op_cancelled") {
    Some(@error.AgentError::Cancelled(_)) => ()
    other => abort("expected a cancelled operation, got \{repr(other)}")
  }
  // Cancellation is a settlement too: the panel does not survive it.
  assert_eq(delivered, ["published", "withdrawn"])
  assert_eq(expect_snapshot(host).resources.length(), 0)
  assert_eq(pulled_labels(host, observation.baseline.cursor), delivered)
  agent.shutdown()
}

///|
async test "ui_operation/a_panel_cannot_be_created_outside_an_operation" {
  let desk = OperationDesk::new()
  let agent = operation_agent(desk, [])
  let resources = desk_capability(desk)
  match resources.operation() {
    Err(@posoco.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("operation"))
    Ok(_) => abort("expected no operation handle while the Agent is idle")
    Err(other) => abort("expected InvalidInput, got \{other}")
  }
  match
    resources.publish(draft=operation_panel_draft(key="panel", note="idle")) {
    Err(@posoco.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("UiResources::operation"))
    Ok(_) => abort("expected an off-operation panel to be refused")
    Err(other) => abort("expected InvalidInput, got \{other}")
  }
  // Session-scoped cleanup is still unimplemented and still says so.
  let session_draft = @posoco.UiResourceDraft::new(
    key="panel",
    kind=@posoco.UiResourceKind::standard(name="operation_panel"),
    body=@posoco.UiResourceBody::Text("session scoped"),
    scope=@posoco.UiResourceScope::SessionScope(id="session_1"),
    lifetime=@posoco.UiResourceLifetime::SessionBound,
  )
  match resources.publish(draft=session_draft) {
    Err(@posoco.UiResourceError::Unsupported(feature~)) =>
      assert_true(feature.contains("session"))
    Ok(_) => abort("expected SessionBound to stay unsupported")
    Err(other) => abort("expected Unsupported, got \{other}")
  }
  assert_eq(expect_snapshot(agent.ui_host()).resources.length(), 0)
  agent.shutdown()
}

///|
async test "ui_operation/an_earlier_operation_handle_is_refused_in_the_next_one" {
  let desk = OperationDesk::new()
  let agent = operation_agent(desk, [
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("first"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("second"),
    ),
  ])
  let host = agent.ui_host()
  assert_true(run_one_turn(agent, "session_op_first") is None)
  let delivered : Array[String] = []
  ignore(subscribe_labels(host, delivered))
  // The second operation tries the first operation's handle before publishing
  // its own panel.
  assert_true(run_one_turn(agent, "session_op_second") is None)
  assert_eq(desk.handles.length(), 2)
  assert_eq(desk.stale_attempts.length(), 1)
  match desk.stale_attempts[0] {
    Err(@posoco.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("agent_run_turn_1"))
    other => abort("expected one typed rejection, got \{repr(other)}")
  }
  // Re-acquiring through the dead handle is refused too.
  assert_eq(desk.stale_nested.length(), 1)
  match desk.stale_nested[0] {
    Err(@posoco.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("agent_run_turn_1"))
    Ok(rebound) => {
      ignore(rebound)
      abort("expected the stale handle not to re-capture agent_run_turn_2")
    }
    Err(other) => abort("expected InvalidInput, got \{other}")
  }
  // The stale write landed nowhere.
  assert_eq(delivered, ["published", "withdrawn"])
  assert_eq(expect_snapshot(host).resources.length(), 0)
  agent.shutdown()
}

///|
async test "ui_operation/a_replacement_cannot_migrate_the_panel" {
  let desk = OperationDesk::new(probe_migration=true)
  let agent = operation_agent(desk, [
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  let host = agent.ui_host()
  let delivered : Array[String] = []
  ignore(subscribe_labels(host, delivered))
  assert_true(run_one_turn(agent, "session_op_migration") is None)
  assert_eq(desk.migration_attempts.length(), 2)
  match desk.migration_attempts[0] {
    Err(@posoco.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("OperationBound"))
    other =>
      abort("expected a lifetime-migration rejection, got \{repr(other)}")
  }
  match desk.migration_attempts[1] {
    Err(@posoco.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("agent_run_turn_1"))
    other => abort("expected a takeover rejection, got \{repr(other)}")
  }
  // Neither refused attempt changed the panel: one publish, one reclaim.
  assert_eq(delivered, ["published", "withdrawn"])
  match desk.panel_publishes[0] {
    Ok(snapshot) => assert_eq(snapshot.revision, 1)
    other => abort("expected the original panel revision, got \{repr(other)}")
  }
  assert_eq(expect_snapshot(host).resources.length(), 0)
  agent.shutdown()
}

///|
async test "ui_operation/owner_bound_cards_outlive_every_operation" {
  let desk = OperationDesk::new(card=true)
  let agent = operation_agent(desk, [
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("first"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("second"),
    ),
  ])
  let host = agent.ui_host()
  assert_true(run_one_turn(agent, "session_op_card_1") is None)
  let after_first = expect_snapshot(host)
  assert_eq(after_first.resources.length(), 1)
  assert_eq(after_first.resources[0].resource.key, "result")
  assert_eq(after_first.resources[0].revision, 1)
  let cut = match host.snapshot() {
    Ok(baseline) => baseline.cursor
    Err(error) => abort("snapshot failed: \{error}")
  }
  assert_true(run_one_turn(agent, "session_op_card_2") is None)
  // The card is a full replacement of the same resource, not a second node,
  // and the second operation's panel was reclaimed independently.
  assert_eq(pulled_labels(host, cut), ["published", "replaced", "withdrawn"])
  let after_second = expect_snapshot(host)
  assert_eq(after_second.resources.length(), 1)
  assert_eq(after_second.resources[0].resource.key, "result")
  assert_eq(after_second.resources[0].revision, 2)
  assert_eq(
    after_second.resources[0].lifetime,
    @posoco.UiResourceLifetime::OwnerBound,
  )
  // Settlement never withdrew the card, and the owner still owns it.
  assert_eq(desk.card_publishes.length(), 2)
  agent.shutdown()
}

///|
async test "ui_operation/a_closed_agent_outranks_the_operation_binding" {
  let desk = OperationDesk::new()
  let agent = operation_agent(desk, [
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("done"),
    ),
  ])
  assert_true(run_one_turn(agent, "session_op_closed") is None)
  assert_eq(desk.handles.length(), 1)
  let handle = desk.handles[0]
  // Before shutdown the operation is simply no longer live.
  match handle.publish(draft=operation_panel_draft(key="panel", note="late")) {
    Err(@posoco.UiResourceError::InvalidInput(_)) => ()
    Ok(_) => abort("expected a settled handle to be refused")
    Err(other) => abort("expected InvalidInput, got \{other}")
  }
  agent.shutdown()
  // After shutdown the closed protocol wins over the operation binding.
  match handle.publish(draft=operation_panel_draft(key="panel", note="late")) {
    Err(@posoco.UiResourceError::Closed) => ()
    Ok(_) => abort("expected Closed after shutdown")
    Err(other) => abort("expected Closed, got \{other}")
  }
  match handle.operation() {
    Err(@posoco.UiResourceError::Closed) => ()
    Ok(_) => abort("expected Closed from a handle after shutdown")
    Err(other) => abort("expected Closed, got \{other}")
  }
  match handle.set_action_handler(handler=_invocation => Ok(())) {
    Err(@posoco.UiResourceError::Closed) => ()
    Ok(_) => abort("expected Closed from a handle after shutdown")
    Err(other) => abort("expected Closed, got \{other}")
  }
  match desk_capability(desk).operation() {
    Err(@posoco.UiResourceError::Closed) => ()
    Ok(_) => abort("expected Closed from the owner capability after shutdown")
    Err(other) => abort("expected Closed, got \{other}")
  }
}

///|
/// Chat that parks inside the admitted operation on its first call, so a hard
/// cancellation lands deterministically after the panel publish.
priv struct ParkedChatModel {
  entered : Ref[Bool]
  mut calls : Int32
  reply : String
}

///|
fn ParkedChatModel::ParkedChatModel(reply~ : String) -> ParkedChatModel {
  { entered: Ref(false), calls: 0, reply, }
}

///|
impl @port.ModelPort for ParkedChatModel with fn chat(
  self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  self.calls = self.calls + 1
  if self.calls == 1 {
    self.entered.val = true
    // Parked until the hard cancel unwinds this call; never elapses in a test.
    @async.sleep(600_000)
  }
  @test_support.tk_stop_response(self.reply)
}

///|
impl @port.ModelPort for ParkedChatModel with fn compact(
  _self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  raise @error.ModelError::ResponseParse("compact is not used by this test")
}

///|
impl @port.ModelPort for ParkedChatModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
fn parked_operation_agent(
  desk : OperationDesk,
  model : &@port.ModelPort,
) -> @posoco.Agent {
  try
    @posoco.Agent(
      exts=[
        @test_support.tk_ext(id="model", model=Some(model)),
        @test_support.tk_ext(id="board", hooks=[desk], lifecycle=[desk], requires=[
          @port.Capability::Ui,
        ]),
      ],
      config=@posoco.agent_config(),
      events=@posoco.EventSystem(),
    )
  catch {
    error => abort("composition failed: \{error}")
  } noraise {
    value => value
  }
}

///|
async test "ui_operation/hard_cancelled_turn_reclaims_the_panel_and_admits_the_next_operation" {
  let desk = OperationDesk::new()
  let model = ParkedChatModel::ParkedChatModel(reply="after cancel")
  let agent = parked_operation_agent(desk, model as &@port.ModelPort)
  let host = agent.ui_host()
  let delivered : Array[String] = []
  let observation = subscribe_labels(host, delivered)
  let outcome : Ref[@error.AgentError?] = Ref(None)
  @async.with_task_group(async fn(group) {
    let turn = group.spawn(async fn() {
      outcome.val = run_one_turn(agent, "session_op_hard_cancel")
    })
    // The cancel lands with the OperationBound panel live.
    while !model.entered.val {
      @async.pause()
    }
    turn.cancel()
    ignore(
      @async.handle_cancellation(async fn() {
        ignore(turn.wait()) catch {
          _ => ()
        }
      }),
    )
  })
  match outcome.val {
    Some(@error.AgentError::Cancelled(_)) => ()
    other => abort("expected a hard-cancelled turn, got \{repr(other)}")
  }
  // The unwind reclaimed the operation-bound panel: no stale progress panel
  // survives the cancellation.
  assert_eq(delivered, ["published", "withdrawn"])
  assert_eq(expect_snapshot(host).resources.length(), 0)
  assert_eq(pulled_labels(host, observation.baseline.cursor), delivered)
  // Settlement released the guard, so the same Agent admits the next
  // operation, which publishes and reclaims its own panel.
  assert_true(run_one_turn(agent, "session_op_hard_cancel") is None)
  assert_eq(delivered, ["published", "withdrawn", "published", "withdrawn"])
  assert_eq(expect_snapshot(host).resources.length(), 0)
  agent.shutdown()
}

///|
async test "ui_operation/a_stale_handle_cannot_address_the_next_operation" {
  let desk = OperationDesk::new(probe_stale=true)
  let agent = operation_agent(desk, [
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("first"),
    ),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("second"),
    ),
  ])
  let host = agent.ui_host()
  assert_true(run_one_turn(agent, "session_op_probe_1") is None)
  assert_true(run_one_turn(agent, "session_op_probe_2") is None)
  // The dead binding is refused, not answered about a resource it never owned.
  assert_eq(desk.stale_support.length(), 1)
  match desk.stale_support[0] {
    Err(@posoco.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("agent_run_turn_1"))
    other => abort("expected a typed support rejection, got \{repr(other)}")
  }
  assert_eq(desk.stale_removals.length(), 1)
  match desk.stale_removals[0] {
    Err(@posoco.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("agent_run_turn_1"))
    Ok(revision) => abort("expected a refusal, got revision \{revision}")
    Err(other) =>
      abort("expected a typed removal rejection, got \{repr(other)}")
  }
  // Nothing leaked: each operation published and reclaimed exactly its own
  // panel.
  assert_eq(desk.panel_publishes.length(), 2)
  assert_eq(expect_snapshot(host).resources.length(), 0)
  let first_handle = desk.handles[0]
  let panel_ref = match desk.panel_publishes[1] {
    Ok(snapshot) => snapshot.resource
    Err(error) => abort("expected the second panel to publish, got \{error}")
  }
  agent.shutdown()
  // After shutdown the closed protocol outranks the dead binding on both
  // queries, so a late host never reads an empty "no support" answer.
  match first_handle.host_support(resource=panel_ref) {
    Err(@posoco.UiResourceError::Closed) => ()
    Ok(reports) => abort("expected Closed, got \{reports.length()} reports")
    Err(other) => abort("expected Closed, got \{other}")
  }
  match first_handle.remove(resource=panel_ref) {
    Err(@posoco.UiResourceError::Closed) => ()
    Ok(revision) => abort("expected Closed, got revision \{revision}")
    Err(other) => abort("expected Closed, got \{other}")
  }
}
