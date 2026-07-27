///|
/// Canonical extension contracts and their product host composition.
///
/// Extensions implement these bindings directly. This host accepts and emits
/// canonical values only.

///|
pub(open) trait ModelBinding {
  fn model_id(Self) -> ModelId
  async fn complete(
    Self,
    messages : Array[@kernel.CanonicalMessage],
    tool_definitions : Array[@kernel.CanonicalToolDef],
    call_options : Json,
    on_chunk : @kernel.HostChunkCallback?,
  ) -> Result[@kernel.AssistantCompletion, @kernel.ModelFailure]
}

///|
pub(open) trait ToolBinding {
  /// Stable owner identity for every definition this binding exposes.
  fn owner_id(Self) -> @kernel.OwnerId

  /// Immutable definitions captured during composition. Every definition must
  /// use `owner_id()` and exactly match the catalog snapshot.
  fn definitions(Self) -> Array[@kernel.CanonicalToolDef]
  async fn execute(
    Self,
    call_id : @kernel.CallId,
    tool_name : @kernel.ToolName,
    arguments : Json,
  ) -> @kernel.ToolOutcome
}

///|
pub(all) suberror CanonicalHostCompositionError {
  OwnerMismatch(
    tool_name~ : String,
    declared_owner~ : String,
    binding_owner~ : String
  )
  DuplicateBinding(tool_name~ : String)
  MissingFromCatalog(tool_name~ : String)
  DefinitionMismatch(tool_name~ : String)
  CatalogToolUnbound(tool_name~ : String)
}

///|
pub impl Show for CanonicalHostCompositionError with fn to_string(
  self : CanonicalHostCompositionError,
) -> String {
  match self {
    OwnerMismatch(tool_name~, declared_owner~, binding_owner~) =>
      "OwnerMismatch(tool=\{tool_name}, declared=\{declared_owner}, binding=\{binding_owner})"
    DuplicateBinding(tool_name~) => "DuplicateBinding(tool=\{tool_name})"
    MissingFromCatalog(tool_name~) => "MissingFromCatalog(tool=\{tool_name})"
    DefinitionMismatch(tool_name~) => "DefinitionMismatch(tool=\{tool_name})"
    CatalogToolUnbound(tool_name~) => "CatalogToolUnbound(tool=\{tool_name})"
  }
}

///|
/// Canonical host assembled once at product composition. The catalog is
/// supplied by the caller after its atomic validation; this constructor proves
/// that every catalog definition has one exact execution binding before a
/// Puppet can start.
pub struct CanonicalHost {
  model : &ModelBinding
  tools_by_name : Map[String, &ToolBinding]
}

///|
pub fn CanonicalHost::from_catalog(
  model : &ModelBinding,
  catalog : @kernel.ToolCatalogSnapshot,
  tools : Array[&ToolBinding],
) -> CanonicalHost raise CanonicalHostCompositionError {
  let tools_by_name : Map[String, &ToolBinding] = Map::from_array([])
  for tool in tools {
    let binding_owner = tool.owner_id()
    for definition in tool.definitions() {
      let name = definition.name.to_string()
      if definition.owner != binding_owner {
        raise OwnerMismatch(
          tool_name=name,
          declared_owner=definition.owner.to_string(),
          binding_owner=binding_owner.to_string(),
        )
      }
      if tools_by_name.contains(name) {
        raise DuplicateBinding(tool_name=name)
      }
      let catalog_definition = match catalog.find(definition.name) {
        Some(entry) => entry.definition
        None => raise MissingFromCatalog(tool_name=name)
      }
      if catalog_definition != definition {
        raise DefinitionMismatch(tool_name=name)
      }
      tools_by_name[name] = tool
    }
  }
  for definition in catalog.definitions() {
    let name = definition.name.to_string()
    if !tools_by_name.contains(name) {
      raise CatalogToolUnbound(tool_name=name)
    }
  }
  { model, tools_by_name }
}

///|
pub fn CanonicalHost::model_id(self : CanonicalHost) -> ModelId {
  self.model.model_id()
}

///|
pub impl @kernel.HostRuntime for CanonicalHost with fn call_model(
  self : CanonicalHost,
  messages : Array[@kernel.CanonicalMessage],
  tool_definitions : Array[@kernel.CanonicalToolDef],
  call_options : Json,
  on_chunk : @kernel.HostChunkCallback?,
) -> Result[@kernel.AssistantCompletion, @kernel.ModelFailure] {
  self.model.complete(messages, tool_definitions, call_options, on_chunk)
}

///|
pub impl @kernel.HostRuntime for CanonicalHost with fn execute_tool(
  self : CanonicalHost,
  owner_id : @kernel.OwnerId,
  call_id : @kernel.CallId,
  tool_name : @kernel.ToolName,
  arguments : Json,
) -> @kernel.ToolOutcome {
  let name = tool_name.to_string()
  match self.tools_by_name.get(name) {
    None =>
      @kernel.RuntimeFailure(
        error_category="MissingOwner",
        message="no canonical tool binding for '" + name + "'",
      )
    Some(tool) =>
      if tool.owner_id() != owner_id {
        @kernel.RuntimeFailure(
          error_category="MissingOwner",
          message="catalog owner does not match binding for '" + name + "'",
        )
      } else {
        tool.execute(call_id, tool_name, arguments)
      }
  }
}

///|
/// Cancel propagation is a terminal-boundary concern owned by the Puppet's
/// `propagate_terminal_cancellations`. Direct bindings have no live-effect
/// registry yet: real concurrent transport cancellation requires a separately
/// designed, testable concurrent execution model and is out of this core
/// cutover. Every requested id is reported as `NotPropagated` so callers see
/// the limitation loudly.
pub impl @kernel.HostRuntime for CanonicalHost with fn cancel_effects(
  self : CanonicalHost,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  ignore(self)
  ignore(reason)
  effect_ids.map(id => (id, @kernel.NotPropagated))
}
