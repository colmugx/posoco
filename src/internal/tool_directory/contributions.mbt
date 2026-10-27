///|
/// One owner's directory slot. `version` is the active version the capture
/// projects; a withdraw clears it while the tombstone keeps the revision
/// sequence so a later publish continues it.
priv struct OwnerSlot {
  mut revision : Int32
  mut version : Int32?
  mut withdrawn : Bool
  /// The last withdrawal was hard; every version live at that point was
  /// revoked and the slot has no active version.
  mut hard : Bool
}

///|
/// Directory fact emitted to observers through the Agent's callback. It carries
/// no provider, credential or argument payload.
pub(all) enum ToolCatalogChange {
  Published(owner~ : String, revision~ : Int32, tools~ : Array[String])
  Withdrawn(owner~ : String, revision~ : Int32, mode~ : String)
  CleanupFailed(owner~ : String, revision~ : Int32, detail~ : String)
}

///|
/// Definitions and executors are committed together; only operation admission
/// derives a catalog and a binding projection from this authority.
///
/// Every accepted contribution is a version record. The owner slot points at
/// the active version; superseded versions stay alive only while an operation
/// references them or while their retire is still pending.
pub struct ToolContributionRegistry {
  priv base : Array[ToolEntry]
  priv mut captured_defs : Array[@kernel.ToolDef]
  priv versions : Map[Int32, ToolVersion]
  priv slots : Map[String, OwnerSlot]
  priv mut next_version : Int32
  priv mut pending_capture : Bool
  /// Bumped on every accepted directory change so a capture prepared during a
  /// concurrent publish cannot clear that publish on accept.
  priv mut generation : Int32
  priv closed : Ref[Bool]
  priv launcher : @kernel_exec.ToolLaunchGate
  priv on_change : (ToolCatalogChange) -> Unit
  /// Reports hard-revoked versions so the Agent can cancel their in-flight
  /// effects and refuse launches from an already-captured binding.
  priv on_revoke : (Array[Int32], Array[String]) -> Unit
}

///|
pub fn ToolContributionRegistry::ToolContributionRegistry(
  base : Array[ToolEntry],
  launcher? : @kernel_exec.ToolLaunchGate,
  on_change? : (ToolCatalogChange) -> Unit,
  on_revoke? : (Array[Int32], Array[String]) -> Unit,
) -> ToolContributionRegistry {
  {
    base,
    captured_defs: base.map(e => {
      let def = snapshot_tool_def(e.definition)
      { ..def, input_schema: normalize_tool_schema(def.input_schema), }
    }),
    versions: Map::from_array([]),
    slots: Map::from_array([]),
    next_version: 1,
    // The constructor already recorded the base definitions as captured; a
    // first admission whose directory is unchanged must not rebuild the catalog
    // (and must not report a spurious capture fact).
    pending_capture: false,
    generation: 0,
    closed: Ref(false),
    launcher: launcher.unwrap_or(@kernel_exec.ToolLaunchGate::ToolLaunchGate()),
    on_change: on_change.unwrap_or(fn(_) { () }),
    on_revoke: on_revoke.unwrap_or(fn(_, _) { () }),
  }
}

///|
pub fn ToolContributionRegistry::capability(
  self : ToolContributionRegistry,
  owner : String,
) -> @port.ToolContributions {
  @port.ToolContributions::from_callbacks(
    owner~,
    replace=async fn(
      provider : &@port.ToolProvider,
      retire : @port.ToolRetire?,
    ) -> Result[@port.ToolContributionCommit, @port.ToolContributionError] noraise {
      self.replace(owner, provider, retire)
    },
    withdraw=async fn(
      mode : @port.ToolWithdrawMode,
    ) -> Result[@port.ToolContributionCommit, @port.ToolContributionError] noraise {
      self.withdraw(owner, mode)
    },
    revision=fn() { self.revision(owner) },
    state=fn() { self.state(owner) },
  )
}

///|
fn ToolContributionRegistry::entries(
  self : ToolContributionRegistry,
) -> Array[ToolEntry] {
  let entries = self.base.copy()
  for _, slot in self.slots {
    match slot.version {
      Some(id) =>
        match self.versions.get(id) {
          Some(version) if !version.gate.revoked =>
            entries.append(version.entries)
          _ => ()
        }
      None => ()
    }
  }
  entries
}

///|
fn ToolContributionRegistry::names_of(
  self : ToolContributionRegistry,
  id : Int32,
) -> Array[String] {
  match self.versions.get(id) {
    Some(version) => version.entries.map(e => e.definition.name.to_string())
    None => []
  }
}

