///|
/// Every agent contributor implements Extension. Returns an `ExtensionManifest`
/// listing which ports it provides (ModelPort, ToolProvider, SessionStore, etc.).
/// Posoco is a protocol, not a framework — an agent is the composition of
/// extensions.

// ExtensionManifest — value type returned by Extension::manifest

///|
/// A composed capability an extension declares it consumes. Declaring is what
/// populates the `CompositionView` delivered at `Lifecycle::on_compose` — the
/// view gates on this declaration, so an undeclared capability reads as
/// `None`. Extensible by adding variants; existing manifests are unaffected.
pub(all) enum Capability {
  /// The single composed ModelPort (post cardinality gate, source-agnostic).
  Model
  /// The composed UiPort (single / Composite / Noop), for human interaction.
  Ui
} derive(Eq, Debug)

///|
/// Self-reported port contributions. All fields default to empty arrays;
/// multi-trait extensions put `self` under each applicable field.
///
/// `requires` is the consumption direction: the extension declares which
/// composed capabilities it wants delivered at `Lifecycle::on_compose`.
/// The declaration is load-bearing (the view gates on it) and auditable
/// (composition can answer "which extensions declared model access").
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
  requires : Array[Capability]
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
    requires: [],
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
