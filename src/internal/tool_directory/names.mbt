///|
pub fn tool_provenance(tool : @kernel.ToolDef) -> String {
  match nonempty_provenance(tool) {
    Some(source) => "ToolDef.provenance='\{safe_error_label(source)}'"
    None =>
      "unlabeled provider declaring '\{safe_error_label(tool.name.to_string())}' (set ToolDef.provenance to a stable provider id)"
  }
}

///|
/// Shared collision scan for the composition passes that walk provider tool
/// lists; each pass supplies its own source wording.
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
/// Returns the labels recorded so far when `name` was already declared.
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
pub fn tool_collision_message(first : String, conflicting : String) -> String {
  "tool collision; first declaration: \{first}; conflicting declaration: \{conflicting}"
}

///|
pub fn nonempty_provenance(tool : @kernel.ToolDef) -> String? {
  match tool.provenance {
    Some(s) if s != "" => Some(s)
    _ => None
  }
}
