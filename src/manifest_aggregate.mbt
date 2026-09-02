///|
/// Manifest aggregation — merges `Array[&Extension]` into a single
/// `AggregatedPorts` value for the agent constructor.

///|
/// A registered Lifecycle contributor paired with its declared capability
/// requirements. The pairing survives aggregation so the composition can
/// gate each contributor's `CompositionView` on its own declared `requires`
/// at `Lifecycle::on_compose` delivery time. (The manifest id is not carried:
/// an extension that fails composition identifies itself through the
/// `manifest_id` of the `CompositionError` it raises.)
priv struct LifecycleEntry {
  requires : Array[@port.Capability]
  port : &@port.Lifecycle
}

///|
/// Flattened port bundle ready for the agent constructor. The `model` field
/// is a single value (multi-model routing is solved in-extension), and `ui`
/// is wrapped into one UiPort reference (the agent never sees a bare array).
priv struct AggregatedPorts {
  model : &@port.ModelPort
  tools : Array[&@port.ToolProvider]
  sessions : Array[&@port.SessionStore]
  observers : Array[&@port.Observer]
  hooks : Array[&@port.PipelineHook]
  /// Memory sources paired with their manifest id — the id routes
  /// `memory_add`'s optional `source` argument.
  memory : Array[(String, &@port.MemoryPort)]
  lifecycle : Array[LifecycleEntry]
  commands : Array[&@port.CommandPort]
  ui : &@port.UiPort
  /// Contributor paired with its manifest id (used as the prompt section
  /// header so the assembled prompt names its source).
  prompt_contributors : Array[(String, &@port.SystemPromptContributor)]
}

///|
/// Shared tool-name collision scan for the two composition passes that walk
/// provider tool lists (`aggregate_extensions` and `build_tool_routing`).
/// Each pass labels a ToolDef with its own source wording but delegates
/// duplicate detection and the message skeleton here.
priv struct ToolNameIndex {
  /// Tool name → source labels in declaration order; `labels[0]` is the
  /// first declaration.
  labels : Map[String, Array[String]]
}

///|
fn ToolNameIndex::new() -> ToolNameIndex {
  { labels: Map::from_array([]), }
}

///|
/// Record one declared tool. Returns None for a new name; on the first
/// duplicate returns the labels recorded so far, untouched — callers raise
/// from this arm, so no further bookkeeping happens.
fn ToolNameIndex::record(
  self : ToolNameIndex,
  name : String,
  source_label : String,
) -> Array[String]? {
  if self.labels.contains(name) {
    Some(self.labels[name])
  } else {
    self.labels[name] = [source_label]
    None
  }
}

///|
/// The shared collision message skeleton; each pass supplies its own
/// source labels.
fn tool_collision_message(first : String, conflicting : String) -> String {
  "tool collision; first declaration: \{first}; conflicting declaration: \{conflicting}"
}

///|
/// A ToolDef's provenance when present and non-empty; None marks an
/// unlabeled definition and each pass words its own actionable fallback.
fn nonempty_provenance(tool : @kernel.ToolDef) -> String? {
  match tool.provenance {
    Some(s) if s != "" => Some(s)
    _ => None
  }
}

///|
/// Aggregate every extension's manifest into one port bundle.
/// Order follows extension array order; collisions fail fast.
fn aggregate_extensions(
  exts : Array[&@port.Extension],
) -> AggregatedPorts raise @error.CompositionError {
  if exts.length() == 0 {
    raise EmptyManifests
  }
  // Per-port collectors.
  let models : Array[&@port.ModelPort] = []
  let model_manifests : Array[String] = []
  let tools : Array[&@port.ToolProvider] = []
  let tool_index = ToolNameIndex::new()
  let sessions : Array[&@port.SessionStore] = []
  let observers : Array[&@port.Observer] = []
  let hooks : Array[&@port.PipelineHook] = []
  let memory : Array[(String, &@port.MemoryPort)] = []
  let lifecycle : Array[LifecycleEntry] = []
  let commands : Array[&@port.CommandPort] = []
  let command_manifests : Map[String, Array[String]] = Map::from_array([])
  let ui : Array[&@port.UiPort] = []
  let prompt_contributors : Array[(String, &@port.SystemPromptContributor)] = []
  for ext in exts {
    let manifest = ext.manifest()
    let mid = manifest.id
    if mid == "" {
      raise ManifestSchemaError(
        manifest_id="",
        detail="extension returned a manifest with empty id",
      )
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
        let source_label = match nonempty_provenance(tool_def) {
          Some(s) => s
          None =>
            "ToolDef.provenance is empty for tool '" +
            name +
            "' in manifest '" +
            mid +
            "' (set ToolDef.provenance to a stable provider id to disambiguate)"
        }
        match tool_index.record(name, source_label) {
          Some(labels) => {
            let manifests = labels.copy()
            manifests.push(mid)
            raise ToolCollision(
              name,
              tool_collision_message(labels[0], source_label),
              manifests~,
            )
          }
          None => ()
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
          raise CommandCollision(cid, manifests=existing)
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
    for h in manifest.hooks {
      hooks.push(h)
    }
    for m in manifest.memory {
      memory.push((mid, m))
    }
    for l in manifest.lifecycle {
      lifecycle.push({ requires: manifest.requires.copy(), port: l, })
    }
    for u in manifest.ui {
      ui.push(u)
    }
    for p in manifest.prompt_contributors {
      prompt_contributors.push((mid, p))
    }
  }
  // Model cardinality: exactly 1.
  match models.length() {
    0 => raise MissingModel
    1 => ()
    _ => raise MultipleModels(manifests=model_manifests)
  }
  // UI cardinality: 0 → NoopUiPort, 1 → passthrough, 2+ → CompositeUiPort.
  let ui_ref : &@port.UiPort = match ui.length() {
    0 => (NoopUiPort() : &@port.UiPort)
    1 => ui[0]
    _ => (CompositeUiPort(ui.copy()) : &@port.UiPort)
  }
  {
    model: models[0],
    tools,
    sessions,
    observers,
    hooks,
    memory,
    lifecycle,
    commands,
    ui: ui_ref,
    prompt_contributors,
  }
}
