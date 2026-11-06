///|
/// Contract tests for owner-bound structured interactions: pending
/// observation, answer settlement, dismissal/withdrawal, cancelled waits,
/// owner isolation, and close. Whitebox (same package); the end-to-end path
/// lives in the root black-box suite.

///|
fn confirm_request(id : String) -> @port.UiInteractionRequest {
  @port.UiInteractionRequest::new(
    request_id=id,
    prompt="Ship it?",
    body=@port.UiInteractionBody::Confirmation,
  )
}

///|
fn choice_request(id : String) -> @port.UiInteractionRequest {
  @port.UiInteractionRequest::new(
    request_id=id,
    prompt="Keep or drop?",
    body=@port.UiInteractionBody::Choice(
      options=["keep", "drop"],
      default=Some(0),
    ),
  )
}

///|
fn ui_opened(
  result : Result[@port.UiInteractionSnapshot, @port.UiInteractionError],
) -> @port.UiInteractionRef {
  match result {
    Ok(snapshot) => snapshot.interaction
    Err(error) => abort("expected an open interaction, got \{error}")
  }
}

///|
fn ui_pending_waiters(
  runtime : UiRuntime,
  owner : String,
  request_id : String,
) -> Int32 {
  let key = ui_interaction_key(owner, request_id)
  match runtime.interactions.get(key) {
    Some(record) => record.waiters
    None => 0
  }
}

///|
async fn ui_wait_until(condition : () -> Bool) -> Unit {
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
async test "ui_interaction/answer_settles_once_and_replays" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let host = runtime.host()
  let opened = ui_opened(requester.open(request=confirm_request("confirm-1")))
  assert_eq(opened.owner, "requester")
  // The open question is part of the atomic baseline, next to resources.
  let baseline = match host.snapshot() {
    Ok(value) => value
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(baseline.pending_interactions.length(), 1)
  assert_eq(baseline.pending_interactions[0].prompt, "Ship it?")
  assert_eq(
    baseline.pending_interactions[0].body,
    @port.UiInteractionBody::Confirmation,
  )
  assert_eq(baseline.interaction_cursor.seq, 1)
  let answer : @port.UiInteractionAnswer = @port.UiInteractionAnswer::Yes
  match host.answer(request={ interaction: opened, answer, }) {
    Ok(receipt) => assert_false(receipt.replayed)
    Err(error) => fail("answer failed: \{error}")
  }
  // A waiter that joins after the settle still learns the accepted answer.
  match requester.wait(interaction=opened) {
    Ok(value) => assert_eq(value, answer)
    Err(error) => fail("wait failed: \{error}")
  }
  // Repeating the accepted answer replays the receipt; a different value is a
  // conflict and never overwrites the first answer.
  match host.answer(request={ interaction: opened, answer, }) {
    Ok(receipt) => assert_true(receipt.replayed)
    Err(error) => fail("replay failed: \{error}")
  }
  match
    host.answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::No,
    }) {
    Err(@port.UiInteractionError::Conflict(reason~)) =>
      assert_true(reason.contains("confirm-1"))
    Ok(_) => fail("expected the second answer to conflict")
    Err(other) => fail("expected Conflict, got \{other}")
  }
  // The question left the pending set and the feed reported both lifecycle
  // facts in order.
  match host.snapshot() {
    Ok(after) => assert_eq(after.pending_interactions.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
  match
    host.interactions_since(cursor={ generation: runtime.generation(), seq: 0, }) {
    Ok(changes) => {
      assert_eq(changes.changes.length(), 2)
      match changes.changes[1] {
        Settled(owner~, request_id~, outcome~) => {
          assert_eq(owner, "requester")
          assert_eq(request_id, "confirm-1")
          assert_eq(outcome, @port.UiInteractionOutcome::Answered(answer~))
        }
        other => fail("expected Settled, got \{repr(other)}")
      }
    }
    Err(error) => fail("changes failed: \{error}")
  }
}

///|
async test "ui_interaction/host_answer_wakes_a_blocked_waiter" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let host = runtime.host()
  // A blocking wait needs a connected host that declares the body kind.
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
    match
      host.answer(request={
        interaction: opened,
        answer: @port.UiInteractionAnswer::Yes,
      }) {
      Ok(_) => ()
      Err(error) => abort("answer failed: \{error}")
    }
    task.wait()
  })
  match answer.val {
    Some(Ok(value)) => assert_eq(value, @port.UiInteractionAnswer::Yes)
    Some(Err(error)) => fail("the waiter did not receive the answer: \{error}")
    None => fail("expected the waiter to record an outcome")
  }
}

