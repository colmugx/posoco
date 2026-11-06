///|
/// Contract tests for explicit host connections and capability matching:
/// fail-fast blocking asks, per-connection support, lease lifecycle and the
/// bounded registry.

///|
fn ui_confirm_capabilities() -> @port.UiHostCapabilities {
  @port.UiHostCapabilities::new(interactions=[@port.UiInteractionKind::YesNo])
}

///|
fn ui_choice_capabilities() -> @port.UiHostCapabilities {
  @port.UiHostCapabilities::new(interactions=[
    @port.UiInteractionKind::SingleChoice,
  ])
}

///|
fn ui_connect_host(
  runtime : UiRuntime,
  capabilities : @port.UiHostCapabilities,
) -> @port.UiHostConnection {
  match runtime.host().connect(capabilities~) {
    Ok(connection) => connection
    Err(error) => abort("connect failed: \{error}")
  }
}

///|
fn ui_connect_confirm_host(runtime : UiRuntime) -> @port.UiHostConnection {
  ui_connect_host(runtime, ui_confirm_capabilities())
}

///|
fn ui_board_kind() -> @port.UiResourceKind {
  @port.UiResourceKind::custom(
    namespace_="publisher",
    name="board",
    schema_version=2,
  )
}

///|
fn ui_board_draft() -> @port.UiResourceDraft {
  @port.UiResourceDraft::new(
    key="board",
    kind=ui_board_kind(),
    body=@port.UiResourceBody::Text("board"),
  )
}

///|
fn ui_publish_board(runtime : UiRuntime) -> @port.UiResourceRef {
  let resources = runtime.capability("publisher")
  match resources.publish(draft=ui_board_draft()) {
    Ok(snapshot) => snapshot.resource
    Err(error) => abort("publish failed: \{error}")
  }
}

///|
async fn ui_resume_after_pauses() -> Unit {
  for _ in 0..<20 {
    @async.pause()
  }
}

///|
async test "ui_host/no_connection_ask_fails_fast_without_consuming_anything" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let host = runtime.host()
  let before = match host.snapshot() {
    Ok(baseline) => baseline
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(before.pending_interactions.length(), 0)
  match requester.ask(request=confirm_request("ask-1")) {
    Err(@port.UiInteractionError::HostUnavailable(reason~)) =>
      assert_true(reason.contains("YesNo"))
    Ok(answer) => fail("a hostless ask must not block: \{answer}")
    Err(other) => fail("expected HostUnavailable, got \{other}")
  }
  let after = match host.snapshot() {
    Ok(baseline) => baseline
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(after.pending_interactions.length(), 0)
  assert_eq(after.interaction_cursor.seq, 0)
  match
    host.interactions_since(cursor={ generation: runtime.generation(), seq: 0, }) {
    Ok(changes) => assert_eq(changes.changes.length(), 0)
    Err(error) => fail("changes failed: \{error}")
  }
  // The id was never consumed: an explicit open of the same id is accepted.
  let opened = ui_opened(requester.open(request=confirm_request("ask-1")))
  assert_eq(opened.request_id, "ask-1")
  // Observing the feed is not a claim to answer, and display-only means none.
  let display_only = ui_connect_host(
    runtime,
    @port.UiHostCapabilities::new(resource_kinds=[ui_board_kind()]),
  )
  assert_true(display_only.is_connected())
  let subscription = match
    host.subscribe(listener=fn(_batch) { Ok(()) }, on_failure=fn(_failure) {
      ()
    }) {
    Ok(observation) => observation.subscription
    Err(error) => fail("subscribe failed: \{error}")
  }
  match requester.ask(request=confirm_request("ask-2")) {
    Err(@port.UiInteractionError::HostUnavailable(_)) => ()
    Ok(answer) => fail("display-only host must not answer: \{answer}")
    Err(other) => fail("expected HostUnavailable, got \{other}")
  }
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 1)
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_true(subscription.is_active())
  subscription.unsubscribe()
  runtime.close()
}

