///|
/// A scripted model proposes a production deployment, then writes a response.
/// This is a real Agent model/tool loop with no HTTP dependency.
struct DeployModel {
  steps : Ref[Int32]
}

///|
fn DeployModel::new() -> DeployModel {
  { steps: Ref(0), }
}

///|
pub impl @posoco.ModelPort for DeployModel with fn chat(
  self,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let step = self.steps.val
  self.steps.val = step + 1
  let completion = if step == 0 {
    let call : @posoco.ToolCall = {
      call_id: @posoco.CallId::unchecked("deploy-1"),
      name: @posoco.ToolName::unchecked("deploy_release"),
      arguments: Json::object(
        Map::from_array([("environment", Json::string("production"))]),
      ),
    }
    @posoco.Completion(
      content=[],
      tool_calls=[call],
      reasoning=None,
      finish_reason=@posoco.FinishReason::ToolCalls,
      usage=None,
    )
  } else {
    @posoco.Completion(
      content=[@posoco.Content::Text("Deployment decision handled.")],
      tool_calls=[],
      reasoning=None,
      finish_reason=@posoco.FinishReason::Stop,
      usage=None,
    )
  }
  { completion, processed_messages: messages.to_owned(), }
}

///|
pub impl @posoco.ModelPort for DeployModel with fn compact(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse("not needed by this demo")
}

///|
pub impl @posoco.ModelPort for DeployModel with fn provider_config(_self) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
struct DeployTools {
  executions : Ref[Int32]
}

///|
pub impl @posoco.ToolProvider for DeployTools with fn list_tools(_self) -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef(
      name=@posoco.ToolName::unchecked("deploy_release"),
      description="Deploy a release to an environment",
      input_schema=Json::object(Map::from_array([])),
      owner=@posoco.OwnerId::unchecked("placeholder"),
      policy=@posoco.ExecutionPolicy::Exclusive,
      provenance=None,
    ),
  ]
}

///|
pub impl @posoco.ToolProvider for DeployTools with fn execute(
  self,
  _ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  self.executions.val += 1
  @posoco.ToolOutcome::Success(
    content="release deployed to production",
    structured=None,
  )
}

///|
struct DeploymentPolicy {
  approved : Bool
}

///|
pub impl @posoco.PipelineHook for DeploymentPolicy with fn before_tool(
  self,
  call : @posoco.ToolCall,
) -> @posoco.ToolDecision {
  if self.approved {
    @posoco.ToolDecision::ApproveAfterConsent(
      call~,
      consent_scope="deploy_release:production",
    )
  } else {
    @posoco.ToolDecision::Reject(
      reason="production deployment requires explicit approval",
    )
  }
}

///|
struct DeployApp {
  model : DeployModel
  tools : DeployTools
  policy : DeploymentPolicy
}

///|
pub impl @posoco.Extension for DeployApp with fn extension_id(_self) -> String {
  "deployment"
}

///|
pub impl @posoco.Extension for DeployApp with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="deployment",
    models=[self.model],
    tools=[self.tools],
    hooks=[self.policy],
  )
}

///|
async fn run_case(approved : Bool) -> Unit {
  let app = DeployApp::{
    model: DeployModel::new(),
    tools: { executions: Ref(0), },
    policy: { approved, },
  }
  let agent = @posoco.Agent(
    exts=[app],
    config=@posoco.agent_config(max_tool_rounds=Some(2)),
    events=@posoco.EventSystem(),
  )
  let input = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("Deploy release 1.2.3 to production"),
  ])
  let result = agent.run_turn(input, "deploy-demo")
  if result.tool_results.length() != 1 {
    abort("expected one tool outcome")
  }
  if approved {
    if app.tools.executions.val != 1 {
      abort("an approved deployment must execute exactly once")
    }
    println("APPROVED: deployment tool executed once")
  } else {
    if app.tools.executions.val != 0 {
      abort("rejected deployment caused a side effect")
    }
    println("REJECTED: no deployment tool executed")
  }
  agent.shutdown()
}

///|
async fn run_demo() -> Unit {
  run_case(false)
  run_case(true)
}

///|
async fn main {
  run_demo()
}
