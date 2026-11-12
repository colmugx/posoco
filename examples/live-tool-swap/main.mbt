///|
/// A release assistant that calls the currently available price-quote tool.
/// Each turn consumes two deterministic model steps: tool call, then response.
struct QuoteModel {
  step : Ref[Int32]
}

///|
pub impl @posoco.ModelPort for QuoteModel with fn chat(
  self,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let step = self.step.val
  self.step.val = step + 1
  let completion = if step % 2 == 0 {
    let call : @posoco.ToolCall = {
      call_id: @posoco.CallId::unchecked("quote-\{step}"),
      name: @posoco.ToolName::unchecked("shipping_quote"),
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
      content=[@posoco.Content::Text("Shipping quote received.")],
      tool_calls=[],
      reasoning=None,
      finish_reason=@posoco.FinishReason::Stop,
      usage=None,
    )
  }
  { completion, processed_messages: messages.to_owned(), }
}

///|
pub impl @posoco.ModelPort for QuoteModel with fn compact(
  _self,
  _scope : @posoco.InvocationScope,
  _messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  raise @posoco.ModelError::ResponseParse("not needed")
}

///|
pub impl @posoco.ModelPort for QuoteModel with fn provider_config(_self) -> @posoco.ProviderConfig {
  @posoco.ProviderConfig::empty()
}

///|
struct ShippingCalculator {
  label : String
  seen : Ref[Int32]
}

///|
pub impl @posoco.ToolProvider for ShippingCalculator with fn list_tools(_self) -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef(
      name=@posoco.ToolName::unchecked("shipping_quote"),
      description="Quote shipping cost for the current cart",
      input_schema=Json::object(Map::from_array([])),
      owner=@posoco.OwnerId::unchecked("placeholder"),
      policy=@posoco.ExecutionPolicy::Parallel,
      provenance=None,
    ),
  ]
}

///|
pub impl @posoco.ToolProvider for ShippingCalculator with fn execute(
  self,
  _ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  self.seen.val += 1
  @posoco.ToolOutcome::Success(content=self.label, structured=None)
}

///|
struct ShippingCatalog {
  initial : ShippingCalculator
  capability : Ref[@posoco.ToolContributions?]
}

///|
pub impl @posoco.Lifecycle for ShippingCatalog with fn on_compose(
  self,
  view : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  guard view.tool_contributions() is Some(capability) else {
    raise @posoco.CompositionError::ExtensionComposeFailed(
      manifest_id="shipping",
      detail="ToolContribution was not delivered",
    )
  }
  self.capability.val = Some(capability)
}

///|
pub impl @posoco.Lifecycle for ShippingCatalog with fn on_start(self) -> Unit {
  guard self.capability.val is Some(capability) else {
    abort("missing shipping capability")
  }
  match capability.replace(provider=self.initial) {
    Ok(commit) => println("published shipping catalog revision \{commit.revision}")
    Err(error) => abort("initial publish rejected: \{error}")
  }
}

///|
pub impl @posoco.Extension for ShippingCatalog with fn extension_id(_self) -> String {
  "shipping"
}

///|
pub impl @posoco.Extension for ShippingCatalog with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="shipping",
    lifecycle=[self],
    requires=[@posoco.Capability::ToolContribution],
  )
}

///|
struct QuoteApp {
  model : QuoteModel
}

///|
pub impl @posoco.Extension for QuoteApp with fn extension_id(_self) -> String {
  "quote-model"
}

///|
pub impl @posoco.Extension for QuoteApp with fn manifest(self) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(id="quote-model", models=[self.model])
}

///|
async fn quote(agent : @posoco.Agent, session : String) -> String {
  let input = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("Quote my order"),
  ])
  let result = agent.run_turn(input, session)
  guard result.tool_results.length() == 1 else {
    abort("expected one shipping tool result")
  }
  match result.tool_results[0] {
    @posoco.ToolOutcome::Success(content~, ..) => content
    other => abort("unexpected tool result: \{other.summary()}")
  }
}

///|
async fn run_demo() -> Unit {
  let v1 = ShippingCalculator::{ label: "standard: $8", seen: Ref(0), }
  let v2 = ShippingCalculator::{ label: "express: $12", seen: Ref(0), }
  let catalog = ShippingCatalog::{ initial: v1, capability: Ref(None), }
  let app = QuoteApp::{ model: { step: Ref(0), }, }
  let agent = @posoco.Agent(
    exts=[app, catalog],
    config=@posoco.agent_config(max_tool_rounds=Some(2)),
    events=@posoco.EventSystem(),
  )
  let first = quote(agent, "checkout")
  if first != "standard: $8" || v1.seen.val != 1 {
    abort("first operation did not use v1")
  }
  println("operation A: \{first}")
  guard catalog.capability.val is Some(capability) else {
    abort("missing owner-bound capability")
  }
  match capability.replace(provider=v2) {
    Ok(commit) => println("replaced shipping catalog revision \{commit.revision}")
    Err(error) => abort("replacement rejected: \{error}")
  }
  let second = quote(agent, "checkout")
  if second != "express: $12" || v2.seen.val != 1 || v1.seen.val != 1 {
    abort("second operation did not exclusively use v2")
  }
  println("operation B: \{second}")
  agent.shutdown()
}

///|
async fn main {
  run_demo()
}
