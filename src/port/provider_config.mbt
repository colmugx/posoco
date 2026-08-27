///|
/// ProviderConfig: modelport's self-description of accepted config values.
/// A String array (not typed enum) because each provider has its own
/// vocabulary for e.g. reasoning_effort values.
pub(all) struct ProviderConfig {
  /// Accepted reasoning_effort values. Empty = not supported.
  reasoning_effort_values : Array[String]
  /// Provider-reported context capacity of the active model, in tokens.
  /// `None` = unknown; auto-compact stays disabled rather than guessing.
  context_window : Int?
  /// Provider-reported fraction of the context window at which auto-compact
  /// fires, in (0, 1]. `None` = the host/default threshold applies.
  compact_threshold : Double?
} derive(Eq, Debug)

///|
pub fn ProviderConfig::ProviderConfig(
  reasoning_effort_values~ : Array[String],
  context_window? : Int? = None,
  compact_threshold? : Double? = None,
) -> ProviderConfig {
  { reasoning_effort_values, context_window, compact_threshold }
}

///|
/// Empty config: no reasoning_effort values accepted, no window reported.
pub fn ProviderConfig::empty() -> ProviderConfig {
  { reasoning_effort_values: [], context_window: None, compact_threshold: None }
}

///|
/// Check if the given reasoning_effort value is accepted.
pub fn ProviderConfig::accepts_reasoning_effort(
  self : ProviderConfig,
  value : String,
) -> Bool {
  self.reasoning_effort_values.contains(value)
}

///|
pub impl Show for ProviderConfig with fn to_string(self : ProviderConfig) -> String {
  "ProviderConfig(reasoning_effort=[\{self.reasoning_effort_values.map(fn(s) { "'\{s}'" }).join(", ")}])"
}
