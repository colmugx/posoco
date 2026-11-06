///|
/// Contract tests for the operation-owned resource lifetime: where an
/// `OperationBound` resource may be created and what settlement reclaims.
/// Whitebox (same package); the full admission/release lifecycle lives in the
/// root black-box suite.

///|
fn operation_panel(
  key~ : String,
  note~ : String = "transient",
) -> @port.UiResourceDraft {
  @port.UiResourceDraft::new(
    key~,
    kind=@port.UiResourceKind::standard(name="operation_panel"),
    body=@port.UiResourceBody::Text(note),
    scope=@port.UiResourceScope::OperationScope(id="operation"),
    lifetime=@port.UiResourceLifetime::OperationBound,
  )
}

///|
/// The error a refused capability acquisition reports. `UiResources` carries
/// callbacks, so the value itself is not comparable; only the failure is.
fn operation_error(
  result : Result[@port.UiResources, @port.UiResourceError],
) -> @port.UiResourceError {
  match result {
    Ok(_) => abort("expected the operation capability to be refused")
    Err(error) => error
  }
}

///|
fn operation_handle(board : @port.UiResources) -> @port.UiResources {
  match board.operation() {
    Ok(handle) => handle
    Err(error) => abort("expected an operation handle, got \{error}")
  }
}

///|
fn settled_labels(
  host : @port.UiHost,
  cursor : @port.UiCursor,
) -> Array[String] {
  match host.changes_since(cursor~) {
    Ok(changes) =>
      changes.changes.map(fn(change) {
        match change {
          Published(_) => "published"
          Replaced(_) => "replaced"
          Withdrawn(..) => "withdrawn"
        }
      })
    Err(error) => abort("changes failed: \{error}")
  }
}

///|
test "ui_operation/operation_bound_resources_are_reclaimed_on_settlement" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let delivered : Array[String] = []
  let observation = ui_subscribe_or_abort(
    host,
    fn(batch) {
      delivered.push(ui_observed_label(batch))
      Ok(())
    },
    fn(_failure) { abort("unexpected listener failure") },
  )
  ignore(runtime.begin_operation("op-1"))
  let handle = operation_handle(board)
  let transient = published_ref(
    handle.publish(draft=operation_panel(key="progress")),
  )
  // The final result card is published through the owner capability and is not
  // operation-scoped.
  let final_card = published_ref(board.publish(draft=board_draft(key="result")))
  assert_eq(observation.baseline.resources.length(), 0)
  assert_eq(delivered, ["1:published", "2:published"])
  match host.snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.resources.length(), 2)
      assert_eq(delivered.length(), 2)
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
  runtime.settle_operation("op-1")
  // Reclaim is delivered through the ordinary feed, once, in publish order.
  assert_eq(delivered, ["1:published", "2:published", "3:withdrawn"])
  match host.snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.resources.length(), 1)
      assert_eq(baseline.resources[0].resource, final_card)
      assert_eq(
        baseline.resources[0].lifetime,
        @port.UiResourceLifetime::OwnerBound,
      )
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
  // Pull agrees with push: the same cut reaches the same three changes.
  match host.changes_since(cursor=observation.baseline.cursor) {
    Ok(changes) => {
      assert_eq(changes.changes.length(), 3)
      match changes.changes[2] {
        Withdrawn(owner~, key~, revision~) => {
          assert_eq(owner, "board")
          assert_eq(key, transient.key)
          assert_eq(revision, 1)
        }
        other => fail("expected Withdrawn, got \{repr(other)}")
      }
    }
    Err(error) => abort("changes failed: \{error}")
  }
  assert_eq(runtime.current_operation(), None)
}

