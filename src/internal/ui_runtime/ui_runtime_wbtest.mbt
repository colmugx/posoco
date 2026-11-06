///|
/// Contract tests for the owner-bound UI resource runtime: owner binding,
/// full-replacement revisions, the atomic baseline/change feed, action
/// routing back to the owner, and shutdown. Whitebox (same package); the
/// end-to-end path lives in the root black-box suite.

///|
fn board_draft(
  key~ : String,
  revision_note~ : String = "v1",
) -> @port.UiResourceDraft {
  @port.UiResourceDraft::new(
    key~,
    kind=@port.UiResourceKind::standard(name="task_board"),
    body=@port.UiResourceBody::Text(revision_note),
  )
}

///|
fn marked_done_action() -> @port.UiActionSpec {
  {
    id: "mark_done",
    label: "Mark done",
    payload: @port.UiActionPayloadKind::JsonPayload,
  }
}

///|
fn published_ref(
  result : Result[@port.UiResourceSnapshot, @port.UiResourceError],
) -> @port.UiResourceRef {
  match result {
    Ok(snapshot) => snapshot.resource
    Err(error) => abort("expected a published snapshot, got \{error}")
  }
}

///|
fn ui_count_run(runs : Map[String, Int32], request_id : String) -> Unit {
  let seen = match runs.get(request_id) {
    Some(count) => count
    None => 0
  }
  runs[request_id] = seen + 1
}

///|
test "ui_runtime/same_local_key_does_not_collide_across_owners" {
  let runtime = UiRuntime()
  let alpha = runtime.capability("alpha")
  let beta = runtime.capability("beta")
  let alpha_ref = published_ref(alpha.publish(draft=board_draft(key="board")))
  let beta_ref = published_ref(beta.publish(draft=board_draft(key="board")))
  assert_eq(alpha_ref.owner, "alpha")
  assert_eq(beta_ref.owner, "beta")
  assert_eq(alpha_ref.key, beta_ref.key)
  assert_eq(alpha_ref.generation, runtime.generation())
  let host = runtime.host()
  match host.snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.resources.length(), 2)
      assert_eq(baseline.cursor.generation, runtime.generation())
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
}

///|
test "ui_runtime/forged_owner_is_rejected" {
  let runtime = UiRuntime()
  let alpha = runtime.capability("alpha")
  let beta = runtime.capability("beta")
  let beta_ref = published_ref(beta.publish(draft=board_draft(key="board")))
  let result = alpha.remove(resource=beta_ref)
  match result {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("owner"))
    Ok(_) => fail("expected the forged owner to be rejected")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
}

///|
test "ui_runtime/publish_replaces_in_place_and_tracks_changes" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let baseline = match host.snapshot() {
    Ok(value) => value
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(baseline.resources.length(), 0)
  assert_eq(baseline.cursor.seq, 0)
  let first = published_ref(board.publish(draft=board_draft(key="board")))
  let second = match
    board.publish(draft=board_draft(key="board", revision_note="v2")) {
    Ok(snapshot) => snapshot
    Err(error) => fail("publish failed: \{error}")
  }
  assert_eq(second.revision, 2)
  assert_true(second.resource == first)
  // Full replacement never grows the table and reuses the same ref.
  let after = match host.snapshot() {
    Ok(value) => value
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(after.resources.length(), 1)
  assert_eq(after.resources[0].revision, 2)
  match host.changes_since(cursor=baseline.cursor) {
    Ok(changes) => {
      assert_eq(changes.changes.length(), 2)
      assert_eq(changes.cursor.seq, 2)
      match changes.changes[0] {
        Published(snapshot~) => assert_eq(snapshot.revision, 1)
        other => fail("expected Published, got \{repr(other)}")
      }
      match changes.changes[1] {
        Replaced(snapshot~) => assert_eq(snapshot.revision, 2)
        other => fail("expected Replaced, got \{repr(other)}")
      }
    }
    Err(error) => fail("changes failed: \{error}")
  }
}

///|
test "ui_runtime/baseline_and_cursor_handoff_loses_nothing" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  ignore(board.publish(draft=board_draft(key="one")))
  let cut = match host.snapshot() {
    Ok(value) => value
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(cut.resources.length(), 1)
  // Every change accepted after the cut is reachable from its cursor.
  ignore(board.publish(draft=board_draft(key="two")))
  ignore(
    board.replace(draft=board_draft(key="one", revision_note="v2"), expected=1),
  )
  match host.changes_since(cursor=cut.cursor) {
    Ok(changes) => {
      assert_eq(changes.changes.length(), 2)
      match changes.changes[0] {
        Published(snapshot~) => assert_eq(snapshot.resource.key, "two")
        other => fail("expected Published(two), got \{repr(other)}")
      }
      match changes.changes[1] {
        Replaced(snapshot~) => assert_eq(snapshot.revision, 2)
        other => fail("expected Replaced(one), got \{repr(other)}")
      }
      let empty = match host.changes_since(cursor=changes.cursor) {
        Ok(value) => value
        Err(error) => fail("changes failed: \{error}")
      }
      assert_eq(empty.changes.length(), 0)
    }
    Err(error) => fail("changes failed: \{error}")
  }
}

///|
test "ui_runtime/stale_revision_is_rejected_and_changes_nothing" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  ignore(board.publish(draft=board_draft(key="board")))
  let result = board.replace(
    draft=board_draft(key="board", revision_note="v2"),
    expected=7,
  )
  match result {
    Err(@port.UiResourceError::StaleRevision(expected~, actual~)) => {
      assert_eq(expected, 7)
      assert_eq(actual, 1)
    }
    Ok(_) => fail("expected a stale revision rejection")
    Err(other) => fail("expected StaleRevision, got \{other}")
  }
  match runtime.host().snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.resources.length(), 1)
      assert_eq(baseline.resources[0].revision, 1)
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
}