///|
async test "ui_host/per_connection_resource_support_is_exact_or_fallback" {
  let runtime = UiRuntime()
  let resources = runtime.capability("publisher")
  let reference = ui_publish_board(runtime)
  // Publishing is state, not a display receipt: no host is fine.
  match resources.host_support(resource=reference) {
    Ok(reports) => assert_eq(reports.length(), 0)
    Err(error) => fail("support failed: \{error}")
  }
  let kind = ui_board_kind()
  let native = ui_connect_host(
    runtime,
    @port.UiHostCapabilities::new(resource_kinds=[kind]),
  )
  let stale_version = ui_connect_host(
    runtime,
    @port.UiHostCapabilities::new(resource_kinds=[
      @port.UiResourceKind::custom(
        namespace_="publisher",
        name="board",
        schema_version=1,
      ),
    ]),
  )
  let fallback = ui_connect_host(
    runtime,
    @port.UiHostCapabilities::new(fallback=true),
  )
  let blind = ui_connect_host(runtime, @port.UiHostCapabilities::new())
  let reports = match resources.host_support(resource=reference) {
    Ok(reports) => reports
    Err(error) => fail("support failed: \{error}")
  }
  assert_eq(reports.length(), 4)
  assert_eq(reports[0].connection, native.id())
  assert_eq(reports[0].support, @port.UiHostSupport::Native)
  assert_eq(reports[1].connection, stale_version.id())
  assert_eq(reports[1].support, @port.UiHostSupport::Unsupported)
  assert_eq(reports[2].connection, fallback.id())
  assert_eq(reports[2].support, @port.UiHostSupport::Fallback)
  assert_eq(reports[3].connection, blind.id())
  assert_eq(reports[3].support, @port.UiHostSupport::Unsupported)
  // The query result is a copy: mutating it cannot reach the registry.
  reports[0] = {
    connection: reports[0].connection,
    support: @port.UiHostSupport::Unsupported,
  }
  match resources.host_support(resource=reference) {
    Ok(again) => assert_eq(again[0].support, @port.UiHostSupport::Native)
    Err(error) => fail("support failed: \{error}")
  }
  // Unknown resources are explicit failures, not "unsupported".
  match
    resources.host_support(resource={
      owner: "publisher",
      key: "missing",
      generation: runtime.generation(),
    }) {
    Err(@port.UiResourceError::NotFound(owner~, key~)) => {
      assert_eq(owner, "publisher")
      assert_eq(key, "missing")
    }
    Ok(_) => fail("a missing resource has no support report")
    Err(other) => fail("expected NotFound, got \{other}")
  }
  match
    resources.host_support(resource={ ..reference, owner: "someone_else", }) {
    Err(@port.UiResourceError::InvalidInput(_)) => ()
    Ok(_) => fail("a foreign owner must not be readable")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  runtime.close()
}

///|
async test "ui_host/capability_arrays_are_copied_on_the_way_in" {
  let runtime = UiRuntime()
  let kinds = [ui_board_kind()]
  let interactions = [@port.UiInteractionKind::YesNo]
  let capabilities = @port.UiHostCapabilities::new(
    resource_kinds=kinds,
    fallback=false,
    interactions~,
  )
  ignore(ui_connect_host(runtime, capabilities))
  // Mutating the caller's arrays after connecting changes nothing.
  kinds.push(@port.UiResourceKind::standard(name="other"))
  interactions.push(@port.UiInteractionKind::SingleChoice)
  let resources = runtime.capability("publisher")
  let reference = ui_publish_board(runtime)
  match resources.host_support(resource=reference) {
    Ok(reports) => {
      assert_eq(reports.length(), 1)
      assert_eq(reports[0].support, @port.UiHostSupport::Native)
    }
    Err(error) => fail("support failed: \{error}")
  }
  let requester = runtime.interactions("requester")
  // The appended SingleChoice was not copied into the live declaration.
  match requester.ask(request=choice_request("choice-not-copied")) {
    Err(@port.UiInteractionError::HostUnavailable(_)) => ()
    Ok(value) =>
      fail("a copied YesNo declaration cannot answer a choice: \{value}")
    Err(other) => fail("expected HostUnavailable, got \{other}")
  }
  let opened = ui_opened(requester.open(request=confirm_request("copied")))
  let answer : Ref[Result[@port.UiInteractionAnswer, @port.UiInteractionError]?] = Ref(
    None,
  )
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      answer.val = Some(requester.wait(interaction=opened))
    })
    ui_wait_until(fn() {
      ui_pending_waiters(runtime, "requester", "copied") == 1
    })
    // SingleChoice was only appended to the caller's array after connecting.
    match runtime.host().snapshot() {
      Ok(_) => ()
      Err(error) => fail("snapshot failed: \{error}")
    }
    match
      runtime
      .host()
      .answer(request={
        interaction: opened,
        answer: @port.UiInteractionAnswer::Yes,
      }) {
      Ok(_) => ()
      Err(error) => fail("answer failed: \{error}")
    }
    task.wait()
  })
  match answer.val {
    Some(Ok(value)) => assert_eq(value, @port.UiInteractionAnswer::Yes)
    Some(Err(error)) => fail("wait failed: \{error}")
    None => fail("wait never recorded an outcome")
  }
  runtime.close()
}

