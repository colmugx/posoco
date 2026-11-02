///|
priv struct LeaseProvider {
  tool : String
}

///|
impl @port.ToolProvider for LeaseProvider with fn list_tools(self) -> Array[
  @kernel.ToolDef,
] {
  [
    @kernel.ToolDef(
      name=@kernel.ToolName::unchecked(self.tool),
      description="lease fixture",
      input_schema=Json::null(),
      owner=@kernel.OwnerId::unchecked("lease"),
      policy=Sequential,
      provenance=None,
    ),
  ]
}

///|
impl @port.ToolProvider for LeaseProvider with fn execute(
  _self,
  _ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  raise @error.RuntimeError::InvocationFailed("lease fixture does not execute")
}

///|
fn lease_registry() -> ToolContributionRegistry {
  let base : Array[ToolEntry] = []
  ToolContributionRegistry(base)
}

///|
fn lease_provider(tool : String) -> &@port.ToolProvider {
  LeaseProvider::{ tool, }
}

///|
fn lease_version(registry : ToolContributionRegistry, owner : String) -> Int32 {
  match registry.slots.get(owner) {
    Some(slot) =>
      match slot.version {
        Some(version) => version
        None => -1
      }
    None => -1
  }
}

///|
fn lease_refs(registry : ToolContributionRegistry, version : Int32) -> Int32 {
  match registry.versions.get(version) {
    Some(record) => record.refs
    None => -1
  }
}

///|
async test "tool_directory/leases retain until an unconfirmed execution settles" {
  let registry = lease_registry()
  let published = registry.replace("ext", lease_provider("leased"), None)
  guard published is Ok(_) else { fail("fixture publish must succeed") }
  let id = lease_version(registry, "ext")
  let leases = ToolVersionLeases::ToolVersionLeases()
  leases.install_captured([id])
  leases.acquire(registry)
  assert_eq(lease_refs(registry, id), 1)
  // While a termination is unconfirmed the lease moves to the retained set
  // instead of being given back, so the version's resources stay alive.
  leases.release_operation(registry, true)
  assert_eq(lease_refs(registry, id), 1)
  assert_eq(leases.retained, [id])
  leases.release_retained(registry, true)
  assert_eq(lease_refs(registry, id), 1)
  // A confirmed settlement releases the retained lease exactly once.
  leases.release_retained(registry, false)
  assert_eq(lease_refs(registry, id), 0)
  assert_eq(leases.retained.length(), 0)
}

///|
async test "tool_directory/leases repeated release never retires twice" {
  let registry = lease_registry()
  let published = registry.replace("ext", lease_provider("leased"), None)
  guard published is Ok(_) else { fail("fixture publish must succeed") }
  let id = lease_version(registry, "ext")
  let leases = ToolVersionLeases::ToolVersionLeases()
  leases.install_captured([id])
  leases.acquire(registry)
  leases.release_operation(registry, false)
  assert_eq(lease_refs(registry, id), 0)
  // Both sets are empty now, so a second settlement pass is a no-op rather
  // than a second decrement of the same reference.
  leases.release_operation(registry, false)
  leases.release_retained(registry, false)
  assert_eq(lease_refs(registry, id), 0)
  assert_eq(leases.operation.length(), 0)
  assert_eq(leases.retained.length(), 0)
}
