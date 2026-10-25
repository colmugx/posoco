///|
/// A candidate is accepted only after Agent installs its catalog. The paired
/// bindings cannot be recomputed from a later registry state.
pub struct ToolDirectoryCapture {
  catalog : @kernel_exec.ToolCatalogSnapshot
  bindings : Map[String, &@port.ToolProvider]
  priv definitions : Array[@kernel.ToolDef]
}

///|
pub fn ToolContributionRegistry::is_closed(
  self : ToolContributionRegistry,
) -> Bool {
  self.closed
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
  for _, group in self.groups {
    if !group.withdrawn {
      all_defs.append(group.entries.map(entry => entry.definition))
    }
  }
  ignore(build_catalog_from_defs(all_defs, version))
  self.base = candidate
  self.pending_capture = true
}

///|
pub fn ToolContributionRegistry::prepare_capture(
  self : ToolContributionRegistry,
  version : @kernel.CatalogVersion,
  hooks : Array[&@port.PipelineHook],
) -> ToolDirectoryCapture? raise @error.CompositionError {
  if self.closed {
    return None
  }
  let definitions = self
    .entries()
    .map(entry => {
      let definition = snapshot_tool_def(entry.definition)
      let mut exposure = definition.exposure
      for hook in hooks {
        exposure = exposure.narrow(
          hook.tool_exposure(snapshot_tool_def(definition)),
        )
      }
      {
        ..definition,
        exposure,
        input_schema: normalize_tool_schema(definition.input_schema),
      }
    })
  if !self.pending_capture && definitions == self.captured_defs {
    return None
  }
  let catalog = build_catalog_from_defs(definitions, version)
  Some({ catalog, bindings: self.captured_tools(), definitions, })
}

///|
pub fn ToolContributionRegistry::accept_capture(
  self : ToolContributionRegistry,
  capture : ToolDirectoryCapture,
) -> Unit {
  self.pending_capture = false
  self.captured_defs = capture.definitions
}
