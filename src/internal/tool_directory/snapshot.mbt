///|
/// A candidate is accepted only after Agent installs its catalog. The paired
/// bindings cannot be recomputed from a later registry state: one frozen entry
/// set yields the definitions, the executor bindings and the version lease
/// together.
pub struct ToolDirectoryCapture {
  catalog : @kernel_exec.ToolCatalogSnapshot
  bindings : Map[String, &@port.ToolProvider]
  priv definitions : Array[@kernel.ToolDef]
  /// Tool name → contributed version behind the captured binding.
  priv binding_versions : Map[String, Int32]
  /// Versions this capture projects; an admitted operation retains each once.
  priv versions : Array[Int32]
  /// Registry generation at freeze time. Accepting a stale capture must not
  /// clear a publication that landed while the capture was being prepared.
  priv generation : Int32
}

///|
pub fn ToolDirectoryCapture::binding_versions(
  self : ToolDirectoryCapture,
) -> Map[String, Int32] {
  self.binding_versions.copy()
}

///|
pub fn ToolDirectoryCapture::versions(
  self : ToolDirectoryCapture,
) -> Array[Int32] {
  self.versions.copy()
}

///|
pub fn ToolContributionRegistry::is_closed(
  self : ToolContributionRegistry,
) -> Bool {
  self.closed.val
}

///|
pub fn ToolContributionRegistry::replace_source(
  self : ToolContributionRegistry,
  definitions : Array[@kernel.ToolDef],
  version : @kernel.CatalogVersion,
) -> Unit raise @error.CompositionError {
  let bound : Map[String, &@port.ToolProvider] = Map::from_array([])
  for entry in self.base {
    if entry.provider is Some(provider) {
      bound[entry.definition.name.to_string()] = provider
    }
  }
  let candidate = definitions.map(def => {
    ToolEntry::legacy(def, bound.get(def.name.to_string()))
  })
  let all_defs = candidate.map(entry => entry.definition)
  for owner, slot in self.slots {
    match slot.version {
      Some(id) =>
        match self.versions.get(id) {
          Some(active) if !active.gate.revoked =>
            all_defs.append(active.entries.map(entry => entry.definition))
          _ => ()
        }
      None => ()
    }
    ignore(owner)
  }
  ignore(build_catalog_from_defs(all_defs, version))
  self.base = candidate
  self.pending_capture = true
  self.generation = self.generation + 1
}

///|
/// Freeze one entries snapshot, then derive the catalog, the bindings and the
/// version lease from it so a concurrently published group can never produce
/// mismatched definitions and bindings.
pub fn ToolContributionRegistry::prepare_capture(
  self : ToolContributionRegistry,
  version : @kernel.CatalogVersion,
  hooks : Array[&@port.PipelineHook],
) -> ToolDirectoryCapture? raise @error.CompositionError {
  if self.closed.val {
    return None
  }
  let generation = self.generation
  let frozen = self.entries()
  let definitions : Array[@kernel.ToolDef] = []
  let bindings : Map[String, &@port.ToolProvider] = Map::from_array([])
  let binding_versions : Map[String, Int32] = Map::from_array([])
  let versions : Array[Int32] = []
  for entry in frozen {
    let definition = snapshot_tool_def(entry.definition)
    let mut exposure = definition.exposure
    for hook in hooks {
      exposure = exposure.narrow(
        hook.tool_exposure(snapshot_tool_def(definition)),
      )
    }
    let name = definition.name.to_string()
    definitions.push({
      ..definition,
      exposure,
      input_schema: normalize_tool_schema(definition.input_schema),
    })
    if entry.provider is Some(provider) {
      bindings[name] = provider
    }
    match entry.version {
      Some(version_id) => {
        binding_versions[name] = version_id
        if !versions.contains(version_id) {
          versions.push(version_id)
        }
      }
      None => ()
    }
  }
  if !self.pending_capture && definitions == self.captured_defs {
    return None
  }
  let catalog = build_catalog_from_defs(definitions, version)
  Some({
    catalog,
    bindings,
    definitions,
    binding_versions,
    versions,
    generation,
  })
}

///|
pub fn ToolContributionRegistry::accept_capture(
  self : ToolContributionRegistry,
  capture : ToolDirectoryCapture,
) -> Unit {
  // A change committed after the freeze keeps the capture pending, so the next
  // admission observes it instead of losing it to this accept.
  if capture.generation == self.generation {
    self.pending_capture = false
  }
  self.captured_defs = capture.definitions
}
