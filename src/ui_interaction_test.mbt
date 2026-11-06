///|
/// Black-box contract tests for the structured interaction protocol, driven
/// through the public `Agent` surface with the shared testkit extensions.

///|
/// An extension-side contributor that keeps both UI capabilities it was handed.
struct InteractionUiExtension {
  resources : Ref[@posoco.UiResources?]
  interactions : Ref[@posoco.UiInteractions?]
}

///|
fn InteractionUiExtension::new() -> InteractionUiExtension {
  { resources: Ref(None), interactions: Ref(None), }
}

///|
impl @port.Lifecycle for InteractionUiExtension with fn on_compose(self, ctx) {
  self.resources.val = ctx.ui_resources()
  self.interactions.val = ctx.ui_interactions()
}

///|
fn interaction_agent(
  extension : InteractionUiExtension,
  requires_ui~ : Bool,
) -> @posoco.Agent {
  try
    @posoco.Agent(
      exts=[
        @test_support.tk_ext(
          id="model",
          model=Some(@test_support.ScriptedModel([])),
        ),
        @test_support.tk_ext(
          id="ask",
          lifecycle=[extension],
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
fn captured_interactions(
  extension : InteractionUiExtension,
) -> @posoco.UiInteractions {
  match extension.interactions.val {
    Some(capability) => capability
    None =>
      abort("expected the composition to deliver the interaction capability")
  }
}

///|
fn approval_request(id : String) -> @posoco.UiInteractionRequest {
  @posoco.UiInteractionRequest::new(
    request_id=id,
    prompt="Apply the patch?",
    body=@posoco.UiInteractionBody::Confirmation,
    title="approval",
  )
}

///|
async test "ui_interaction/extension_questions_reach_the_host_and_back" {
  let extension = InteractionUiExtension::new()
  let agent = interaction_agent(extension, requires_ui=true)
  let capability = captured_interactions(extension)
  assert_eq(capability.owner(), "ask")
  let host = agent.ui_host()
  // Subscribe first: everything the extension does afterwards arrives in order.
  let delivered : Array[String] = []
  let failures : Array[String] = []
  let observation = match
    host.subscribe(
      listener=fn(batch) {
        match batch.change {
          Resource(_) => delivered.push("resource")
          Interaction(change~) =>
            match change {
              Opened(_) => delivered.push("opened")
              Settled(..) => delivered.push("settled")
            }
        }
        Ok(())
      },
      on_failure=fn(failure) { failures.push(failure.detail) },
    ) {
    Ok(value) => value
    Err(error) => fail("subscribe failed: \{error}")
  }
  assert_eq(observation.baseline.pending_interactions.length(), 0)
  let opened = match capability.open(request=approval_request("approval-1")) {
    Ok(snapshot) => snapshot
    Err(error) => fail("open failed: \{error}")
  }
  assert_eq(opened.interaction.owner, "ask")
  assert_eq(delivered, ["opened"])
  // The question is pending in the atomic baseline the host renders from.
  let pending = match host.snapshot() {
    Ok(baseline) => baseline
    Err(error) => fail("snapshot failed: \{error}")
  }
  assert_eq(pending.pending_interactions.length(), 1)
  assert_eq(pending.pending_interactions[0].prompt, "Apply the patch?")
  assert_eq(pending.pending_interactions[0].title, Some("approval"))
  // The user answers; the extension's own waiting call receives that answer.
  match
    host.answer(request={
      interaction: opened.interaction,
      answer: @posoco.UiInteractionAnswer::Yes,
    }) {
    Ok(receipt) => assert_false(receipt.replayed)
    Err(error) => fail("answer failed: \{error}")
  }
  match capability.wait(interaction=opened.interaction) {
    Ok(answer) => assert_eq(answer, @posoco.UiInteractionAnswer::Yes)
    Err(error) => fail("wait failed: \{error}")
  }
  assert_eq(delivered, ["opened", "settled"])
  assert_eq(failures.length(), 0)
  // A duplicate answer replays instead of answering twice.
  match
    host.answer(request={
      interaction: opened.interaction,
      answer: @posoco.UiInteractionAnswer::Yes,
    }) {
    Ok(receipt) => assert_true(receipt.replayed)
    Err(error) => fail("replay failed: \{error}")
  }
  match host.snapshot() {
    Ok(baseline) => assert_eq(baseline.pending_interactions.length(), 0)
    Err(error) => fail("snapshot failed: \{error}")
  }
  observation.subscription.unsubscribe()
  assert_false(observation.subscription.is_active())
  assert_true(extension.resources.val is Some(_))
  agent.shutdown()
}

///|
test "ui_interaction/capability_is_gated_on_the_ui_declaration" {
  let extension = InteractionUiExtension::new()
  let agent = interaction_agent(extension, requires_ui=false)
  assert_true(extension.interactions.val is None)
  assert_true(extension.resources.val is None)
  // The host side still exists: it simply has nothing to show.
  match agent.ui_host().snapshot() {
    Ok(baseline) => {
      assert_eq(baseline.resources.length(), 0)
      assert_eq(baseline.pending_interactions.length(), 0)
    }
    Err(error) => fail("snapshot failed: \{error}")
  }
}

///|
async test "ui_interaction/shutdown_settles_pending_questions_as_closed" {
  let extension = InteractionUiExtension::new()
  let agent = interaction_agent(extension, requires_ui=true)
  let capability = captured_interactions(extension)
  let host = agent.ui_host()
  let opened = match capability.open(request=approval_request("approval-1")) {
    Ok(snapshot) => snapshot
    Err(error) => fail("open failed: \{error}")
  }
  agent.shutdown()
  // A pending question never outlives the Agent.
  match
    host.answer(request={
      interaction: opened.interaction,
      answer: @posoco.UiInteractionAnswer::No,
    }) {
    Err(@posoco.UiInteractionError::Closed) => ()
    Ok(_) => fail("expected a closed Agent to refuse the answer")
    Err(other) => fail("expected Closed, got \{other}")
  }
  match capability.open(request=approval_request("approval-2")) {
    Err(@posoco.UiInteractionError::Closed) => ()
    Ok(_) => fail("expected a closed Agent to refuse new questions")
    Err(other) => fail("expected Closed, got \{other}")
  }
  assert_eq(host.snapshot(), Err(@posoco.UiResourceError::Closed))
}

///|
/// Fails its first `on_shutdown` attempt and succeeds afterwards, so the failed
/// shutdown path can be observed without poisoning the Agent permanently.
struct FlakyShutdownUiExtension {
  interactions : Ref[@posoco.UiInteractions?]
  resources : Ref[@posoco.UiResources?]
  mut attempts : Int32
}

///|
fn FlakyShutdownUiExtension::new() -> FlakyShutdownUiExtension {
  { interactions: Ref(None), resources: Ref(None), attempts: 0, }
}

///|
impl @port.Lifecycle for FlakyShutdownUiExtension with fn on_compose(self, ctx) {
  self.interactions.val = ctx.ui_interactions()
  self.resources.val = ctx.ui_resources()
}

///|
impl @port.Lifecycle for FlakyShutdownUiExtension with fn on_shutdown(self) {
  self.attempts = self.attempts + 1
  if self.attempts == 1 {
    raise @posoco.AgentError::Runtime(
      @posoco.RuntimeError::InvocationFailed("flaky shutdown"),
    )
  }
}

///|
/// Publishes one last revision from `Lifecycle::on_shutdown` and keeps the
/// result, so a shutdown that closed the protocol too early is visible.
struct LateShutdownPublish {
  resources : Ref[@posoco.UiResources?]
  final_publish : Ref[
    Result[@posoco.UiResourceSnapshot, @posoco.UiResourceError]?,
  ]
}

///|
fn LateShutdownPublish::new() -> LateShutdownPublish {
  { resources: Ref(None), final_publish: Ref(None), }
}

///|
impl @port.Lifecycle for LateShutdownPublish with fn on_compose(self, ctx) {
  self.resources.val = ctx.ui_resources()
}

///|
impl @port.Lifecycle for LateShutdownPublish with fn on_shutdown(self) {
  let published : Result[@posoco.UiResourceSnapshot, @posoco.UiResourceError] = match
    self.resources.val {
    Some(capability) => capability.publish(draft=approval_draft("closing"))
    None => Err(@posoco.UiResourceError::Closed)
  }
  self.final_publish.val = Some(published)
}

///|
fn approval_draft(note : String) -> @posoco.UiResourceDraft {
  @posoco.UiResourceDraft::new(
    key="approval",
    kind=@posoco.UiResourceKind::standard(name="approval_board"),
    body=@posoco.UiResourceBody::Text(note),
  )
}

///|
async test "ui_interaction/failed_shutdown_still_closes_the_ui_protocol" {
  let late = LateShutdownPublish::new()
  let flaky = FlakyShutdownUiExtension::new()
  // Registration order decides shutdown order (reverse): `flaky` fails before
  // `late` gets its turn on the first attempt.
  let agent = try
    @posoco.Agent(
      exts=[
        @test_support.tk_ext(
          id="model",
          model=Some(@test_support.ScriptedModel([])),
        ),
        @test_support.tk_ext(id="late", lifecycle=[late], requires=[
          @port.Capability::Ui,
        ]),
        @test_support.tk_ext(id="flaky", lifecycle=[flaky], requires=[
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
  let interactions = match flaky.interactions.val {
    Some(capability) => capability
    None =>
      abort("expected the composition to deliver the interaction capability")
  }
  let resources = match flaky.resources.val {
    Some(capability) => capability
    None => abort("expected the composition to deliver the resource capability")
  }
  let host = agent.ui_host()
  let opened = match interactions.open(request=approval_request("approval-1")) {
    Ok(snapshot) => snapshot
    Err(error) => fail("open failed: \{error}")
  }
  // First shutdown attempt fails inside an extension hook.
  let first_attempt : Result[Unit, Error] = Ok(agent.shutdown()) catch {
    error => Err(error)
  }
  match first_attempt {
    Ok(_) => fail("expected the failing on_shutdown to raise")
    Err(error) => assert_true(error.to_string().contains("flaky shutdown"))
  }
  assert_eq(flaky.attempts, 1)
  // The failure left no half-open UI protocol behind.
  assert_eq(
    resources.publish(draft=approval_draft("late")),
    Err(@posoco.UiResourceError::Closed),
  )
  assert_eq(host.snapshot(), Err(@posoco.UiResourceError::Closed))
  match interactions.wait(interaction=opened.interaction) {
    Err(@posoco.UiInteractionError::Closed) => ()
    Ok(answer) => fail("a pending question cannot settle as \{answer}")
    Err(other) => fail("expected Closed, got \{other}")
  }
  assert_true(late.final_publish.val is None)
  // Retrying finishes the remaining cleanup; the protocol is already closed.
  agent.shutdown()
  assert_eq(flaky.attempts, 2)
  match late.final_publish.val {
    Some(Err(@posoco.UiResourceError::Closed)) => ()
    Some(Ok(_)) =>
      fail("a retry after a failed shutdown cannot reopen the UI protocol")
    Some(Err(other)) => fail("expected Closed, got \{other}")
    None => fail("expected the retried shutdown to reach the remaining hook")
  }
  assert_eq(host.snapshot(), Err(@posoco.UiResourceError::Closed))
  assert_false(
    host.subscribe(listener=fn(_batch) { Ok(()) }, on_failure=fn(_failure) {
      ()
    })
    is Ok(_),
  )
}