///|
async test "ui_host/ask_blocks_only_with_a_matching_connection" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let choice_host = ui_connect_host(runtime, ui_choice_capabilities())
  // The connected host cannot answer a Confirmation body.
  match requester.ask(request=confirm_request("confirm-1")) {
    Err(@port.UiInteractionError::HostUnavailable(_)) => ()
    Ok(answer) => fail("a single-choice host must not answer Yes/No: \{answer}")
    Err(other) => fail("expected HostUnavailable, got \{other}")
  }
  match runtime.host().snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
  // Adding the matching kind makes the same ask block and settle.
  ignore(
    choice_host.update(
      capabilities=@port.UiHostCapabilities::new(interactions=[
        @port.UiInteractionKind::SingleChoice,
        @port.UiInteractionKind::YesNo,
      ]),
    ),
  )
  let answer : Ref[Result[@port.UiInteractionAnswer, @port.UiInteractionError]?] = Ref(
    None,
  )
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      answer.val = Some(requester.ask(request=confirm_request("confirm-2")))
    })
    ui_wait_until(fn() {
      match runtime.host().snapshot() {
        Ok(baseline) => baseline.pending_interactions.length() == 1
        Err(_) => false
      }
    })
    match
      choice_host.answer(request={
        interaction: match runtime.host().snapshot() {
          Ok(baseline) => baseline.pending_interactions[0].interaction
          Err(error) => abort("snapshot failed: \{error}")
        },
        answer: @port.UiInteractionAnswer::Yes,
      }) {
      Ok(_) => ()
      Err(error) => fail("answer failed: \{error}")
    }
    task.wait()
  })
  match answer.val {
    Some(Ok(value)) => assert_eq(value, @port.UiInteractionAnswer::Yes)
    Some(Err(error)) => fail("ask failed: \{error}")
    None => fail("ask never recorded an outcome")
  }
  runtime.close()
}

///|
async test "ui_host/last_matching_detach_wakes_wait_without_settling" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let first = ui_connect_confirm_host(runtime)
  let second = ui_connect_confirm_host(runtime)
  let opened = ui_opened(requester.open(request=confirm_request("confirm-1")))
  let answer : Ref[Result[@port.UiInteractionAnswer, @port.UiInteractionError]?] = Ref(
    None,
  )
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      answer.val = Some(requester.wait(interaction=opened))
    })
    ui_wait_until(fn() {
      ui_pending_waiters(runtime, "requester", "confirm-1") == 1
    })
    // A non-last matching host leaving changes nothing for the waiter.
    ignore(first.detach())
    ui_resume_after_pauses()
    assert_true(answer.val is None)
    assert_eq(ui_pending_waiters(runtime, "requester", "confirm-1"), 1)
    // The last one leaving returns HostUnavailable but keeps the question.
    ignore(second.detach())
    task.wait()
  })
  match answer.val {
    Some(Err(@port.UiInteractionError::HostUnavailable(_))) => ()
    Some(Ok(value)) => fail("no host can answer: \{value}")
    Some(Err(other)) => fail("expected HostUnavailable, got \{other}")
    None => fail("wait never recorded an outcome")
  }
  match runtime.host().snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.pending_interactions.length(), 1)
      assert_eq(baseline.pending_interactions[0].interaction, opened)
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
  // The question is still pending, so a later host can answer it.
  let replacement = ui_connect_confirm_host(runtime)
  match
    replacement.answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::No,
    }) {
    Ok(receipt) => assert_false(receipt.replayed)
    Err(error) => fail("answer failed: \{error}")
  }
  match requester.wait(interaction=opened) {
    Ok(value) => assert_eq(value, @port.UiInteractionAnswer::No)
    Err(error) =>
      fail("the settled answer must outrank the lost host: \{error}")
  }
  // The feed reports Opened then a real Answered; no WaitCancelled was faked.
  let kinds = match
    runtime
    .host()
    .interactions_since(cursor={ generation: runtime.generation(), seq: 0, }) {
    Ok(changes) => changes.changes
    Err(error) => fail("changes failed: \{error}")
  }
  assert_eq(kinds.length(), 2)
  match kinds[1] {
    Settled(outcome~, ..) =>
      match outcome {
        Answered(..) => ()
        other => fail("expected Answered, got \{other.to_string()}")
      }
    Opened(_) => fail("expected the second change to be Settled")
  }
  runtime.close()
}