///|
test "ui_runtime/withdraw_is_explicit_and_revisions_never_rewind" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let reference = published_ref(board.publish(draft=board_draft(key="board")))
  match board.remove(resource=reference) {
    Ok(revision) => assert_eq(revision, 1)
    Err(error) => fail("remove failed: \{error}")
  }
  match board.remove(resource=reference) {
    Err(@port.UiResourceError::NotFound(owner~, key~)) => {
      assert_eq(owner, "board")
      assert_eq(key, "board")
    }
    Ok(_) => fail("expected the second withdrawal to be NotFound")
    Err(other) => fail("expected NotFound, got \{other}")
  }
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
  // The tombstone keeps the sequence: a re-publish does not restart at 1.
  let again = match board.publish(draft=board_draft(key="board")) {
    Ok(snapshot) => snapshot
    Err(error) => fail("publish failed: \{error}")
  }
  assert_eq(again.revision, 2)
  match
    host.changes_since(cursor={ generation: runtime.generation(), seq: 0, }) {
    Ok(changes) => {
      assert_eq(changes.changes.length(), 3)
      match changes.changes[1] {
        Withdrawn(owner~, key~, revision~) => {
          assert_eq(owner, "board")
          assert_eq(key, "board")
          assert_eq(revision, 1)
        }
        other => fail("expected Withdrawn, got \{repr(other)}")
      }
    }
    Err(error) => fail("changes failed: \{error}")
  }
}

///|
test "ui_runtime/old_generation_ref_is_never_accepted" {
  let previous = UiRuntime()
  let current = UiRuntime()
  let old_ref = published_ref(
    previous.capability("board").publish(draft=board_draft(key="board")),
  )
  let board = current.capability("board")
  ignore(board.publish(draft=board_draft(key="board")))
  assert_true(old_ref.generation != current.generation())
  match board.remove(resource=old_ref) {
    Err(@port.UiResourceError::NotFound(owner~, key~)) => {
      assert_eq(owner, "board")
      assert_eq(key, "board")
    }
    Ok(_) => fail("expected the stale generation ref to be rejected")
    Err(other) => fail("expected NotFound, got \{other}")
  }
}

///|
test "ui_runtime/foreign_cursor_requires_a_fresh_snapshot" {
  let previous = UiRuntime()
  let current = UiRuntime()
  let host = current.host()
  ignore(current.capability("board").publish(draft=board_draft(key="board")))
  let foreign = match previous.host().snapshot() {
    Ok(value) => value
    Err(error) => fail("snapshot failed: \{error}")
  }
  match host.changes_since(cursor=foreign.cursor) {
    Err(@port.UiResourceError::SnapshotRequired(reason=_)) => ()
    Ok(_) => fail("expected SnapshotRequired for a foreign generation cursor")
    Err(other) => fail("expected SnapshotRequired, got \{other}")
  }
}

