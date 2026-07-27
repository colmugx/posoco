///|
/// Canonical extension-host composition tests. These prove that the host binds
/// only exact catalog definitions and routes execution without root adapters.

///|
pub(all) struct CanonicalHostModel {}

///|
pub impl ModelBinding for CanonicalHostModel with fn model_id(
  _self : CanonicalHostModel,
) -> ModelId {
  ModelId::unchecked("canonical-host-test")
}

///|
pub impl ModelBinding for CanonicalHostModel with fn complete(
  _self : CanonicalHostModel,
  _messages : Array[@kernel.CanonicalMessage],
  _tool_definitions : Array[@kernel.CanonicalToolDef],
  _call_options : Json,
  _on_chunk : @kernel.HostChunkCallback?,
) -> Result[@kernel.AssistantCompletion, @kernel.ModelFailure] {
  Ok(fixture_stop("done"))
}

///|
pub(all) struct CanonicalHostTool {
  definition : @kernel.CanonicalToolDef
  mut calls : Int
}

///|
pub impl ToolBinding for CanonicalHostTool with fn owner_id(
  self : CanonicalHostTool,
) -> @kernel.OwnerId {
  self.definition.owner
}

///|
pub impl ToolBinding for CanonicalHostTool with fn definitions(
  self : CanonicalHostTool,
) -> Array[@kernel.CanonicalToolDef] {
  [self.definition]
}

///|
pub impl ToolBinding for CanonicalHostTool with fn execute(
  self : CanonicalHostTool,
  call_id : @kernel.CallId,
  tool_name : @kernel.ToolName,
  _arguments : Json,
) -> @kernel.ToolOutcome {
  self.calls = self.calls + 1
  @kernel.Success(
    content=tool_name.to_string() + ":" + call_id.to_string(),
    structured=None,
  )
}

///|
fn canonical_host_definition() -> @kernel.CanonicalToolDef {
  @kernel.CanonicalToolDef(
    name=@kernel.ToolName::unchecked("canonical_probe"),
    description="canonical host probe",
    input_schema=Json::object(Map::from_array([])),
    owner=@kernel.OwnerId::unchecked("canonical_test"),
    policy=@kernel.Parallel,
    provenance=Some("canonical_host_wbtest"),
  )
}

///|
fn canonical_host_catalog(
  definition : @kernel.CanonicalToolDef,
) -> @kernel.ToolCatalogSnapshot raise @kernel.CatalogCompositionError {
  let builder = @kernel.ToolCatalogBuilder()
  ignore(builder.add(definition))
  builder.finish(version=@kernel.CatalogVersion(1))
}

///|
async test "canonical_host/routes_exact_catalog_binding" {
  let definition = canonical_host_definition()
  let catalog = canonical_host_catalog(definition)
  let model = CanonicalHostModel::{  }
  let tool = CanonicalHostTool::{ definition, calls: 0 }
  let host = CanonicalHost::from_catalog(model, catalog, [tool])
  let outcome = (host as &@kernel.HostRuntime).execute_tool(
    @kernel.OwnerId::unchecked("canonical_test"),
    @kernel.CallId::unchecked("call-1"),
    @kernel.ToolName::unchecked("canonical_probe"),
    Json::object(Map::from_array([])),
  )
  match outcome {
    @kernel.Success(content~, ..) =>
      assert_eq(content, "canonical_probe:call-1")
    _ => fail("expected canonical binding success")
  }
  assert_eq(tool.calls, 1)
}

///|
async test "canonical_host/rejects_binding_not_present_in_catalog" {
  let catalog = canonical_host_catalog(canonical_host_definition())
  let mismatched : @kernel.CanonicalToolDef = @kernel.CanonicalToolDef(
    name=@kernel.ToolName::unchecked("other_probe"),
    description="mismatch",
    input_schema=Json::object(Map::from_array([])),
    owner=@kernel.OwnerId::unchecked("canonical_test"),
    policy=@kernel.Parallel,
    provenance=Some("canonical_host_wbtest"),
  )
  let model = CanonicalHostModel::{  }
  let tool = CanonicalHostTool::{ definition: mismatched, calls: 0 }
  let result : Result[CanonicalHost, CanonicalHostCompositionError] = Ok(
    CanonicalHost::from_catalog(model, catalog, [tool]),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(MissingFromCatalog(tool_name~)) => assert_eq(tool_name, "other_probe")
    _ => fail("expected MissingFromCatalog")
  }
}
