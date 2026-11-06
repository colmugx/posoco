///|
/// Black-box tests for explicit host connections and capability matching,
/// driven through the public `Agent` surface.

///|
fn capability_confirm() -> @posoco.UiHostCapabilities {
  @posoco.UiHostCapabilities::new(interactions=[
    @posoco.UiInteractionKind::YesNo,
  ])
}

///|
fn capability_board(
  kind : @posoco.UiResourceKind,
) -> @posoco.UiHostCapabilities {
  @posoco.UiHostCapabilities::new(resource_kinds=[kind])
}

///|
async fn capability_wait_until(condition : () -> Bool) -> Unit {
  let waited = @async.with_timeout_opt(2_000, async fn() {
    while !condition() {
      @async.pause()
    }
  })
  match waited {
    Some(_) => ()
    None => abort("condition did not become true in time")
  }
}

///|
async fn capability_resume_async() -> Unit {
  for _ in 0..<20 {
    @async.pause()
  }
}

///|
async test "ui_host_capability/blocking_ask_needs_a_declared_host" {
  let extension = InteractionUiExtension::new()
  let agent = interaction_agent(extension, requires_ui=true)
  let interactions = captured_interactions(extension)
  let host = agent.ui_host()
  // No host at all: fail fast, and leave no pending question or consumed id.
  match interactions.ask(request=approval_request("ask-1")) {
    Err(@posoco.UiInteractionError::HostUnavailable(reason~)) =>
      assert_true(reason.contains("YesNo"))
    Ok(answer) => abort("a hostless ask must not block: \{answer}")
    Err(other) => abort("expected HostUnavailable, got \{other}")
  }
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 0)
    Err(error) => abort("snapshot failed: \{error}")
  }
  // The id was never consumed: no question exists to find yet.
  match interactions.find(request_id="ask-1") {
    Err(@posoco.UiInteractionError::NotFound(owner~, request_id~)) => {
      assert_eq(owner, "ask")
      assert_eq(request_id, "ask-1")
    }
    Ok(_) => abort("a failed ask must not leave a question behind")
    Err(other) => abort("expected NotFound, got \{other}")
  }
  // An explicit open of the same id is accepted and stays pending without a
  // host; the owner can retrieve its ref through the owner-bound lookup.
  let opened = match interactions.open(request=approval_request("ask-1")) {
    Ok(snapshot) => snapshot
    Err(error) => abort("open failed: \{error}")
  }
  let found = match interactions.find(request_id="ask-1") {
    Ok(snapshot) => snapshot
    Err(error) => abort("find failed: \{error}")
  }
  assert_eq(found.interaction, opened.interaction)
  // Observing the feed is not a claim that anybody can answer.
  let subscription = match
    host.subscribe(listener=fn(_batch) { Ok(()) }, on_failure=fn(_failure) {
      ()
    }) {
    Ok(observation) => observation.subscription
    Err(error) => abort("subscribe failed: \{error}")
  }
  // A display-only host still cannot answer a question.
  let board = @posoco.UiResourceKind::standard(name="board")
  let display_only = match host.connect(capabilities=capability_board(board)) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  let second = match interactions.open(request=approval_request("ask-2")) {
    Ok(snapshot) => snapshot
    Err(error) => abort("open failed: \{error}")
  }
  match interactions.find(request_id="ask-2") {
    Ok(snapshot) => assert_eq(snapshot.interaction, second.interaction)
    Err(error) => abort("find failed: \{error}")
  }
  match interactions.wait(interaction=second.interaction) {
    Err(@posoco.UiInteractionError::HostUnavailable(_)) => ()
    Ok(answer) => abort("display-only host must not answer: \{answer}")
    Err(other) => abort("expected HostUnavailable, got \{other}")
  }
  // Withdrawing the explicit questions is how their pending state ends.
  for reference in [opened.interaction, second.interaction] {
    match interactions.withdraw(interaction=reference) {
      Ok(_) => ()
      Err(error) => abort("withdraw failed: \{error}")
    }
  }
  // A host that declares the body kind makes the same ask block and settle.
  let answer = match host.connect(capabilities=capability_confirm()) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  let result : Ref[
    Result[@posoco.UiInteractionAnswer, @posoco.UiInteractionError]?,
  ] = Ref(None)
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      result.val = Some(interactions.ask(request=approval_request("ask-3")))
    })
    capability_wait_until(fn() {
      match host.snapshot() {
        Ok(baseline) => baseline.pending_interactions.length() == 1
        Err(_) => false
      }
    })
    let reference = match host.snapshot() {
      Ok(baseline) => baseline.pending_interactions[0].interaction
      Err(error) => abort("snapshot failed: \{error}")
    }
    match
      answer.answer(request={
        interaction: reference,
        answer: @posoco.UiInteractionAnswer::Yes,
      }) {
      Ok(receipt) => assert_false(receipt.replayed)
      Err(error) => abort("answer failed: \{error}")
    }
    // A repeated answer through the lease replays the stored receipt.
    match
      answer.answer(request={
        interaction: reference,
        answer: @posoco.UiInteractionAnswer::Yes,
      }) {
      Ok(receipt) => assert_true(receipt.replayed)
      Err(error) => abort("replay failed: \{error}")
    }
    task.wait()
  })
  match result.val {
    Some(Ok(value)) => assert_eq(value, @posoco.UiInteractionAnswer::Yes)
    Some(Err(error)) => abort("ask failed: \{error}")
    None => abort("the ask never recorded an outcome")
  }
  assert_true(subscription.is_active())
  assert_true(display_only.is_connected())
  subscription.unsubscribe()
  agent.shutdown()
}

