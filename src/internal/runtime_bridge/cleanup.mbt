///|
/// Runtime uses run-local effect ids. Admission cannot reuse those ids while
/// an earlier execution has no confirmed terminal disposition.
pub fn RuntimeHostShim::require_settled(
  self : RuntimeHostShim,
) -> Unit raise @error.AgentError {
  if !self.incomplete.is_empty() {
    let scopes = self.incomplete
      .keys()
      .to_array()
      .map(key => key.0 + "/" + key.1.to_string())
      .join(", ")
    raise @error.AgentError::Runtime(
      @error.RuntimeError::InvocationFailed(
        "unconfirmed tool execution: " + scopes,
      ),
    )
  }
}

///|
pub async fn RuntimeHostShim::cleanup_unconfirmed(
  self : RuntimeHostShim,
) -> Unit {
  let ids = self.incomplete
    .values()
    .to_array()
    .filter_map(scope => scope.effect_id)
  if ids.is_empty() {
    return
  }
  let _ = @kernel_exec.HostRuntime::cancel_effects(
    self,
    ids,
    HostRequested(detail=Some("Agent shutdown cleanup")),
  )
  self.require_settled()
}

///|
fn validate_runtime_cancellations(
  expected : Array[@kernel.EffectId],
  reported : Array[(@kernel.EffectId, @kernel.CancelDisposition)],
) -> Unit raise @error.RuntimeError {
  let remaining : Map[Int32, Bool] = Map::from_array([])
  for id in expected {
    if remaining.contains(id.to_int()) {
      raise InvocationFailed(
        "duplicate cancellation effect id: " + id.to_int().to_string(),
      )
    }
    remaining[id.to_int()] = true
  }
  for entry in reported {
    let (id, _) = entry
    if !remaining.contains(id.to_int()) {
      raise InvocationFailed(
        "foreign or duplicate cancellation result: " + id.to_int().to_string(),
      )
    }
    remaining.remove(id.to_int())
  }
  if !remaining.is_empty() {
    raise InvocationFailed("missing cancellation results")
  }
}
