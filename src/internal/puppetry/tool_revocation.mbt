///|
/// Core-owned revocation facts for the bindings an admitted operation captured.
///
/// The Agent records the names it actually resolved to a hard-revoked
/// contribution version. The pump consults them at its final pre-start check
/// (after hooks and consent rewriting) and the running tool tree uses the
/// generation counter to notice new revocations and cancel the matching
/// in-flight effects through the ordinary `cancel_effects` contract.
///
/// The facts belong to one operation: the Agent resets them when a new capture
/// is installed, so a name republished by the same owner is not refused by a
/// previous operation's revocation.
pub struct ToolRevocationFacts {
  priv mut generation : Int32
  priv names : Map[String, Bool]
}

///|
pub fn ToolRevocationFacts::ToolRevocationFacts() -> ToolRevocationFacts {
  { generation: 0, names: Map::from_array([]), }
}

///|
/// Record newly revoked binding names. The generation advances only when
/// something new was actually added, so the tree's poll sees real changes.
pub fn ToolRevocationFacts::add(
  self : ToolRevocationFacts,
  names : Array[String],
) -> Unit {
  let mut added = false
  for name in names {
    if !self.names.contains(name) {
      self.names[name] = true
      added = true
    }
  }
  if added {
    self.generation = self.generation + 1
  }
}

///|
pub fn ToolRevocationFacts::generation(self : ToolRevocationFacts) -> Int32 {
  self.generation
}

///|
pub fn ToolRevocationFacts::is_revoked(
  self : ToolRevocationFacts,
  name : String,
) -> Bool {
  self.names.contains(name)
}

///|
/// Start a fresh operation's fact set.
pub fn ToolRevocationFacts::reset(self : ToolRevocationFacts) -> Unit {
  self.names.clear()
  self.generation = self.generation + 1
}
