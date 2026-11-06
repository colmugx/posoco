///|
/// One host/ext closed loop driven through the public `Agent` surface. Nothing
/// here reaches Agent internals: the extension only uses the ports the
/// composition handed it, and the host only uses `Agent::ui_host()`.

///|
/// Bounded yield budget for the recovery handshake. The test sets the flag and
/// the extension only yields meanwhile, so this is a predicate with a bound,
/// never a sleep race.
let host_loop_back_spins : Int32 = 4000

///|
/// Observation gate: yield until the predicate holds, and fail with the caller's
/// label if it never does, so a broken barrier names itself instead of hanging.
async fn host_loop_wait(label : String, condition : () -> Bool) -> Unit {
  let finished = @async.with_timeout_opt(5_000, async fn() {
    while !condition() {
      @async.pause()
    }
  })
  match finished {
    Some(_) => ()
    None => abort("timed out waiting for " + label)
  }
}

///|
fn host_loop_display_caps(
  kind : @posoco.UiResourceKind,
) -> @posoco.UiHostCapabilities {
  @posoco.UiHostCapabilities::new(resource_kinds=[kind])
}

///|
fn host_loop_answer_caps() -> @posoco.UiHostCapabilities {
  @posoco.UiHostCapabilities::new(interactions=[
    @posoco.UiInteractionKind::YesNo,
  ])
}

///|
/// Unwrap a recorded publish result: a refused call fails the test with the
/// protocol error instead of being counted as a recorded success.
fn host_loop_published(
  outcome : Result[@posoco.UiResourceSnapshot, @posoco.UiResourceError],
) -> @posoco.UiResourceSnapshot {
  match outcome {
    Ok(snapshot) => snapshot
    Err(error) => abort("the extension's UI call failed: \{error}")
  }
}

///|
/// Extension side of the loop: the transient panel, the action handler, the
/// question whose answer the operation waits for, the owner-bound final card,
/// and the observer trace the test asserts on.
struct HostLoopDesk {
  mut board : @posoco.UiResources?
  mut questions : @posoco.UiInteractions?
  /// 1-based turn whose `ask` deliberately loses its only host before settling.
  recover_on_turn : Int32
  /// Set by the test once a replacement lease is connected and has answered.
  mut host_back : Bool
  /// Set when the bounded host-back handshake expired; the test asserts it is
  /// empty so the expiry can never masquerade as a failed `wait`.
  mut handshake : String
  mut turns : Int32
  mut turn_ends : Int32
  mut last_terminal : String
  events : Array[(@types.EventScope?, @types.TurnEvent)]
  panels : Array[Result[@posoco.UiResourceSnapshot, @posoco.UiResourceError]]
  cards : Array[Result[@posoco.UiResourceSnapshot, @posoco.UiResourceError]]
  handles : Array[@posoco.UiResources]
  actions : Array[@posoco.UiActionInvocation]
  action_outcomes : Array[Result[Unit, String]]
  asks : Array[Result[@posoco.UiInteractionAnswer, @posoco.UiInteractionError]]
  finds : Array[
    Result[@posoco.UiInteractionSnapshot, @posoco.UiInteractionError],
  ]
  waits : Array[Result[@posoco.UiInteractionAnswer, @posoco.UiInteractionError]]
}

///|
fn HostLoopDesk::new(recover_on_turn~ : Int32 = 0) -> HostLoopDesk {
  {
    board: None,
    questions: None,
    recover_on_turn,
    host_back: false,
    handshake: "",
    turns: 0,
    turn_ends: 0,
    last_terminal: "",
    events: [],
    panels: [],
    cards: [],
    handles: [],
    actions: [],
    action_outcomes: [],
    asks: [],
    finds: [],
    waits: [],
  }
}

///|
fn HostLoopDesk::board(self : HostLoopDesk) -> @posoco.UiResources {
  match self.board {
    Some(capability) => capability
    None => abort("the composition must deliver ui_resources")
  }
}

///|
fn HostLoopDesk::questions(self : HostLoopDesk) -> @posoco.UiInteractions {
  match self.questions {
    Some(capability) => capability
    None => abort("the composition must deliver ui_interactions")
  }
}

///|
impl @port.Lifecycle for HostLoopDesk with fn on_compose(self, ctx) {
  self.board = ctx.ui_resources()
  self.questions = ctx.ui_interactions()
  let board = self.board()
  match
    board.set_action_handler(handler=fn(invocation) {
      self.accept_action(invocation)
    }) {
    Ok(_) => ()
    Err(error) =>
      raise @error.CompositionError::ExtensionComposeFailed(
        manifest_id="desk",
        detail="action handler registration failed: " + error.to_string(),
      )
  }
}

