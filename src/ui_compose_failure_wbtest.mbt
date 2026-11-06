///|
/// Composition-failure revocation for the owner-bound UI protocol: a
/// capability delivered by `on_compose` must not outlive a composition that
/// fails later, because no Agent is produced that could ever `shutdown`.

///|
/// Composition-time UI probe: captures both capabilities, publishes one
/// resource and opens one question, then optionally fails the composition.
priv struct UiComposeProbe {
  resources : Ref[@port.UiResources?]
  interactions : Ref[@port.UiInteractions?]
  published : Ref[@port.UiResourceRef?]
  opened : Ref[@port.UiInteractionRef?]
  fail : Bool
}

///|
fn UiComposeProbe::new(fail : Bool) -> UiComposeProbe {
  {
    resources: Ref(None),
    interactions: Ref(None),
    published: Ref(None),
    opened: Ref(None),
    fail,
  }
}

///|
fn UiComposeProbe::resources(self : UiComposeProbe) -> @port.UiResources {
  match self.resources.val {
    Some(capability) => capability
    None =>
      abort("expected the composition to deliver the UI resource capability")
  }
}

///|
fn UiComposeProbe::interactions(self : UiComposeProbe) -> @port.UiInteractions {
  match self.interactions.val {
    Some(capability) => capability
    None =>
      abort("expected the composition to deliver the interaction capability")
  }
}

///|
fn UiComposeProbe::published(self : UiComposeProbe) -> @port.UiResourceRef {
  match self.published.val {
    Some(resource) => resource
    None => abort("expected the probe to publish a live resource")
  }
}

///|
fn UiComposeProbe::opened(self : UiComposeProbe) -> @port.UiInteractionRef {
  match self.opened.val {
    Some(interaction) => interaction
    None => abort("expected the probe to open a live question")
  }
}

///|
impl @port.Lifecycle for UiComposeProbe with fn on_compose(self, ctx) -> Unit raise @error.CompositionError {
  self.resources.val = ctx.ui_resources()
  self.interactions.val = ctx.ui_interactions()
  match self.resources.val {
    Some(resources) =>
      match resources.publish(draft=probe_draft("composed")) {
        Ok(snapshot) => self.published.val = Some(snapshot.resource)
        Err(error) =>
          raise ExtensionComposeFailed(
            manifest_id="probe",
            detail="probe publish failed: \{error}",
          )
      }
    None =>
      raise ExtensionComposeFailed(
        manifest_id="probe",
        detail="ui_resources was not delivered",
      )
  }
  match self.interactions.val {
    Some(interactions) =>
      match interactions.open(request=probe_request("probe-pending")) {
        Ok(snapshot) => self.opened.val = Some(snapshot.interaction)
        Err(error) =>
          raise ExtensionComposeFailed(
            manifest_id="probe",
            detail="probe open failed: \{error}",
          )
      }
    None =>
      raise ExtensionComposeFailed(
        manifest_id="probe",
        detail="ui_interactions was not delivered",
      )
  }
  if self.fail {
    raise ExtensionComposeFailed(
      manifest_id="probe",
      detail="probe fails after publishing and opening",
    )
  }
}

///|
fn probe_draft(note : String) -> @port.UiResourceDraft {
  @port.UiResourceDraft::new(
    key="probe",
    kind=@port.UiResourceKind::standard(name="probe_board"),
    body=@port.UiResourceBody::Text(note),
  )
}

///|
fn probe_request(id : String) -> @port.UiInteractionRequest {
  @port.UiInteractionRequest::new(
    request_id=id,
    prompt="Continue?",
    body=@port.UiInteractionBody::Confirmation,
  )
}

///|
fn assert_event_resource_closed(system : EventSystem) -> Unit {
  match system.publisher(owner="probe") {
    Err(@events.EventError::Closed) => ()
    Ok(_) => abort("a failed composition left the event resource open")
    Err(_) => abort("expected Closed from publisher")
  }
}