///|
async test "ui_host_capability/ask_lost_after_creation_is_recovered_with_find" {
  let extension = InteractionUiExtension::new()
  let agent = interaction_agent(extension, requires_ui=true)
  let interactions = captured_interactions(extension)
  let host = agent.ui_host()
  let connection = match host.connect(capabilities=capability_confirm()) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  let failures : Array[String] = []
  // The listener detaches the only matching host while `Opened` is delivered,
  // so `ask` loses its host before it can keep waiting.
  let observation = match
    host.subscribe(
      listener=fn(batch) {
        match batch.change {
          Interaction(change~) =>
            match change {
              Opened(_) => ignore(connection.detach())
              Settled(..) => ()
            }
          Resource(_) => ()
        }
        Ok(())
      },
      on_failure=fn(failure) { failures.push(failure.detail) },
    ) {
    Ok(value) => value
    Err(error) => abort("subscribe failed: \{error}")
  }
  match interactions.ask(request=approval_request("lost-1")) {
    Err(@posoco.UiInteractionError::HostUnavailable(_)) => ()
    Ok(answer) => abort("the lost host must not settle ask: \{answer}")
    Err(other) => abort("expected HostUnavailable, got \{other}")
  }
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 1)
    Err(error) => abort("snapshot failed: \{error}")
  }
  // The caller still knows the request id it supplied, so the owner-bound
  // lookup returns the ref that ask could not hand back.
  let found = match interactions.find(request_id="lost-1") {
    Ok(snapshot) => snapshot
    Err(error) => abort("find failed: \{error}")
  }
  match interactions.wait(interaction=found.interaction) {
    Err(@posoco.UiInteractionError::HostUnavailable(_)) => ()
    Ok(answer) => abort("a hostless wait must not settle: \{answer}")
    Err(other) => abort("expected HostUnavailable, got \{other}")
  }
  // The pending question is not auto-settled; a new host answers the same ref.
  let replacement = match host.connect(capabilities=capability_confirm()) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  match
    replacement.answer(request={
      interaction: found.interaction,
      answer: @posoco.UiInteractionAnswer::Yes,
    }) {
    Ok(_) => ()
    Err(error) => abort("answer failed: \{error}")
  }
  match interactions.wait(interaction=found.interaction) {
    Ok(value) => assert_eq(value, @posoco.UiInteractionAnswer::Yes)
    Err(error) => abort("wait failed: \{error}")
  }
  assert_eq(failures.length(), 0)
  observation.subscription.unsubscribe()
  agent.shutdown()
}

