///|
/// Push observation half of the UI runtime.

///|
fn ui_copy_delivery(delivery : UiDelivery) -> UiDelivery {
  {
    cursor: delivery.cursor,
    change: match delivery.change {
      Resource(change~) => Resource(change=ui_copy_change(change))
      Interaction(change~) =>
        Interaction(change=ui_copy_interaction_change(change))
    },
  }
}

///|
/// Register a subscriber; baseline and registration come from one synchronous
/// step.
fn UiRuntime::subscribe(
  self : UiRuntime,
  listener : (@port.UiFeedBatch) -> Result[Unit, String],
  on_failure : (@port.UiListenerFailure) -> Unit,
) -> Result[@port.UiObservation, @port.UiResourceError] {
  if self.closed {
    return Err(ui_closed_error())
  }
  let baseline = match self.snapshot() {
    Ok(baseline) => baseline
    Err(error) => return Err(error)
  }
  let id = self.next_subscriber
  self.next_subscriber = id + 1
  self.subscribers[id] = { id, active: true, listener, on_failure, queue: [], }
  self.subscriber_order.push(id)
  Ok({
    baseline,
    subscription: @port.UiSubscription::from_callbacks(
      id~,
      is_active=fn() {
        match self.subscribers.get(id) {
          Some(subscriber) => subscriber.active
          None => false
        }
      },
      unsubscribe=fn() { self.unsubscribe(id) },
    ),
  })
}

///|
/// Stop delivery for one subscriber. Idempotent, and safe from inside the
/// listener: the queue is cleared and nothing is delivered afterwards.
fn UiRuntime::unsubscribe(self : UiRuntime, id : Int32) -> Unit {
  match self.subscribers.get(id) {
    Some(subscriber) => {
      subscriber.active = false
      subscriber.queue.clear()
    }
    None => ()
  }
  self.subscribers.remove(id)
  let mut index = 0
  while index < self.subscriber_order.length() {
    if self.subscriber_order[index] == id {
      ignore(self.subscriber_order.remove(index))
    } else {
      index = index + 1
    }
  }
}

///|
/// Queue one change for every active subscriber and drain the queues.
fn UiRuntime::notify(self : UiRuntime, delivery : UiDelivery) -> Unit {
  if self.subscribers.is_empty() {
    return
  }
  for id in self.subscriber_order.copy() {
    match self.subscribers.get(id) {
      Some(subscriber) =>
        if subscriber.active {
          subscriber.queue.push(ui_copy_delivery(delivery))
        }
      None => ()
    }
  }
  self.flush_subscribers()
}

///|
fn UiRuntime::has_queued_delivery(self : UiRuntime) -> Bool {
  for id in self.subscriber_order {
    match self.subscribers.get(id) {
      Some(subscriber) =>
        if subscriber.active && subscriber.queue.length() > 0 {
          return true
        }
      None => ()
    }
  }
  false
}

///|
/// Deliver until every queue is empty, one batch per subscriber per round, so
/// a re-entrant publisher cannot starve other subscribers.
fn UiRuntime::flush_subscribers(self : UiRuntime) -> Unit {
  if self.delivering {
    return
  }
  self.delivering = true
  while self.has_queued_delivery() {
    for id in self.subscriber_order.copy() {
      match self.subscribers.get(id) {
        None => ()
        Some(subscriber) =>
          if subscriber.active && subscriber.queue.length() > 0 {
            self.deliver_next(subscriber)
          }
      }
    }
  }
  self.delivering = false
}

///|
/// Deliver exactly one queued batch to one subscriber; an `Err` ends that
/// subscription and reports the failure once.
fn UiRuntime::deliver_next(self : UiRuntime, subscriber : UiSubscriber) -> Unit {
  let delivery = subscriber.queue.remove(0)
  let batch : @port.UiFeedBatch = {
    cursor: delivery.cursor,
    change: delivery.change,
  }
  match (subscriber.listener)(batch) {
    Ok(_) => ()
    Err(detail) => self.drop_subscriber(subscriber, delivery.cursor.seq, detail)
  }
}

///|
/// Drop a failing subscriber and report it after removal.
fn UiRuntime::drop_subscriber(
  self : UiRuntime,
  subscriber : UiSubscriber,
  seq : Int32,
  detail : String,
) -> Unit {
  let id = subscriber.id
  let reporter = subscriber.on_failure
  subscriber.active = false
  subscriber.queue.clear()
  self.unsubscribe(id)
  let failure : @port.UiListenerFailure = { subscription: id, seq, detail, }
  reporter(failure)
}

///|
/// Close-path cleanup: every subscription ends; no listener is called again.
fn UiRuntime::drop_all_subscribers(self : UiRuntime) -> Unit {
  for id in self.subscriber_order.copy() {
    match self.subscribers.get(id) {
      Some(subscriber) => {
        subscriber.active = false
        subscriber.queue.clear()
      }
      None => ()
    }
  }
  self.subscribers.clear()
  self.subscriber_order.clear()
}