///|
test "ui_runtime/cursor_outside_the_window_requires_a_snapshot" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let cut = match host.snapshot() {
    Ok(value) => value
    Err(error) => fail("snapshot failed: \{error}")
  }
  // Overflow the bounded window so the original cursor falls out of it.
  for index in 0..<80 {
    ignore(board.publish(draft=board_draft(key="resource-\{index}")))
  }
  match host.changes_since(cursor=cut.cursor) {
    Err(@port.UiResourceError::SnapshotRequired(reason=_)) => ()
    Ok(_) => fail("expected SnapshotRequired for an expired cursor")
    Err(other) => fail("expected SnapshotRequired, got \{other}")
  }
  // A fresh baseline is the documented recovery path.
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 80)
    Err(error) => fail("snapshot failed: \{error}")
  }
}

///|
test "ui_runtime/custom_body_is_deep_copied_on_both_sides" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let payload = Json::object(Map::from_array([("count", Json::number(1.0))]))
  let draft = @port.UiResourceDraft::new(
    key="opaque",
    kind=@port.UiResourceKind::custom(namespace_="board", name="waveform"),
    body=@port.UiResourceBody::Custom(payload),
  )
  ignore(board.publish(draft~))
  // The publisher mutating its own Json after publishing cannot reach the
  // stored revision.
  match payload {
    Object(fields) => fields["count"] = Json::number(99.0)
    _ => fail("expected an object payload")
  }
  let first = match host.snapshot() {
    Ok(baseline) => baseline.resources[0]
    Err(error) => fail("snapshot failed: \{error}")
  }
  match first.body {
    Custom(stored) =>
      assert_eq(
        stored,
        Json::object(Map::from_array([("count", Json::number(1.0))])),
      )
    other => fail("expected a Custom body, got \{repr(other)}")
  }
  // And a reader mutating the value it received cannot reach live state.
  match first.body {
    Custom(reader_view) =>
      match reader_view {
        Object(fields) => fields["count"] = Json::number(7.0)
        _ => fail("expected an object payload")
      }
    _ => fail("expected a Custom body")
  }
  let second = match host.snapshot() {
    Ok(baseline) => baseline.resources[0]
    Err(error) => fail("snapshot failed: \{error}")
  }
  match second.body {
    Custom(stored) =>
      assert_eq(
        stored,
        Json::object(Map::from_array([("count", Json::number(1.0))])),
      )
    other => fail("expected a Custom body, got \{repr(other)}")
  }
}

