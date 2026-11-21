///|
using @directory {
  type ToolContributionRegistry,
  type ToolEntry,
  type ToolNameIndex,
  build_catalog_from_defs,
  nonempty_provenance,
  tool_collision_message,
}

///|
fn emit_tool_catalog_change(
  events : @event_runtime.EventRuntime,
  change : @directory.ToolCatalogChange,
) -> Unit {
  let payload : @types.ToolCatalogChangedPayload = match change {
    Published(owner~, revision~, tools~) =>
      {
        change: Published,
        owner,
        revision: Some(revision),
        catalog_version: None,
        tool_count: tools.length(),
        operation_id: None,
        detail: None,
      }
    Withdrawn(owner~, revision~, mode~) =>
      {
        change: Withdrawn,
        owner,
        revision: Some(revision),
        catalog_version: None,
        tool_count: 0,
        operation_id: None,
        detail: Some("mode=" + mode),
      }
    CleanupFailed(owner~, revision~, detail=_) =>
      {
        change: CleanupFailed,
        owner,
        revision: Some(revision),
        catalog_version: None,
        tool_count: 0,
        operation_id: None,
        detail: Some("retire failed"),
      }
  }
  let event : @types.TurnEvent = ToolCatalogChanged(payload~)
  events.emit_core(None, event)
}

///|
fn emit_catalog_captured(
  events : @event_runtime.EventRuntime,
  operation_id : String,
  catalog_version : Int32,
  tool_count : Int32,
) -> Unit {
  let payload : @types.ToolCatalogChangedPayload = {
    change: Captured,
    owner: "",
    revision: None,
    catalog_version: Some(catalog_version),
    tool_count,
    operation_id: Some(operation_id),
    detail: None,
  }
  let event : @types.TurnEvent = ToolCatalogChanged(payload~)
  events.emit_core(None, event)
}

///|
fn AgentRuntime::capture_tool_contributions(
  self : AgentRuntime,
  operation_id~ : String,
) -> Unit raise @error.AgentError {
  if self.tool_contributions.is_closed() {
    return
  }
  let candidate = self.tool_contributions.prepare_capture(
    CatalogVersion(self.next_catalog_version),
    self.hooks,
  ) catch {
    error =>
      raise Runtime(
        InvocationFailed(
          "tool catalog: " +
          @diagnostic.bounded_error_label(error.to_string(), 256),
        ),
      )
  }
  guard candidate is Some(capture) else { return }
  if !self.puppet.replace_catalog(capture.catalog) {
    raise Runtime(
      InvocationFailed("tool catalog: a run is active at operation admission"),
    )
  }
  let catalog_version = self.next_catalog_version
  self.tool_bindings.val = capture.bindings
  self.binding_versions.val = capture.binding_versions()
  self.versions.install_captured(capture.versions())
  self.next_catalog_version += 1
  self.tool_contributions.accept_capture(capture)
  emit_catalog_captured(
    self.events,
    operation_id,
    catalog_version,
    capture.catalog.definitions().length(),
  )
}

///|
fn AgentRuntime::acquire_operation_versions(self : AgentRuntime) -> Unit {
  self.versions.acquire(self.tool_contributions)
}

///|
fn AgentRuntime::release_operation_versions(self : AgentRuntime) -> Unit {
  self.versions.release_operation(
    self.tool_contributions,
    self.tool_runtime.has_unconfirmed(),
  )
}

///|
fn AgentRuntime::release_retained_versions(self : AgentRuntime) -> Unit {
  self.versions.release_retained(
    self.tool_contributions,
    self.tool_runtime.has_unconfirmed(),
  )
}

///|
async fn AgentRuntime::retire_released_versions(
  self : AgentRuntime,
) -> Unit noraise + nocancel {
  @async.protect_from_cancel(async fn() noraise {
    self.release_operation_versions()
    self.release_retained_versions()
    self.retire_pending_versions()
  }) catch {
    error =>
      emit_secondary_failure(
        self.events,
        "tool_version_finalizer",
        error.to_string(),
      )
  }
}

///|
async fn AgentRuntime::retire_pending_versions(
  self : AgentRuntime,
) -> Unit noraise {
  let failures = self.tool_contributions.retire_unreferenced()
  for failure in failures {
    emit_secondary_failure(
      self.events,
      "tool_version_retire",
      "version=\{failure.version} owner=\{failure.owner} revision=\{failure.revision}: retire failed",
    )
  }
}