///|
async test "ui_host/capability_downgrade_wakes_only_unsupported_waiters" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let host = ui_connect_host(
    runtime,
    @port.UiHostCapabilities::new(interactions=[
      @port.UiInteractionKind::YesNo,
      @port.UiInteractionKind::SingleChoice,
    ]),
  )
  let confirm = ui_opened(requester.open(request=confirm_request("confirm-1")))
  let pick = ui_opened(requester.open(request=choice_request("pick-1")))
  let confirm_result : Ref[
    Result[@port.UiInteractionAnswer, @port.UiInteractionError]?,
  ] = Ref(None)
  let pick_result : Ref[
    Result[@port.UiInteractionAnswer, @port.UiInteractionError]?,
  ] = Ref(None)
  @async.with_task_group(async fn(group) {
    let confirm_task = group.spawn(async fn() {
      confirm_result.val = Some(requester.wait(interaction=confirm))
    })
    let pick_task = group.spawn(async fn() {
      pick_result.val = Some(requester.wait(interaction=pick))
    })
    ui_wait_until(fn() {
      ui_pending_waiters(runtime, "requester", "confirm-1") == 1 &&
      ui_pending_waiters(runtime, "requester", "pick-1") == 1
    })
    // Dropping YesNo wakes the confirmation waiter only.
    ignore(
      host.update(
        capabilities=@port.UiHostCapabilities::new(interactions=[
          @port.UiInteractionKind::SingleChoice,
        ]),
      ),
    )
    confirm_task.wait()
    ui_resume_after_pauses()
    assert_true(pick_result.val is None)
    assert_eq(ui_pending_waiters(runtime, "requester", "pick-1"), 1)
    ignore(
      host.update(
        capabilities=@port.UiHostCapabilities::new(interactions=[
          @port.UiInteractionKind::SingleChoice,
          @port.UiInteractionKind::YesNo,
        ]),
      ),
    )
    match
      host.answer(request={
        interaction: pick,
        answer: @port.UiInteractionAnswer::Choice(1),
      }) {
      Ok(_) => ()
      Err(error) => fail("answer failed: \{error}")
    }
    pick_task.wait()
  })
  match confirm_result.val {
    Some(Err(@port.UiInteractionError::HostUnavailable(_))) => ()
    Some(Ok(value)) =>
      fail("downgraded confirmation cannot be answered: \{value}")
    Some(Err(other)) => fail("expected HostUnavailable, got \{other}")
    None => fail("confirmation wait never recorded an outcome")
  }
  match pick_result.val {
    Some(Ok(value)) => assert_eq(value, @port.UiInteractionAnswer::Choice(1))
    Some(Err(error)) => fail("choice wait failed: \{error}")
    None => fail("choice wait never recorded an outcome")
  }
  // The confirmation question survives for a host that supports it again, but
  // re-waiting while it is still downgraded fails fast instead of blocking.
  ignore(
    host.update(
      capabilities=@port.UiHostCapabilities::new(interactions=[
        @port.UiInteractionKind::SingleChoice,
      ]),
    ),
  )
  match requester.wait(interaction=confirm) {
    Err(@port.UiInteractionError::HostUnavailable(_)) => ()
    Ok(value) => fail("no supported wait should settle: \{value}")
    Err(other) => fail("expected HostUnavailable, got \{other}")
  }
  ignore(
    host.update(
      capabilities=@port.UiHostCapabilities::new(interactions=[
        @port.UiInteractionKind::SingleChoice,
        @port.UiInteractionKind::YesNo,
      ]),
    ),
  )
  match
    host.answer(request={
      interaction: confirm,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Ok(_) => ()
    Err(error) => fail("answer failed: \{error}")
  }
  match requester.wait(interaction=confirm) {
    Ok(value) => assert_eq(value, @port.UiInteractionAnswer::Yes)
    Err(error) => fail("wait failed: \{error}")
  }
  runtime.close()
}