///|
test "ui_runtime/invalid_drafts_and_deferred_lifetimes_are_explicit" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let empty_key = @port.UiResourceDraft::new(
    key="",
    kind=@port.UiResourceKind::standard(name="task_board"),
    body=@port.UiResourceBody::Text("body"),
  )
  match board.publish(draft=empty_key) {
    Err(@port.UiResourceError::InvalidInput(reason=_)) => ()
    Ok(_) => fail("expected an empty key to be rejected")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  let reserved_body = @port.UiResourceDraft::new(
    key="opaque",
    kind=@port.UiResourceKind::standard(name="opaque"),
    body=@port.UiResourceBody::Custom(Json::null()),
  )
  match board.publish(draft=reserved_body) {
    Err(@port.UiResourceError::InvalidInput(reason=_)) => ()
    Ok(_) =>
      fail("expected a Custom body in the posoco namespace to be rejected")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  let session_scoped = @port.UiResourceDraft::new(
    key="board",
    kind=@port.UiResourceKind::standard(name="task_board"),
    body=@port.UiResourceBody::Text("body"),
    scope=@port.UiResourceScope::SessionScope(id="session_1"),
    lifetime=@port.UiResourceLifetime::SessionBound,
  )
  match board.publish(draft=session_scoped) {
    Err(@port.UiResourceError::Unsupported(feature~)) =>
      assert_true(feature.contains("session"))
    Ok(_) => fail("expected an unimplemented lifetime to be refused")
    Err(other) => fail("expected Unsupported, got \{other}")
  }
  let duplicate_actions = @port.UiResourceDraft::new(
    key="board",
    kind=@port.UiResourceKind::standard(name="task_board"),
    body=@port.UiResourceBody::Text("body"),
    actions=[
      { id: "a", label: "A", payload: @port.UiActionPayloadKind::NoPayload, },
      {
        id: "a",
        label: "A again",
        payload: @port.UiActionPayloadKind::NoPayload,
      },
    ],
  )
  match board.publish(draft=duplicate_actions) {
    Err(@port.UiResourceError::InvalidInput(reason=_)) => ()
    Ok(_) => fail("expected duplicate action ids to be rejected")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
}

///|
async test "ui_runtime/action_routes_back_to_the_owner_handler" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let calls : Ref[Int32] = Ref(0)
  let draft = @port.UiResourceDraft::new(
    key="board",
    kind=@port.UiResourceKind::standard(name="task_board"),
    body=@port.UiResourceBody::Text("v1"),
    actions=[marked_done_action()],
  )
  let reference = published_ref(board.publish(draft~))
  let install = board.set_action_handler(handler=invocation => {
    calls.val = calls.val + 1
    let updated = @port.UiResourceDraft::new(
      key=invocation.resource.key,
      kind=@port.UiResourceKind::standard(name="task_board"),
      body=@port.UiResourceBody::Text("done"),
      actions=[marked_done_action()],
    )
    // The owner re-checks the live revision, so a late completion cannot
    // overwrite newer content.
    match board.replace(draft=updated, expected=invocation.revision) {
      Ok(_) => Ok(())
      Err(error) => Err(error.to_string())
    }
  })
  match install {
    Ok(_) => ()
    Err(error) => fail("handler install failed: \{error}")
  }
  let request : @port.UiActionRequest = {
    resource: reference,
    action: "mark_done",
    expected_revision: 1,
    request_id: "req-1",
    payload: Some(Json::object(Map::from_array([("task", Json::string("t1"))]))),
  }
  match host.dispatch(request~) {
    Ok(result) => {
      assert_eq(result.revision, 1)
      assert_false(result.replayed)
      assert_eq(result.request_id, "req-1")
    }
    Err(error) => fail("dispatch failed: \{error}")
  }
  assert_eq(calls.val, 1)
  // The accepted action is observed as a resource change, not in the receipt.
  match
    host.changes_since(cursor={ generation: runtime.generation(), seq: 0, }) {
    Ok(changes) => {
      assert_eq(changes.changes.length(), 2)
      match changes.changes[1] {
        Replaced(snapshot~) => {
          assert_eq(snapshot.revision, 2)
          assert_eq(snapshot.body, @port.UiResourceBody::Text("done"))
        }
        other => fail("expected Replaced after the action, got \{repr(other)}")
      }
    }
    Err(error) => fail("changes failed: \{error}")
  }
  // Same request id, same content: the stored receipt is replayed.
  match host.dispatch(request~) {
    Ok(result) => assert_true(result.replayed)
    Err(error) => fail("replay failed: \{error}")
  }
  assert_eq(calls.val, 1)
}

///|
async test "ui_runtime/action_rejections_are_typed_and_do_not_run_handlers" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let calls : Ref[Int32] = Ref(0)
  let draft = @port.UiResourceDraft::new(
    key="board",
    kind=@port.UiResourceKind::standard(name="task_board"),
    body=@port.UiResourceBody::Text("v1"),
    actions=[
      marked_done_action(),
      {
        id: "dismiss",
        label: "Dismiss",
        payload: @port.UiActionPayloadKind::NoPayload,
      },
    ],
  )
  let reference = published_ref(board.publish(draft~))
  ignore(
    board.set_action_handler(handler=_invocation => {
      calls.val = calls.val + 1
      Ok(())
    }),
  )
  let base : @port.UiActionRequest = {
    resource: reference,
    action: "mark_done",
    expected_revision: 1,
    request_id: "req-a",
    payload: Some(Json::object(Map::from_array([]))),
  }
  // Stale revision.
  match host.dispatch(request={ ..base, expected_revision: 5, }) {
    Err(@port.UiResourceError::StaleRevision(expected~, actual~)) => {
      assert_eq(expected, 5)
      assert_eq(actual, 1)
    }
    Ok(_) => fail("expected a stale revision rejection")
    Err(other) => fail("expected StaleRevision, got \{other}")
  }
  // Undeclared action.
  match host.dispatch(request={ ..base, action: "delete_everything", }) {
    Err(@port.UiResourceError::InvalidInput(reason=_)) => ()
    Ok(_) => fail("expected an undeclared action to be rejected")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  // Declared payload shape is enforced.
  match host.dispatch(request={ ..base, payload: None, }) {
    Err(@port.UiResourceError::InvalidInput(reason=_)) => ()
    Ok(_) => fail("expected a missing required payload to be rejected")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  match host.dispatch(request={ ..base, action: "dismiss", }) {
    Err(@port.UiResourceError::InvalidInput(reason=_)) => ()
    Ok(_) => fail("expected a payload on a no-payload action to be rejected")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  // A withdrawn resource is no longer addressable.
  ignore(board.remove(resource=reference))
  match host.dispatch(request=base) {
    Err(@port.UiResourceError::NotFound(owner~, key~)) => {
      assert_eq(owner, "board")
      assert_eq(key, "board")
    }
    Ok(_) => fail("expected a withdrawn resource to be NotFound")
    Err(other) => fail("expected NotFound, got \{other}")
  }
  assert_eq(calls.val, 0)
}

///|
async test "ui_runtime/duplicate_request_id_with_new_content_conflicts" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let draft = @port.UiResourceDraft::new(
    key="board",
    kind=@port.UiResourceKind::standard(name="task_board"),
    body=@port.UiResourceBody::Text("v1"),
    actions=[marked_done_action()],
  )
  let reference = published_ref(board.publish(draft~))
  ignore(board.set_action_handler(handler=_invocation => Ok(())))
  let request : @port.UiActionRequest = {
    resource: reference,
    action: "mark_done",
    expected_revision: 1,
    request_id: "req-x",
    payload: Some(Json::object(Map::from_array([("task", Json::string("t1"))]))),
  }
  match host.dispatch(request~) {
    Ok(_) => ()
    Err(error) => fail("dispatch failed: \{error}")
  }
  // A new resource revision with the same request id is a different request.
  ignore(
    board.replace(
      draft={ ..draft, body: @port.UiResourceBody::Text("v2"), },
      expected=1,
    ),
  )
  let conflicting : @port.UiActionRequest = {
    ..request,
    expected_revision: 2,
    payload: Some(Json::object(Map::from_array([("task", Json::string("t2"))]))),
  }
  match host.dispatch(request=conflicting) {
    Err(@port.UiResourceError::Conflict(reason~)) =>
      assert_true(reason.contains("req-x"))
    Ok(_) => fail("expected a conflicting request id to be rejected")
    Err(other) => fail("expected Conflict, got \{other}")
  }
}

///|
async test "ui_runtime/handler_failures_and_missing_handlers_are_reported" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let draft = @port.UiResourceDraft::new(
    key="board",
    kind=@port.UiResourceKind::standard(name="task_board"),
    body=@port.UiResourceBody::Text("v1"),
    actions=[marked_done_action()],
  )
  let reference = published_ref(board.publish(draft~))
  let base : @port.UiActionRequest = {
    resource: reference,
    action: "mark_done",
    expected_revision: 1,
    request_id: "req-1",
    payload: Some(Json::object(Map::from_array([]))),
  }
  // Declared action but no handler installed: loud, not silent, and not cached
  // because no owner code ran.
  match host.dispatch(request=base) {
    Err(@port.UiResourceError::HandlerFailed(detail~)) =>
      assert_true(detail.contains("no action handler"))
    Ok(_) => fail("expected a missing handler to fail loudly")
    Err(other) => fail("expected HandlerFailed, got \{other}")
  }
  // A handler that reports failure, under a fresh request id.
  ignore(
    board.set_action_handler(handler=_invocation => Err("cannot mark done")),
  )
  match host.dispatch(request={ ..base, request_id: "req-fail", }) {
    Err(@port.UiResourceError::HandlerFailed(detail~)) =>
      assert_eq(detail, "cannot mark done")
    Ok(_) => fail("expected the handler failure to be reported")
    Err(other) => fail("expected HandlerFailed, got \{other}")
  }
  // A handler that raises.
  ignore(
    board.set_action_handler(handler=_invocation => {
      fail("boom")
      Ok(())
    }),
  )
  match host.dispatch(request={ ..base, request_id: "req-raise", }) {
    Err(@port.UiResourceError::HandlerFailed(detail~)) =>
      assert_true(detail.contains("boom"))
    Ok(_) => fail("expected the raised handler error to be reported")
    Err(other) => fail("expected HandlerFailed, got \{other}")
  }
}

///|
async test "ui_runtime/shutdown_closes_capabilities_and_the_host_feed" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let reference = published_ref(board.publish(draft=board_draft(key="board")))
  runtime.close()
  assert_true(runtime.is_closed())
  assert_eq(
    board.publish(draft=board_draft(key="board")),
    Err(@port.UiResourceError::Closed),
  )
  assert_eq(
    board.replace(draft=board_draft(key="board"), expected=1),
    Err(@port.UiResourceError::Closed),
  )
  assert_eq(
    board.remove(resource=reference),
    Err(@port.UiResourceError::Closed),
  )
  assert_eq(
    board.set_action_handler(handler=_invocation => Ok(())),
    Err(@port.UiResourceError::Closed),
  )
  assert_eq(host.snapshot(), Err(@port.UiResourceError::Closed))
  assert_eq(
    host.changes_since(cursor={ generation: runtime.generation(), seq: 0, }),
    Err(@port.UiResourceError::Closed),
  )
  let request : @port.UiActionRequest = {
    resource: reference,
    action: "mark_done",
    expected_revision: 1,
    request_id: "req-1",
    payload: None,
  }
  assert_eq(host.dispatch(request~), Err(@port.UiResourceError::Closed))
}

