///|
/// Core-owned revocation facts for the bindings an admitted operation captured.
pub struct ToolRevocationFacts {
  priv mut generation : Int32
  priv names : Map[String, Bool]
  priv changed : @cond_var.Cond
}

///|
pub fn ToolRevocationFacts::ToolRevocationFacts() -> ToolRevocationFacts {
  { generation: 0, names: Map::from_array([]), changed: @cond_var.Cond(), }
}

///|
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
    self.changed.broadcast()
  }
}

///|
pub fn ToolRevocationFacts::generation(self : ToolRevocationFacts) -> Int32 {
  self.generation
}

///|
pub async fn ToolRevocationFacts::wait_change(
  self : ToolRevocationFacts,
  seen : Int32,
) -> Int32 {
  while self.generation == seen {
    self.changed.wait()
  }
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
pub fn ToolRevocationFacts::reset(self : ToolRevocationFacts) -> Unit {
  self.names.clear()
  self.generation = self.generation + 1
  self.changed.broadcast()
}