///|
/// Serve one host action; the handler re-checks the live revision through the
/// admitted operation's own handle.
fn HostLoopDesk::accept_action(
  self : HostLoopDesk,
  invocation : @posoco.UiActionInvocation,
) -> Result[Unit, String] {
  self.actions.push(invocation)
  let outcome = if invocation.action != "refresh" {
    Err("the desk does not serve " + invocation.action)
  } else {
    // The last captured handle is the live one.
    match self.handles.last() {
      Some(handle) =>
        match
          handle.replace(
            draft=host_loop_panel("action accepted"),
            expected=invocation.revision,
          ) {
          Ok(_) => Ok(())
          Err(error) => Err(error.to_string())
        }
      None => Err("no admitted operation handle")
    }
  }
  self.action_outcomes.push(outcome)
  outcome
}

///|
impl @port.PipelineHook for HostLoopDesk with fn on_turn_begin(self) {
  self.turns = self.turns + 1
  let board = self.board()
  let handle = match board.operation() {
    Ok(handle) => handle
    Err(error) => {
      self.panels.push(Err(error))
      return
    }
  }
  self.handles.push(handle)
  self.panels.push(
    handle.publish(draft=host_loop_panel("waiting for the host")),
  )
  let questions = self.questions()
  let request = approval_request("approval-\{self.turns}")
  if self.turns == self.recover_on_turn {
    // The only matching host detaches while the question is pending; `ask`
    // loses its host without settling anything, and the owner recovers by id.
    self.asks.push(questions.ask(request~))
    match questions.find(request_id=request.request_id) {
      Ok(found) => {
        self.finds.push(Ok(found))
        let mut spins = 0
        while !self.host_back && spins < host_loop_back_spins {
          spins = spins + 1
          @async.pause()
        }
        if !self.host_back {
          self.handshake = "the replacement lease never came back within the bounded yield budget"
          return
        }
        self.waits.push(questions.wait(interaction=found.interaction))
      }
      Err(error) => self.finds.push(Err(error))
    }
  } else {
    self.asks.push(questions.ask(request~))
  }
}

///|
impl @port.PipelineHook for HostLoopDesk with fn on_turn_end(self) {
  self.turn_ends = self.turn_ends + 1
  // The final card is owner-bound state, published only for a turn that really
  // completed: a cancelled turn leaves the previous card untouched.
  if self.last_terminal == "completed" {
    self.cards.push(self.board().publish(draft=host_loop_card()))
  }
}

///|
impl @port.Observer for HostLoopDesk with fn on_event(self, scope, event) {
  match event {
    TurnCompleted => self.last_terminal = "completed"
    TurnFailed(_) => self.last_terminal = "failed"
    TurnCancelled => self.last_terminal = "cancelled"
    _ => ()
  }
  self.events.push((scope, event))
}

///|
/// A transient panel: only an admitted operation can publish it, only that
/// operation's handle can replace it, and settlement reclaims it.
fn host_loop_panel(note : String) -> @posoco.UiResourceDraft {
  @posoco.UiResourceDraft::new(
    key="panel",
    kind=@posoco.UiResourceKind::standard(name="operation_panel"),
    body=@posoco.UiResourceBody::Text(note),
    scope=@posoco.UiResourceScope::OperationScope(id="turn"),
    lifetime=@posoco.UiResourceLifetime::OperationBound,
    actions=[
      {
        id: "refresh",
        label: "Refresh",
        payload: @posoco.UiActionPayloadKind::NoPayload,
      },
    ],
  )
}

///|
fn host_loop_card() -> @posoco.UiResourceDraft {
  @posoco.UiResourceDraft::new(
    key="result",
    kind=@posoco.UiResourceKind::standard(name="review_board"),
    body=@posoco.UiResourceBody::Text("result accepted"),
  )
}

