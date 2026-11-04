///|
/// Instance-level event resource. Create it before constructing publishers,
/// then transfer its lifetime to exactly one Agent with `events=system`.
/// Ordinary publishers receive only the owner-bound `Events` capability.
pub struct EventSystem {
  priv runtime : @event_runtime.EventRuntime
  priv mut owned : Bool
}

///|
/// Create an unclaimed resource. Close it explicitly if no Agent takes it over.
///
/// ```mbt check
/// test {
///   let system = @posoco.EventSystem()
///   let publisher = system.publisher(owner="provider").unwrap()
///   let subscription = publisher.subscribe(fn(_) { () }).unwrap()
///   assert_true(system.close() is Ok(_))
///   assert_true(system.publisher(owner="provider") is Err(Closed))
///   subscription.cancel()
/// }
/// ```
pub fn EventSystem::EventSystem() -> EventSystem {
  { runtime: @event_runtime.EventRuntime(), owned: false, }
}

///|
/// Grant publication in `Extension(owner)`, before or after Agent composition.
/// Granting a name is the resource holder's authority; a capability cannot
/// change its namespace or publish Posoco core events.
pub fn EventSystem::publisher(
  self : EventSystem,
  owner~ : String,
) -> Result[@events.Events, @events.EventError] {
  if self.runtime.is_closed() {
    return Err(Closed)
  }
  if owner.trim().is_empty() {
    return Err(InvalidOwner)
  }
  Ok(self.runtime.capability(owner))
}

///|
/// Subscribe before ports or the Agent exist. Registration order is shared
/// with Agent and extension listeners. Earlier events are never replayed.
pub fn EventSystem::subscribe(
  self : EventSystem,
  handler : (@events.EventEnvelope) -> Unit,
  namespace_~ : @events.EventNamespace? = None,
) -> Result[@events.Subscription, @events.EventError] {
  self.runtime.subscribe(handler, namespace_~)
}

///|
/// Release an unclaimed resource. Once an Agent owns it, only Agent.shutdown
/// may end its lifetime. Closing an already-closed resource is idempotent.
pub fn EventSystem::close(
  self : EventSystem,
) -> Result[Unit, @events.EventError] {
  if self.runtime.is_closed() {
    return Ok(())
  }
  if self.owned {
    return Err(Owned)
  }
  self.runtime.close()
  Ok(())
}

///|
fn EventSystem::claim(
  self : EventSystem,
) -> @event_runtime.EventRuntime raise @error.CompositionError {
  if self.runtime.is_closed() {
    raise EventSystemClosed
  }
  if self.owned {
    raise EventSystemAlreadyOwned
  }
  self.owned = true
  self.runtime
}