///|
test "ui_operation/creating_a_transient_resource_needs_an_admitted_operation" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  // Without an admitted operation there is no handle to capture ...
  match board.operation() {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("operation"))
    Ok(_) => fail("expected no operation handle outside an operation")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  // ... and the owner capability refuses to invent the promise.
  match board.publish(draft=operation_panel(key="progress")) {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("UiResources::operation"))
    Ok(_) => fail("expected an operation lifetime to be refused off-operation")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  // Session cleanup is still unimplemented, and says so.
  let session_draft = @port.UiResourceDraft::new(
    key="session_panel",
    kind=@port.UiResourceKind::standard(name="operation_panel"),
    body=@port.UiResourceBody::Text("body"),
    scope=@port.UiResourceScope::SessionScope(id="session_1"),
    lifetime=@port.UiResourceLifetime::SessionBound,
  )
  match board.publish(draft=session_draft) {
    Err(@port.UiResourceError::Unsupported(feature~)) =>
      assert_true(feature.contains("session"))
    Ok(_) => fail("expected SessionBound to stay unsupported")
    Err(other) => fail("expected Unsupported, got \{other}")
  }
  // After settlement the handle is gone, not silently re-armed.
  ignore(runtime.begin_operation("op-1"))
  let handle = operation_handle(board)
  runtime.settle_operation("op-1")
  match handle.publish(draft=operation_panel(key="progress")) {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("op-1"))
    Ok(_) => fail("expected a settled operation handle to be refused")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  match handle.operation() {
    Err(@port.UiResourceError::InvalidInput(_)) => ()
    Ok(_) => fail("expected re-acquisition through a stale handle to fail")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  match handle.set_action_handler(handler=_invocation => Ok(())) {
    Err(@port.UiResourceError::InvalidInput(_)) => ()
    Ok(_) => fail("expected a stale handle to refuse handler installation")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  // The owner capability keeps working: the handler slot belongs to the owner.
  match board.set_action_handler(handler=_invocation => Ok(())) {
    Ok(_) => ()
    Err(error) =>
      fail("expected the owner capability to install a handler: \{error}")
  }
}

///|
test "ui_operation/a_stale_handle_is_refused_instead_of_rebinding" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  ignore(runtime.begin_operation("op-1"))
  let stale = operation_handle(board)
  let first = match stale.publish(draft=operation_panel(key="progress")) {
    Ok(snapshot) => snapshot
    Err(error) => abort("publish failed: \{error}")
  }
  runtime.settle_operation("op-1")
  // The next operation is a different binding: the old handle must not slip
  // its late work into it.
  ignore(runtime.begin_operation("op-2"))
  let fresh = operation_handle(board)
  match stale.publish(draft=operation_panel(key="progress", note="late")) {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("op-1"))
    Ok(_) => fail("expected the stale handle to be refused inside op-2")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  // Re-acquiring from a handle keeps its own binding: it must not capture the
  // operation that happens to be live now.
  match stale.operation() {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("op-1"))
    Ok(rebound) => {
      ignore(rebound)
      fail("expected the stale handle not to re-capture op-2")
    }
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  match stale.set_action_handler(handler=_invocation => Ok(())) {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("op-1"))
    Ok(_) => fail("expected the stale handle not to reach the owner slot")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  // Re-acquiring inside the operation it owns is allowed and stays bound to it.
  let same = operation_handle(fresh)
  match same.publish(draft=operation_panel(key="same-op")) {
    Ok(snapshot) =>
      assert_eq(snapshot.lifetime, @port.UiResourceLifetime::OperationBound)
    Err(error) => fail("expected a same-operation handle to publish: \{error}")
  }
  // The same key in the new operation is a different resource generation of
  // the revision counter: no ABA through an old ref/revision.
  let second = match fresh.publish(draft=operation_panel(key="progress")) {
    Ok(snapshot) => snapshot
    Err(error) => fail("publish failed: \{error}")
  }
  assert_eq(second.revision, first.revision + 1)
  assert_eq(second.resource, first.resource)
  match
    fresh.replace(
      draft=operation_panel(key="progress", note="cas"),
      expected=first.revision,
    ) {
    Err(@port.UiResourceError::StaleRevision(expected~, actual~)) => {
      assert_eq(expected, first.revision)
      assert_eq(actual, second.revision)
    }
    Ok(_) => fail("expected the pre-settlement revision to be stale")
    Err(other) => fail("expected StaleRevision, got \{other}")
  }
  // The fresh handle only sees resources it owns.
  match
    fresh.remove(
      resource=published_ref(board.publish(draft=board_draft(key="result"))),
    ) {
    Err(@port.UiResourceError::NotFound(owner~, key~)) => {
      assert_eq(owner, "board")
      assert_eq(key, "result")
    }
    Ok(_) => fail("expected an owner-bound resource to be invisible")
    Err(other) => fail("expected NotFound, got \{other}")
  }
  runtime.settle_operation("op-2")
  match runtime.host().snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 1)
    Err(error) => fail("snapshot failed: \{error}")
  }
}

