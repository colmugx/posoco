///|
/// Manifest aggregation — merges `Array[&Extension]` into a single
/// `AggregatedPorts` value for the agent constructor.

///|
/// Flattened port bundle ready for the agent constructor. The `model` field
/// is a single value (multi-model routing is solved in-extension), and `ui`
/// is wrapped into one UiPort reference (the agent never sees a bare array).
pub(all) struct AggregatedPorts {
  model : &@port.ModelPort
  tools : Array[&@port.ToolProvider]
  sessions : Array[&@port.SessionStore]
  observers : Array[&@port.Observer]
  pre_model_hooks : Array[&@port.PreModelHook]
  pre_tool_hooks : Array[&@port.PreToolHook]
  post_event_hooks : Array[&@port.PostEventHook]
  memory : Array[&@port.MemoryPort]
  lifecycle : Array[&@port.Lifecycle]
  commands : Array[&@port.CommandPort]
  ui : &@port.UiPort
  prompt_contributors : Array[&@port.SystemPromptContributor]
  /// IDs of every extension that contributed at least one port. Useful for
  /// diagnostics and for the agent's startup banner.
  contributor_ids : Array[String]
}

///|
/// Aggregate every extension's manifest into one port bundle.
/// Order follows extension array order; collisions fail fast.
pub fn aggregate_extensions(
  exts : Array[&@port.Extension],
) -> AggregatedPorts raise @error.CompositionError {
  if exts.length() == 0 {
    raise @error.CompositionError::EmptyManifests
  }
  // Per-port collectors.
  let models : Array[&@port.ModelPort] = []
  let model_manifests : Array[String] = []
  let tools : Array[&@port.ToolProvider] = []
  let tool_manifests : Map[String, Array[String]] = Map::from_array([])
  let sessions : Array[&@port.SessionStore] = []
  let observers : Array[&@port.Observer] = []
  let pre_model_hooks : Array[&@port.PreModelHook] = []
  let pre_tool_hooks : Array[&@port.PreToolHook] = []
  let post_event_hooks : Array[&@port.PostEventHook] = []
  let memory : Array[&@port.MemoryPort] = []
  let lifecycle : Array[&@port.Lifecycle] = []
  let commands : Array[&@port.CommandPort] = []
  let command_manifests : Map[String, Array[String]] = Map::from_array([])
  let ui : Array[&@port.UiPort] = []
  let prompt_contributors : Array[&@port.SystemPromptContributor] = []
  let contributor_ids : Array[String] = []
  for ext in exts {
    let manifest = ext.manifest()
    let mid = manifest.id
    if mid == "" {
      raise @error.CompositionError::ManifestSchemaError(
        manifest_id="",
        detail="extension returned a manifest with empty id",
      )
    }
    let contributed = manifest.models.length() +
      manifest.tools.length() +
      manifest.sessions.length() +
      manifest.observers.length() +
      manifest.pre_model_hooks.length() +
      manifest.pre_tool_hooks.length() +
      manifest.post_event_hooks.length() +
      manifest.memory.length() +
      manifest.lifecycle.length() +
      manifest.commands.length() +
      manifest.ui.length() +
      manifest.prompt_contributors.length()
    if contributed > 0 {
      contributor_ids.push(mid)
    }
    // models: collect for later cardinality check
    for m in manifest.models {
      models.push(m)
      model_manifests.push(mid)
    }
    // tools: collect + collision check by tool name
    for provider in manifest.tools {
      for tool_def in provider.list_tools() {
        let name = tool_def.name.to_string()
        let source_label = match tool_def.provenance {
          Some(s) if s != "" => s
          _ =>
            "ToolDef.provenance is empty for tool '" +
            name +
            "' in manifest '" +
            mid +
            "' (set ToolDef.provenance to a stable provider id to disambiguate)"
        }
        if tool_manifests.contains(name) {
          let existing = tool_manifests[name]
          existing.push(mid)
          raise @error.CompositionError::ToolCollision(
            name,
            "tool collision; first declaration: " +
            existing[0] +
            "; conflicting declaration: " +
            source_label,
            manifests=existing,
          )
        } else {
          tool_manifests[name] = [source_label]
        }
      }
      tools.push(provider)
    }
    // commands: collect + collision check by command id
    for cmd in manifest.commands {
      for def in cmd.commands() {
        let cid = def.id
        if command_manifests.contains(cid) {
          let existing = command_manifests[cid]
          existing.push(mid)
          raise @error.CompositionError::CommandCollision(
            cid,
            manifests=existing,
          )
        } else {
          command_manifests[cid] = [mid]
        }
      }
      commands.push(cmd)
    }
    // simple concat ports
    for s in manifest.sessions {
      sessions.push(s)
    }
    for o in manifest.observers {
      observers.push(o)
    }
    for h in manifest.pre_model_hooks {
      pre_model_hooks.push(h)
    }
    for h in manifest.pre_tool_hooks {
      pre_tool_hooks.push(h)
    }
    for h in manifest.post_event_hooks {
      post_event_hooks.push(h)
    }
    for m in manifest.memory {
      memory.push(m)
    }
    for l in manifest.lifecycle {
      lifecycle.push(l)
    }
    for u in manifest.ui {
      ui.push(u)
    }
    for p in manifest.prompt_contributors {
      prompt_contributors.push(p)
    }
  }
  // Model cardinality: exactly 1.
  match models.length() {
    0 => raise @error.CompositionError::MissingModel
    1 => ()
    _ =>
      raise @error.CompositionError::MultipleModels(manifests=model_manifests)
  }
  // UI cardinality: 0 → NoopUiPort, 1 → passthrough, 2+ → CompositeUiPort.
  let ui_ref : &@port.UiPort = match ui.length() {
    0 => {
      let n : &@port.UiPort = NoopUiPort()
      n
    }
    1 => {
      let u : &@port.UiPort = ui[0]
      u
    }
    _ => {
      let c : &@port.UiPort = CompositeUiPort(ui.copy())
      c
    }
  }
  {
    model: models[0],
    tools,
    sessions,
    observers,
    pre_model_hooks,
    pre_tool_hooks,
    post_event_hooks,
    memory,
    lifecycle,
    commands,
    ui: ui_ref,
    prompt_contributors,
    contributor_ids,
  }
}