///|
test "ui_runtime/published_snapshot_is_a_copy_not_the_live_state" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let payload = Json::object(Map::from_array([("count", Json::number(1.0))]))
  let draft = @port.UiResourceDraft::new(
    key="opaque",
    kind=@port.UiResourceKind::custom(namespace_="board", name="waveform"),
    body=@port.UiResourceBody::Custom(payload),
    actions=[marked_done_action()],
  )
  let published = match board.publish(draft~) {
    Ok(snapshot) => snapshot
    Err(error) => abort("publish failed: \{error}")
  }
  // The publisher mutating the snapshot it received must not reach live state.
  match published.body {
    Custom(owned) =>
      match owned {
        Object(fields) => fields["count"] = Json::number(42.0)
        _ => fail("expected an object payload")
      }
    _ => fail("expected a Custom body")
  }
  published.actions.push({
    id: "injected",
    label: "Injected",
    payload: @port.UiActionPayloadKind::NoPayload,
  })
  let live = match host.snapshot() {
    Ok(baseline) => baseline.resources[0]
    Err(error) => fail("snapshot failed: \{error}")
  }
  match live.body {
    Custom(stored) =>
      assert_eq(
        stored,
        Json::object(Map::from_array([("count", Json::number(1.0))])),
      )
    other => fail("expected a Custom body, got \{repr(other)}")
  }
  assert_eq(live.actions.length(), 1)
  assert_eq(live.actions[0].id, "mark_done")
}