///|
async test "ui_host/connection_lease_is_bounded_and_never_silent" {
  let runtime = UiRuntime()
  let opened = ui_opened(
    runtime.interactions("requester").open(request=confirm_request("confirm-1")),
  )
  let connection = ui_connect_confirm_host(runtime)
  // Answers must still be declared by this connection and it must be online.
  let wrong = ui_connect_host(runtime, ui_choice_capabilities())
  match
    wrong.answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Err(@port.UiInteractionError::HostUnavailable(reason~)) =>
      assert_true(reason.contains("YesNo"))
    Ok(_) => fail("an undeclared body kind must not be answerable")
    Err(other) => fail("expected HostUnavailable, got \{other}")
  }
  match
    connection.answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Ok(receipt) => assert_false(receipt.replayed)
    Err(error) => fail("answer failed: \{error}")
  }
  // Detach is idempotent and turns later routing into HostUnavailable.
  ignore(connection.detach())
  assert_false(connection.is_connected())
  ignore(connection.detach())
  match connection.update(capabilities=ui_confirm_capabilities()) {
    Err(@port.UiInteractionError::HostUnavailable(_)) => ()
    Ok(_) => fail("a detached connection must not update capabilities")
    Err(other) => fail("expected HostUnavailable, got \{other}")
  }
  match
    connection.answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Err(@port.UiInteractionError::HostUnavailable(_)) => ()
    Ok(_) => fail("a detached connection must not answer")
    Err(other) => fail("expected HostUnavailable, got \{other}")
  }
  // The management answer stays available.
  match
    runtime
    .host()
    .answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Ok(receipt) => assert_true(receipt.replayed)
    Err(error) => fail("legacy replay failed: \{error}")
  }
  runtime.close()
  // Close outranks detach/update for every lease call.
  assert_false(connection.is_connected())
  match connection.detach() {
    Err(@port.UiInteractionError::Closed) => ()
    Ok(_) => fail("a closed Agent must report Closed on detach")
    Err(other) => fail("expected Closed, got \{other}")
  }
  match connection.update(capabilities=ui_confirm_capabilities()) {
    Err(@port.UiInteractionError::Closed) => ()
    Ok(_) => fail("a closed Agent must report Closed on update")
    Err(other) => fail("expected Closed, got \{other}")
  }
}