///|
async test "ui_host_capability/find_is_owner_bound_and_withdraw_releases_pending" {
  let primary = InteractionUiExtension::new()
  let other = InteractionUiExtension::new()
  let agent = try
    @posoco.Agent(
      exts=[
        @test_support.tk_ext(
          id="model",
          model=Some(@test_support.ScriptedModel([])),
        ),
        @test_support.tk_ext(id="ask", lifecycle=[primary], requires=[
          @port.Capability::Ui,
        ]),
        @test_support.tk_ext(id="other", lifecycle=[other], requires=[
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
  let interactions = match primary.interactions.val {
    Some(capability) => capability
    None =>
      abort("expected the composition to deliver the interaction capability")
  }
  let other_interactions = match other.interactions.val {
    Some(capability) => capability
    None =>
      abort("expected the composition to deliver the interaction capability")
  }
  let opened = match interactions.open(request=approval_request("shared-1")) {
    Ok(snapshot) => snapshot
    Err(error) => abort("open failed: \{error}")
  }
  match interactions.find(request_id="shared-1") {
    Ok(found) => assert_eq(found.interaction, opened.interaction)
    Err(error) => abort("find failed: \{error}")
  }
  // The lookup is owner-bound: another extension cannot resolve the ref.
  match other_interactions.find(request_id="shared-1") {
    Err(@posoco.UiInteractionError::NotFound(owner~, request_id~)) => {
      assert_eq(owner, "other")
      assert_eq(request_id, "shared-1")
    }
    Ok(_) => abort("a foreign owner must not find the question")
    Err(other) => abort("expected NotFound, got \{other}")
  }
  // Withdrawing through the found ref releases the pending question; the
  // retained window still resolves it so the owner can join the terminal state.
  match interactions.withdraw(interaction=opened.interaction) {
    Ok(_) => ()
    Err(error) => abort("withdraw failed: \{error}")
  }
  match agent.ui_host().snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 0)
    Err(error) => abort("snapshot failed: \{error}")
  }
  match interactions.find(request_id="shared-1") {
    Ok(found) => assert_eq(found.interaction, opened.interaction)
    Err(error) => abort("retained find failed: \{error}")
  }
  match interactions.wait(interaction=opened.interaction) {
    Err(@posoco.UiInteractionError::Withdrawn) => ()
    Ok(answer) => abort("withdrawn must not be an answer: \{answer}")
    Err(other) => abort("expected Withdrawn, got \{other}")
  }
  agent.shutdown()
  match interactions.find(request_id="shared-1") {
    Err(@posoco.UiInteractionError::Closed) => ()
    Ok(_) => abort("a closed Agent must not answer lookup")
    Err(other) => abort("expected Closed, got \{other}")
  }
}

///|
async test "ui_host_capability/resource_support_is_reported_per_connection" {
  let extension = InteractionUiExtension::new()
  let agent = interaction_agent(extension, requires_ui=true)
  let resources = match extension.resources.val {
    Some(capability) => capability
    None => abort("expected the composition to deliver the resource capability")
  }
  let host = agent.ui_host()
  let kind = @posoco.UiResourceKind::standard(name="approval_board")
  let published = match resources.publish(draft=approval_draft("ready")) {
    Ok(snapshot) => snapshot
    Err(error) => abort("publish failed: \{error}")
  }
  // Publishing is state, not a display receipt: no host is fine.
  match resources.host_support(resource=published.resource) {
    Ok(reports) => assert_eq(reports.length(), 0)
    Err(error) => abort("support failed: \{error}")
  }
  let native_answer = match host.connect(capabilities=capability_board(kind)) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  let fallback = match
    host.connect(capabilities=@posoco.UiHostCapabilities::new(fallback=true)) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  let reports = match resources.host_support(resource=published.resource) {
    Ok(reports) => reports
    Err(error) => abort("support failed: \{error}")
  }
  assert_eq(reports.length(), 2)
  assert_eq(reports[0].connection, native_answer.id())
  assert_eq(reports[0].support, @posoco.UiHostSupport::Native)
  assert_eq(reports[1].connection, fallback.id())
  assert_eq(reports[1].support, @posoco.UiHostSupport::Fallback)
  // A host that never declared the kind and no fallback is Unsupported.
  let blind = match
    host.connect(capabilities=@posoco.UiHostCapabilities::new()) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  match resources.host_support(resource=published.resource) {
    Ok(after) => {
      assert_eq(after.length(), 3)
      assert_eq(after[2].connection, blind.id())
      assert_eq(after[2].support, @posoco.UiHostSupport::Unsupported)
    }
    Err(error) => abort("support failed: \{error}")
  }
  agent.shutdown()
}

///|
async test "ui_host_capability/last_matching_lease_detach_keeps_the_question" {
  let extension = InteractionUiExtension::new()
  let agent = interaction_agent(extension, requires_ui=true)
  let interactions = captured_interactions(extension)
  let host = agent.ui_host()
  let first = match host.connect(capabilities=capability_confirm()) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  let second = match host.connect(capabilities=capability_confirm()) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  let opened = match interactions.open(request=approval_request("detach-me")) {
    Ok(snapshot) => snapshot
    Err(error) => abort("open failed: \{error}")
  }
  let result : Ref[
    Result[@posoco.UiInteractionAnswer, @posoco.UiInteractionError]?,
  ] = Ref(None)
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      result.val = Some(interactions.wait(interaction=opened.interaction))
    })
    capability_wait_until(fn() {
      match host.snapshot() {
        Ok(baseline) => baseline.pending_interactions.length() == 1
        Err(_) => false
      }
    })
    // A non-last matching lease leaving does not fail the waiter.
    match first.detach() {
      Ok(_) => ()
      Err(error) => abort("detach failed: \{error}")
    }
    capability_resume_async()
    assert_true(result.val is None)
    // The last one leaving wakes the waiter with HostUnavailable.
    match second.detach() {
      Ok(_) => ()
      Err(error) => abort("detach failed: \{error}")
    }
    task.wait()
  })
  match result.val {
    Some(Err(@posoco.UiInteractionError::HostUnavailable(_))) => ()
    Some(Ok(value)) => abort("no host can answer: \{value}")
    Some(Err(other)) => abort("expected HostUnavailable, got \{other}")
    None => abort("the wait never recorded an outcome")
  }
  // The question is still pending, so a later host can answer it.
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 1)
    Err(error) => abort("snapshot failed: \{error}")
  }
  let replacement = match host.connect(capabilities=capability_confirm()) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  match
    replacement.answer(request={
      interaction: opened.interaction,
      answer: @posoco.UiInteractionAnswer::No,
    }) {
    Ok(_) => ()
    Err(error) => abort("answer failed: \{error}")
  }
  match interactions.wait(interaction=opened.interaction) {
    Ok(value) => assert_eq(value, @posoco.UiInteractionAnswer::No)
    Err(error) =>
      abort("the settled answer must outrank the lost host: \{error}")
  }
  agent.shutdown()
}

