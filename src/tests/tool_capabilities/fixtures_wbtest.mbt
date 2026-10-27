///|
using @agent {
  type Agent,
  type AgentControl,
  type ScriptedModel,
  type RecordingToolProvider,
  type RecordingObserver,
  type RecordingSessionStore,
  type ScriptedMemoryPort,
  tk_ext,
  tk_config,
  tk_tool_def,
  tk_ok_result,
  tk_tool_call_response,
  tk_stop_response,
  tk_user_msg,
}

///|
using @support {
  type FakeRuntime,
  probe_effect,
  policy_replace_result,
  compact_tools_seed,
}

///|
priv struct InvokingTool {
  seen_tools : Array[String]
}

///|
impl @port.Extension for InvokingTool with fn extension_id(_self) -> String {
  "parent"
}

///|
impl @port.Extension for InvokingTool with fn manifest(self) -> @port.ExtensionManifest {
  @port.ExtensionManifest(id="parent", tools=[self], tool_call_owners=["child"])
}

///|
impl @port.ToolProvider for InvokingTool with fn list_tools(_self) -> Array[
  @kernel.ToolDef,
] {
  [{ ..tk_tool_def("parent", "call a child"), policy: Exclusive, }]
}

///|
impl @port.ToolProvider for InvokingTool with fn execute(
  self,
  ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome {
  self.seen_tools.append(ctx.tools().map(def => def.name.to_string()))
  match ctx.invoke("child", { "text": "hello" }) {
    Completed(outcome) => outcome
    Interrupted(reason~, ..) =>
      RuntimeFailure(error_category="ChildInterrupted", message=reason)
  }
}

///|
priv struct InvocationFixture {
  id : String
  definitions : Array[@kernel.ToolDef]
  owners : Array[String]
  action : async (@port.ToolCallContext) -> @kernel.ToolOutcome
}

///|
impl @port.Extension for InvocationFixture with fn extension_id(self) -> String {
  self.id
}

///|
impl @port.Extension for InvocationFixture with fn manifest(self) -> @port.ExtensionManifest {
  @port.ExtensionManifest(
    id=self.id,
    tools=[self],
    tool_call_owners=self.owners,
  )
}

///|
impl @port.ToolProvider for InvocationFixture with fn list_tools(self) -> Array[
  @kernel.ToolDef,
] {
  self.definitions
}

///|
impl @port.ToolProvider for InvocationFixture with fn execute(self, ctx) -> @kernel.ToolOutcome {
  (self.action)(ctx) catch {
    error => raise @error.RuntimeError::InvocationFailed(error.to_string())
  }
}

///|
fn contribution_result_texts(
  outcomes : Array[@kernel.ToolOutcome],
) -> Array[String] {
  outcomes.map(fn(outcome) {
    match outcome {
      Success(content~, ..) => content
      SuccessWithAttachments(content~, ..) => content
      other => other.summary()
    }
  })
}

///|
/// Extension-side publisher: takes the capability in `on_compose` (which only
/// wires handles) and publishes its first group from the managed async
/// `on_start` scope. The accepted capability stays reachable so a test can
/// replace or withdraw it while the Agent is alive.
priv struct ContributionPublisher {
  initial : &@port.ToolProvider
  /// Publish `initial` from the managed `on_start` scope. Tests that need to
  /// publish at a precise moment clear this and call `publish` themselves.
  mut publish_at_start : Bool
  mut contributions : @port.ToolContributions?
  mut published : @port.ToolContributionCommit?
}

///|
fn ContributionPublisher::new(
  provider : &@port.ToolProvider,
) -> ContributionPublisher {
  {
    initial: provider,
    publish_at_start: true,
    contributions: None,
    published: None,
  }
}

///|
fn ContributionPublisher::capability(
  self : ContributionPublisher,
) -> @port.ToolContributions {
  match self.contributions {
    Some(value) => value
    None => abort("tool contribution capability was not composed")
  }
}

///|
async fn ContributionPublisher::publish(
  self : ContributionPublisher,
  provider : &@port.ToolProvider,
  retire? : @port.ToolRetire,
) -> @port.ToolContributionCommit {
  let commit = match self.capability().replace(provider~, retire?) {
    Ok(commit) => commit
    Err(error) =>
      abort("tool contribution publish rejected: " + error.to_string())
  }
  self.published = Some(commit)
  commit
}

///|
impl @port.Lifecycle for ContributionPublisher with fn on_compose(
  self : ContributionPublisher,
  view : @port.CompositionView,
) {
  match view.tool_contributions() {
    Some(contributions) => self.contributions = Some(contributions)
    None =>
      raise @error.CompositionError::ExtensionComposeFailed(
        manifest_id="contrib",
        detail="Capability::ToolContribution was not delivered",
      )
  }
}

///|
impl @port.Lifecycle for ContributionPublisher with fn on_start(
  self : ContributionPublisher,
) {
  if self.publish_at_start {
    ignore(self.publish(self.initial))
  }
}