///|
test "ui_operation/reclaim_delivery_cannot_revive_the_operation" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  ignore(runtime.begin_operation("op-1"))
  let handle = operation_handle(board)
  ignore(handle.publish(draft=operation_panel(key="progress")))
  // A listener that reacts to its own resource disappearing must not be able
  // to publish back into the operation that just settled.
  let revivals : Array[String] = []
  let nested = Ref(false)
  let observation = ui_subscribe_or_abort(
    host,
    fn(batch) {
      if nested.val {
        return Ok(())
      }
      match batch.change {
        Resource(change~) =>
          match change {
            Withdrawn(..) => {
              nested.val = true
              match handle.publish(draft=operation_panel(key="progress")) {
                Ok(_) => revivals.push("published")
                Err(error) => revivals.push(error.to_string())
              }
              match handle.operation() {
                Ok(_) => revivals.push("handle")
                Err(error) => revivals.push(error.to_string())
              }
            }
            _ => ()
          }
        Interaction(_) => ()
      }
      Ok(())
    },
    fn(failure) { abort("unexpected listener failure: \{failure.detail}") },
  )
  runtime.settle_operation("op-1")
  let expected = [
    "UiResourceError::InvalidInput(operation op-1 is no longer admitted; an operation-bound UI capability never outlives its operation)",
    "UiResourceError::InvalidInput(operation op-1 is no longer admitted; an operation-bound UI capability never outlives its operation)",
  ]
  assert_eq(revivals, expected)
  // Re-entrant publication changed nothing: the operation still has no live
  // resource and no second change was appended.
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(settled_labels(host, observation.baseline.cursor), ["withdrawn"])
}

///|
test "ui_operation/replacement_cannot_change_lifetime_or_operation" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  ignore(runtime.begin_operation("op-1"))
  let handle = operation_handle(board)
  let reference = published_ref(
    handle.publish(draft=operation_panel(key="progress")),
  )
  // An operation-owned resource cannot be promoted to an owner-bound card, so
  // a replacement can never escape reclamation.
  match
    handle.replace(
      draft=@port.UiResourceDraft::new(
        key="progress",
        kind=@port.UiResourceKind::standard(name="operation_panel"),
        body=@port.UiResourceBody::Text("promoted"),
      ),
      expected=1,
    ) {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("OperationBound"))
    Ok(_) => fail("expected an operation handle to refuse OwnerBound")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  // Nor can the owner capability take the resource over, by replace or by
  // publish-replaces-in-place.
  match
    board.replace(
      draft=@port.UiResourceDraft::new(
        key="progress",
        kind=@port.UiResourceKind::standard(name="progress_bar"),
        body=@port.UiResourceBody::Text("hijacked"),
      ),
      expected=1,
    ) {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("op-1"))
    Ok(_) => fail("expected an operation-owned resource to be protected")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  match board.publish(draft=board_draft(key="progress")) {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("op-1"))
    Ok(_) => fail("expected publish not to hijack an operation resource")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  // The resource is untouched by either rejected attempt.
  match runtime.host().snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.resources.length(), 1)
      assert_eq(baseline.resources[0].revision, 1)
      assert_eq(
        baseline.resources[0].lifetime,
        @port.UiResourceLifetime::OperationBound,
      )
      assert_eq(baseline.resources[0].resource, reference)
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
  // The owning handle keeps the ordinary replace contract.
  match
    handle.replace(draft=operation_panel(key="progress", note="v2"), expected=1) {
    Ok(snapshot) => assert_eq(snapshot.revision, 2)
    Err(error) => fail("replace failed: \{error}")
  }
  // An owner-bound card cannot be pulled into the operation either.
  let final_card = published_ref(board.publish(draft=board_draft(key="result")))
  match
    handle.publish(
      draft=@port.UiResourceDraft::new(
        key="result",
        kind=@port.UiResourceKind::standard(name="operation_panel"),
        body=@port.UiResourceBody::Text("transient copy"),
        lifetime=@port.UiResourceLifetime::OperationBound,
      ),
    ) {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("OwnerBound"))
    Ok(_) => fail("expected an owner-bound card to stay with the owner")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  match handle.remove(resource=final_card) {
    Err(@port.UiResourceError::NotFound(..)) => ()
    Ok(_) => fail("expected an owner-bound card to be invisible to op-1")
    Err(other) => fail("expected NotFound, got \{other}")
  }
}