///|
fn host_loop_agent(
  desk : HostLoopDesk,
  model : @test_support.ScriptedModel,
) -> @posoco.Agent {
  try
    @posoco.Agent(
      exts=[
        @test_support.tk_ext(id="model", model=Some(model)),
        @test_support.tk_ext(
          id="desk",
          lifecycle=[desk],
          hooks=[desk],
          observers=[desk],
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
fn host_loop_snapshot(host : @posoco.UiHost) -> @posoco.UiBaseline {
  match host.snapshot() {
    Ok(baseline) => baseline
    Err(error) => abort("snapshot failed: \{error}")
  }
}

///|
/// Host side of the loop: the push feed's facts per family, the exact interleaved
/// delivery order, and the last cursor each family reported so the pull path can
/// be compared against the push path instead of assumed.
struct HostLoopFeed {
  order : Array[String]
  resources : Array[String]
  interactions : Array[String]
  mut resource_cursor : @posoco.UiCursor?
  mut interaction_cursor : @posoco.UiCursor?
  failures : Array[String]
}

///|
fn host_loop_resource_label(change : @posoco.UiResourceChange) -> String {
  match change {
    Published(snapshot~) =>
      "published:\{snapshot.resource.key}:\{snapshot.revision}"
    Replaced(snapshot~) =>
      "replaced:\{snapshot.resource.key}:\{snapshot.revision}"
    Withdrawn(key~, revision~, ..) => "withdrawn:\{key}:\{revision}"
  }
}

///|
fn host_loop_interaction_label(change : @posoco.UiInteractionChange) -> String {
  match change {
    Opened(snapshot~) => "opened:\{snapshot.interaction.request_id}"
    Settled(request_id~, outcome~, ..) => {
      let name = match outcome {
        Answered(_) => "answered"
        Dismissed(_) => "dismissed"
        Withdrawn => "withdrawn"
        WaitCancelled => "wait-cancelled"
        Closed => "closed"
      }
      "settled:\{request_id}:\{name}"
    }
  }
}

///|
fn host_loop_subscribe(
  host : @posoco.UiHost,
) -> (@posoco.UiObservation, HostLoopFeed) {
  let feed : HostLoopFeed = {
    order: [],
    resources: [],
    interactions: [],
    resource_cursor: None,
    interaction_cursor: None,
    failures: [],
  }
  let observation = match
    host.subscribe(
      listener=fn(batch) {
        match batch.change {
          @posoco.UiChange::Resource(change~) => {
            let label = host_loop_resource_label(change)
            feed.resources.push(label)
            feed.order.push("r:" + label)
            feed.resource_cursor = Some(batch.cursor)
          }
          @posoco.UiChange::Interaction(change~) => {
            let label = host_loop_interaction_label(change)
            feed.interactions.push(label)
            feed.order.push("i:" + label)
            feed.interaction_cursor = Some(batch.cursor)
          }
        }
        Ok(())
      },
      on_failure=fn(failure) { feed.failures.push(failure.detail) },
    ) {
    Ok(observation) => observation
    Err(error) => abort("subscribe failed: \{error}")
  }
  (observation, feed)
}

///|
/// Turn scopes in `TurnStarted` order.
fn host_loop_turn_scopes(
  events : Array[(@types.EventScope?, @types.TurnEvent)],
) -> Array[@types.EventScope] {
  let scopes : Array[@types.EventScope] = []
  for entry in events {
    if entry.1 is TurnStarted {
      match entry.0 {
        Some(scope) => scopes.push(scope)
        None => abort("TurnStarted must carry its turn scope")
      }
    }
  }
  scopes
}

///|
fn host_loop_terminals(
  events : Array[(@types.EventScope?, @types.TurnEvent)],
  scope : @types.EventScope,
) -> Array[String] {
  let labels : Array[String] = []
  for entry in events {
    if entry.0 == Some(scope) {
      match entry.1 {
        TurnCompleted => labels.push("completed")
        TurnFailed(_) => labels.push("failed")
        TurnCancelled => labels.push("cancelled")
        _ => ()
      }
    }
  }
  labels
}

///|
fn host_loop_chunks(
  events : Array[(@types.EventScope?, @types.TurnEvent)],
  scope : @types.EventScope,
) -> Array[@types.StreamChunk] {
  let chunks : Array[@types.StreamChunk] = []
  for entry in events {
    if entry.0 == Some(scope) {
      match entry.1 {
        StreamChunkReceived(chunk~) => chunks.push(chunk)
        _ => ()
      }
    }
  }
  chunks
}

///|
/// `operation_settled` outcomes in projection order.
fn host_loop_settled_outcomes(
  events : Array[(@types.EventScope?, @types.TurnEvent)],
) -> Array[String] {
  let outcomes : Array[String] = []
  for entry in events {
    match entry.1 {
      Custom(source~, label~, data~) if source == "posoco.operation" &&
        label == "operation_settled" =>
        match data {
          Object(fields) =>
            match fields.get("outcome") {
              Some(String(outcome)) => outcomes.push(outcome)
              _ => ()
            }
          _ => ()
        }
      _ => ()
    }
  }
  outcomes
}

///|
fn host_loop_pull_resources(
  host : @posoco.UiHost,
  cursor : @posoco.UiCursor,
) -> @posoco.UiChanges {
  match host.changes_since(cursor~) {
    Ok(changes) => changes
    Err(error) => abort("changes_since failed: \{error}")
  }
}

///|
fn host_loop_pull_interactions(
  host : @posoco.UiHost,
  cursor : @posoco.UiCursor,
) -> @posoco.UiInteractionChanges {
  match host.interactions_since(cursor~) {
    Ok(changes) => changes
    Err(error) => abort("interactions_since failed: \{error}")
  }
}

///|
fn host_loop_pending(host : @posoco.UiHost) -> @posoco.UiInteractionSnapshot {
  let baseline = host_loop_snapshot(host)
  guard baseline.pending_interactions.length() == 1 else {
    abort("expected exactly one pending interaction")
  }
  baseline.pending_interactions[0]
}

///|
async test "host_loop/completed_operation_runs_the_whole_host_ext_loop" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Stream(
      chunks=[@types.TextDelta(token="he"), @types.TextDelta(token="llo")],
      response=@test_support.tk_stop_response("done"),
    ),
  ])
  let desk = HostLoopDesk::new()
  let agent = host_loop_agent(desk, model)
  let host = agent.ui_host()
  // The push subscription hands back exactly the cut a snapshot reads, so
  // nothing committed before it is replayed and nothing after it is missed.
  let cut = host_loop_snapshot(host)
  let (observation, feed) = host_loop_subscribe(host)
  assert_eq(observation.baseline, cut)
  assert_eq(cut.resources.length(), 0)
  assert_eq(cut.pending_interactions.length(), 0)
  assert_eq(cut.cursor.seq, 0)
  assert_eq(cut.interaction_cursor.seq, 0)
  let panel_kind = @posoco.UiResourceKind::standard(name="operation_panel")
  let connection = match
    host.connect(
      capabilities=@posoco.UiHostCapabilities::new(
        resource_kinds=[panel_kind],
        interactions=[@posoco.UiInteractionKind::YesNo],
      ),
    ) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  let display = match
    host.connect(capabilities=host_loop_display_caps(panel_kind)) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  let fallback = match
    host.connect(capabilities=@posoco.UiHostCapabilities::new(fallback=true)) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  let blind = match
    host.connect(capabilities=@posoco.UiHostCapabilities::new()) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  let outcome : Ref[Result[@types.TurnResult, @error.AgentError]?] = Ref(None)
  let live_panel : Ref[@posoco.UiResourceRef?] = Ref(None)
  let live_question : Ref[@posoco.UiInteractionRef?] = Ref(None)
  @async.with_timeout(30_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(allow_failure=true, async fn() {
        let result : Result[@types.TurnResult, @error.AgentError] = Ok(
          agent.run_turn(@test_support.tk_user_msg("review"), "loop-complete"),
        ) catch {
          error => Err(error)
        }
        outcome.val = Some(result)
      })
      host_loop_wait("the panel and the question are live", fn() {
        match host.snapshot() {
          Ok(baseline) =>
            baseline.resources.length() == 1 &&
            baseline.pending_interactions.length() == 1
          Err(_) => false
        }
      })
      let live = host_loop_snapshot(host)
      let panel = live.resources[0]
      live_panel.val = Some(panel.resource)
      assert_eq(panel.resource.owner, "desk")
      assert_eq(panel.resource.key, "panel")
      assert_eq(panel.revision, 1)
      assert_eq(panel.lifetime, @posoco.UiResourceLifetime::OperationBound)
      assert_eq(panel.scope, @posoco.UiResourceScope::OperationScope(id="turn"))
      assert_eq(
        panel.body,
        @posoco.UiResourceBody::Text("waiting for the host"),
      )
      // Declared capabilities are reported per live lease, in attach order.
      let support = match desk.board().host_support(resource=panel.resource) {
        Ok(reports) => reports
        Err(error) => abort("host_support failed: \{error}")
      }
      assert_eq(support.length(), 4)
      assert_eq(support[0].connection, connection.id())
      assert_eq(support[0].support, @posoco.UiHostSupport::Native)
      assert_eq(support[1].connection, display.id())
      assert_eq(support[1].support, @posoco.UiHostSupport::Native)
      assert_eq(support[2].connection, fallback.id())
      assert_eq(support[2].support, @posoco.UiHostSupport::Fallback)
      assert_eq(support[3].connection, blind.id())
      assert_eq(support[3].support, @posoco.UiHostSupport::Unsupported)
      let pending = live.pending_interactions[0]
      live_question.val = Some(pending.interaction)
      assert_eq(pending.interaction.owner, "desk")
      assert_eq(pending.interaction.request_id, "approval-1")
      assert_eq(pending.prompt, "Apply the patch?")
      assert_eq(pending.title, Some("approval"))
      // A lease that declared the panel kind but no interaction kind may not
      // answer; the question stays pending for the host that can.
      match
        display.answer(request={
          interaction: pending.interaction,
          answer: @posoco.UiInteractionAnswer::Yes,
        }) {
        Err(@posoco.UiInteractionError::HostUnavailable(_)) => ()
        Ok(_) => abort("a display-only lease must not answer")
        Err(other) => abort("expected HostUnavailable, got \{other}")
      }
      // Host action -> owner handler -> operation-handle CAS on the revision.
      let refresh : @posoco.UiActionRequest = {
        resource: panel.resource,
        action: "refresh",
        expected_revision: 1,
        request_id: "action-1",
        payload: None,
      }
      match host.dispatch(request=refresh) {
        Ok(receipt) => {
          assert_eq(receipt.resource, panel.resource)
          assert_eq(receipt.revision, 1)
          assert_false(receipt.replayed)
        }
        Err(error) => abort("dispatch failed: \{error}")
      }
      assert_eq(desk.actions.length(), 1)
      assert_eq(desk.actions[0].revision, 1)
      assert_eq(desk.actions[0].action, "refresh")
      match desk.action_outcomes[0] {
        Ok(_) => ()
        Err(detail) => abort("the action handler failed: \{detail}")
      }
      let bumped = host_loop_snapshot(host)
      assert_eq(bumped.resources[0].revision, 2)
      assert_eq(
        bumped.resources[0].body,
        @posoco.UiResourceBody::Text("action accepted"),
      )
      // A stale revision is refused before the owner runs, and a repeated
      // request id replays its stored receipt instead of running it twice.
      match host.dispatch(request={ ..refresh, request_id: "action-2", }) {
        Err(@posoco.UiResourceError::StaleRevision(expected~, actual~)) => {
          assert_eq(expected, 1)
          assert_eq(actual, 2)
        }
        Ok(result) =>
          abort("a stale revision must not dispatch: \{repr(result)}")
        Err(other) => abort("expected StaleRevision, got \{other}")
      }
      assert_eq(desk.actions.length(), 1)
      match host.dispatch(request=refresh) {
        Ok(receipt) => assert_true(receipt.replayed)
        Err(error) => abort("replay failed: \{error}")
      }
      assert_eq(desk.actions.length(), 1)
      // The host answers through its own lease; the waiting operation resumes
      // with that answer.
      match
        connection.answer(request={
          interaction: pending.interaction,
          answer: @posoco.UiInteractionAnswer::Yes,
        }) {
        Ok(receipt) => assert_false(receipt.replayed)
        Err(error) => abort("answer failed: \{error}")
      }
      ignore(turn.wait())
    })
  })
  guard outcome.val is Some(Ok(result)) else { abort("the turn must complete") }
  assert_eq(result.final_session_id, "loop-complete")
  assert_eq(model.call_count(), 1)
  assert_eq(desk.turns, 1)
  assert_eq(desk.turn_ends, 1)
  assert_eq(desk.panels.length(), 1)
  let panel_publish = host_loop_published(desk.panels[0])
  assert_eq(panel_publish.resource.key, "panel")
  assert_eq(panel_publish.revision, 1)
  assert_eq(panel_publish.lifetime, @posoco.UiResourceLifetime::OperationBound)
  assert_eq(desk.cards.length(), 1)
  let card_publish = host_loop_published(desk.cards[0])
  assert_eq(card_publish.resource.key, "result")
  assert_eq(card_publish.revision, 1)
  assert_eq(card_publish.lifetime, @posoco.UiResourceLifetime::OwnerBound)
  match desk.asks[0] {
    Ok(answer) => assert_eq(answer, @posoco.UiInteractionAnswer::Yes)
    Err(error) => abort("the ask must be answered: \{error}")
  }
  assert_eq(feed.failures.length(), 0)
  // Interleaved fact sequence: panel, question, replacement + answer, card,
  // reclamation.
  assert_eq(feed.order, [
    "r:published:panel:1", "i:opened:approval-1", "r:replaced:panel:2", "i:settled:approval-1:answered",
    "r:published:result:1", "r:withdrawn:panel:2",
  ])
  assert_eq(feed.resources, [
    "published:panel:1", "replaced:panel:2", "published:result:1", "withdrawn:panel:2",
  ])
  assert_eq(feed.interactions, [
    "opened:approval-1", "settled:approval-1:answered",
  ])
  // Pull from the subscription cut agrees with push, cursor included.
  let pulled = host_loop_pull_resources(host, cut.cursor)
  assert_eq(pulled.changes.map(host_loop_resource_label), feed.resources)
  assert_eq(pulled.cursor, feed.resource_cursor.unwrap())
  assert_eq(pulled.cursor.seq, 4)
  let pulled_interactions = host_loop_pull_interactions(
    host,
    cut.interaction_cursor,
  )
  assert_eq(
    pulled_interactions.changes.map(host_loop_interaction_label),
    feed.interactions,
  )
  assert_eq(pulled_interactions.cursor, feed.interaction_cursor.unwrap())
  assert_eq(pulled_interactions.cursor.seq, 2)
  assert_eq(host_loop_pull_resources(host, pulled.cursor).changes.length(), 0)
  let settled = host_loop_snapshot(host)
  assert_eq(settled.resources.length(), 1)
  assert_eq(settled.resources[0].resource.key, "result")
  assert_eq(settled.resources[0].revision, 1)
  assert_eq(
    settled.resources[0].lifetime,
    @posoco.UiResourceLifetime::OwnerBound,
  )
  assert_eq(settled.pending_interactions.length(), 0)
  // One turn, one terminal, and every chunk carried that turn's scope.
  let scopes = host_loop_turn_scopes(desk.events)
  assert_eq(scopes.length(), 1)
  assert_eq(scopes[0].session_id.to_string(), "loop-complete")
  assert_eq(host_loop_terminals(desk.events, scopes[0]), ["completed"])
  assert_eq(host_loop_chunks(desk.events, scopes[0]), [
    @types.TextDelta(token="he"),
    @types.TextDelta(token="llo"),
  ])
  assert_eq(host_loop_settled_outcomes(desk.events), ["completed"])
  // Shutdown closes the lease, the subscription and every capability.
  agent.shutdown()
  assert_false(connection.is_connected())
  assert_false(display.is_connected())
  assert_false(fallback.is_connected())
  assert_false(blind.is_connected())
  assert_false(observation.subscription.is_active())
  assert_eq(
    desk.board().publish(draft=host_loop_panel("late")),
    Err(@posoco.UiResourceError::Closed),
  )
  assert_eq(
    desk.questions().open(request=approval_request("approval-late")),
    Err(@posoco.UiInteractionError::Closed),
  )
  assert_eq(host.snapshot(), Err(@posoco.UiResourceError::Closed))
  let late_panel = match live_panel.val {
    Some(resource) => resource
    None => abort("expected the live panel ref")
  }
  match
    host.dispatch(request={
      resource: late_panel,
      action: "refresh",
      expected_revision: 2,
      request_id: "action-late",
      payload: None,
    }) {
    Err(@posoco.UiResourceError::Closed) => ()
    Ok(result) => abort("a closed host must not dispatch: \{repr(result)}")
    Err(other) => abort("expected Closed, got \{other}")
  }
  let late_question = match live_question.val {
    Some(interaction) => interaction
    None => abort("expected the live interaction ref")
  }
  match
    connection.answer(request={
      interaction: late_question,
      answer: @posoco.UiInteractionAnswer::Yes,
    }) {
    Err(@posoco.UiInteractionError::Closed) => ()
    Ok(_) => abort("a closed lease must not answer")
    Err(other) => abort("expected Closed, got \{other}")
  }
  assert_eq(feed.order.length(), 6)
}