///|
async test "ui_runtime/receipt_keeps_a_payload_snapshot" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let draft = @port.UiResourceDraft::new(
    key="board",
    kind=@port.UiResourceKind::standard(name="task_board"),
    body=@port.UiResourceBody::Text("v1"),
    actions=[marked_done_action()],
  )
  let reference = published_ref(board.publish(draft~))
  ignore(board.set_action_handler(handler=_invocation => Ok(())))
  let payload = Json::object(Map::from_array([("note", Json::string("a"))]))
  let request : @port.UiActionRequest = {
    resource: reference,
    action: "mark_done",
    expected_revision: 1,
    request_id: "req-1",
    payload: Some(payload),
  }
  match host.dispatch(request~) {
    Ok(_) => ()
    Err(error) => fail("dispatch failed: \{error}")
  }
  // The caller rewrites its own payload after the fact; the stored receipt must
  // still describe what was accepted, so the same id with new content conflicts
  // instead of being replayed as if it were the same request.
  match payload {
    Object(fields) => fields["note"] = Json::string("b")
    _ => fail("expected an object payload")
  }
  match host.dispatch(request~) {
    Err(@port.UiResourceError::Conflict(reason~)) =>
      assert_true(reason.contains("req-1"))
    Ok(_) => fail("expected the rewritten payload to conflict")
    Err(other) => fail("expected Conflict, got \{other}")
  }
}

///|
async test "ui_runtime/in_flight_request_id_is_never_run_twice" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let calls : Ref[Int32] = Ref(0)
  let reentrant : Ref[Result[@port.UiActionResult, @port.UiResourceError]?] = Ref(
    None,
  )
  let draft = @port.UiResourceDraft::new(
    key="board",
    kind=@port.UiResourceKind::standard(name="task_board"),
    body=@port.UiResourceBody::Text("v1"),
    actions=[marked_done_action()],
  )
  let reference = published_ref(board.publish(draft~))
  let request : @port.UiActionRequest = {
    resource: reference,
    action: "mark_done",
    expected_revision: 1,
    request_id: "req-1",
    payload: Some(Json::object(Map::from_array([]))),
  }
  ignore(
    board.set_action_handler(handler=_invocation => {
      calls.val = calls.val + 1
      // A re-entrant dispatch of the same id while this handler is still
      // running: it must be answered immediately, never awaited.
      reentrant.val = Some(host.dispatch(request~))
      Ok(())
    }),
  )
  match host.dispatch(request~) {
    Ok(result) => assert_false(result.replayed)
    Err(error) => fail("dispatch failed: \{error}")
  }
  assert_eq(calls.val, 1)
  match reentrant.val {
    Some(Err(@port.UiResourceError::InProgress(request_id~))) =>
      assert_eq(request_id, "req-1")
    Some(other) => fail("expected InProgress, got \{repr(other)}")
    None => fail("expected the re-entrant dispatch to be attempted")
  }
  // Once settled, the same id replays instead of running again.
  match host.dispatch(request~) {
    Ok(result) => {
      assert_true(result.replayed)
      assert_eq(result.revision, 1)
    }
    Err(error) => fail("replay failed: \{error}")
  }
  assert_eq(calls.val, 1)
}

