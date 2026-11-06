///|
/// Contract tests for push observation: the atomic baseline plus the ordered
/// change stream, re-entrant publishing, unsubscribe, listener failure and
/// close. Whitebox (same package); the end-to-end path lives in the root
/// black-box suite.

///|
fn ui_change_label(change : @port.UiChange) -> String {
  match change {
    Resource(change~) =>
      match change {
        Published(_) => "published"
        Replaced(_) => "replaced"
        Withdrawn(..) => "withdrawn"
      }
    Interaction(change~) =>
      match change {
        Opened(_) => "opened"
        Settled(..) => "settled"
      }
  }
}

///|
fn ui_observed_label(batch : @port.UiFeedBatch) -> String {
  "\{batch.cursor.seq}:\{ui_change_label(batch.change)}"
}

///|
fn ui_subscribe_or_abort(
  host : @port.UiHost,
  listener : (@port.UiFeedBatch) -> Result[Unit, String],
  on_failure : (@port.UiListenerFailure) -> Unit,
) -> @port.UiObservation {
  match host.subscribe(listener~, on_failure~) {
    Ok(value) => value
    Err(error) => abort("subscribe failed: \{error}")
  }
}

///|
test "ui_observation/baseline_and_subscription_handoff_loses_nothing" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  ignore(board.publish(draft=board_draft(key="one")))
  let delivered : Array[String] = []
  let failures : Array[String] = []
  let observation = ui_subscribe_or_abort(
    host,
    fn(batch) {
      delivered.push(ui_observed_label(batch))
      Ok(())
    },
    fn(failure) { failures.push(failure.detail) },
  )
  // The cut already contains everything committed before the subscription and
  // replays none of it.
  assert_eq(observation.baseline.resources.length(), 1)
  assert_eq(observation.baseline.cursor.seq, 1)
  assert_eq(delivered.length(), 0)
  ignore(board.publish(draft=board_draft(key="two")))
  ignore(
    board.replace(draft=board_draft(key="one", revision_note="v2"), expected=1),
  )
  assert_eq(delivered, ["2:published", "3:replaced"])
  // Push and pull agree: the same cut reaches the same changes.
  match host.changes_since(cursor=observation.baseline.cursor) {
    Ok(changes) => {
      assert_eq(changes.changes.length(), 2)
      assert_eq(changes.cursor.seq, 3)
    }
    Err(error) => fail("changes failed: \{error}")
  }
  assert_true(observation.subscription.is_active())
  assert_eq(failures.length(), 0)
}

///|
test "ui_observation/reentrant_publish_is_delivered_in_order" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let delivered : Array[String] = []
  let depth = Ref(0)
  let deepest = Ref(0)
  let nested = Ref(false)
  ignore(
    ui_subscribe_or_abort(
      host,
      fn(batch) {
        depth.val = depth.val + 1
        if depth.val > deepest.val {
          deepest.val = depth.val
        }
        delivered.push(ui_observed_label(batch))
        if !nested.val {
          nested.val = true
          // Publishing from inside the listener must be queued behind the
          // change being delivered, not delivered inside it.
          ignore(board.publish(draft=board_draft(key="nested")))
          if delivered.length() != 1 {
            abort("the nested publish was delivered re-entrantly")
          }
        }
        depth.val = depth.val - 1
        Ok(())
      },
      fn(_failure) { abort("unexpected listener failure") },
    ),
  )
  ignore(board.publish(draft=board_draft(key="first")))
  // Both changes arrive, in commit order, and the listener was never re-entered.
  assert_eq(delivered, ["1:published", "2:published"])
  assert_eq(deepest.val, 1)
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 2)
    Err(error) => fail("snapshot failed: \{error}")
  }
}

///|
test "ui_observation/unsubscribe_stops_delivery_and_is_idempotent" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let handle : Ref[@port.UiSubscription?] = Ref(None)
  let delivered = Ref(0)
  let observation = ui_subscribe_or_abort(
    host,
    fn(_batch) {
      delivered.val = delivered.val + 1
      // Unsubscribing from inside the listener is legal and stops delivery
      // immediately.
      match handle.val {
        Some(subscription) => subscription.unsubscribe()
        None => abort("expected the subscription handle")
      }
      Ok(())
    },
    fn(_failure) { abort("unexpected listener failure") },
  )
  handle.val = Some(observation.subscription)
  ignore(board.publish(draft=board_draft(key="one")))
  assert_eq(delivered.val, 1)
  assert_false(observation.subscription.is_active())
  // A second unsubscribe is a no-op, and later changes never arrive.
  observation.subscription.unsubscribe()
  ignore(board.publish(draft=board_draft(key="two")))
  assert_eq(delivered.val, 1)
}

