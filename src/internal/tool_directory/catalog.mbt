///|
/// Bound an error label without interpreting its contents.
fn bounded_error_label(value : String, cap : Int32) -> String {
  let chars : Array[Char] = []
  let mut truncated = false
  for char in value {
    if chars.length() >= cap {
      truncated = true
      break
    }
    match char {
      '\n' | '\r' => chars.push(' ')
      other => chars.push(other)
    }
  }
  let label = String::from_array(chars)
  if truncated {
    label + "...(truncated)"
  } else {
    label
  }
}

///|
fn safe_error_label(value : String) -> String {
  bounded_error_label(value, 64)
}

///|
fn snapshot_json(value : Json) -> Json {
  match value {
    Array(items) => Json::array(items.map(snapshot_json))
    Object(fields) => {
      let snapshot : Map[String, Json] = Map::from_array([])
      for key in fields.keys() {
        snapshot[key] = snapshot_json(fields[key])
      }
      Json::object(snapshot)
    }
    scalar => scalar
  }
}

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
pub fn build_catalog_from_defs(
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
      exposure=tool.exposure,
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
/// Merge the core basic definitions ahead of a wired `CatalogSource`'s
/// definitions. Basic tools are the base layer, so a source definition
/// colliding with a basic name is shadowed (first-name-wins, basic first);
/// duplicates within the source list itself are not resolved here — the
/// catalog builder still rejects them.
pub fn merge_basic_catalog_defs(
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
fn snapshot_tool_def(tool : @kernel.ToolDef) -> @kernel.ToolDef {
  @kernel.ToolDef(
    name=tool.name,
    description=tool.description,
    input_schema=snapshot_json(tool.input_schema),
    owner=tool.owner,
    policy=tool.policy,
    provenance=tool.provenance,
    exposure=tool.exposure,
  )
}
