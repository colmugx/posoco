///|
/// Observer fake that records the manifest-order delivery log, the scope, and
/// the event shape it was handed.
priv struct RecordingObserver {
  name : String
  log : Ref[Array[String]]
  received : Array[(@types.EventScope?, @types.TurnEvent)]
}

///|
fn recording_observer(
  name : String,
  log : Ref[Array[String]],
) -> RecordingObserver {
  { name, log, received: [], }
}

///|
fn RecordingObserver::events(
  self : RecordingObserver,
) -> Array[@types.TurnEvent] {
  self.received.map(fn(entry) { entry.1 })
}

///|
fn RecordingObserver::scopes(
  self : RecordingObserver,
) -> Array[@types.EventScope?] {
  self.received.map(fn(entry) { entry.0 })
}

///|
impl @port.Observer for RecordingObserver with fn on_event(
  self : RecordingObserver,
  scope : @types.EventScope?,
  event : @types.TurnEvent,
) -> Unit {
  self.log.val.push(self.name)
  self.received.push((scope, event))
}

///|
fn test_scope(
  session : String,
  run : String,
  turn : String,
) -> @types.EventScope {
  {
    session_id: @kernel.SessionId::unchecked(session),
    run_id: @kernel.RunId::unchecked(run),
    turn_id: @kernel.TurnId::unchecked(turn),
  }
}

///|
fn core_label(event : @types.TurnEvent) -> String {
  match event {
    TurnStarted => "TurnStarted"
    TurnCompleted => "TurnCompleted"
    TurnFailed(reason) => "TurnFailed:" + reason
    Custom(label~, ..) => "Custom:" + label
    _ => "other"
  }
}

///|
/// Stable text of one delivery: namespace + typed payload. Tests compare
/// sequences instead of inspecting internal queue state.
fn envelope_label(envelope : @events.EventEnvelope) -> String {
  let owner = match envelope.namespace_of() {
    Posoco => "posoco"
    Extension(owner) => owner
  }
  let payload = match envelope.event {
    @events.Core(event) => core_label(event)
    @protocol.SprintChanged(sprint) => sprint.describe()
    _ => "unknown"
  }
  owner + "/" + payload
}

///|
fn json_value(value : Json) -> String? {
  match value {
    Object(fields) =>
      match fields["k"] {
        String(text) => Some(text)
        _ => None
      }
    _ => None
  }
}