///|
async test "ui_runtime/close_does_not_retain_an_in_flight_receipt" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let draft = @port.UiResourceDraft::new(
    key="board",
    kind=@port.UiResourceKind::standard(name="task_board"),
    body=@port.UiResourceBody::Text("v1"),
    actions=[marked_done_action()],
  )
  let reference = published_ref(board.publish(draft~))
  ignore(
    board.set_action_handler(handler=_invocation => {
      // Shutdown lands while the handler is running: the handler is not
      // force-revoked, but the protocol closes underneath it.
      runtime.close()
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
  // The started handler still completes and its outcome reaches the host.
  match host.dispatch(request~) {
    Ok(result) => assert_false(result.replayed)
    Err(error) => fail("expected the started handler to complete, got \{error}")
  }
  assert_true(runtime.is_closed())
  // ... but the closed runtime retains no deduplication state afterwards.
  assert_eq(runtime.receipts.length(), 0)
  assert_eq(board.publish(draft~), Err(@port.UiResourceError::Closed))
  assert_eq(host.snapshot(), Err(@port.UiResourceError::Closed))
}

///|
async test "ui_runtime/owner_and_ref_keys_cannot_alias_another_owner" {
  let runtime = UiRuntime()
  let host = runtime.host()
  // A manifest id carrying the internal key separator could alias another
  // owner's resources, so it is refused instead of being mapped to a key.
  let aliasing = runtime.capability("a\u{0}b")
  match aliasing.publish(draft=board_draft(key="board")) {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("NUL"))
    Ok(_) => fail("expected the owner with NUL to be rejected")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  let board = runtime.capability("board")
  let reference = published_ref(board.publish(draft=board_draft(key="board")))
  // The host cannot smuggle a separator through a ref key either.
  let forged : @port.UiActionRequest = {
    resource: {
      owner: "a\u{0}b",
      key: reference.key,
      generation: runtime.generation(),
    },
    action: "mark_done",
    expected_revision: 1,
    request_id: "req-1",
    payload: None,
  }
  match host.dispatch(request=forged) {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("NUL"))
    Ok(_) => fail("expected the forged owner ref to be rejected")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
}

///|
test "ui_runtime/custom_body_namespace_must_be_the_publisher" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let foreign = @port.UiResourceDraft::new(
    key="opaque",
    kind=@port.UiResourceKind::custom(namespace_="alpha", name="waveform"),
    body=@port.UiResourceBody::Custom(Json::object(Map::from_array([]))),
  )
  match board.publish(draft=foreign) {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("board"))
    Ok(_) => fail("expected a foreign namespace to be rejected")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  let own = @port.UiResourceDraft::new(
    key="opaque",
    kind=@port.UiResourceKind::custom(namespace_="board", name="waveform"),
    body=@port.UiResourceBody::Custom(Json::object(Map::from_array([]))),
  )
  match board.publish(draft=own) {
    Ok(snapshot) => assert_eq(snapshot.revision, 1)
    Err(error) =>
      fail("expected the publisher's own namespace to be accepted: \{error}")
  }
}

///|
async test "ui_runtime/cancelled_dispatch_releases_its_reservation" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let started : Ref[Bool] = Ref(false)
  let draft = @port.UiResourceDraft::new(
    key="board",
    kind=@port.UiResourceKind::standard(name="task_board"),
    body=@port.UiResourceBody::Text("v1"),
    actions=[marked_done_action()],
  )
  let reference = published_ref(board.publish(draft~))
  ignore(
    board.set_action_handler(handler=_invocation => {
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
    let mut waited = 0
    while !started.val && waited < 1_000 {
      @async.sleep(1)
      waited = waited + 1
    }
    task.cancel()
  })
  // Cancellation interrupted the dispatch before it settled: the reservation is
  // gone instead of leaving the id permanently `InProgress`.
  assert_true(runtime.receipts.get("req-1") is None)
  ignore(board.set_action_handler(handler=_invocation => Ok(())))
  match host.dispatch(request~) {
    Ok(result) => assert_false(result.replayed)
    Err(error) => fail("expected the retry to run the handler, got \{error}")
  }
}

///|
/// The receipt map and its window order agree, always: no id is ordered without
/// a receipt, and no receipt lives outside the window.
fn ui_assert_receipt_window_consistent(runtime : UiRuntime) -> Unit raise {
  assert_eq(runtime.receipt_order.length(), runtime.receipts.length())
  for id in runtime.receipt_order {
    match runtime.receipts.get(id) {
      Some(_) => ()
      None => fail("the receipt window orders \{id} without a receipt")
    }
  }
}

///|
/// A cancelled dispatch releases its reservation *and* its window slot. Order
/// entries for ids that never settled would otherwise evict still-valid
/// receipts ahead of them, turning a replay into a second handler run.
async test "ui_runtime/cancelled_dispatch_leaves_no_receipt_window_residue" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let runs : Map[String, Int32] = Map::from_array([])
  let parked : Ref[Int32] = Ref(0)
  let draft = @port.UiResourceDraft::new(
    key="board",
    kind=@port.UiResourceKind::standard(name="task_board"),
    body=@port.UiResourceBody::Text("v1"),
    actions=[marked_done_action()],
  )
  let reference = published_ref(board.publish(draft~))
  ignore(
    board.set_action_handler(handler=invocation => {
      ui_count_run(runs, invocation.request_id)
      Ok(())
    }),
  )
  let accepted : @port.UiActionRequest = {
    resource: reference,
    action: "mark_done",
    expected_revision: 1,
    request_id: "req-a",
    payload: Some(Json::object(Map::from_array([]))),
  }
  match host.dispatch(request=accepted) {
    Ok(result) => assert_false(result.replayed)
    Err(error) => fail("the first accepted dispatch failed: \{error}")
  }
  ui_assert_receipt_window_consistent(runtime)
  // Each cancelled attempt must leave the window exactly as it found it: the
  // in-flight reservation is visible while the handler is parked, and gone from
  // both the map and the order afterwards.
  ignore(
    board.set_action_handler(handler=invocation => {
      ui_count_run(runs, invocation.request_id)
      parked.val = parked.val + 1
      @async.sleep(60_000)
      Ok(())
    }),
  )
  @async.with_task_group(async fn(group) {
    for index in 0..<(ui_receipt_window - 1) {
      let id = "park-\{index}"
      let request : @port.UiActionRequest = {
        resource: reference,
        action: "mark_done",
        expected_revision: 1,
        request_id: id,
        payload: Some(Json::object(Map::from_array([]))),
      }
      let started = parked.val
      let task = group.spawn(async fn() { ignore(host.dispatch(request~)) })
      ui_wait_until(fn() { parked.val > started })
      match runtime.receipts.get(id) {
        Some(entry) => assert_true(entry.outcome is None)
        None => fail("the in-flight reservation \{id} is not in the window")
      }
      task.cancel()
      ui_wait_until(fn() { runtime.receipts.get(id) is None })
      ui_assert_receipt_window_consistent(runtime)
    }
  })
  ignore(
    board.set_action_handler(handler=invocation => {
      ui_count_run(runs, invocation.request_id)
      Ok(())
    }),
  )
  let fresh : @port.UiActionRequest = {
    resource: reference,
    action: "mark_done",
    expected_revision: 1,
    request_id: "req-b",
    payload: Some(Json::object(Map::from_array([]))),
  }
  match host.dispatch(request=fresh) {
    Ok(result) => assert_false(result.replayed)
    Err(error) => fail("the fresh dispatch failed: \{error}")
  }
  ui_assert_receipt_window_consistent(runtime)
  // The cancelled attempts did not crowd the accepted receipt out: the retry is
  // a replay, and the handler does not run a second time.
  match host.dispatch(request=accepted) {
    Ok(result) => assert_true(result.replayed)
    Err(error) =>
      fail("a cancelled attempt evicted the accepted receipt: \{error}")
  }
  match runs.get("req-a") {
    Some(count) => assert_eq(count, 1)
    None => fail("the accepted handler never ran")
  }
}