///|
/// A revoked lease is answered by the registry, not by its payload.
test "ui_host/detached_lease_outranks_an_invalid_declaration" {
  let runtime = UiRuntime()
  let connection = ui_connect_confirm_host(runtime)
  let duplicated = @port.UiHostCapabilities::new(interactions=[
    @port.UiInteractionKind::YesNo,
    @port.UiInteractionKind::YesNo,
  ])
  // Online: the declaration itself is the problem, and nothing is stored.
  match connection.update(capabilities=duplicated) {
    Err(@port.UiInteractionError::InvalidInput(_)) => ()
    Ok(_) => fail("a duplicate interaction declaration must be refused")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  match runtime.host_connections.get(connection.id()) {
    Some(record) => assert_eq(record.capabilities, ui_confirm_capabilities())
    None => fail("an online lease must have a registry record")
  }
  ignore(connection.detach())
  assert_false(connection.is_connected())
  // Detached: "this lease is gone" is the answer, not "your array is bad".
  match connection.update(capabilities=duplicated) {
    Err(@port.UiInteractionError::HostUnavailable(_)) => ()
    Ok(_) => fail("a detached lease must not update capabilities")
    Err(other) => fail("expected HostUnavailable, got \{other}")
  }
  match runtime.host_connections.get(connection.id()) {
    Some(_) => fail("a detached lease must not leave a registry record")
    None => ()
  }
  runtime.close()
}

///|
test "ui_host/connection_registry_is_bounded_and_validated" {
  let runtime = UiRuntime()
  for _ in 0..<ui_max_host_connections {
    ignore(ui_connect_confirm_host(runtime))
  }
  match runtime.host().connect(capabilities=ui_confirm_capabilities()) {
    Err(@port.UiInteractionError::ConnectionsFull(limit~)) =>
      assert_eq(limit, ui_max_host_connections)
    Ok(_) => fail("expected the connection registry to be bounded")
    Err(other) => fail("expected ConnectionsFull, got \{other}")
  }
  match
    runtime
    .host()
    .connect(
      capabilities=@port.UiHostCapabilities::new(resource_kinds=[
        @port.UiResourceKind::custom(namespace_="", name="x", schema_version=1),
      ]),
    ) {
    Err(@port.UiInteractionError::InvalidInput(_)) => ()
    Ok(_) => fail("a nameless kind must be refused")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  runtime.close()
}

///|
async test "ui_host/two_matching_hosts_keep_the_first_answer_contract" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let first = ui_connect_confirm_host(runtime)
  let second = ui_connect_confirm_host(runtime)
  let opened = ui_opened(requester.open(request=confirm_request("confirm-1")))
  let answer : Ref[Result[@port.UiInteractionAnswer, @port.UiInteractionError]?] = Ref(
    None,
  )
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      answer.val = Some(requester.wait(interaction=opened))
    })
    ui_wait_until(fn() {
      ui_pending_waiters(runtime, "requester", "confirm-1") == 1
    })
    match
      first.answer(request={
        interaction: opened,
        answer: @port.UiInteractionAnswer::Yes,
      }) {
      Ok(_) => ()
      Err(error) => fail("first answer failed: \{error}")
    }
    match
      second.answer(request={
        interaction: opened,
        answer: @port.UiInteractionAnswer::Yes,
      }) {
      Ok(receipt) => assert_true(receipt.replayed)
      Err(error) => fail("replay failed: \{error}")
    }
    match
      second.answer(request={
        interaction: opened,
        answer: @port.UiInteractionAnswer::No,
      }) {
      Err(@port.UiInteractionError::Conflict(_)) => ()
      Ok(_) => fail("a different second answer must conflict")
      Err(other) => fail("expected Conflict, got \{other}")
    }
    task.wait()
  })
  match answer.val {
    Some(Ok(value)) => assert_eq(value, @port.UiInteractionAnswer::Yes)
    Some(Err(error)) => fail("wait failed: \{error}")
    None => fail("wait never recorded an outcome")
  }
  runtime.close()
}

///|
async test "ui_host/closed_outranks_host_unavailable" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  ignore(ui_connect_confirm_host(runtime))
  let opened = ui_opened(requester.open(request=confirm_request("confirm-1")))
  let answer : Ref[Result[@port.UiInteractionAnswer, @port.UiInteractionError]?] = Ref(
    None,
  )
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      answer.val = Some(requester.wait(interaction=opened))
    })
    ui_wait_until(fn() {
      ui_pending_waiters(runtime, "requester", "confirm-1") == 1
    })
    runtime.close()
    task.wait()
  })
  match answer.val {
    Some(Err(@port.UiInteractionError::Closed)) => ()
    Some(Ok(value)) => fail("a closed question cannot settle as \{value}")
    Some(Err(other)) => fail("expected Closed, got \{other}")
    None => fail("wait never recorded an outcome")
  }
}

