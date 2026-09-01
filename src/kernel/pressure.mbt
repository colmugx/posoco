///|
/// Context-pressure advisory for a model-side call. Posoco resolves the
/// effective window and threshold per turn (host config > provider report >
/// core default) and tracks the latest verified occupancy; compact is the
/// call that needs these numbers, so the pump attaches them to the
/// `InvocationScope` instead of leaving modelports to re-estimate from
/// characters. Read-only for ports; absent dimensions are genuinely unknown
/// and must not be guessed.
pub(all) struct ContextPressure {
  /// Resolved token budget ceiling for the active model. None = unknown.
  window_tokens : Int?
  /// Context occupancy reported by the LATEST model step (that call's total
  /// tokens). None = no verified reading yet.
  occupancy_tokens : Int?
  /// Resolved auto-compact trigger point as a fraction of the window.
  compact_threshold : Double
} derive(Eq, Debug)
