///|
/// Agent-side tool catalog: canonical schema normalization, the
/// composition snapshots, and the CatalogSource refresh seam.

///|
/// Normalise a tool schema into the canonical form the Kernel catalog
/// accepts. The Kernel requires a JSON object (`{"type":"object",...}`) or a
/// boolean at the top level; providers often pass `Json::null()` to signal
/// "no schema". We convert `null` → empty object so providers keep working
/// without each one having to construct `{}`.
fn normalize_tool_schema(schema : Json) -> Json {
  match schema {
    Null => Json::object(Map::from_array([]))
    other => other
  }
}

///|
/// Build a `ToolCatalogSnapshot` from canonical definitions. Used both for
/// the port-derived catalog (at composition) and for `CatalogSource`
/// refreshes (at prompt boundaries, with a bumped version). The schema is
/// normalised into the Kernel's required object/boolean form; `owner` and
/// `policy` are taken verbatim from each definition.
fn build_catalog_from_defs(
  defs : Array[@kernel.ToolDef],
  version : @kernel.CatalogVersion,
) -> @kernel_exec.ToolCatalogSnapshot raise @error.CompositionError {
  let builder = @kernel_exec.ToolCatalogBuilder()
  for tool in defs {
    let def = @kernel.ToolDef(
      name=tool.name,
      description=tool.description,
      input_schema=normalize_tool_schema(tool.input_schema),
      owner=tool.owner,
      policy=tool.policy,
      provenance=tool.provenance,
    )
    try {
      let _ = builder.add(def)
    } catch {
      e =>
        raise ManifestSchemaError(
          manifest_id="agent.catalog",
          detail="catalog add '\{tool.name.to_string()}': " +
            safe_error_label(e.to_string()),
        )
    }
  }
  builder.finish(version~) catch {
    e =>
      raise ManifestSchemaError(
        manifest_id="agent.catalog",
        detail="catalog finish: " + safe_error_label(e.to_string()),
      )
  }
}

///|
/// Canonical definitions for the aggregated tool providers. Each tool's
/// declared `policy` is honored as-is (M1-T06: declarations select behavior
/// through stable composition contracts); providers that do not care declare
/// `Parallel`, the legacy `@async.all`-every-batch default. Owner is derived
/// from the ToolDef's own `owner` field if it is non-placeholder, else from
/// provenance, else `legacy_provider`.
fn provider_tool_defs(
  providers : Array[&@port.ToolProvider],
) -> Array[@kernel.ToolDef] {
  let defs : Array[@kernel.ToolDef] = []
  for provider in providers {
    for tool in provider.list_tools() {
      let owner_str = tool.owner.to_string()
      let owner : @kernel.OwnerId = if owner_str == "placeholder" ||
        owner_str == "" {
        match tool.provenance {
          Some(p) if p != "" => @kernel.OwnerId::unchecked(p)
          _ => @kernel.OwnerId::unchecked("legacy_provider")
        }
      } else {
        tool.owner
      }
      defs.push(
        ToolDef(
          name=tool.name,
          description=tool.description,
          input_schema=tool.input_schema,
          owner~,
          policy=tool.policy,
          provenance=tool.provenance,
        ),
      )
    }
  }
  defs
}

///|
/// Build a `ToolCatalogSnapshot` from the agent's aggregated tool providers.
fn build_agent_catalog(
  providers : Array[&@port.ToolProvider],
) -> @kernel_exec.ToolCatalogSnapshot raise @error.CompositionError {
  build_catalog_from_defs(provider_tool_defs(providers), CatalogVersion(1))
}

///|
/// Merge the core basic definitions ahead of a wired `CatalogSource`'s
/// definitions. Basic tools are the base layer, so a source definition
/// colliding with a basic name is shadowed (first-name-wins, basic first);
/// duplicates within the source list itself are not resolved here — the
/// catalog builder still rejects them.
fn merge_basic_catalog_defs(
  basic : Array[@kernel.ToolDef],
  source : Array[@kernel.ToolDef],
) -> Array[@kernel.ToolDef] {
  let defs : Array[@kernel.ToolDef] = []
  let basic_names : Map[String, Bool] = Map::from_array([])
  for tool in basic {
    defs.push(tool)
    basic_names[tool.name.to_string()] = true
  }
  for tool in source {
    if !basic_names.contains(tool.name.to_string()) {
      defs.push(tool)
    }
  }
  defs
}

///|
/// Catalog refresh at a prompt boundary (experimental runtime seam). With
/// no `CatalogSource` wired this is a no-op and the catalog stays the
/// static composition snapshot. Otherwise a changed `revision()` triggers
/// exactly one rebuild attempt:
/// - success → the new snapshot (next monotonic catalog version) is swapped
///   into the Puppet; subsequent runs see it, in-flight runs never do;
/// - validation failure or a busy pump → the previous snapshot stays in
///   effect and the failure is surfaced as a `secondary_failure` observer
///   event. The turn is never aborted by a catalog problem.
/// The revision tracker advances on every attempt, so a deterministically
/// bad definition set is not re-validated (and re-reported) on every turn;
/// the source retries by changing `revision()` again.
fn AgentRuntime::refresh_catalog_if_changed(self : AgentRuntime) -> Unit {
  match self.catalog_source {
    None => ()
    Some(source) => {
      let revision = source.revision()
      if revision == self.last_catalog_revision {
        return
      }
      self.last_catalog_revision = revision
      let version = @kernel.CatalogVersion(self.next_catalog_version)
      let snapshot = build_catalog_from_defs(
        merge_basic_catalog_defs(self.basic_tool_defs, source.tools()),
        version,
      ) catch {
        error => {
          emit_secondary_failure(
            self.observers,
            "catalog_refresh",
            "catalog revision \{revision} rejected: " +
            safe_error_label(error.to_string()),
          )
          return
        }
      }
      if self.puppet.replace_catalog(snapshot) {
        self.next_catalog_version = self.next_catalog_version + 1
      } else {
        emit_secondary_failure(
          self.observers,
          "catalog_refresh",
          "catalog revision \{revision} deferred: a run is active",
        )
      }
    }
  }
}
