///|
/// A deterministic on-call model adapter: investigate service health, file a
/// triage report, then close the turn. Replace with a real ModelPort to let an
/// LLM decide which tools to use.
struct IncidentModel {
  step : Ref[Int32]
}

///|
pub impl @posoco.ModelPort for IncidentModel with fn chat(
  self,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let step = self.step.val
  self.step.val = step + 1
  let completion = if step < 2 {
    let tool_name = if step == 0 {
      "inspect_service"
    } else {
      "file_incident"
    }
    let call : @posoco.ToolCall = {
      call_id: @posoco.CallId::unchecked("oncall-\{step}"),
      name: @posoco.ToolName::unchecked(tool_name),
      arguments: Json::object(Map::from_array([])),
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
      content=[@posoco.Content::Text("Triage complete; incident recorded.")],
      tool_calls=[],
      reasoning=None,
      finish_reason=@posoco.FinishReason::Stop,
      usage=None,
    )
  }
  { completion, processed_messages: messages.to_owned(), }
}

///|
pub impl @posoco.ModelPort for IncidentModel with fn compact(
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
pub impl @posoco.ModelPort for IncidentModel with fn provider_config(_self) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
/// Two ordinary tool calls executed under the same Agent run. For a real
/// system, these could be monitoring and incident-management integrations.
struct IncidentTools {
  executed : Array[String]
}

///|
pub impl @posoco.ToolProvider for IncidentTools with fn list_tools(_self) -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef(
      name=@posoco.ToolName::unchecked("inspect_service"),
      description="Inspect the health of the checkout API",
      input_schema=Json::object(Map::from_array([])),
      owner=@posoco.OwnerId::unchecked("placeholder"),
      policy=@posoco.ExecutionPolicy::Sequential,
      provenance=None,
    ),
    @posoco.ToolDef(
      name=@posoco.ToolName::unchecked("file_incident"),
      description="File a report describing the service incident",
      input_schema=Json::object(Map::from_array([])),
      owner=@posoco.OwnerId::unchecked("placeholder"),
      policy=@posoco.ExecutionPolicy::Exclusive,
      provenance=None,
    ),
  ]
}

///|
pub impl @posoco.ToolProvider for IncidentTools with fn execute(
  self,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let name = ctx.name.to_string()
  self.executed.push(name)
  let content = if name == "inspect_service" {
    "checkout API error rate 17%; upstream timed out"
  } else {
    "INC-1042 created with checkout API diagnostic summary"
  }
  @posoco.ToolOutcome::Success(content~, structured=None)
}

///|
struct OnCallApp {
  model : IncidentModel
  tools : IncidentTools
}

///|
pub impl @posoco.Extension for OnCallApp with fn extension_id(_self) -> String {
  "oncall"
}

///|
pub impl @posoco.Extension for OnCallApp with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="oncall",
    models=[self.model],
    tools=[self.tools],
  )
}

///|
async fn run_demo() -> Unit {
  let app = OnCallApp::{
    model: { step: Ref(0), },
    tools: { executed: [], },
  }
  let agent = @posoco.Agent(
    exts=[app],
    config=@posoco.agent_config(max_tool_rounds=Some(3)),
    events=@posoco.EventSystem(),
  )
  let request = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text(
      "Checkout API is returning errors. Investigate and file a report.",
    ),
  ])
  let result = agent.run_turn(request, "oncall-inc1042")
  if app.tools.executed != ["inspect_service", "file_incident"] {
    abort("on-call tools did not execute in the expected order")
  }
  if result.tool_results.length() != 2 {
    abort("expected two real tool outcomes")
  }
  println("diagnostic: checkout API error rate 17%")
  println("report: INC-1042 created")
  agent.shutdown()
}

///|
async fn main {
  run_demo()
}
