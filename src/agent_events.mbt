///|
/// Listen to this Agent's notifications without acquiring publication rights.
/// The subscription is live until cancelled or the Agent finishes shutdown.
/// No history is replayed; `namespace_=None` listens to every namespace.
pub fn Agent::subscribe_events(
  self : Agent,
  handler : (@events.EventEnvelope) -> Unit,
  namespace_~ : @events.EventNamespace? = None,
) -> Result[@events.Subscription, @events.EventError] {
  self.runtime.events.subscribe(handler, namespace_~)
}