///|
async test "ui_host/reentrant_detach_during_ask_returns_fast" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let host = runtime.host()
  let connection = ui_connect_confirm_host(runtime)
  let failures : Array[String] = []
  // The listener detaches the only matching host while the `Opened` change is
  // delivered, so the ask loses its host before it can block.
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
    Err(error) => fail("subscribe failed: \{error}")
  }
  match requester.ask(request=confirm_request("reentrant-1")) {
    Err(@port.UiInteractionError::HostUnavailable(_)) => ()
    Ok(answer) =>
      fail("the re-entrant detach must not leave ask blocked: \{answer}")
    Err(other) => fail("expected HostUnavailable, got \{other}")
  }
  // The change was accepted before the detach: the question is real and stays
  // pending for the next host instead of being erased or settled as a rejection.
  let baseline = match host.snapshot() {
    Ok(baseline) => baseline
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(baseline.pending_interactions.length(), 1)
  let replacement = ui_connect_confirm_host(runtime)
  match
    replacement.answer(request={
      interaction: baseline.pending_interactions[0].interaction,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Ok(_) => ()
    Err(error) => fail("answer failed: \{error}")
  }
  match
    requester.wait(interaction=baseline.pending_interactions[0].interaction) {
    Ok(value) => assert_eq(value, @port.UiInteractionAnswer::Yes)
    Err(error) => fail("wait failed: \{error}")
  }
  assert_eq(failures.length(), 0)
  observation.subscription.unsubscribe()
  runtime.close()
}

///|
async test "ui_host/find_recovers_a_question_lost_after_ask_creation" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let host = runtime.host()
  let connection = ui_connect_confirm_host(runtime)
  let failures : Array[String] = []
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
    Err(error) => fail("subscribe failed: \{error}")
  }
  // The ask creates the question, then loses its only matching host during
  // the `Opened` delivery and returns HostUnavailable.
  match requester.ask(request=confirm_request("found-1")) {
    Err(@port.UiInteractionError::HostUnavailable(_)) => ()
    Ok(answer) => fail("the lost host must not settle ask: \{answer}")
    Err(other) => fail("expected HostUnavailable, got \{other}")
  }
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 1)
    Err(error) => fail("snapshot failed: \{error}")
  }
  // The owner still knows the id it supplied, so find returns the live ref.
  let found = match requester.find(request_id="found-1") {
    Ok(snapshot) => snapshot
    Err(error) => fail("find failed: \{error}")
  }
  assert_eq(found.interaction.request_id, "found-1")
  assert_eq(found.prompt, "Ship it?")
  // No host is connected: waiting fails fast but leaves the question pending.
  match requester.wait(interaction=found.interaction) {
    Err(@port.UiInteractionError::HostUnavailable(_)) => ()
    Ok(answer) => fail("a hostless wait must not settle: \{answer}")
    Err(other) => fail("expected HostUnavailable, got \{other}")
  }
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 1)
    Err(error) => fail("snapshot failed: \{error}")
  }
  // A later host answers; the recovered ref joins the terminal outcome.
  let replacement = ui_connect_confirm_host(runtime)
  match
    replacement.answer(request={
      interaction: found.interaction,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Ok(_) => ()
    Err(error) => fail("answer failed: \{error}")
  }
  match requester.wait(interaction=found.interaction) {
    Ok(value) => assert_eq(value, @port.UiInteractionAnswer::Yes)
    Err(error) => fail("wait failed: \{error}")
  }
  assert_eq(failures.length(), 0)
  observation.subscription.unsubscribe()
  runtime.close()
}

///|
async test "ui_host/find_is_owner_bound_and_survives_retention" {
  let runtime = UiRuntime()
  let alpha = runtime.interactions("alpha")
  let beta = runtime.interactions("beta")
  let opened = ui_opened(alpha.open(request=confirm_request("shared-1")))
  match alpha.find(request_id="shared-1") {
    Ok(found) => assert_eq(found.interaction, opened)
    Err(error) => fail("owner find failed: \{error}")
  }
  match beta.find(request_id="shared-1") {
    Err(@port.UiInteractionError::NotFound(owner~, request_id~)) => {
      assert_eq(owner, "beta")
      assert_eq(request_id, "shared-1")
    }
    Ok(_) => fail("a foreign owner must not find another owner's question")
    Err(other) => fail("expected NotFound, got \{other}")
  }
  match alpha.find(request_id="missing") {
    Err(@port.UiInteractionError::NotFound(_)) => ()
    Ok(_) => fail("an unknown id has no snapshot")
    Err(other) => fail("expected NotFound, got \{other}")
  }
  // Withdraw releases the pending question; the retained window still answers
  // a lookup so the owner can join the terminal outcome.
  match alpha.withdraw(interaction=opened) {
    Ok(_) => ()
    Err(error) => fail("withdraw failed: \{error}")
  }
  match alpha.find(request_id="shared-1") {
    Ok(found) => assert_eq(found.interaction, opened)
    Err(error) => fail("retained find failed: \{error}")
  }
  match runtime.host().snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
  match alpha.wait(interaction=opened) {
    Err(@port.UiInteractionError::Withdrawn) => ()
    Ok(answer) => fail("withdrawn must not be an answer: \{answer}")
    Err(other) => fail("expected Withdrawn, got \{other}")
  }
  runtime.close()
  match alpha.find(request_id="shared-1") {
    Err(@port.UiInteractionError::Closed) => ()
    Ok(_) => fail("a closed runtime must not answer lookup")
    Err(other) => fail("expected Closed, got \{other}")
  }
}