///|
async test "ui_interaction/invalid_answer_leaves_the_question_pending" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let host = runtime.host()
  let opened = ui_opened(requester.open(request=choice_request("pick-1")))
  // The wrong answer shape is refused and changes nothing.
  match
    host.answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Err(@port.UiInteractionError::InvalidAnswer(reason~)) =>
      assert_true(reason.contains("choice"))
    Ok(_) => fail("expected a Yes answer to a Choice body to be refused")
    Err(other) => fail("expected InvalidAnswer, got \{other}")
  }
  match
    host.answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::Choice(9),
    }) {
    Err(@port.UiInteractionError::InvalidAnswer(reason~)) =>
      assert_true(reason.contains("range"))
    Ok(_) => fail("expected an out-of-range choice to be refused")
    Err(other) => fail("expected InvalidAnswer, got \{other}")
  }
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 1)
    Err(error) => fail("snapshot failed: \{error}")
  }
  // The host can still answer correctly afterwards.
  match
    host.answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::Choice(1),
    }) {
    Ok(receipt) => assert_false(receipt.replayed)
    Err(error) => fail("answer failed: \{error}")
  }
  match requester.wait(interaction=opened) {
    Ok(value) => assert_eq(value, @port.UiInteractionAnswer::Choice(1))
    Err(error) => fail("wait failed: \{error}")
  }
}

///|
async test "ui_interaction/duplicate_request_id_is_explicit" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let host = runtime.host()
  let opened = ui_opened(requester.open(request=confirm_request("confirm-1")))
  match requester.open(request=confirm_request("confirm-1")) {
    Err(@port.UiInteractionError::Duplicate(request_id~)) =>
      assert_eq(request_id, "confirm-1")
    Ok(_) => fail("expected a duplicate request id to be refused")
    Err(other) => fail("expected Duplicate, got \{other}")
  }
  match
    host.answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Ok(_) => ()
    Err(error) => fail("answer failed: \{error}")
  }
  // The id stays retained after the settle: reopening it would silently bind
  // two different questions to one identity.
  match requester.open(request=confirm_request("confirm-1")) {
    Err(@port.UiInteractionError::Duplicate(request_id~)) =>
      assert_eq(request_id, "confirm-1")
    Ok(_) => fail("expected the retained request id to be refused")
    Err(other) => fail("expected Duplicate, got \{other}")
  }
  // A fresh id works.
  let next = ui_opened(requester.open(request=confirm_request("confirm-2")))
  assert_eq(next.request_id, "confirm-2")
}

