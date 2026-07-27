///|
/// Boundary-journal contracts: effects must observe their intent boundary as
/// already durable, and the next model intent joins the final tool outcome
/// boundary instead of paying for a separate append.

///|
struct BoundaryProbeHost {
  journal : InMemoryJournal
  model_results : Array[Result[AssistantCompletion, ModelFailure]]
  mut definitions : Array[CanonicalToolDef]
  mut model_index : Int
  append_counts_at_model_call : Array[Int]
}

///|
fn BoundaryProbeHost::new(
  journal : InMemoryJournal,
  model_results : Array[Result[AssistantCompletion, ModelFailure]],
) -> BoundaryProbeHost {
  {
    journal,
    model_results: model_results.copy(),
    definitions: [],
    model_index: 0,
    append_counts_at_model_call: [],
  }
}

///|
fn BoundaryProbeHost::append_counts_at_model_call(
  self : BoundaryProbeHost,
) -> Array[Int] {
  self.append_counts_at_model_call.copy()
}

///|
pub impl ModelBinding for BoundaryProbeHost with fn model_id(
  _self : BoundaryProbeHost,
) -> ModelId {
  ModelId::unchecked("boundary-probe")
}

///|
pub impl ModelBinding for BoundaryProbeHost with fn complete(
  self,
  _messages : Array[CanonicalMessage],
  _tool_definitions : Array[CanonicalToolDef],
  _call_options : Json,
  _on_chunk : HostChunkCallback?,
) -> Result[AssistantCompletion, ModelFailure] {
  self.append_counts_at_model_call.push(self.journal.append_count())
  let index = self.model_index
  self.model_index = index + 1
  if index >= self.model_results.length() {
    Err(Runtime(reason="boundary probe exhausted model results"))
  } else {
    self.model_results[index]
  }
}

///|
pub impl ToolBinding for BoundaryProbeHost with fn owner_id(
  _self : BoundaryProbeHost,
) -> OwnerId {
  OwnerId::unchecked("fixture")
}

///|
pub impl ToolBinding for BoundaryProbeHost with fn definitions(
  self : BoundaryProbeHost,
) -> Array[CanonicalToolDef] {
  self.definitions.copy()
}

///|
pub impl ToolBinding for BoundaryProbeHost with fn execute(
  _self,
  call_id : CallId,
  _tool_name : ToolName,
  _arguments : Json,
) -> ToolOutcome {
  Success(content=call_id.to_string(), structured=None)
}

///|
fn BoundaryProbeHost::bind_catalog(
  self : BoundaryProbeHost,
  catalog : ToolCatalogSnapshot,
) -> CanonicalHost raise CanonicalHostCompositionError {
  self.definitions = catalog.definitions()
  CanonicalHost::from_catalog(self, catalog, [self])
}

///|
async test "puppet/boundary_commits_intent_before_each_model_effect" {
  let journal = InMemoryJournal()
  let host = BoundaryProbeHost::new(journal, [
    Ok(fixture_tool_calls([fixture_call("echo", "tool_1")])),
    Ok(fixture_stop("done")),
  ])
  let catalog = fixture_tool_catalog("echo")
  let puppet = Puppet(
    canonical_puppet_config(
      host.bind_catalog(catalog),
      catalog,
      journal,
      [],
      [],
      None,
      Json::null(),
    ),
  )

  assert_true(fixture_prompt(puppet, "boundary_intent") is Accepted(_))
  // Initial InputAccepted boundary exists before the first model effect. The
  // final tool outcome and second model intent share the third boundary.
  assert_eq(host.append_counts_at_model_call(), [1, 3])
  assert_eq(journal.append_count(), 4)
}
