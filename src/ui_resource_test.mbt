///|
/// Black-box contract tests for the owner-bound UI resource protocol, driven
/// through the public `Agent` surface with the shared testkit extensions.

///|
/// An extension-side contributor that keeps the capability it was handed.
struct CapturingUiExtension {
  captured : Ref[@posoco.UiResources?]
  saw_legacy_port : Ref[Bool]
}

///|
fn CapturingUiExtension::new() -> CapturingUiExtension {
  { captured: Ref(None), saw_legacy_port: Ref(false), }
}

///|
impl @port.Lifecycle for CapturingUiExtension with fn on_compose(self, ctx) {
  self.captured.val = ctx.ui_resources()
  self.saw_legacy_port.val = ctx.ui() is Some(_)
}

///|
fn ui_composed_agent(
  board : CapturingUiExtension,
  requires_ui~ : Bool,
  ui~ : Array[&@port.UiPort],
) -> @posoco.Agent {
  try
    @posoco.Agent(
      exts=[
        @test_support.tk_ext(
          id="model",
          model=Some(@test_support.ScriptedModel([])),
        ),
        @test_support.tk_ext(
          id="board",
          ui~,
          lifecycle=[board],
          requires=if requires_ui { [@port.Capability::Ui] } else { [] },
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
fn ui_capability(board : CapturingUiExtension) -> @posoco.UiResources {
  match board.captured.val {
    Some(capability) => capability
    None => abort("expected the composition to deliver the UI capability")
  }
}

///|
fn board_published(
  snapshot : Result[@posoco.UiResourceSnapshot, @posoco.UiResourceError],
) -> @posoco.UiResourceRef {
  match snapshot {
    Ok(value) => value.resource
    Err(error) => abort("expected a published snapshot, got \{error}")
  }
}

///|
fn review_draft(note : String) -> @posoco.UiResourceDraft {
  @posoco.UiResourceDraft::new(
    key="review",
    kind=@posoco.UiResourceKind::standard(name="review_board"),
    body=@posoco.UiResourceBody::Text(note),
    actions=[
      {
        id: "approve",
        label: "Approve",
        payload: @posoco.UiActionPayloadKind::JsonPayload,
      },
    ],
  )
}

///|
async test "ui_resource/host_observes_resources_and_actions_reach_the_owner" {
  let board = CapturingUiExtension::new()
  let agent = ui_composed_agent(board, requires_ui=true, ui=[])
  assert_true(board.saw_legacy_port.val)
  let capability = ui_capability(board)
  assert_eq(capability.owner(), "board")
  let host = agent.ui_host()
  let empty = match host.snapshot() {
    Ok(baseline) => baseline
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(empty.resources.length(), 0)
  // The extension publishes through its composition-delivered capability.
  let reference = board_published(
    capability.publish(draft=review_draft("draft")),
  )
  let after_publish = match host.snapshot() {
    Ok(baseline) => baseline
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(after_publish.resources.length(), 1)
  assert_eq(after_publish.resources[0].revision, 1)
  assert_eq(
    after_publish.resources[0].body,
    @posoco.UiResourceBody::Text("draft"),
  )
  match host.changes_since(cursor=empty.cursor) {
    Ok(changes) => {
      assert_eq(changes.changes.length(), 1)
      match changes.changes[0] {
        Published(snapshot~) => assert_eq(snapshot.resource, reference)
        other => fail("expected Published, got \{repr(other)}")
      }
    }
    Err(error) => fail("changes failed: \{error}")
  }
  // Owner handler: a user decision comes back as a governed action, and the
  // owner republishes with compare-and-set on the revision it was invoked at.
  ignore(
    capability.set_action_handler(handler=invocation => {
      let updated = @posoco.UiResourceDraft::new(
        key=invocation.resource.key,
        kind=@posoco.UiResourceKind::standard(name="review_board"),
        body=@posoco.UiResourceBody::Text("approved"),
        actions=[],
      )
      match capability.replace(draft=updated, expected=invocation.revision) {
        Ok(_) => Ok(())
        Err(error) => Err(error.to_string())
      }
    }),
  )
  let request : @posoco.UiActionRequest = {
    resource: reference,
    action: "approve",
    expected_revision: 1,
    request_id: "req-approve",
    payload: Some(
      Json::object(Map::from_array([("note", Json::string("lgtm"))])),
    ),
  }
  match host.dispatch(request~) {
    Ok(result) => {
      assert_eq(result.revision, 1)
      assert_false(result.replayed)
    }
    Err(error) => fail("dispatch failed: \{error}")
  }
  let latest = match host.snapshot() {
    Ok(baseline) => baseline
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(latest.resources.length(), 1)
  assert_eq(latest.resources[0].revision, 2)
  assert_eq(latest.resources[0].body, @posoco.UiResourceBody::Text("approved"))
  // Retrying the same request id replays the receipt instead of rerunning
  // the owner handler.
  match host.dispatch(request~) {
    Ok(result) => assert_true(result.replayed)
    Err(error) => fail("replay failed: \{error}")
  }
  // A second host handle observes the same runtime: same baseline, and the
  // same request id still replays instead of running the owner again.
  let second_host = agent.ui_host()
  match second_host.snapshot() {
    Ok(baseline) => assert_eq(baseline.resources[0].revision, 2)
    Err(error) => fail("snapshot failed: \{error}")
  }
  match second_host.dispatch(request~) {
    Ok(result) => assert_true(result.replayed)
    Err(error) => fail("replay failed: \{error}")
  }
  // Withdrawing the resource is an explicit lifecycle fact the host sees.
  match capability.remove(resource=reference) {
    Ok(revision) => assert_eq(revision, 2)
    Err(error) => fail("remove failed: \{error}")
  }
  match host.changes_since(cursor=latest.cursor) {
    Ok(changes) => {
      assert_eq(changes.changes.length(), 1)
      match changes.changes[0] {
        Withdrawn(owner~, key~, revision~) => {
          assert_eq(owner, "board")
          assert_eq(key, "review")
          assert_eq(revision, 2)
        }
        other => fail("expected Withdrawn, got \{repr(other)}")
      }
    }
    Err(error) => fail("changes failed: \{error}")
  }
  // After shutdown the capability and the feed are closed, not silently empty.
  agent.shutdown()
  assert_eq(
    capability.publish(draft=review_draft("late")),
    Err(@posoco.UiResourceError::Closed),
  )
  assert_eq(host.snapshot(), Err(@posoco.UiResourceError::Closed))
}

///|
test "ui_resource/owner_binding_keeps_extensions_out_of_each_other" {
  let alpha = CapturingUiExtension::new()
  let beta = CapturingUiExtension::new()
  let agent = try
    @posoco.Agent(
      exts=[
        @test_support.tk_ext(
          id="model",
          model=Some(@test_support.ScriptedModel([])),
        ),
        @test_support.tk_ext(id="alpha", lifecycle=[alpha], requires=[
          @port.Capability::Ui,
        ]),
        @test_support.tk_ext(id="beta", lifecycle=[beta], requires=[
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
  let alpha_capability = ui_capability(alpha)
  let beta_capability = ui_capability(beta)
  // Same local key, two owners: no collision.
  let alpha_ref = board_published(
    alpha_capability.publish(draft=review_draft("alpha")),
  )
  let beta_ref = board_published(
    beta_capability.publish(draft=review_draft("beta")),
  )
  assert_eq(alpha_ref.owner, "alpha")
  assert_eq(beta_ref.owner, "beta")
  match agent.ui_host().snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 2)
    Err(error) => fail("snapshot failed: \{error}")
  }
  // Neither extension can withdraw the other's resource.
  match alpha_capability.remove(resource=beta_ref) {
    Err(@posoco.UiResourceError::InvalidInput(reason=_)) => ()
    Ok(_) => fail("expected a cross-owner withdrawal to be rejected")
    Err(other) => fail("expected InvalidInput, got \{other}")
  }
}

///|
test "ui_resource/capability_is_gated_on_the_ui_declaration" {
  let undeclared = CapturingUiExtension::new()
  let agent = ui_composed_agent(undeclared, requires_ui=false, ui=[])
  assert_eq(agent.ui_host().snapshot() is Ok(_), true)
  assert_true(undeclared.captured.val is None)
  assert_false(undeclared.saw_legacy_port.val)
}

///|
test "ui_resource/headless_composition_still_gets_the_resource_protocol" {
  // No UI contributor at all: the noop port is delivered while the resource
  // protocol stays host-observable.
  let board = CapturingUiExtension::new()
  let agent = ui_composed_agent(board, requires_ui=true, ui=[])
  let capability = ui_capability(board)
  let reference = board_published(
    capability.publish(draft=review_draft("headless")),
  )
  assert_eq(reference.owner, "board")
  match agent.ui_host().snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 1)
    Err(error) => fail("snapshot failed: \{error}")
  }
}

///|
test "ui_resource/legacy_ui_port_survives_alongside_the_resource_protocol" {
  let legacy = @test_support.RecordingUiPort(responses=[Yes])
  let board = CapturingUiExtension::new()
  let agent = ui_composed_agent(board, requires_ui=true, ui=[legacy])
  // The old port is still delivered and still renders.
  assert_true(board.saw_legacy_port.val)
  assert_true(board.captured.val is Some(_))
  assert_eq(legacy.render_count(), 0)
  match agent.ui_host().snapshot() {
    Ok(baseline) => assert_eq(baseline.resources.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
}

///|
/// An extension that publishes one last revision from `Lifecycle::on_shutdown`.
struct ShutdownPublishingUiExtension {
  captured : Ref[@posoco.UiResources?]
  final_publish : Ref[
    Result[@posoco.UiResourceSnapshot, @posoco.UiResourceError]?,
  ]
}

///|
fn ShutdownPublishingUiExtension::new() -> ShutdownPublishingUiExtension {
  { captured: Ref(None), final_publish: Ref(None), }
}

///|
impl @port.Lifecycle for ShutdownPublishingUiExtension with fn on_compose(
  self,
  ctx,
) {
  self.captured.val = ctx.ui_resources()
}

///|
impl @port.Lifecycle for ShutdownPublishingUiExtension with fn on_shutdown(self) {
  self.final_publish.val = Some(
    match self.captured.val {
      Some(capability) => capability.publish(draft=review_draft("closed out"))
      None => Err(@posoco.UiResourceError::Closed)
    },
  )
}

///|
async test "ui_resource/shutdown_close_waits_for_the_last_legitimate_publish" {
  let extension = ShutdownPublishingUiExtension::new()
  let agent = try
    @posoco.Agent(
      exts=[
        @test_support.tk_ext(
          id="model",
          model=Some(@test_support.ScriptedModel([])),
        ),
        @test_support.tk_ext(id="board", lifecycle=[extension], requires=[
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
  let capability = match extension.captured.val {
    Some(capability) => capability
    None => abort("expected the composition to deliver the UI capability")
  }
  ignore(board_published(capability.publish(draft=review_draft("before"))))
  agent.shutdown()
  // The final publish from `on_shutdown` still lands.
  match extension.final_publish.val {
    Some(Ok(snapshot)) => {
      assert_eq(snapshot.revision, 2)
      assert_eq(snapshot.body, @posoco.UiResourceBody::Text("closed out"))
    }
    Some(Err(error)) =>
      fail("expected the on_shutdown publish to be accepted, got \{error}")
    None => fail("expected on_shutdown to publish a final revision")
  }
  // Only afterwards is the capability and the host feed closed.
  assert_eq(
    capability.publish(draft=review_draft("too late")),
    Err(@posoco.UiResourceError::Closed),
  )
  assert_eq(agent.ui_host().snapshot(), Err(@posoco.UiResourceError::Closed))
}

///|
async test "ui_resource/republished_resource_refuses_the_old_revision" {
  let board = CapturingUiExtension::new()
  let agent = ui_composed_agent(board, requires_ui=true, ui=[])
  let capability = ui_capability(board)
  let host = agent.ui_host()
  let first = board_published(capability.publish(draft=review_draft("draft")))
  let cut = match host.snapshot() {
    Ok(baseline) => baseline.cursor
    Err(error) => fail("snapshot failed: \{error}")
  }
  ignore(capability.set_action_handler(handler=_invocation => Ok(())))
  match capability.remove(resource=first) {
    Ok(revision) => assert_eq(revision, 1)
    Err(error) => fail("remove failed: \{error}")
  }
  let second = board_published(capability.publish(draft=review_draft("reborn")))
  // Same identity, next revision.
  assert_eq(second, first)
  match host.snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.resources.length(), 1)
      assert_eq(baseline.resources[0].revision, 2)
      assert_eq(
        baseline.resources[0].body,
        @posoco.UiResourceBody::Text("reborn"),
      )
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
  let stale_request : @posoco.UiActionRequest = {
    resource: first,
    action: "approve",
    expected_revision: 1,
    request_id: "old-revision",
    payload: Some(Json::object(Map::from_array([]))),
  }
  match host.dispatch(request=stale_request) {
    Err(@posoco.UiResourceError::StaleRevision(expected~, actual~)) => {
      assert_eq(expected, 1)
      assert_eq(actual, 2)
    }
    Ok(result) =>
      fail("expected the old revision to be refused, got \{repr(result)}")
    Err(other) => fail("expected StaleRevision, got \{other}")
  }
  // The refused request reserved nothing: a retry at the live revision is a
  // fresh dispatch.
  match
    host.dispatch(request={
      ..stale_request,
      request_id: "fresh-revision",
      expected_revision: 2,
    }) {
    Ok(result) => {
      assert_eq(result.revision, 2)
      assert_false(result.replayed)
    }
    Err(error) => fail("expected the live revision to dispatch: \{error}")
  }
  match host.changes_since(cursor=cut) {
    Ok(changes) =>
      assert_eq(changes.changes.map(change_label), ["withdrawn", "published"])
    Err(error) => fail("changes failed: \{error}")
  }
  agent.shutdown()
}