///|
test "ui_operation/settlement_is_idempotent_across_every_release_path" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  let cut = match host.snapshot() {
    Ok(value) => value
    Err(error) => fail("snapshot failed: \{error}")
  }
  // Normal settlement.
  ignore(runtime.begin_operation("op-1"))
  ignore(operation_handle(board).publish(draft=operation_panel(key="one")))
  runtime.settle_operation("op-1")
  // A stale release of an operation that is no longer live never touches the
  // next operation's resources.
  ignore(runtime.begin_operation("op-2"))
  ignore(operation_handle(board).publish(draft=operation_panel(key="two")))
  runtime.settle_operation("op-1")
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 1)
    Err(error) => fail("snapshot failed: \{error}")
  }
  // Repeating the real settlement is a no-op, not a second withdrawal.
  runtime.settle_operation("op-2")
  runtime.settle_operation("op-2")
  // Admission rollback takes the same path.
  ignore(runtime.begin_operation("op-3"))
  ignore(operation_handle(board).publish(draft=operation_panel(key="three")))
  runtime.settle_operation("op-3")
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(settled_labels(host, cut.cursor), [
    "published", "withdrawn", "published", "withdrawn", "published", "withdrawn",
  ])
  assert_eq(runtime.current_operation(), None)
}

///|
async test "ui_operation/a_late_action_completion_cannot_publish_back" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  ignore(runtime.begin_operation("op-1"))
  let handle = operation_handle(board)
  let draft = @port.UiResourceDraft::new(
    key="progress",
    kind=@port.UiResourceKind::standard(name="operation_panel"),
    body=@port.UiResourceBody::Text("running"),
    lifetime=@port.UiResourceLifetime::OperationBound,
    actions=[marked_done_action()],
  )
  let reference = published_ref(handle.publish(draft~))
  let late : Ref[Result[@port.UiResourceSnapshot, @port.UiResourceError]?] = Ref(
    None,
  )
  // The handler models an async completion that lands after settlement: it
  // keeps the handle it was given and tries its CAS afterwards.
  ignore(
    handle.set_action_handler(handler=invocation => {
      late.val = Some(
        handle.replace(
          draft=@port.UiResourceDraft::new(
            key=invocation.resource.key,
            kind=@port.UiResourceKind::standard(name="operation_panel"),
            body=@port.UiResourceBody::Text("done"),
            lifetime=@port.UiResourceLifetime::OperationBound,
          ),
          expected=invocation.revision,
        ),
      )
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
  // Accepted while the operation is live: the handler runs and writes back.
  match host.dispatch(request~) {
    Ok(result) => assert_eq(result.revision, 1)
    Err(error) => fail("dispatch failed: \{error}")
  }
  match late.val {
    Some(Ok(snapshot)) => assert_eq(snapshot.revision, 2)
    Some(Err(error)) =>
      fail("expected the in-operation CAS to succeed: \{error}")
    None => fail("expected the handler to run")
  }
  late.val = None
  runtime.settle_operation("op-1")
  // The reclaimed resource is gone for both dispatch and any late CAS.
  match host.dispatch(request={ ..request, request_id: "req-2", }) {
    Err(@port.UiResourceError::NotFound(owner~, key~)) => {
      assert_eq(owner, "board")
      assert_eq(key, "progress")
    }
    Ok(_) => fail("expected a reclaimed resource to be unaddressable")
    Err(other) => fail("expected NotFound, got \{other}")
  }
  ignore(runtime.begin_operation("op-2"))
  ignore(operation_handle(board).publish(draft=operation_panel(key="progress")))
  match
    handle.replace(
      draft=operation_panel(key="progress", note="late"),
      expected=2,
    ) {
    Err(@port.UiResourceError::InvalidInput(reason~)) =>
      assert_true(reason.contains("op-1"))
    Ok(_) => fail("expected the old completion to be refused in op-2")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  match host.snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.resources.length(), 1)
      assert_eq(
        baseline.resources[0].body,
        @port.UiResourceBody::Text("transient"),
      )
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
}

///|
test "ui_operation/withdrawal_reports_validity_not_a_user_decision" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  ignore(runtime.begin_operation("op-1"))
  let handle = operation_handle(board)
  let reference = published_ref(
    handle.publish(draft=operation_panel(key="progress")),
  )
  // An owner may withdraw its own transient resource early; settlement must not
  // report the same resource twice.
  match board.remove(resource=reference) {
    Ok(revision) => assert_eq(revision, 1)
    Err(error) => fail("remove failed: \{error}")
  }
  runtime.settle_operation("op-1")
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(
    settled_labels(host, { generation: runtime.generation(), seq: 0, }),
    ["published", "withdrawn"],
  )
}

///|
test "ui_operation/a_second_window_is_refused_without_touching_the_live_one" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  ignore(runtime.begin_operation("op-1"))
  let first = operation_handle(board)
  ignore(first.publish(draft=operation_panel(key="progress")))
  // Opening a second window is a broken invariant, not a silent takeover.
  match runtime.begin_operation("op-2") {
    Err(@port.UiResourceError::InvalidInput(reason~)) => {
      assert_true(reason.contains("op-1"))
      assert_true(reason.contains("op-2"))
    }
    Ok(_) => fail("expected the second window to be refused")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
  // The incumbent is untouched: same id, its handle still publishes, its
  // resource is still live.
  assert_eq(runtime.current_operation(), Some("op-1"))
  match first.publish(draft=operation_panel(key="progress", note="v2")) {
    Ok(snapshot) => assert_eq(snapshot.revision, 2)
    Err(error) => fail("expected the live operation to keep working: \{error}")
  }
  // The refused admission's own late settlement is a no-op and cannot reclaim
  // the incumbent's resources.
  runtime.settle_operation("op-2")
  assert_eq(runtime.current_operation(), Some("op-1"))
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 1)
    Err(error) => fail("snapshot failed: \{error}")
  }
  runtime.settle_operation("op-1")
  assert_eq(runtime.current_operation(), None)
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
  // A fresh window opens normally afterwards.
  match runtime.begin_operation("op-3") {
    Ok(_) => ()
    Err(error) => fail("expected a fresh window to open: \{error}")
  }
  assert_eq(runtime.current_operation(), Some("op-3"))
}

