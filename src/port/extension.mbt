///|
/// Every agent contributor implements Extension. Returns an `ExtensionManifest`
/// listing which ports it provides (ModelPort, ToolProvider, SessionStore, etc.).
/// Posoco is a protocol, not a framework — an agent is the composition of
/// extensions.

// ExtensionManifest — value type returned by Extension::manifest

///|
/// Self-reported port contributions. All fields default to empty arrays;
/// multi-trait extensions put `self` under each applicable field.
pub(all) struct ExtensionManifest {
  id : String
  models : Array[&ModelPort]
  tools : Array[&ToolProvider]
  sessions : Array[&SessionStore]
  observers : Array[&Observer]
  /// Pipeline interception points. One array for every hook kind: the pump
  /// calls `Hook::before_model` / `before_tool` / `on_post_event` on each
  /// entry in registration order. An extension that intercepts several
  /// points puts `self` here once and overrides the methods it needs.
  hooks : Array[&Hook]
  memory : Array[&MemoryPort]
  lifecycle : Array[&Lifecycle]
  commands : Array[&CommandPort]
  ui : Array[&UiPort]
  prompt_contributors : Array[&SystemPromptContributor]
}

///|
/// Construct an empty manifest with only the id set. Fields can then be
/// assigned individually.
pub fn ExtensionManifest::empty(id~ : String) -> ExtensionManifest {
  {
    id,
    models: [],
    tools: [],
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
  }
}

// Extension trait

///|
pub(open) trait Extension {
  /// Stable identifier for diagnostics. Should be unique per composition.
  fn extension_id(Self) -> String

  /// Return this extension's port contributions. May reference `self` under
  /// multiple port-trait views.
  fn manifest(Self) -> ExtensionManifest
}
