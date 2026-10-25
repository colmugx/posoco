///|
pub fn tool_provenance(tool : @kernel.ToolDef) -> String {
  match nonempty_provenance(tool) {
    Some(source) => "ToolDef.provenance='\{safe_error_label(source)}'"
    None =>
      "unlabeled provider declaring '\{safe_error_label(tool.name.to_string())}' (set ToolDef.provenance to a stable provider id)"
  }
}

///|
/// Shared tool-name collision scan for the two composition passes that walk
/// provider tool lists (`aggregate_extensions` and `build_tool_routing`).
/// Each pass labels a ToolDef with its own source wording but delegates
/// duplicate detection and the message skeleton here.
pub struct ToolNameIndex {
  /// Tool name → source labels in declaration order; `labels[0]` is the
  /// first declaration.
  priv labels : Map[String, Array[String]]
}

///|
pub fn ToolNameIndex::new() -> ToolNameIndex {
  { labels: Map::from_array([]), }
}

///|
/// Record one declared tool. Returns None for a new name; on the first
/// duplicate returns the labels recorded so far, untouched — callers raise
/// from this arm, so no further bookkeeping happens.
pub fn ToolNameIndex::record(
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
pub fn tool_collision_message(first : String, conflicting : String) -> String {
  "tool collision; first declaration: \{first}; conflicting declaration: \{conflicting}"
}

///|
/// A ToolDef's provenance when present and non-empty; None marks an
/// unlabeled definition and each pass words its own actionable fallback.
pub fn nonempty_provenance(tool : @kernel.ToolDef) -> String? {
  match tool.provenance {
    Some(s) if s != "" => Some(s)
    _ => None
  }
}