///|
async test "ui_host_capability/cancelled_wait_with_a_host_is_still_not_a_rejection" {
  let extension = InteractionUiExtension::new()
  let agent = interaction_agent(extension, requires_ui=true)
  let interactions = captured_interactions(extension)
  let host = agent.ui_host()
  let connection = match host.connect(capabilities=capability_confirm()) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  let opened = match interactions.open(request=approval_request("cancel-me")) {
    Ok(snapshot) => snapshot
    Err(error) => abort("open failed: \{error}")
  }
  let waiting = Ref(false)
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      waiting.val = true
      ignore(interactions.wait(interaction=opened.interaction))
    })
    while !waiting.val {
      @async.pause()
    }
    // The wait is registered once its task has set the flag without a later
    // suspension point; cancel exactly one waiter.
    task.cancel()
  })
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 0)
    Err(error) => abort("snapshot failed: \{error}")
  }
  match
    connection.answer(request={
      interaction: opened.interaction,
      answer: @posoco.UiInteractionAnswer::Yes,
    }) {
    Err(@posoco.UiInteractionError::AlreadySettled(outcome~)) =>
      assert_eq(outcome, @posoco.UiInteractionOutcome::WaitCancelled)
    Ok(_) => abort("a cancelled wait must not accept an answer")
    Err(other) => abort("expected AlreadySettled, got \{other}")
  }
  agent.shutdown()
}