///|
async test "host_loop/lost_host_is_recovered_then_the_operation_cancels_and_reuses" {
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("first"),
    ),
    @test_support.ScriptedModelStep::StreamParked(chunks=[
      @types.TextDelta(token="lo"),
      @types.TextDelta(token="st"),
    ]),
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("again"),
    ),
  ])
  let desk = HostLoopDesk::new(recover_on_turn=2)
  let agent = host_loop_agent(desk, model)
  let host = agent.ui_host()
  let cut = host_loop_snapshot(host)
  let (observation, feed) = host_loop_subscribe(host)
  assert_eq(observation.baseline, cut)
  let first = match host.connect(capabilities=host_loop_answer_caps()) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  // Turn 1: an ordinary answered turn leaves the owner-bound card behind.
  let first_outcome : Ref[Result[@types.TurnResult, @error.AgentError]?] = Ref(
    None,
  )
  @async.with_timeout(30_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(allow_failure=true, async fn() {
        let result : Result[@types.TurnResult, @error.AgentError] = Ok(
          agent.run_turn(@test_support.tk_user_msg("start"), "loop-recover"),
        ) catch {
          error => Err(error)
        }
        first_outcome.val = Some(result)
      })
      host_loop_wait("the question is pending", fn() {
        match host.snapshot() {
          Ok(baseline) => baseline.pending_interactions.length() == 1
          Err(_) => false
        }
      })
      let pending = host_loop_pending(host)
      match
        first.answer(request={
          interaction: pending.interaction,
          answer: @posoco.UiInteractionAnswer::Yes,
        }) {
        Ok(receipt) => assert_false(receipt.replayed)
        Err(error) => abort("answer failed: \{error}")
      }
      ignore(turn.wait())
    })
  })
  guard first_outcome.val is Some(Ok(_)) else {
    abort("the first turn must complete")
  }
  let after_first = host_loop_snapshot(host)
  assert_eq(after_first.resources.length(), 1)
  assert_eq(after_first.resources[0].resource.key, "result")
  assert_eq(after_first.resources[0].revision, 1)
  assert_eq(
    after_first.resources[0].lifetime,
    @posoco.UiResourceLifetime::OwnerBound,
  )
  assert_eq(feed.order, [
    "r:published:panel:1", "i:opened:approval-1", "i:settled:approval-1:answered",
    "r:published:result:1", "r:withdrawn:panel:1",
  ])
  match desk.asks[0] {
    Ok(answer) => assert_eq(answer, @posoco.UiInteractionAnswer::Yes)
    Err(error) => abort("the first ask must be answered: \{error}")
  }
  let turn_one_cursor = after_first.cursor
  let turn_one_interaction_cursor = after_first.interaction_cursor
  assert_eq(turn_one_cursor.seq, 3)
  assert_eq(turn_one_interaction_cursor.seq, 2)
  // Turn 2: the question loses its only host and is recovered through `find`.
  let second_outcome : Ref[Result[@types.TurnResult, @error.AgentError]?] = Ref(
    None,
  )
  let recovered : Ref[@posoco.UiHostConnection?] = Ref(None)
  @async.with_timeout(30_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(allow_failure=true, async fn() {
        let result : Result[@types.TurnResult, @error.AgentError] = Ok(
          agent.run_turn(@test_support.tk_user_msg("hold"), "loop-recover"),
        ) catch {
          error => Err(error)
        }
        second_outcome.val = Some(result)
      })
      host_loop_wait("the panel and the question are live", fn() {
        match host.snapshot() {
          Ok(baseline) =>
            baseline.resources.length() == 2 &&
            baseline.pending_interactions.length() == 1
          Err(_) => false
        }
      })
      let pending = host_loop_pending(host)
      match first.detach() {
        Ok(_) => ()
        Err(error) => abort("detach failed: \{error}")
      }
      assert_false(first.is_connected())
      // The ask woke with HostUnavailable; the owner's lookup found the
      // question still pending.
      host_loop_wait("the lost ask returned", fn() { desk.asks.length() == 2 })
      match desk.asks[1] {
        Err(@posoco.UiInteractionError::HostUnavailable(_)) => ()
        Ok(answer) => abort("the lost host must not settle the ask: \{answer}")
        Err(other) => abort("expected HostUnavailable, got \{other}")
      }
      host_loop_wait("the owner found its question", fn() {
        desk.finds.length() == 1
      })
      match desk.finds[0] {
        Ok(found) => assert_eq(found.interaction, pending.interaction)
        Err(error) => abort("find failed: \{error}")
      }
      let preserved = host_loop_snapshot(host)
      assert_eq(preserved.pending_interactions.length(), 1)
      assert_eq(
        preserved.pending_interactions[0].interaction,
        pending.interaction,
      )
      assert_eq(preserved.resources.length(), 2)
      let replacement = match
        host.connect(capabilities=host_loop_answer_caps()) {
        Ok(connection) => connection
        Err(error) => abort("reconnect failed: \{error}")
      }
      recovered.val = Some(replacement)
      assert_true(replacement.is_connected())
      assert_true(replacement.id() != first.id())
      match
        replacement.answer(request={
          interaction: preserved.pending_interactions[0].interaction,
          answer: @posoco.UiInteractionAnswer::Yes,
        }) {
        Ok(receipt) => assert_false(receipt.replayed)
        Err(error) => abort("answer failed: \{error}")
      }
      desk.host_back = true
      host_loop_wait("the owner resumed its wait", fn() {
        desk.waits.length() == 1 || desk.handshake != ""
      })
      assert_eq(
        desk.handshake,
        "",
        msg="the host-back handshake must not expire",
      )
      match desk.waits[0] {
        Ok(answer) => assert_eq(answer, @posoco.UiInteractionAnswer::Yes)
        Err(error) => abort("the recovered wait must be answered: \{error}")
      }
      host_loop_wait("the model parked", fn() { model.parked_calls == 1 })
      turn.cancel()
      ignore(
        @async.handle_cancellation(async fn() {
          ignore(turn.wait()) catch {
            @error.AgentError::Cancelled(_)
            | @async.WaitedTaskAlreadyCancelled => ()
            error => raise error
          }
        }),
      )
    })
  })
  guard second_outcome.val is Some(Err(@error.AgentError::Cancelled(_))) else {
    abort("the cancelled operation must surface as a typed cancellation")
  }
  assert_eq(model.call_count(), 2)
  assert_eq(desk.turns, 2)
  // The cancelled turn published no card; the completed turn's card is the
  // only one left.
  assert_eq(desk.panels.length(), 2)
  assert_eq(host_loop_published(desk.panels[1]).revision, 2)
  assert_eq(desk.cards.length(), 1)
  assert_eq(host_loop_published(desk.cards[0]).revision, 1)
  assert_eq(feed.failures.length(), 0)
  let after_cancel = host_loop_snapshot(host)
  assert_eq(after_cancel.resources.length(), 1)
  assert_eq(after_cancel.resources[0].resource.key, "result")
  assert_eq(after_cancel.resources[0].revision, 1)
  assert_eq(after_cancel.pending_interactions.length(), 0)
  // Cancellation reclaimed the panel without touching the owner-bound card.
  let cancelled = host_loop_pull_resources(host, turn_one_cursor)
  assert_eq(cancelled.changes.map(host_loop_resource_label), [
    "published:panel:2", "withdrawn:panel:2",
  ])
  assert_eq(cancelled.cursor.seq, 5)
  let cancelled_interactions = host_loop_pull_interactions(
    host, turn_one_interaction_cursor,
  )
  assert_eq(cancelled_interactions.changes.map(host_loop_interaction_label), [
    "opened:approval-2", "settled:approval-2:answered",
  ])
  assert_eq(cancelled_interactions.cursor.seq, 4)
  // Turn 2 has exactly one terminal, and it is the cancellation.
  let scopes = host_loop_turn_scopes(desk.events)
  assert_eq(scopes.length(), 2)
  assert_eq(host_loop_terminals(desk.events, scopes[0]), ["completed"])
  assert_eq(host_loop_terminals(desk.events, scopes[1]), ["cancelled"])
  assert_true(scopes[0] != scopes[1])
  assert_eq(host_loop_chunks(desk.events, scopes[1]), [
    @types.TextDelta(token="lo"),
    @types.TextDelta(token="st"),
  ])
  assert_eq(host_loop_settled_outcomes(desk.events), ["completed", "cancelled"])
  // Turn 3: the same Agent admits the next operation and runs the loop again.
  let third_outcome : Ref[Result[@types.TurnResult, @error.AgentError]?] = Ref(
    None,
  )
  @async.with_timeout(30_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(allow_failure=true, async fn() {
        let result : Result[@types.TurnResult, @error.AgentError] = Ok(
          agent.run_turn(@test_support.tk_user_msg("again"), "loop-recover"),
        ) catch {
          error => Err(error)
        }
        third_outcome.val = Some(result)
      })
      host_loop_wait("the panel and the question are live", fn() {
        match host.snapshot() {
          Ok(baseline) =>
            baseline.resources.length() == 2 &&
            baseline.pending_interactions.length() == 1
          Err(_) => false
        }
      })
      let pending = host_loop_pending(host)
      let replacement = match recovered.val {
        Some(connection) => connection
        None => abort("expected the replacement lease")
      }
      match
        replacement.answer(request={
          interaction: pending.interaction,
          answer: @posoco.UiInteractionAnswer::Yes,
        }) {
        Ok(receipt) => assert_false(receipt.replayed)
        Err(error) => abort("answer failed: \{error}")
      }
      ignore(turn.wait())
    })
  })
  guard third_outcome.val is Some(Ok(result)) else {
    abort("the reused operation must complete")
  }
  assert_eq(result.final_session_id, "loop-recover")
  assert_eq(model.call_count(), 3)
  match desk.asks[2] {
    Ok(answer) => assert_eq(answer, @posoco.UiInteractionAnswer::Yes)
    Err(error) => abort("the reused ask must be answered: \{error}")
  }
  assert_eq(desk.cards.length(), 2)
  assert_eq(host_loop_published(desk.cards[1]).revision, 2)
  let completed = host_loop_snapshot(host)
  assert_eq(completed.resources.length(), 1)
  assert_eq(completed.resources[0].resource.key, "result")
  assert_eq(completed.resources[0].revision, 2)
  assert_eq(
    completed.resources[0].lifetime,
    @posoco.UiResourceLifetime::OwnerBound,
  )
  assert_eq(completed.pending_interactions.length(), 0)
  assert_eq(feed.order, [
    "r:published:panel:1", "i:opened:approval-1", "i:settled:approval-1:answered",
    "r:published:result:1", "r:withdrawn:panel:1", "r:published:panel:2", "i:opened:approval-2",
    "i:settled:approval-2:answered", "r:withdrawn:panel:2", "r:published:panel:3",
    "i:opened:approval-3", "i:settled:approval-3:answered", "r:replaced:result:2",
    "r:withdrawn:panel:3",
  ])
  // Pull still agrees with push; the cursor tracks the two feeds
  // independently.
  let pulled = host_loop_pull_resources(host, cut.cursor)
  assert_eq(pulled.changes.map(host_loop_resource_label), feed.resources)
  assert_eq(pulled.cursor, feed.resource_cursor.unwrap())
  let pulled_interactions = host_loop_pull_interactions(
    host,
    cut.interaction_cursor,
  )
  assert_eq(
    pulled_interactions.changes.map(host_loop_interaction_label),
    feed.interactions,
  )
  assert_eq(pulled_interactions.cursor, feed.interaction_cursor.unwrap())
  let scopes = host_loop_turn_scopes(desk.events)
  assert_eq(scopes.length(), 3)
  assert_eq(host_loop_terminals(desk.events, scopes[2]), ["completed"])
  assert_eq(host_loop_settled_outcomes(desk.events), [
    "completed", "cancelled", "completed",
  ])
  assert_false(scopes[1] == scopes[2])
  assert_eq(host_loop_chunks(desk.events, scopes[2]), [])
  // Shutdown closes the live lease and the subscription.
  agent.shutdown()
  match recovered.val {
    Some(connection) => assert_false(connection.is_connected())
    None => abort("expected the replacement lease")
  }
  assert_false(observation.subscription.is_active())
  assert_eq(
    desk.board().publish(draft=host_loop_card()),
    Err(@posoco.UiResourceError::Closed),
  )
  assert_eq(feed.order.length(), 14)
}