///|
test "ui_interaction/invalid_requests_are_explicit" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let empty_prompt = @port.UiInteractionRequest::new(
    request_id="a",
    prompt="",
    body=@port.UiInteractionBody::Confirmation,
  )
  match requester.open(request=empty_prompt) {
    Err(@port.UiInteractionError::InvalidInput(reason~)) =>
      assert_true(reason.contains("prompt"))
    Ok(_) => fail("expected an empty prompt to be refused")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  let empty_id = @port.UiInteractionRequest::new(
    request_id="",
    prompt="Ship it?",
    body=@port.UiInteractionBody::Confirmation,
  )
  match requester.open(request=empty_id) {
    Err(@port.UiInteractionError::InvalidInput(reason~)) =>
      assert_true(reason.contains("request_id"))
    Ok(_) => fail("expected an empty request id to be refused")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  let empty_choices = @port.UiInteractionRequest::new(
    request_id="b",
    prompt="Pick",
    body=@port.UiInteractionBody::Choice(options=[], default=None),
  )
  match requester.open(request=empty_choices) {
    Err(@port.UiInteractionError::InvalidInput(reason~)) =>
      assert_true(reason.contains("option"))
    Ok(_) => fail("expected an empty option list to be refused")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  let bad_default = @port.UiInteractionRequest::new(
    request_id="c",
    prompt="Pick",
    body=@port.UiInteractionBody::Choice(options=["one"], default=Some(2)),
  )
  match requester.open(request=bad_default) {
    Err(@port.UiInteractionError::InvalidInput(reason~)) =>
      assert_true(reason.contains("default"))
    Ok(_) => fail("expected an out-of-range default to be refused")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  let empty_scope = @port.UiInteractionRequest::new(
    request_id="d",
    prompt="Ship it?",
    body=@port.UiInteractionBody::Confirmation,
    scope=@port.UiResourceScope::SessionScope(id=""),
  )
  match requester.open(request=empty_scope) {
    Err(@port.UiInteractionError::InvalidInput(reason~)) =>
      assert_true(reason.contains("scope"))
    Ok(_) => fail("expected an empty scope id to be refused")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
}

///|
test "ui_interaction/pending_limit_is_reported" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  for index in 0..<ui_max_pending_interactions {
    ignore(requester.open(request=confirm_request("confirm-\{index}")))
  }
  match requester.open(request=confirm_request("one-too-many")) {
    Err(@port.UiInteractionError::PendingFull(limit~)) =>
      assert_eq(limit, ui_max_pending_interactions)
    Ok(_) => fail("expected the pending limit to refuse the request")
    Err(other) => fail("expected PendingFull, got \{other}")
  }
}

///|
async test "ui_interaction/dismiss_is_not_a_rejection" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let host = runtime.host()
  let opened = ui_opened(requester.open(request=confirm_request("confirm-1")))
  match host.dismiss(interaction=opened, reason="closed by user") {
    Ok(@port.UiInteractionOutcome::Dismissed(reason~)) =>
      assert_eq(reason, "closed by user")
    Ok(other) => fail("expected Dismissed, got \{repr(other)}")
    Err(error) => fail("dismiss failed: \{error}")
  }
  // The wait ends as `Dismissed`, not as `Ok(No)`: no answer was given.
  match requester.wait(interaction=opened) {
    Err(@port.UiInteractionError::Dismissed(reason~)) =>
      assert_eq(reason, "closed by user")
    Ok(answer) => fail("a dismissal must not become an answer: \{answer}")
    Err(other) => fail("expected Dismissed, got \{other}")
  }
  // Dismissing again, or answering afterwards, is refused as already settled.
  match host.dismiss(interaction=opened) {
    Err(@port.UiInteractionError::AlreadySettled(outcome~)) =>
      match outcome {
        Dismissed(_) => ()
        other => fail("expected a Dismissed outcome, got \{repr(other)}")
      }
    Ok(_) => fail("expected the second dismissal to be refused")
    Err(other) => fail("expected AlreadySettled, got \{other}")
  }
  match
    host.answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Err(@port.UiInteractionError::AlreadySettled(outcome~)) =>
      match outcome {
        Dismissed(_) => ()
        other => fail("expected a Dismissed outcome, got \{repr(other)}")
      }
    Ok(_) => fail("expected an answer after dismissal to be refused")
    Err(other) => fail("expected AlreadySettled, got \{other}")
  }
}

///|
async test "ui_interaction/withdraw_wakes_the_waiter_explicitly" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let other = runtime.interactions("other")
  let host = runtime.host()
  let opened = ui_opened(requester.open(request=confirm_request("confirm-1")))
  // Another extension cannot withdraw someone else's question.
  match other.withdraw(interaction=opened) {
    Err(@port.UiInteractionError::InvalidInput(reason~)) =>
      assert_true(reason.contains("owner"))
    Ok(_) => fail("expected a cross-owner withdrawal to be refused")
    Err(error) => fail("expected InvalidInput, got \{error}")
  }
  match requester.withdraw(interaction=opened) {
    Ok(@port.UiInteractionOutcome::Withdrawn) => ()
    Ok(other) => fail("expected Withdrawn, got \{repr(other)}")
    Err(error) => fail("withdraw failed: \{error}")
  }
  match requester.wait(interaction=opened) {
    Err(@port.UiInteractionError::Withdrawn) => ()
    Ok(answer) => fail("a withdrawal must not become an answer: \{answer}")
    Err(other) => fail("expected Withdrawn, got \{other}")
  }
  match
    host.answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Err(@port.UiInteractionError::AlreadySettled(outcome~)) =>
      match outcome {
        Withdrawn => ()
        other => fail("expected a Withdrawn outcome, got \{repr(other)}")
      }
    Ok(_) => fail("expected an answer after withdrawal to be refused")
    Err(other) => fail("expected AlreadySettled, got \{other}")
  }
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
}