///|
/// Every capability call after the failed composition reports `Closed`: no
/// Agent exists that could run `shutdown`, so the failure itself must revoke.
async fn assert_ui_revoked(probe : UiComposeProbe) -> Unit {
  let resources = probe.resources()
  let interactions = probe.interactions()
  let resource = probe.published()
  let interaction = probe.opened()
  match resources.publish(draft=probe_draft("late")) {
    Err(@port.UiResourceError::Closed) => ()
    Ok(_) => abort("a failed composition left publish alive")
    Err(error) => abort("expected Closed from publish, got \{error}")
  }
  match resources.replace(draft=probe_draft("late"), expected=1) {
    Err(@port.UiResourceError::Closed) => ()
    Ok(_) => abort("a failed composition left replace alive")
    Err(error) => abort("expected Closed from replace, got \{error}")
  }
  match resources.remove(resource~) {
    Err(@port.UiResourceError::Closed) => ()
    Ok(_) => abort("a failed composition left remove alive")
    Err(error) => abort("expected Closed from remove, got \{error}")
  }
  match
    resources.set_action_handler(handler=fn(
      _invocation,
    ) -> Result[Unit, String] {
      Ok(())
    }) {
    Err(@port.UiResourceError::Closed) => ()
    Ok(_) => abort("a failed composition left the action route alive")
    Err(error) => abort("expected Closed from set_action_handler, got \{error}")
  }
  match resources.host_support(resource~) {
    Err(@port.UiResourceError::Closed) => ()
    Ok(_) => abort("a failed composition left host_support alive")
    Err(error) => abort("expected Closed from host_support, got \{error}")
  }
  match resources.operation() {
    Err(@port.UiResourceError::Closed) => ()
    Ok(_) => abort("a failed composition left operation capture alive")
    Err(error) => abort("expected Closed from operation, got \{error}")
  }
  match interactions.open(request=probe_request("late")) {
    Err(@port.UiInteractionError::Closed) => ()
    Ok(_) => abort("a failed composition left open alive")
    Err(error) => abort("expected Closed from open, got \{error}")
  }
  match interactions.find(request_id="probe-pending") {
    Err(@port.UiInteractionError::Closed) => ()
    Ok(_) => abort("a failed composition left find alive")
    Err(error) => abort("expected Closed from find, got \{error}")
  }
  match interactions.wait(interaction~) {
    Err(@port.UiInteractionError::Closed) => ()
    Ok(_) => abort("a failed composition left wait alive")
    Err(error) => abort("expected Closed from wait, got \{error}")
  }
  match interactions.withdraw(interaction~) {
    Err(@port.UiInteractionError::Closed) => ()
    Ok(_) => abort("a failed composition left withdraw alive")
    Err(error) => abort("expected Closed from withdraw, got \{error}")
  }
}

///|
async test "ui_compose_failure/later_contributor_failure_revokes_delivered_capabilities" {
  let probe = UiComposeProbe::new(false)
  let system = EventSystem()
  try
    Agent(
      events=system,
      exts=[
        scripted_model_ext([]),
        @test_support.tk_ext(
          id="probe",
          lifecycle=[probe as &@port.Lifecycle],
          requires=[@port.Capability::Ui],
        ),
        @test_support.tk_ext(id="bad", lifecycle=[
          FailCompose::{ id: "bad", } as &@port.Lifecycle,
        ]),
      ],
      config=agent_config(),
    )
  catch {
    ExtensionComposeFailed(manifest_id~, ..) => assert_eq(manifest_id, "bad")
    error => abort("unexpected composition failure: \{error}")
  } noraise {
    _ => abort("expected composition failure")
  }
  assert_event_resource_closed(system)
  assert_ui_revoked(probe)
}

///|
async test "ui_compose_failure/holder_failing_after_publish_and_open_is_revoked" {
  let probe = UiComposeProbe::new(true)
  let system = EventSystem()
  try
    Agent(
      events=system,
      exts=[
        scripted_model_ext([]),
        @test_support.tk_ext(
          id="probe",
          lifecycle=[probe as &@port.Lifecycle],
          requires=[@port.Capability::Ui],
        ),
      ],
      config=agent_config(),
    )
  catch {
    ExtensionComposeFailed(manifest_id~, ..) => assert_eq(manifest_id, "probe")
    error => abort("unexpected composition failure: \{error}")
  } noraise {
    _ => abort("expected composition failure")
  }
  assert_event_resource_closed(system)
  assert_ui_revoked(probe)
}

///|
async test "ui_compose_failure/with_runtime_shares_the_same_revocation" {
  let probe = UiComposeProbe::new(false)
  let system = EventSystem()
  let model = @test_support.ScriptedModel([])
  try
    Agent::with_runtime(
      events=system,
      exts=[
        @test_support.tk_ext(id="model", model=Some(model)),
        @test_support.tk_ext(
          id="probe",
          lifecycle=[probe as &@port.Lifecycle],
          requires=[@port.Capability::Ui],
        ),
        @test_support.tk_ext(id="bad", lifecycle=[
          FailCompose::{ id: "bad", } as &@port.Lifecycle,
        ]),
      ],
      config=agent_config(),
      runtime=@runtime.PortRuntime(model~),
    )
  catch {
    ExtensionComposeFailed(manifest_id~, ..) => assert_eq(manifest_id, "bad")
    error => abort("unexpected composition failure: \{error}")
  } noraise {
    _ => abort("expected composition failure")
  }
  assert_event_resource_closed(system)
  assert_ui_revoked(probe)
}
