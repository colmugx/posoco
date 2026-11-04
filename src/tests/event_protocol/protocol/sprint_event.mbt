///|
/// Community-owned payload ADT. Posoco never learns its shape: the sprint
/// lifecycle stays a closed, exhaustively matchable enum in this package.
#derive(Eq, Debug)
pub(all) enum SprintEvent {
  Started(Int32)
  Blocked(reason~ : String)
  Finished
}

///|
/// The community protocol adds its own constructor to Posoco's open event
/// type. No core file changes and no JSON codec are involved.
pub(all) extenum @events.Event += {
  SprintChanged(SprintEvent)
}

///|
pub extend SprintEvent with Eq::{not_equal, equal}

///|
pub extend SprintEvent with Debug::{to_repr}

///|
/// Producer-side publish helper. The runtime tags the event with the
/// namespace bound to the capability, so this package cannot choose or forge
/// one.
pub fn publish_sprint(
  events : @events.Events,
  event : SprintEvent,
  scope~ : @types.EventScope? = None,
) -> Result[Unit, @events.EventError] {
  events.publish(SprintChanged(event), scope~)
}

///|
pub fn SprintEvent::describe(self : SprintEvent) -> String {
  match self {
    Started(sprint) => "started #\{sprint}"
    Blocked(reason~) => "blocked: " + reason
    Finished => "finished"
  }
}

///|
/// Consumer-side projection: recover the community payload from a delivered
/// envelope. The wildcard absorbs constructors declared by other packages;
/// `SprintEvent` below it matches exhaustively.
pub fn sprint_of(envelope : @events.EventEnvelope) -> SprintEvent? {
  match envelope.event {
    SprintChanged(event) => Some(event)
    _ => None
  }
}