///|
test "ui_operation/closed_outranks_every_operation_binding" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  ignore(runtime.begin_operation("op-1"))
  let handle = operation_handle(board)
  ignore(handle.publish(draft=operation_panel(key="progress")))
  runtime.close()
  // A closed protocol reports why it is closed, not which operation used to be
  // live — on the owner capability and on the settled handle alike.
  assert_eq(operation_error(board.operation()), @port.UiResourceError::Closed)
  assert_eq(operation_error(handle.operation()), @port.UiResourceError::Closed)
  assert_eq(
    handle.set_action_handler(handler=_invocation => Ok(())),
    Err(@port.UiResourceError::Closed),
  )
  assert_eq(
    handle.publish(draft=operation_panel(key="progress")),
    Err(@port.UiResourceError::Closed),
  )
  assert_eq(
    handle.replace(draft=operation_panel(key="progress"), expected=1),
    Err(@port.UiResourceError::Closed),
  )
  assert_eq(
    board.set_action_handler(handler=_invocation => Ok(())),
    Err(@port.UiResourceError::Closed),
  )
  // Close cleared the window: settlement afterwards is a no-op, not a revive.
  runtime.settle_operation("op-1")
  assert_eq(runtime.current_operation(), None)
}

///|
/// Subscribe one listener that reacts exactly once, so a probe issued from a
/// delivered change cannot re-enter itself forever.
fn probe_once(
  host : @port.UiHost,
  react : (@port.UiChange) -> Unit,
) -> @port.UiObservation {
  let armed = Ref(true)
  ui_subscribe_or_abort(
    host,
    fn(batch) {
      if armed.val {
        armed.val = false
        react(batch.change)
      }
      Ok(())
    },
    fn(failure) { abort("unexpected listener failure: \{failure.detail}") },
  )
}

