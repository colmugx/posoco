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
  priv active : Ref[Bool]
}

///|
/// Framework construction hook. Product code receives subscriptions from
/// `Events::subscribe` and does not need this constructor.
pub fn Subscription::from_cancel(cancel : () -> Unit) -> Subscription {
  { cancel_: cancel, active: Ref(true), }
}

///|
pub fn Subscription::cancel(self : Subscription) -> Unit {
  if self.active.val {
    self.active.val = false
    (self.cancel_)()
  }
}
