///|
/// Trusted final-gate refusals, distinguished from a host inventing NotExecuted.
pub struct ToolLaunchGate {
  priv refusals : Map[(String, Int32), @kernel.NotExecutedReason]
}

///|
pub fn ToolLaunchGate::ToolLaunchGate() -> ToolLaunchGate {
  { refusals: Map::from_array([]), }
}

///|
pub fn ToolLaunchGate::record_refusal(
  self : ToolLaunchGate,
  run_id : String,
  effect_id : Int32,
  reason : @kernel.NotExecutedReason,
) -> Unit {
  self.refusals[(run_id, effect_id)] = reason
}

///|
pub fn ToolLaunchGate::take_refusal(
  self : ToolLaunchGate,
  run_id : String,
  effect_id : Int32,
) -> @kernel.NotExecutedReason? {
  let key = (run_id, effect_id)
  let found = self.refusals.get(key)
  self.refusals.remove(key)
  found
}
