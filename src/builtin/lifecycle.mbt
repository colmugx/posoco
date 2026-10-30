///|
pub(all) struct NoopLifecycle {}

///|
pub extend NoopLifecycle with @port.Lifecycle::{
  on_compose,
  on_shutdown,
  on_start,
}

///|
pub impl @port.Lifecycle for NoopLifecycle

