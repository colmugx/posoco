///|
/// ProviderConfig: modelport's self-description of accepted config values.
/// A String array (not typed enum) because each provider has its own
/// vocabulary for e.g. reasoning_effort values.
pub(all) struct ProviderConfig {
  /// Accepted reasoning_effort values. Empty = not supported.
  reasoning_effort_values : Array[String]
} derive(Eq, Debug)

///|
pub fn ProviderConfig::ProviderConfig(
  reasoning_effort_values~ : Array[String],
) -> ProviderConfig {
  { reasoning_effort_values, }
}

///|
/// Empty config: no reasoning_effort values accepted.
pub fn ProviderConfig::empty() -> ProviderConfig {
  { reasoning_effort_values: [] }
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
  let values = self.reasoning_effort_values
    .copy()
    .map(fn(s) { "'" + s + "'" })
    .join(", ")
  "ProviderConfig(reasoning_effort=[\{values}])"
}