///|
/// Validate a candidate group against the complete directory, publish it as a
/// new version, then retire versions that lost every reference. Every
/// validation and the authoritative commit happen before the first await; a
/// rejected group changes nothing.
pub async fn ToolContributionRegistry::replace(
  self : ToolContributionRegistry,
  owner : String,
  provider : &@port.ToolProvider,
  retire : @port.ToolRetire?,
) -> Result[@port.ToolContributionCommit, @port.ToolContributionError] noraise {
  if self.closed.val {
    return Err(@port.ToolContributionError::Closed)
  }
  if owner == "" {
    return Err(
      @port.ToolContributionError::Rejected(reason="owner must be non-empty"),
    )
  }
  // Definitions are read exactly once and owned by the version.
  let definitions = provider.list_tools().map(def => owned_tool_def(def, owner))
  let version_id = self.next_version
  let gate : VersionGate = { revoked: false, }
  let gated : &@port.ToolProvider = VersionBoundProvider::{
    inner: provider,
    definitions: definitions.map(snapshot_tool_def),
    gate,
    launcher: self.launcher,
  }
  let version_entries = definitions.map(def => {
    definition: def,
    provider: gated,
    version: Some(version_id),
  })
  let previous = match self.slots.get(owner) {
    Some(slot) => slot.version
    None => None
  }
  let candidate : Array[ToolEntry] = []
  let replaced : Map[String, Bool] = Map::from_array([])
  match previous {
    Some(current) =>
      match self.versions.get(current) {
        Some(old) =>
          for entry in old.entries {
            replaced[entry.definition.name.to_string()] = true
          }
        None => ()
      }
    None => ()
  }
  for entry in self.entries() {
    if !replaced.contains(entry.definition.name.to_string()) {
      candidate.push(entry)
    }
  }
  candidate.append(version_entries)
  let _ = build_catalog_from_defs(
    candidate.map(e => e.definition),
    CatalogVersion(1),
  ) catch {
    error =>
      return Err(
        @port.ToolContributionError::Rejected(
          reason=bounded_error_label(error.to_string(), 256),
        ),
      )
  }
  let revision = match self.slots.get(owner) {
    Some(slot) => slot.revision + 1
    None => 1
  }
  let version : ToolVersion = {
    owner,
    revision,
    entries: version_entries,
    gate,
    active: true,
    refs: 0,
    retire,
    retiring: false,
  }
  self.versions[version_id] = version
  self.next_version = self.next_version + 1
  match previous {
    Some(current) =>
      match self.versions.get(current) {
        Some(old) => old.active = false
        None => ()
      }
    None => ()
  }
  self.slots[owner] = {
    revision,
    version: Some(version_id),
    withdrawn: false,
    hard: false,
  }
  self.pending_capture = true
  self.generation = self.generation + 1
  (self.on_change)(
    Published(owner~, revision~, tools=self.names_of(version_id)),
  )
  match self.retire_unreferenced(owner~) {
    [] => Ok({ owner, revision, state: @port.ToolContributionState::Active, })
    failures =>
      Err(
        @port.ToolContributionError::CleanupPending(
          revision~,
          state=@port.ToolContributionState::Active,
          detail=describe_retire_failures(failures),
        ),
      )
  }
}

///|
/// Withdraw the owner's group. Soft keeps admitted operations working; hard
/// additionally revokes every live version of the owner so no operation can
/// start a new call through them. Repeating the same mode is idempotent.
pub async fn ToolContributionRegistry::withdraw(
  self : ToolContributionRegistry,
  owner : String,
  mode : @port.ToolWithdrawMode,
) -> Result[@port.ToolContributionCommit, @port.ToolContributionError] noraise {
  if self.closed.val {
    return Err(@port.ToolContributionError::Closed)
  }
  let slot = match self.slots.get(owner) {
    Some(slot) => slot
    None => return Err(@port.ToolContributionError::NotContributed)
  }
  let already = slot.withdrawn &&
    (mode is @port.ToolWithdrawMode::Soft || slot.hard)
  let revision = if already { slot.revision } else { slot.revision + 1 }
  let revoked : Array[Int32] = []
  if !already {
    match slot.version {
      Some(id) =>
        match self.versions.get(id) {
          Some(version) => version.active = false
          None => ()
        }
      None => ()
    }
    if mode is @port.ToolWithdrawMode::Hard {
      // Every live version of this owner — including versions an earlier
      // replace or soft withdrawal already superseded — is irrevocably
      // revoked, so no operation may start a new call through them.
      for id, version in self.versions {
        if version.owner == owner && !version.gate.revoked {
          version.revoke()
          revoked.push(id)
        }
      }
    }
    slot.revision = revision
    slot.version = None
    slot.withdrawn = true
    slot.hard = mode is @port.ToolWithdrawMode::Hard
    self.pending_capture = true
    self.generation = self.generation + 1
    (self.on_change)(Withdrawn(owner~, revision~, mode=mode.to_string()))
    if !revoked.is_empty() {
      let names : Array[String] = []
      for id in revoked {
        names.append(self.names_of(id))
      }
      (self.on_revoke)(revoked, names)
    }
  }
  match self.retire_unreferenced(owner~) {
    [] =>
      Ok({ owner, revision, state: @port.ToolContributionState::Withdrawn, })
    failures =>
      Err(
        @port.ToolContributionError::CleanupPending(
          revision~,
          state=@port.ToolContributionState::Withdrawn,
          detail=describe_retire_failures(failures),
        ),
      )
  }
}