///|
async test "ui_host/find_without_an_adapter_callback_is_explicit" {
  let owner = "legacy"
  let interactions = @port.UiInteractions::from_callbacks(
    owner~,
    open=fn(_request) { Err(@port.UiInteractionError::Closed) },
    wait=async fn(_interaction) noraise {
      @async.pause()
      Err(@port.UiInteractionError::Closed)
    },
    withdraw=fn(_interaction) { Err(@port.UiInteractionError::Closed) },
  )
  match interactions.find(request_id="anything") {
    Err(@port.UiInteractionError::HostUnavailable(reason~)) =>
      assert_true(reason.contains("lookup"))
    Ok(_) => fail("an adapter without lookup must not succeed")
    Err(other) => fail("expected HostUnavailable, got \{other}")
  }
}

///|
test "ui_host/capability_declarations_are_bounded_and_deduplicated" {
  let runtime = UiRuntime()
  let kind = ui_board_kind()
  match
    runtime
    .host()
    .connect(
      capabilities=@port.UiHostCapabilities::new(resource_kinds=[kind, kind]),
    ) {
    Err(@port.UiInteractionError::InvalidInput(reason~)) =>
      assert_true(reason.contains("duplicate"))
    Ok(_) => fail("a repeated resource kind must be refused")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  match
    runtime
    .host()
    .connect(
      capabilities=@port.UiHostCapabilities::new(interactions=[
        @port.UiInteractionKind::YesNo,
        @port.UiInteractionKind::YesNo,
      ]),
    ) {
    Err(@port.UiInteractionError::InvalidInput(reason~)) =>
      assert_true(reason.contains("duplicate"))
    Ok(_) => fail("a repeated interaction kind must be refused")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  // Different schema versions are different kinds, not accidental duplicates.
  ignore(
    ui_connect_host(
      runtime,
      @port.UiHostCapabilities::new(resource_kinds=[
        kind,
        @port.UiResourceKind::custom(
          namespace_="publisher",
          name="board",
          schema_version=3,
        ),
      ]),
    ),
  )
  // The list size is bounded like the other runtime windows.
  let too_many : Array[@port.UiResourceKind] = []
  for index in 0..<(ui_max_host_capability_entries + 1) {
    too_many.push(
      @port.UiResourceKind::custom(
        namespace_="publisher",
        name="k\{index}",
        schema_version=1,
      ),
    )
  }
  match
    runtime
    .host()
    .connect(
      capabilities=@port.UiHostCapabilities::new(resource_kinds=too_many),
    ) {
    Err(@port.UiInteractionError::InvalidInput(reason~)) =>
      assert_true(reason.contains("exceed"))
    Ok(_) => fail("an oversized capability list must be refused")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  // Exactly the limit is still accepted.
  let at_limit : Array[@port.UiResourceKind] = []
  for index in 0..<ui_max_host_capability_entries {
    at_limit.push(
      @port.UiResourceKind::custom(
        namespace_="publisher",
        name="k\{index}",
        schema_version=1,
      ),
    )
  }
  ignore(
    ui_connect_host(
      runtime,
      @port.UiHostCapabilities::new(resource_kinds=at_limit),
    ),
  )
  runtime.close()
}