///|
test "ui_operation/published_listener_can_query_host_support" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  match
    host.connect(
      capabilities=@port.UiHostCapabilities::new(resource_kinds=[
        @port.UiResourceKind::standard(name="operation_panel"),
      ]),
    ) {
    Ok(_) => ()
    Err(error) => abort("connect failed: \{error}")
  }
  ignore(runtime.begin_operation("op-1"))
  let handle = operation_handle(board)
  let support : Array[
    Result[Array[@port.UiHostConnectionSupport], @port.UiResourceError],
  ] = []
  ignore(
    probe_once(host, fn(change) {
      match change {
        Resource(change~) =>
          match change {
            Published(snapshot~) =>
              support.push(handle.host_support(resource=snapshot.resource))
            _ => ()
          }
        Interaction(_) => ()
      }
    }),
  )
  let reference = published_ref(
    handle.publish(draft=operation_panel(key="progress")),
  )
  assert_eq(support.length(), 1)
  match support[0] {
    Ok(reports) => {
      assert_eq(reports.length(), 1)
      assert_eq(reports[0].support, @port.UiHostSupport::Native)
    }
    Err(error) =>
      fail("expected the announced resource to answer support: \{error}")
  }
  // The listener only read: the resource is still live and owned by op-1.
  match host.snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.resources.length(), 1)
      assert_eq(baseline.resources[0].resource, reference)
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
  runtime.settle_operation("op-1")
  assert_eq(
    settled_labels(host, { generation: runtime.generation(), seq: 0, }),
    ["published", "withdrawn"],
  )
}

///|
test "ui_operation/published_listener_can_replace_what_it_saw" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  ignore(runtime.begin_operation("op-1"))
  let handle = operation_handle(board)
  let replacements : Array[
    Result[@port.UiResourceSnapshot, @port.UiResourceError],
  ] = []
  let observation = probe_once(host, fn(change) {
    match change {
      Resource(change~) =>
        match change {
          Published(snapshot~) =>
            replacements.push(
              handle.replace(
                draft=operation_panel(key=snapshot.resource.key, note="v2"),
                expected=snapshot.revision,
              ),
            )
          _ => ()
        }
      Interaction(_) => ()
    }
  })
  ignore(handle.publish(draft=operation_panel(key="progress")))
  assert_eq(replacements.length(), 1)
  match replacements[0] {
    Ok(snapshot) => assert_eq(snapshot.revision, 2)
    Err(error) =>
      fail("expected the announced revision to be replaceable: \{error}")
  }
  // No second node and no leftover: the replacement is the live resource.
  match host.snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.resources.length(), 1)
      assert_eq(baseline.resources[0].revision, 2)
      assert_eq(baseline.resources[0].body, @port.UiResourceBody::Text("v2"))
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(settled_labels(host, observation.baseline.cursor), [
    "published", "replaced",
  ])
  runtime.settle_operation("op-1")
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
}