///|
fn ToolContributionRegistry::revision(
  self : ToolContributionRegistry,
  owner : String,
) -> Int32? {
  match self.slots.get(owner) {
    Some(slot) if !slot.withdrawn => Some(slot.revision)
    _ => None
  }
}

///|
fn ToolContributionRegistry::state(
  self : ToolContributionRegistry,
  owner : String,
) -> @port.ToolContributionState {
  if self.closed.val {
    return @port.ToolContributionState::Closed
  }
  match self.slots.get(owner) {
    Some(slot) if !slot.withdrawn => @port.ToolContributionState::Active
    _ => @port.ToolContributionState::Withdrawn
  }
}

///|
/// Retain every existing version in `versions` once for an admitted operation.
pub fn ToolContributionRegistry::retain_versions(
  self : ToolContributionRegistry,
  versions : Array[Int32],
) -> Unit {
  for id in versions {
    match self.versions.get(id) {
      Some(version) => version.refs = version.refs + 1
      None => ()
    }
  }
}

///|
/// Release an operation's references. A version that is inactive or revoked and
/// now unreferenced becomes retire-eligible; nothing is awaited here and no
/// task is spawned.
pub fn ToolContributionRegistry::release_versions(
  self : ToolContributionRegistry,
  versions : Array[Int32],
) -> Unit {
  for id in versions {
    match self.versions.get(id) {
      Some(version) => if version.refs > 0 { version.refs = version.refs - 1 }
      None => ()
    }
  }
}

///|
/// Retire every version that is neither active nor referenced. Each successful
/// version is called once and dropped from the live set; failures stay pending.
pub async fn ToolContributionRegistry::retire_unreferenced(
  self : ToolContributionRegistry,
  owner? : String,
) -> Array[ToolRetireFailure] noraise {
  let failures : Array[ToolRetireFailure] = []
  for id in self.versions.keys().to_array() {
    guard self.versions.get(id) is Some(version) else { continue }
    if owner is Some(expected) && version.owner != expected {
      continue
    }
    if version.active || version.refs > 0 || version.retiring {
      continue
    }
    version.retiring = true
    defer {
      version.retiring = false
    }
    match version.retire {
      None => self.versions.remove(id)
      Some(callback) => {
        // Bounded by the same five-second settlement budget the operation
        // uses for cancellation cleanup; no new configuration.
        let attempted : Result[Result[Unit, String], String] = Ok(
          @async.with_timeout(version_retire_settle_ms, async fn() {
            callback()
          }),
        ) catch {
          error => Err(bounded_error_label(error.to_string(), 256))
        }
        let failure : String? = match attempted {
          Ok(Ok(_)) => None
          Ok(Err(detail)) => Some(bounded_error_label(detail, 256))
          Err(detail) => Some(detail)
        }
        match failure {
          None => self.versions.remove(id)
          Some(detail) => {
            failures.push({
              owner: version.owner,
              revision: version.revision,
              version: id,
              detail,
            })
            (self.on_change)(
              CleanupFailed(
                owner=version.owner,
                revision=version.revision,
                detail~,
              ),
            )
          }
        }
      }
    }
  }
  failures
}

///|
/// Failures still awaiting a successful retire. Shutdown reports them and does
/// not mark itself complete while any remains.
pub fn ToolContributionRegistry::pending_cleanup(
  self : ToolContributionRegistry,
) -> Array[ToolRetireFailure] {
  let pending : Array[ToolRetireFailure] = []
  for id, version in self.versions {
    if !version.active {
      pending.push({
        owner: version.owner,
        revision: version.revision,
        version: id,
        detail: if version.retiring {
          "retire in progress"
        } else if version.refs > 0 {
          "version still referenced"
        } else {
          "retire pending"
        },
      })
    }
  }
  pending
}

///|
fn describe_retire_failures(failures : Array[ToolRetireFailure]) -> String {
  let labels : Array[String] = []
  for failure in failures {
    labels.push(
      "version=\{failure.version} owner=\{failure.owner} revision=\{failure.revision}: \{failure.detail}",
    )
  }
  bounded_error_label(labels.join("; "), 256)
}

///|
pub fn ToolContributionRegistry::captured_tools(
  self : ToolContributionRegistry,
) -> Map[String, &@port.ToolProvider] {
  let tools : Map[String, &@port.ToolProvider] = Map::from_array([])
  for entry in self.entries() {
    tools[entry.definition.name.to_string()] = entry.provider
  }
  tools
}

///|
/// Close contribution handles. Versions are not retired here: shutdown settles
/// the admitted operation first, then retires every remaining version.
pub fn ToolContributionRegistry::close(self : ToolContributionRegistry) -> Unit {
  self.closed.val = true
}

///|
/// Deactivate every remaining version so shutdown retires core-managed
/// contributions without asking an extension to withdraw on a closed handle.
pub fn ToolContributionRegistry::begin_retire_all(
  self : ToolContributionRegistry,
) -> Unit {
  for _, version in self.versions {
    version.active = false
  }
  for _, slot in self.slots {
    slot.version = None
  }
}