///|
async test "ui_host_capability/shutdown_closes_every_lease" {
  let extension = InteractionUiExtension::new()
  let agent = interaction_agent(extension, requires_ui=true)
  let interactions = captured_interactions(extension)
  let host = agent.ui_host()
  let connection = match host.connect(capabilities=capability_confirm()) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  let opened = match interactions.open(request=approval_request("pending")) {
    Ok(snapshot) => snapshot
    Err(error) => abort("open failed: \{error}")
  }
  agent.shutdown()
  assert_false(connection.is_connected())
  match connection.detach() {
    Err(@posoco.UiInteractionError::Closed) => ()
    Ok(_) => abort("a closed Agent must report Closed on detach")
    Err(other) => abort("expected Closed, got \{other}")
  }
  match connection.update(capabilities=capability_confirm()) {
    Err(@posoco.UiInteractionError::Closed) => ()
    Ok(_) => abort("a closed Agent must report Closed on update")
    Err(other) => abort("expected Closed, got \{other}")
  }
  match
    connection.answer(request={
      interaction: opened.interaction,
      answer: @posoco.UiInteractionAnswer::Yes,
    }) {
    Err(@posoco.UiInteractionError::Closed) => ()
    Ok(_) => abort("a closed Agent must refuse answers")
    Err(other) => abort("expected Closed, got \{other}")
  }
  match host.connect(capabilities=capability_confirm()) {
    Err(@posoco.UiInteractionError::Closed) => ()
    Ok(_) => abort("a closed Agent must refuse new leases")
    Err(other) => abort("expected Closed, got \{other}")
  }
  match interactions.wait(interaction=opened.interaction) {
    Err(@posoco.UiInteractionError::Closed) => ()
    Ok(value) => abort("a closed question cannot settle as \{value}")
    Err(other) => abort("expected Closed, got \{other}")
  }
}

///|
/// Answering from inside the `Opened` delivery: the question is live before
/// the change is announced.
async test "ui_host_capability/answering_inside_the_opened_change_settles_the_ask" {
  let extension = InteractionUiExtension::new()
  let agent = interaction_agent(extension, requires_ui=true)
  let interactions = captured_interactions(extension)
  let host = agent.ui_host()
  let connection = match host.connect(capabilities=capability_confirm()) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
  let delivered : Array[String] = []
  let receipts : Array[
    Result[@posoco.UiInteractionAnswerReceipt, @posoco.UiInteractionError],
  ] = []
  let answered = Ref(false)
  let observation = match
    host.subscribe(
      listener=fn(batch) {
        match batch.change {
          Resource(_) => delivered.push("resource")
          Interaction(change~) =>
            match change {
              Opened(snapshot~) => {
                delivered.push("opened")
                if !answered.val {
                  answered.val = true
                  receipts.push(
                    connection.answer(request={
                      interaction: snapshot.interaction,
                      answer: @posoco.UiInteractionAnswer::Yes,
                    }),
                  )
                }
              }
              Settled(..) => delivered.push("settled")
            }
        }
        Ok(())
      },
      on_failure=fn(failure) { abort("listener failed: \{failure.detail}") },
    ) {
    Ok(value) => value
    Err(error) => abort("subscribe failed: \{error}")
  }
  // The listener answers while `Opened` is still being delivered.
  match interactions.ask(request=approval_request("inline-ask")) {
    Ok(answer) => assert_eq(answer, @posoco.UiInteractionAnswer::Yes)
    Err(error) =>
      abort("expected the inline answer to settle the ask: \{error}")
  }
  assert_eq(delivered, ["opened", "settled"])
  assert_eq(receipts.length(), 1)
  match receipts[0] {
    Ok(receipt) => {
      assert_false(receipt.replayed)
      assert_eq(receipt.interaction.request_id, "inline-ask")
    }
    Err(error) => abort("expected the answer to be accepted: \{error}")
  }
  let baseline = match host.snapshot() {
    Ok(value) => value
    Err(error) => abort("snapshot failed: \{error}")
  }
  assert_eq(baseline.pending_interactions.length(), 0)
  assert_eq(observation.baseline.pending_interactions.length(), 0)
  match
    host.interactions_since(cursor=observation.baseline.interaction_cursor) {
    Ok(changes) => {
      assert_eq(changes.changes.length(), 2)
      assert_true(changes.changes[0] is Opened(_))
      assert_true(changes.changes[1] is Settled(..))
    }
    Err(error) => abort("interaction changes failed: \{error}")
  }
  agent.shutdown()
}
