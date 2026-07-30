///|
/// Model-call result and compact protocol.
/// Posoco decides WHEN to compact; modelport decides HOW via `ModelPort::compact`.
/// `processed_messages` is the dynamic-removal channel (always present).

///|
/// Return value of `HostRuntime::call_model` and `ModelPort::chat`. Bundles
/// the model completion with the processed message tree.
///
/// The pump ALWAYS replaces the transcript body with `processed_messages`,
/// then appends `completion` as the new assistant entry.
pub(all) struct ModelCallResult {
  /// The assistant completion returned by the provider.
  completion : Completion
  /// The messages the modelport sent to the provider, after any
  /// provider-specific preprocessing (e.g. DeepSeek dynamic tool-result
  /// removal). Always present — when the modelport performed no preprocessing
  /// it returns the input messages unchanged.
  processed_messages : Array[Message]
} derive(Eq)

///|
pub impl Show for ModelCallResult with fn to_string(self : ModelCallResult) -> String {
  "ModelCallResult(processed=\{self.processed_messages.length()} msgs)"
}

///|
/// How posoco applies the result of `ModelPort::compact`.
pub(all) enum CompactMode {
  /// New thread with `parent_thread_id` lineage; original thread preserved.
  NewThread
  /// Replace current session body in place; no new session created.
  Replace
  /// Append compacted messages to current session.
  Append
} derive(Eq)

///|
pub impl Show for CompactMode with fn to_string(self : CompactMode) -> String {
  match self {
    NewThread => "NewThread"
    Replace => "Replace"
    Append => "Append"
  }
}

///|
/// Return value of `ModelPort::compact`.
pub(all) struct CompactResult {
  compacted_messages : Array[Message]
  mode : CompactMode
} derive(Eq)

///|
pub impl Show for CompactResult with fn to_string(self : CompactResult) -> String {
  "CompactResult(mode=\{self.mode}, msgs=\{self.compacted_messages.length()})"
}

///|
/// What triggered a compact. Advisory — modelport may ignore.
pub(all) enum CompactTrigger {
  Auto
  Manual
} derive(Eq, Debug)

///|
pub impl Show for CompactTrigger with fn to_string(self : CompactTrigger) -> String {
  match self {
    Auto => "Auto"
    Manual => "Manual"
  }
}
