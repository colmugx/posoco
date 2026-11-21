///|
/// Opaque handle of one listener registration. `cancel` is idempotent and
/// releases the handler reference; a handle whose runtime is gone cancels to
/// a no-op.
///
/// # Example
/// ```mbt check
/// test {
///   let cancels = Ref(0)
///   let subscription = @events.Subscription::from_cancel(fn() {
///     cancels.val = cancels.val + 1
///   })
///   subscription.cancel()
///   subscription.cancel()
///   assert_eq(cancels.val, 1)
/// }
/// ```
pub struct Subscription {
  priv cancel_ : () -> Unit
  priv state : Ref[@proof_events.SubscriptionState]
}

///|
pub fn Subscription::from_cancel(cancel : () -> Unit) -> Subscription {
  { cancel_: cancel, state: Ref({ active: true, }), }
}

///|
pub fn Subscription::cancel(self : Subscription) -> Unit {
  let outcome = @proof_events.cancel_subscription(self.state.val)
  self.state.val = outcome.state
  if outcome.should_run {
    (self.cancel_)()
  }
}
