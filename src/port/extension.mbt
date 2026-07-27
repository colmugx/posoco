///|
/// Extension — the self-description protocol that every agent contributor
/// implements.
///
/// Posoco is a protocol, not a framework. An agent is *the composition* of
/// extensions. Each extension contributes zero or more ports (ModelPort,
/// ToolProvider, SessionStore, Observer, Compressor, PipelineHook, MemoryPort,
/// Lifecycle, CommandPort, UiPort, SystemPromptContributor) by listing them in
/// the `ExtensionManifest` it returns from `manifest()`.
///
/// Why this trait (and not a bare struct value):
/// - extensions already implement one or more port traits on the same struct
///   (e.g. `posoco-ext-goal`'s `GoalRunner` implements both PipelineHook and
///   Observer); requiring them to *also* declare `extension_id` and a manifest
///   is one consistent step, not two;
/// - the manifest can reference `self` directly as `&ToolProvider` etc.,
///   because at the impl site the concrete type is statically known to satisfy
///   every port it implements — no runtime trait downcast is involved;
/// - callers pass `Array[&Extension]` to `Agent::new` and the agent aggregates
///   manifests internally, so the composition surface is one array.
///
/// `extension_id` is for diagnostics (collision messages name the offending
/// extensions). It is NOT used for routing, identity-based dispatch, or
/// persistence — extensions are stateless participants identified only by the
/// ports they contribute.

// ──────────────────────────────────────────────────────────────────────────
// ExtensionManifest — value type returned by Extension::manifest
// ──────────────────────────────────────────────────────────────────────────

///|
/// Self-reported port contributions of one extension.
///
/// Every field defaults to an empty array, so a contributor that only
/// provides (say) tools writes `{ id: "read", tools: [self], ..default}` and
/// omits the rest. The `id` field is required.
///
/// Multi-trait extensions (one struct implementing multiple port traits) put
/// the same `self` reference under multiple fields — MoonBit tracks each
/// `&PortTrait` view independently, no merging happens at this layer.
pub(all) struct ExtensionManifest {
  id : String
  models : Array[&ModelPort]
  tools : Array[&ToolProvider]
  sessions : Array[&SessionStore]
  observers : Array[&Observer]
  compressors : Array[&Compressor]
  hooks : Array[&PipelineHook]
  memory : Array[&MemoryPort]
  lifecycle : Array[&Lifecycle]
  commands : Array[&CommandPort]
  ui : Array[&UiPort]
  prompt_contributors : Array[&SystemPromptContributor]
}

///|
/// Construct an empty manifest with only the id set. Extension authors can
/// then assign fields individually:
///
/// ```moonbit nocheck
/// let m = ExtensionManifest::empty("read")
/// m.tools.push(self)
/// m.prompt_contributors.push(self)
/// ```
pub fn ExtensionManifest::empty(id~ : String) -> ExtensionManifest {
  {
    id,
    models: [],
    tools: [],
    sessions: [],
    observers: [],
    compressors: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Extension trait
// ──────────────────────────────────────────────────────────────────────────

///|
pub(open) trait Extension {
  /// Stable identifier for diagnostics (collision messages, logs). Should be
  /// unique within a single `Agent::new` call; collisions are not fatal but
  /// make error messages ambiguous.
  fn extension_id(Self) -> String

  /// Return this extension's port contributions. The implementation MAY
  /// reference `self` under multiple port-trait views; each reference is an
  /// independent `&PortTrait` fat-pointer that the agent aggregates with
  /// others across all extensions.
  fn manifest(Self) -> ExtensionManifest
}
