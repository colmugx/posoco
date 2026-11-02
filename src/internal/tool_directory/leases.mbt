///|
pub struct ToolVersionLeases {
  priv mut captured : Array[Int32]
  priv mut operation : Array[Int32]
  priv mut retained : Array[Int32]
}

///|
pub fn ToolVersionLeases::ToolVersionLeases() -> ToolVersionLeases {
  { captured: [], operation: [], retained: [], }
}

///|
pub fn ToolVersionLeases::install_captured(
  self : ToolVersionLeases,
  versions : Array[Int32],
) -> Unit {
  self.captured = versions
}

///|
pub fn ToolVersionLeases::acquire(
  self : ToolVersionLeases,
  registry : ToolContributionRegistry,
) -> Unit {
  self.operation = self.captured.copy()
  registry.retain_versions(self.operation)
}

///|
/// Unconfirmed executions may still use the version's resources.
pub fn ToolVersionLeases::release_operation(
  self : ToolVersionLeases,
  registry : ToolContributionRegistry,
  unconfirmed : Bool,
) -> Unit {
  if self.operation.is_empty() {
    return
  }
  if unconfirmed {
    self.retained.append(self.operation)
  } else {
    registry.release_versions(self.operation)
  }
  self.operation = []
}

///|
pub fn ToolVersionLeases::release_retained(
  self : ToolVersionLeases,
  registry : ToolContributionRegistry,
  unconfirmed : Bool,
) -> Unit {
  if self.retained.is_empty() || unconfirmed {
    return
  }
  registry.release_versions(self.retained)
  self.retained = []
}
