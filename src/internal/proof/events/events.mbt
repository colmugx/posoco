///|
pub(all) enum NamespaceTag {
  Posoco
  Extension(Int32)
}

///|
pub(all) enum PayloadKind {
  Core
  Community
}

///|
pub(all) enum PublishDecision {
  Allowed
  ErrClosed
  ErrReservedEvent
}

///|
pub(all) struct SubscriptionState {
  active : Bool
}

///|
pub(all) struct CancelOutcome {
  state : SubscriptionState
  should_run : Bool
}

///|
pub fn authorize_publish(
  closed : Bool,
  cap_ns : NamespaceTag,
  payload : PayloadKind,
) -> PublishDecision where {
  proof_ensure: result => authorize_post(closed, cap_ns, payload, result),
} {
  if closed {
    ErrClosed
  } else {
    match (cap_ns, payload) {
      (Extension(_), Core) => ErrReservedEvent
      _ => Allowed
    }
  }
}

///|
pub fn listener_accepts(
  filter : NamespaceTag?,
  ns : NamespaceTag,
) -> Bool where {
  proof_ensure: result => result == listener_accepts_spec(filter, ns),
} {
  match filter {
    None => true
    Some(Posoco) =>
      match ns {
        Posoco => true
        Extension(_) => false
      }
    Some(Extension(fid)) =>
      match ns {
        Posoco => false
        Extension(nid) => fid == nid
      }
  }
}

///|
pub fn cancel_subscription(
  state : SubscriptionState,
) -> CancelOutcome where {
  proof_ensure: result => {
    !result.state.active && result.should_run == state.active
  },
} {
  if state.active {
    { state: { active: false, }, should_run: true, }
  } else {
    { state: { active: false, }, should_run: false, }
  }
}
