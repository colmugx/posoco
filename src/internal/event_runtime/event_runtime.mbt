///|
/// One listener registration. `namespace_` is the namespace filter the
/// listener asked for (`None` = every namespace).
priv struct Listener {
  id : Int32
  namespace_ : @events.EventNamespace?
  handler : (@events.EventEnvelope) -> Unit
}

///|
/// One queued notification. Core payloads carry the enqueue-time snapshot in
/// `core`; community payloads are values and are delivered as published. The
/// namespace is recorded at enqueue so a capability cannot re-tag it later.
priv struct QueuedEvent {
  namespace_ : @events.EventNamespace
  scope : @types.EventScope?
  event : @events.Event
  core : @types.TurnEvent?
}

///|
/// Agent-owned synchronous notification runtime. One instance per Agent; core
/// notifications and community events share this queue, registration order
/// and per-batch listener snapshot. No background task and no process-global
/// bus: producers enqueue, the outermost publish drains.
pub struct EventRuntime {
  priv listeners : Array[Listener]
  priv queue : Array[QueuedEvent]
  priv next_id : Ref[Int32]
  priv delivering : Ref[Bool]
  priv closed : Ref[Bool]
}

///|
pub fn EventRuntime::EventRuntime() -> EventRuntime {
  {
    listeners: [],
    queue: [],
    next_id: Ref(0),
    delivering: Ref(false),
    closed: Ref(false),
  }
}

///|
/// Attach composed observers to the existing resource, in manifest order.
pub fn EventRuntime::register_observers(
  self : EventRuntime,
  observers : Array[&@port.Observer],
) -> Result[Unit, @events.EventError] {
  if self.closed.val {
    return Err(Closed)
  }
  for observer in observers {
    match
      self.subscribe(
        fn(envelope) {
          match envelope.event {
            @events.Core(event) => observer.on_event(envelope.scope, event)
            _ => ()
          }
        },
        namespace_=Some(@events.EventNamespace::Posoco),
      ) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  Ok(())
}

///|
pub fn EventRuntime::is_closed(self : EventRuntime) -> Bool {
  self.closed.val
}

///|
/// Register one listener. Delivery is synchronous in registration order; a
/// listener added or cancelled inside a delivery batch takes effect from the
/// next batch, and a new listener receives no history.
pub fn EventRuntime::subscribe(
  self : EventRuntime,
  handler : (@events.EventEnvelope) -> Unit,
  namespace_~ : @events.EventNamespace? = None,
) -> Result[@events.Subscription, @events.EventError] {
  if self.closed.val {
    return Err(@events.EventError::Closed)
  }
  let id = self.next_id.val
  self.next_id.val = id + 1
  self.listeners.push({ id, namespace_, handler, })
  let cancel = fn() {
    let mut index = 0
    while index < self.listeners.length() {
      if self.listeners[index].id == id {
        ignore(self.listeners.remove(index))
        break
      }
      index = index + 1
    }
  }
  Ok(@events.Subscription::from_cancel(cancel))
}

///|
/// Publish one core notification. Core producers call this; a call after
/// `close` means shutdown ordering is broken, so it aborts loudly instead of
/// silently dropping the notification.
pub fn EventRuntime::emit_core(
  self : EventRuntime,
  scope : @types.EventScope?,
  event : @types.TurnEvent,
) -> Unit {
  if self.closed.val {
    abort("event_runtime: emit_core after close")
  }
  self.enqueue(@events.EventNamespace::Posoco, scope, @events.Core(event))
}

///|
/// Owner-bound extension capability: publication is tagged with
/// `Extension(owner)` and a core payload is rejected with `ReservedEvent`.
pub fn EventRuntime::capability(
  self : EventRuntime,
  owner : String,
) -> @events.Events {
  let owner_namespace = @events.EventNamespace::Extension(owner)
  @events.Events::from_callbacks(
    publish=fn(event, scope) {
      match event {
        @events.Core(_) => Err(@events.EventError::ReservedEvent)
        _ => self.publish(owner_namespace, scope, event)
      }
    },
    subscribe=fn(handler, namespace_) { self.subscribe(handler, namespace_~) },
  )
}

///|
/// End the runtime: later publishes and subscriptions fail with `Closed`,
/// queued events are dropped, and listener/queue references are released so
/// capabilities and extension callbacks stop retaining each other. Cancelling
/// a subscription after close stays a no-op.
pub fn EventRuntime::close(self : EventRuntime) -> Unit {
  if self.closed.val {
    return
  }
  self.closed.val = true
  self.listeners.clear()
  self.queue.clear()
}

///|
/// Whether any listener is registered (composed observers count). Producers
/// use it to skip notification cost when nobody listens; it does not
/// distinguish namespace filters.
pub fn EventRuntime::has_listeners(self : EventRuntime) -> Bool {
  !self.listeners.is_empty()
}
