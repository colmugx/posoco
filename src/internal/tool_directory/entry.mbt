///|
/// Definition and fixed executor are assembled once, then projected together.
pub struct ToolEntry {
  definition : @kernel.ToolDef
  provider : &@port.ToolProvider
  /// Contributed version this entry belongs to; `None` for base/static entries
  /// that have no version lifetime.
  version : Int32?
}

///|
pub fn ToolEntry::bound(
  definition : @kernel.ToolDef,
  owner : String,
  provider : &@port.ToolProvider,
) -> ToolEntry {
  { definition: owned_tool_def(definition, owner), provider, version: None, }
}

///|
fn owned_tool_def(tool : @kernel.ToolDef, owner : String) -> @kernel.ToolDef {
  @kernel.ToolDef(
    name=tool.name,
    description=tool.description,
    input_schema=snapshot_json(tool.input_schema),
    owner=@kernel.OwnerId::unchecked(owner),
    policy=tool.policy,
    provenance=tool.provenance,
    exposure=tool.exposure,
  )
}

///|
pub fn entry_routing(
  entries : Array[ToolEntry],
) -> Map[String, &@port.ToolProvider] raise @error.CompositionError {
  let tool_map : Map[String, &@port.ToolProvider] = Map::from_array([])
  let seen = ToolNameIndex::new()
  for entry in entries {
    let def = entry.definition
    let name = def.name.to_string()
    let label = "owner='\{def.owner.to_string()}', " + tool_provenance(def)
    match seen.record(name, label) {
      Some(labels) =>
        raise ToolCollision(name, tool_collision_message(labels[0], label), manifests=[])
      None => ()
    }
    tool_map[name] = entry.provider
  }
  tool_map
}
