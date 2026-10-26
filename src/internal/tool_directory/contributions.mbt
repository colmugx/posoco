///|
priv struct ContributedToolGroup {
  revision : Int32
  entries : Array[ToolEntry]
  withdrawn : Bool
}

///|
/// Definitions and executors are committed together; only operation admission
/// derives a catalog and a binding projection from this authority.
pub struct ToolContributionRegistry {
  priv mut base : Array[ToolEntry]
  priv mut captured_defs : Array[@kernel.ToolDef]
  priv groups : Map[String, ContributedToolGroup]
  priv mut pending_capture : Bool
  priv mut closed : Bool
}

///|
pub fn ToolContributionRegistry::ToolContributionRegistry(
  base : Array[ToolEntry],
) -> ToolContributionRegistry {
  {
    base,
    captured_defs: base.map(e => {
      let def = snapshot_tool_def(e.definition)
      { ..def, input_schema: normalize_tool_schema(def.input_schema), }
    }),
    groups: Map::from_array([]),
    pending_capture: false,
    closed: false,
  }
}

///|
pub fn ToolContributionRegistry::capability(
  self : ToolContributionRegistry,
  owner : String,
) -> @port.ToolContributions {
  @port.ToolContributions::from_callbacks(
    owner~,
    replace=provider => self.replace(owner, provider),
    withdraw=fn() { self.withdraw(owner) },
    revision=fn() { self.revision(owner) },
  )
}

///|
fn ToolContributionRegistry::entries(
  self : ToolContributionRegistry,
  excluding? : String,
) -> Array[ToolEntry] {
  let entries = self.base.copy()
  for owner, group in self.groups {
    if !group.withdrawn && excluding != Some(owner) {
      entries.append(group.entries)
    }
  }
  entries
}

///|
fn ToolContributionRegistry::replace(
  self : ToolContributionRegistry,
  owner : String,
  provider : &@port.ToolProvider,
) -> Result[@port.ToolContributionCommit, @port.ToolContributionError] {
  if self.closed {
    return Err(Closed)
  }
  if owner == "" {
    return Err(Rejected(reason="owner must be non-empty"))
  }
  let candidate = provider
    .list_tools()
    .map(def => {
      definition: owned_tool_def(def, owner),
      provider: Some(provider),
    })
  let entries = self.entries(excluding=owner)
  entries.append(candidate)
  let _ = build_catalog_from_defs(
    entries.map(e => e.definition),
    CatalogVersion(1),
  ) catch {
    error =>
      return Err(Rejected(reason=bounded_error_label(error.to_string(), 256)))
  }
  let revision = match self.groups.get(owner) {
    Some(group) => group.revision + 1
    None => 1
  }
  self.groups[owner] = { revision, entries: candidate, withdrawn: false, }
  self.pending_capture = true
  Ok({ owner, revision, })
}

///|
fn ToolContributionRegistry::withdraw(
  self : ToolContributionRegistry,
  owner : String,
) -> Result[@port.ToolContributionCommit, @port.ToolContributionError] {
  if self.closed {
    return Err(Closed)
  }
  match self.groups.get(owner) {
    None => Err(NotContributed)
    Some(group) => {
      let revision = if group.withdrawn {
        group.revision
      } else {
        group.revision + 1
      }
      if !group.withdrawn {
        self.groups[owner] = {
          revision,
          entries: group.entries,
          withdrawn: true,
        }
        self.pending_capture = true
      }
      Ok({ owner, revision, })
    }
  }
}

///|
fn ToolContributionRegistry::revision(
  self : ToolContributionRegistry,
  owner : String,
) -> Int32? {
  match self.groups.get(owner) {
    Some(group) if !group.withdrawn => Some(group.revision)
    _ => None
  }
}

///|
pub fn ToolContributionRegistry::captured_tools(
  self : ToolContributionRegistry,
) -> Map[String, &@port.ToolProvider] {
  let tools : Map[String, &@port.ToolProvider] = Map::from_array([])
  for entry in self.entries() {
    if entry.provider is Some(provider) {
      tools[entry.definition.name.to_string()] = provider
    }
  }
  tools
}

///|
pub fn ToolContributionRegistry::close(self : ToolContributionRegistry) -> Unit {
  self.closed = true
}