///|
async test "ui_interaction/cancelled_wait_is_not_a_user_rejection" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let host = runtime.host()
  ignore(ui_connect_confirm_host(runtime))
  let opened = ui_opened(requester.open(request=confirm_request("confirm-1")))
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() {
      ignore(requester.wait(interaction=opened))
    })
    ui_wait_until(fn() {
      ui_pending_waiters(runtime, "requester", "confirm-1") == 1
    })
    task.cancel()
  })
  // Losing the waiter abandons the question: it is no longer pending, and no
  // answer or rejection was invented.
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
  match
    host.interactions_since(cursor={ generation: runtime.generation(), seq: 1, }) {
    Ok(changes) => {
      assert_eq(changes.changes.length(), 1)
      match changes.changes[0] {
        Settled(owner~, request_id~, outcome~) => {
          assert_eq(owner, "requester")
          assert_eq(request_id, "confirm-1")
          assert_eq(outcome, @port.UiInteractionOutcome::WaitCancelled)
        }
        other => fail("expected Settled, got \{repr(other)}")
      }
    }
    Err(error) => fail("changes failed: \{error}")
  }
  // A late answer is refused instead of being attached to a question nobody is
  // waiting for any more.
  match
    host.answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Err(@port.UiInteractionError::AlreadySettled(outcome~)) =>
      assert_eq(outcome, @port.UiInteractionOutcome::WaitCancelled)
    Ok(_) => fail("expected the abandoned question to refuse the answer")
    Err(other) => fail("expected AlreadySettled, got \{other}")
  }
}

///|
async test "ui_interaction/close_settles_pending_as_closed" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let host = runtime.host()
  ignore(ui_connect_confirm_host(runtime))
  let opened = ui_opened(requester.open(request=confirm_request("confirm-1")))
  ignore(requester.open(request=confirm_request("confirm-2")))
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
  // The waiter is released with `Closed`, and no pending question survives the
  // Agent.
  match answer.val {
    Some(Err(@port.UiInteractionError::Closed)) => ()
    Some(Ok(value)) => fail("an unanswered question cannot settle as \{value}")
    Some(Err(other)) => fail("expected Closed, got \{other}")
    None => fail("expected the waiter to record an outcome")
  }
  match
    host.answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Err(@port.UiInteractionError::Closed) => ()
    Ok(_) => fail("expected a closed runtime to refuse answers")
    Err(other) => fail("expected Closed, got \{other}")
  }
  match requester.open(request=confirm_request("confirm-3")) {
    Err(@port.UiInteractionError::Closed) => ()
    Ok(_) => fail("expected a closed runtime to refuse new questions")
    Err(other) => fail("expected Closed, got \{other}")
  }
}

///|
async test "ui_interaction/two_owners_with_the_same_request_id_are_isolated" {
  let runtime = UiRuntime()
  let alpha = runtime.interactions("alpha")
  let beta = runtime.interactions("beta")
  let host = runtime.host()
  let alpha_ref = ui_opened(alpha.open(request=confirm_request("confirm-1")))
  let beta_ref = ui_opened(beta.open(request=confirm_request("confirm-1")))
  assert_eq(alpha_ref.owner, "alpha")
  assert_eq(beta_ref.owner, "beta")
  assert_eq(alpha_ref.request_id, beta_ref.request_id)
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 2)
    Err(error) => fail("snapshot failed: \{error}")
  }
  // Answering alpha's question leaves beta's pending.
  match
    host.answer(request={
      interaction: alpha_ref,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Ok(_) => ()
    Err(error) => fail("answer failed: \{error}")
  }
  match host.snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.pending_interactions.length(), 1)
      assert_eq(baseline.pending_interactions[0].interaction.owner, "beta")
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
  // An unknown owner is not a way to reach someone else's question.
  match
    host.answer(request={
      interaction: {
        owner: "gamma",
        request_id: "confirm-1",
        generation: runtime.generation(),
      },
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Err(@port.UiInteractionError::NotFound(owner~, request_id~)) => {
      assert_eq(owner, "gamma")
      assert_eq(request_id, "confirm-1")
    }
    Ok(_) => fail("expected the unknown owner to be NotFound")
    Err(other) => fail("expected NotFound, got \{other}")
  }
  // Both waits learn their own answer.
  match alpha.wait(interaction=alpha_ref) {
    Ok(value) => assert_eq(value, @port.UiInteractionAnswer::Yes)
    Err(error) => fail("alpha wait failed: \{error}")
  }
  match
    host.answer(request={
      interaction: beta_ref,
      answer: @port.UiInteractionAnswer::No,
    }) {
    Ok(_) => ()
    Err(error) => fail("answer failed: \{error}")
  }
  match beta.wait(interaction=beta_ref) {
    Ok(value) => assert_eq(value, @port.UiInteractionAnswer::No)
    Err(error) => fail("beta wait failed: \{error}")
  }
}

