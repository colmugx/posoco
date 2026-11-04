///|
/// Delivery namespace of one event. `Posoco` is reserved for core
/// notifications; an extension capability publishes only its own
/// `Extension(manifest_id)`. The namespace is system-produced envelope
/// metadata, never a string a publisher can spoof.
#derive(Eq, Debug)
pub(all) enum EventNamespace {
  Posoco
  Extension(String)
}

///|
pub extend EventNamespace with Eq::{not_equal, equal}

///|
pub extend EventNamespace with Debug::{to_repr}
