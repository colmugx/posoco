///|
fn EventRuntime::publish(
  self : EventRuntime,
  namespace_ : @events.EventNamespace,
  scope : @types.EventScope?,
  event : @events.Event,
) -> Result[Unit, @events.EventError] {
  if self.closed.val {
    return Err(@events.EventError::Closed)
  }
  self.enqueue(namespace_, scope, event)
  Ok(())
}

///|
fn EventRuntime::enqueue(
  self : EventRuntime,
  namespace_ : @events.EventNamespace,
  scope : @types.EventScope?,
  event : @events.Event,
) -> Unit {
  // Core payloads are copied at the enqueue boundary: a producer that keeps
  // mutating the value it handed over cannot change what listeners see.
  let core = match event {
    @events.Core(core_event) =>
      Some(@event_snapshot.snapshot_turn_event(core_event))
    _ => None
  }
  self.queue.push({ namespace_, scope, event, core, })
  self.drain()
}

///|
let max_drain_batches : Int32 = 1024

///|
fn EventRuntime::drain(self : EventRuntime) -> Unit {
  if self.delivering.val {
    return
  }
  self.delivering.val = true
  defer {
    self.delivering.val = false
  }
  let mut batches = 0
  while !self.queue.is_empty() &&
        !self.closed.val &&
        batches < max_drain_batches {
    batches = batches + 1
    let batch = self.queue.copy()
    self.queue.clear()
    let listeners = self.listeners.copy()
    for queued in batch {
      if self.closed.val {
        break
      }
      for listener in listeners {
        if self.closed.val {
          break
        }
        if listener_accepts(listener, queued.namespace_) {
          (listener.handler)(envelope_of(queued))
        }
      }
    }
  }
}

///|
fn listener_accepts(
  listener : Listener,
  namespace_ : @events.EventNamespace,
) -> Bool {
  match listener.namespace_ {
    Some(filtered) => filtered == namespace_
    None => true
  }
}

///|
/// One envelope per delivery. Core payloads are snapshot again per receiver so
/// no listener can mutate what the next listener gets; community payloads are
/// the published value (immutable-by-convention, no generic deep copy).
fn envelope_of(queued : QueuedEvent) -> @events.EventEnvelope {
  match queued.core {
    Some(core) =>
      @events.EventEnvelope(
        namespace_=queued.namespace_,
        scope=queued.scope,
        event=@events.Core(@event_snapshot.snapshot_turn_event(core)),
      )
    None =>
      @events.EventEnvelope(
        namespace_=queued.namespace_,
        scope=queued.scope,
        event=queued.event,
      )
  }
}
