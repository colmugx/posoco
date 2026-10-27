///|
/// Read-only committed event projection. Run-bound events carry attribution;
/// operation-level diagnostics may have no run scope. Use PipelineHook for
/// interception, approval or asynchronous side effects.
pub(open) trait Observer {
  fn on_event(Self, scope : @types.EventScope?, event : @types.TurnEvent) -> Unit = _
}

///|
impl Observer with fn on_event(
  _self,
  _scope : @types.EventScope?,
  _event : @types.TurnEvent,
) -> Unit {
  ()
}