///|
test "ui_observation/listener_failure_is_reported_and_drops_the_subscriber" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let delivered : Array[String] = []
  let failures : Array[String] = []
  let observation = ui_subscribe_or_abort(
    host,
    fn(batch) {
      delivered.push(ui_observed_label(batch))
      if ui_change_label(batch.change) == "replaced" {
        Err("render failed")
      } else {
        Ok(())
      }
    },
    fn(failure) {
      failures.push("\{failure.subscription}:\{failure.seq}:\{failure.detail}")
    },
  )
  ignore(board.publish(draft=board_draft(key="one")))
  ignore(
    board.replace(draft=board_draft(key="one", revision_note="v2"), expected=1),
  )
  // The failing batch was delivered, the failure is reported once, and the
  // subscription is gone instead of failing forever.
  assert_eq(delivered, ["1:published", "2:replaced"])
  assert_eq(failures.length(), 1)
  assert_true(failures[0].contains("render failed"))
  assert_true(failures[0].contains(observation.subscription.id().to_string()))
  assert_false(observation.subscription.is_active())
  ignore(board.publish(draft=board_draft(key="three")))
  assert_eq(delivered, ["1:published", "2:replaced"])
  // The accepted changes are still in the log: a failure never rolls back.
  match
    host.changes_since(cursor={ generation: runtime.generation(), seq: 0, }) {
    Ok(changes) => assert_eq(changes.changes.length(), 3)
    Err(error) => fail("changes failed: \{error}")
  }
}

///|
test "ui_observation/close_ends_every_subscription_and_the_feed" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let delivered = Ref(0)
  let observation = ui_subscribe_or_abort(
    host,
    fn(_batch) {
      delivered.val = delivered.val + 1
      Ok(())
    },
    fn(_failure) { abort("unexpected listener failure") },
  )
  ignore(board.publish(draft=board_draft(key="one")))
  assert_eq(delivered.val, 1)
  runtime.close()
  assert_false(observation.subscription.is_active())
  match
    host.subscribe(listener=fn(_batch) { Ok(()) }, on_failure=fn(_failure) {
      ()
    }) {
    Err(@port.UiResourceError::Closed) => ()
    Ok(_) => fail("expected a closed runtime to refuse new subscriptions")
    Err(other) => fail("expected Closed, got \{other}")
  }
  assert_eq(host.snapshot(), Err(@port.UiResourceError::Closed))
  assert_eq(
    host.interactions_since(cursor={ generation: runtime.generation(), seq: 0, }),
    Err(@port.UiResourceError::Closed),
  )
  assert_eq(delivered.val, 1)
}

///|
async test "ui_observation/accepted_change_survives_a_cancelled_dispatch" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let delivered : Array[String] = []
  let started = Ref(false)
  ignore(
    ui_subscribe_or_abort(
      host,
      fn(batch) {
        delivered.push(ui_observed_label(batch))
        Ok(())
      },
      fn(_failure) { abort("unexpected listener failure") },
    ),
  )
  let draft = @port.UiResourceDraft::new(
    key="board",
    kind=@port.UiResourceKind::standard(name="task_board"),
    body=@port.UiResourceBody::Text("v1"),
    actions=[marked_done_action()],
  )
  let reference = published_ref(board.publish(draft~))
  ignore(
    board.set_action_handler(handler=invocation => {
      // The owner publishes before awaiting, then blocks: the action dispatch
      // itself is cancelled while the mutation is already accepted.
      ignore(
        board.replace(
          draft=@port.UiResourceDraft::new(
            key=invocation.resource.key,
            kind=@port.UiResourceKind::standard(name="task_board"),
            body=@port.UiResourceBody::Text("published before cancel"),
            actions=[marked_done_action()],
          ),
          expected=invocation.revision,
        ),
      )
      started.val = true
      @async.sleep(60_000)
      Ok(())
    }),
  )
  let request : @port.UiActionRequest = {
    resource: reference,
    action: "mark_done",
    expected_revision: 1,
    request_id: "req-1",
    payload: Some(Json::object(Map::from_array([]))),
  }
  @async.with_task_group(async fn(group) {
    let task = group.spawn(async fn() { ignore(host.dispatch(request~)) })
    ui_wait_until(fn() { started.val })
    task.cancel()
  })
  // The accepted change was delivered before the cancellation and stays
  // accepted afterwards: cancellation never retracts observation.
  assert_eq(delivered, ["1:published", "2:replaced"])
  match host.snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.resources.length(), 1)
      assert_eq(baseline.resources[0].revision, 2)
      assert_eq(
        baseline.resources[0].body,
        @port.UiResourceBody::Text("published before cancel"),
      )
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
  runtime.close()
}

///|
test "ui_observation/round_robin_keeps_one_listener_from_starving_another" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let order : Array[String] = []
  let republished = Ref(0)
  let greedy = ui_subscribe_or_abort(
    host,
    fn(_batch) {
      order.push("greedy")
      if republished.val < 3 {
        republished.val = republished.val + 1
        // A listener that publishes on every batch: without round-robin its own
        // queue would never drain and the second subscriber would never run.
        ignore(board.publish(draft=board_draft(key="again-\{republished.val}")))
      }
      Ok(())
    },
    fn(_failure) { abort("unexpected listener failure") },
  )
  let quiet = ui_subscribe_or_abort(
    host,
    fn(_batch) {
      order.push("quiet")
      Ok(())
    },
    fn(_failure) { abort("unexpected listener failure") },
  )
  ignore(board.publish(draft=board_draft(key="start")))
  // Four accepted changes, two subscribers, strict round-robin: the quiet
  // listener is never starved by the one that keeps republishing.
  assert_eq(order.length(), 8)
  assert_eq(order, [
    "greedy", "quiet", "greedy", "quiet", "greedy", "quiet", "greedy", "quiet",
  ])
  assert_true(greedy.subscription.is_active())
  assert_true(quiet.subscription.is_active())
  runtime.close()
}
