///|
/// Manifest aggregation — turns `Array[&Extension]` into a single
/// `AggregatedPorts` value that the agent constructor consumes.
///
/// This is the single composition-time step that decides which extensions
/// contribute which ports. After aggregation the agent never re-visits
/// manifests; the resulting `AggregatedPorts` is what the internal Puppet
/// consumes directly.
///
/// Hard-fail semantics (preserved from 0.5.x):
/// - missing ModelPort → `CompositionError::MissingModel`
/// - more than one ModelPort → `MultipleModels` (multi-model routing is an
///   in-extension concern, e.g. posoco-ext-llm)
/// - tool name collision across extensions → `ToolCollision`
/// - slash-command id collision → `CommandCollision`
/// - empty extension list → `EmptyManifests`
/// - extension returning manifest with empty id → `ManifestSchemaError`
///
/// Concat semantics (preserved from 0.5.x per-port behavior):
/// - tools/sessions/observers/compressors/hooks/memory/lifecycle/commands/
///   prompt_contributors are concatenated in extension order
/// - ui: 0 → NoopUiPort, 1 → passthrough, 2+ → CompositeUiPort
/// - lifecycle ordering: startup runs in aggregate order, shutdown in reverse
///   (enforced by the agent's lifecycle driver, not here)

// ──────────────────────────────────────────────────────────────────────────
// AggregatedPorts — the result of aggregation
// ──────────────────────────────────────────────────────────────────────────

///|
/// Flattened port bundle ready for the agent constructor. The `model` field
/// is a single value (multi-model routing is solved in-extension), and `ui`
/// is wrapped into one UiPort reference (the agent never sees a bare array).
pub(all) struct AggregatedPorts {
  model : &@port.ModelPort
  tools : Array[&@port.ToolProvider]
  sessions : Array[&@port.SessionStore]
  observers : Array[&@port.Observer]
  compressors : Array[&@port.Compressor]
  hooks : Array[&@port.PipelineHook]
  memory : Array[&@port.MemoryPort]
  lifecycle : Array[&@port.Lifecycle]
  commands : Array[&@port.CommandPort]
  ui : &@port.UiPort
  prompt_contributors : Array[&@port.SystemPromptContributor]
  /// IDs of every extension that contributed at least one port. Useful for
  /// diagnostics and for the agent's startup banner.
  contributor_ids : Array[String]
}

// ──────────────────────────────────────────────────────────────────────────
// aggregate_extensions — the entry point
// ──────────────────────────────────────────────────────────────────────────

///|
/// Aggregate every extension's manifest into one port bundle.
///
/// Order matters: extension arrays are concatenated in the order extensions
/// appear in the input array, and within each manifest in the order the
/// manifest lists them. Tool/command collisions name the offending extension
/// ids in their error variants.
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
  let compressors : Array[&@port.Compressor] = []
  let hooks : Array[&@port.PipelineHook] = []
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
      manifest.compressors.length() +
      manifest.hooks.length() +
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
        let name = tool_def.name
        let source_label = match tool_def.source {
          Some(s) if s != "" => s
          _ =>
            "ToolDef.source is empty for tool '" +
            name +
            "' in manifest '" +
            mid +
            "' (set ToolDef.source to a stable provider id to disambiguate)"
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
    for c in manifest.compressors {
      compressors.push(c)
    }
    for h in manifest.hooks {
      hooks.push(h)
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
      let n : &@port.UiPort = NoopUiPort::new()
      n
    }
    1 => {
      let u : &@port.UiPort = ui[0]
      u
    }
    _ => {
      let c : &@port.UiPort = CompositeUiPort::new(ui.copy())
      c
    }
  }
  {
    model: models[0],
    tools,
    sessions,
    observers,
    compressors,
    hooks,
    memory,
    lifecycle,
    commands,
    ui: ui_ref,
    prompt_contributors,
    contributor_ids,
  }
}