///|
test "ui_interaction/pending_snapshots_are_copies" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let host = runtime.host()
  let options = ["keep", "drop"]
  let request = @port.UiInteractionRequest::new(
    request_id="pick-1",
    prompt="Keep or drop?",
    body=@port.UiInteractionBody::Choice(options~, default=Some(0)),
  )
  let opened = match requester.open(request~) {
    Ok(snapshot) => snapshot
    Err(error) => abort("open failed: \{error}")
  }
  // The publisher mutating its own option array cannot reach live state.
  options[0] = "mutated"
  let first = match host.snapshot() {
    Ok(baseline) => baseline.pending_interactions[0]
    Err(error) => abort("snapshot failed: \{error}")
  }
  match first.body {
    Choice(options~, ..) => assert_eq(options, ["keep", "drop"])
    other => abort("expected a Choice body, got \{repr(other)}")
  }
  // A reader mutating what it received cannot reach live state either.
  match opened.body {
    Choice(options~, ..) => options[1] = "aliased"
    other => abort("expected a Choice body, got \{repr(other)}")
  }
  let second = match host.snapshot() {
    Ok(baseline) => baseline.pending_interactions[0]
    Err(error) => abort("snapshot failed: \{error}")
  }
  match second.body {
    Choice(options~, ..) => assert_eq(options, ["keep", "drop"])
    other => abort("expected a Choice body, got \{repr(other)}")
  }
}

///|
async test "ui_interaction/foreign_wait_is_rejected_and_cannot_abandon_a_question" {
  let runtime = UiRuntime()
  let alpha = runtime.interactions("alpha")
  let beta = runtime.interactions("beta")
  let host = runtime.host()
  let opened = ui_opened(alpha.open(request=confirm_request("confirm-1")))
  // Waiting is owner-bound: another capability cannot even register as a
  // waiter, so it has no way to abandon alpha's question.
  match beta.wait(interaction=opened) {
    Err(@port.UiInteractionError::InvalidInput(reason~)) =>
      assert_true(reason.contains("owner"))
    Ok(answer) => fail("a foreign capability must not wait: \{answer}")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  assert_eq(ui_pending_waiters(runtime, "alpha", "confirm-1"), 0)
  // Even wrapping the foreign wait in a cancelled task changes nothing.
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() { ignore(beta.wait(interaction=opened)) })
    task.wait()
  })
  assert_eq(ui_pending_waiters(runtime, "alpha", "confirm-1"), 0)
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 1)
    Err(error) => fail("snapshot failed: \{error}")
  }
  // The owner still gets its answer.
  match
    host.answer(request={
      interaction: opened,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Ok(receipt) => assert_false(receipt.replayed)
    Err(error) => fail("answer failed: \{error}")
  }
  match alpha.wait(interaction=opened) {
    Ok(value) => assert_eq(value, @port.UiInteractionAnswer::Yes)
    Err(error) => fail("alpha wait failed: \{error}")
  }
}

///|
async test "ui_interaction/settled_outcome_outranks_close" {
  let runtime = UiRuntime()
  let requester = runtime.interactions("requester")
  let host = runtime.host()
  let answered = ui_opened(requester.open(request=confirm_request("answered")))
  let pending = ui_opened(requester.open(request=confirm_request("pending")))
  match
    host.answer(request={
      interaction: answered,
      answer: @port.UiInteractionAnswer::Yes,
    }) {
    Ok(_) => ()
    Err(error) => fail("answer failed: \{error}")
  }
  runtime.close()
  // The answer already existed: a late waiter must receive it instead of being
  // told the runtime closed, which would rewrite what happened.
  match requester.wait(interaction=answered) {
    Ok(value) => assert_eq(value, @port.UiInteractionAnswer::Yes)
    Err(error) => fail("the settled answer must outrank the close: \{error}")
  }
  // A question that was still pending does report the close.
  match requester.wait(interaction=pending) {
    Err(@port.UiInteractionError::Closed) => ()
    Ok(value) => fail("an unanswered question cannot settle as \{value}")
    Err(other) => fail("expected Closed, got \{other}")
  }
}