///|
test "ui_operation/published_listener_can_remove_what_it_saw" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  ignore(runtime.begin_operation("op-1"))
  let handle = operation_handle(board)
  let removals : Array[Result[Int32, @port.UiResourceError]] = []
  let observation = probe_once(host, fn(change) {
    match change {
      Resource(change~) =>
        match change {
          Published(snapshot~) =>
            removals.push(handle.remove(resource=snapshot.resource))
          _ => ()
        }
      Interaction(_) => ()
    }
  })
  ignore(handle.publish(draft=operation_panel(key="progress")))
  assert_eq(removals, [Ok(1)])
  // The outer publish frame does not re-bind after delivery: the withdrawal
  // stands and settlement has nothing left to reclaim.
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
  runtime.settle_operation("op-1")
  assert_eq(settled_labels(host, observation.baseline.cursor), [
    "published", "withdrawn",
  ])
}

///|
test "ui_operation/settlement_from_a_published_listener_reclaims_in_order" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  ignore(runtime.begin_operation("op-1"))
  let handle = operation_handle(board)
  let delivered : Array[String] = []
  let observation = ui_subscribe_or_abort(
    host,
    fn(batch) {
      delivered.push(ui_observed_label(batch))
      match batch.change {
        Resource(change~) =>
          match change {
            Published(_) => runtime.settle_operation("op-1")
            _ => ()
          }
        Interaction(_) => ()
      }
      Ok(())
    },
    fn(failure) { abort("unexpected listener failure: \{failure.detail}") },
  )
  // The operation settles while its own publish is being announced: the panel
  // is reclaimed in the same commit order, and nothing re-binds it afterwards.
  ignore(handle.publish(draft=operation_panel(key="progress")))
  assert_eq(delivered, ["1:published", "2:withdrawn"])
  assert_eq(runtime.current_operation(), None)
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(settled_labels(host, observation.baseline.cursor), [
    "published", "withdrawn",
  ])
  // A stale settlement cannot reach the next operation's resource.
  ignore(runtime.begin_operation("op-2"))
  ignore(operation_handle(board).publish(draft=operation_panel(key="progress")))
  runtime.settle_operation("op-1")
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 1)
    Err(error) => fail("snapshot failed: \{error}")
  }
  runtime.settle_operation("op-2")
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
}

///|
test "ui_operation/repeated_replacement_from_a_listener_leaves_no_residue" {
  let runtime = UiRuntime()
  let board = runtime.capability("board")
  let host = runtime.host()
  ignore(runtime.begin_operation("op-1"))
  let handle = operation_handle(board)
  let replacements : Array[Int32] = []
  let observation = ui_subscribe_or_abort(
    host,
    fn(batch) {
      match batch.change {
        Resource(change~) =>
          match change {
            Published(snapshot~) | Replaced(snapshot~) =>
              if replacements.length() < 2 {
                replacements.push(snapshot.revision)
                ignore(
                  handle.replace(
                    draft=operation_panel(
                      key=snapshot.resource.key,
                      note="v\{snapshot.revision + 1}",
                    ),
                    expected=snapshot.revision,
                  ),
                )
              }
            _ => ()
          }
        Interaction(_) => ()
      }
      Ok(())
    },
    fn(failure) { abort("unexpected listener failure: \{failure.detail}") },
  )
  ignore(handle.publish(draft=operation_panel(key="progress")))
  assert_eq(replacements, [1, 2])
  match host.snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.resources.length(), 1)
      assert_eq(baseline.resources[0].revision, 3)
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(settled_labels(host, observation.baseline.cursor), [
    "published", "replaced", "replaced",
  ])
  runtime.settle_operation("op-1")
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
  // No binding survived settlement: the next operation re-publishes the same
  // key at the next revision and keeps exactly one live node.
  ignore(runtime.begin_operation("op-2"))
  let next = match
    operation_handle(board).publish(draft=operation_panel(key="progress")) {
    Ok(snapshot) => snapshot
    Err(error) => fail("publish failed: \{error}")
  }
  assert_eq(next.revision, 4)
  match host.snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.resources.length(), 1)
      assert_eq(baseline.resources[0].revision, 4)
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
}
