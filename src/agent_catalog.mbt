///|
using @directory {
  type ToolEntry,
  type ToolContributionRegistry,
  type ToolNameIndex,
  build_catalog_from_defs,
  merge_basic_catalog_defs,
  nonempty_provenance,
  tool_collision_message,
  tool_provenance,
}

///|
/// Agent owns source revisions and operation admission; the directory owns
/// validation and the definition/binding snapshot.
fn AgentRuntime::refresh_catalog_if_changed(self : AgentRuntime) -> Unit {
  match self.catalog_source {
    None => ()
    Some(source) => {
      let revision = source.revision()
      if revision == self.last_catalog_revision {
        return
      }
      self.last_catalog_revision = revision
      let defs = merge_basic_catalog_defs(self.basic_tool_defs, source.tools())
      self.tool_contributions.replace_source(
        defs,
        @kernel.CatalogVersion(self.next_catalog_version),
      ) catch {
        error =>
          emit_secondary_failure(
            self.observers,
            "catalog_refresh",
            "catalog revision \{revision} rejected: " +
            safe_error_label(error.to_string()),
          )
      }
    }
  }
}

///|
fn AgentRuntime::capture_tool_contributions(
  self : AgentRuntime,
) -> Unit raise @error.AgentError {
  if self.tool_contributions.is_closed() {
    return
  }
  self.refresh_catalog_if_changed()
  let candidate = self.tool_contributions.prepare_capture(
    CatalogVersion(self.next_catalog_version),
    self.hooks,
  ) catch {
    error =>
      raise @error.AgentError::Runtime(
        @error.RuntimeError::InvocationFailed(
          "tool catalog: " + bounded_error_label(error.to_string(), 256),
        ),
      )
  }
  guard candidate is Some(capture) else { return }
  if !self.puppet.replace_catalog(capture.catalog) {
    raise @error.AgentError::Runtime(
      @error.RuntimeError::InvocationFailed(
        "tool catalog: a run is active at operation admission",
      ),
    )
  }
  self.tool_bindings.val = capture.bindings
  self.next_catalog_version += 1
  self.tool_contributions.accept_capture(capture)
}
