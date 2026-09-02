// ---------------------------------------------------------------------------
// RecordingObserver — preserves full event order.
// ---------------------------------------------------------------------------

///|
/// Observer fake that records every TurnEvent in arrival order.
/// Unlike a counter, it keeps the full sequence for trace assertions.
pub(all) struct RecordingObserver {
  mut events : Array[@types.TurnEvent]
}

///|
pub fn RecordingObserver::RecordingObserver() -> RecordingObserver {
  { events: [], }
}

///|
/// Snapshot of all recorded events in order.
pub fn RecordingObserver::events(
  self : RecordingObserver,
) -> Array[@types.TurnEvent] {
  self.events.map(testkit_snapshot_event)
}

///|
pub impl @port.Observer for RecordingObserver with fn on_event(self, event) {
  self.events.push(testkit_snapshot_event(event))
}

// ---------------------------------------------------------------------------
// RecordingHook — records hook invocations (native hook traits).
// ---------------------------------------------------------------------------

///|
/// The exact decision made by a RecordingHook invocation.
pub(all) enum RecordedHookOutcome {
  PassedThrough
  AbortedWith(String)
  DeferredWith(String)
} derive(Debug)

///|
/// A recorded hook invocation: which hook function ran and its decision.
pub(all) struct HookRecord {
  label : String
  outcome : RecordedHookOutcome
} derive(Debug)

///|
/// Multi-hook fake that implements `PipelineHook` at all three interception points.
/// By default it is a pass-through (returns messages unchanged, approves
/// tool calls). Records every call.
pub(all) struct RecordingHook {
  mut records : Array[HookRecord]
  abort_on : Map[String, String]
  defer_on : Map[String, String]
}

///|
pub fn RecordingHook::RecordingHook() -> RecordingHook {
  { records: [], abort_on: Map::from_array([]), defer_on: Map::from_array([]), }
}

///|
/// Configure the hook to abort/reject when the label contains `trigger`.
pub fn RecordingHook::abort_when(
  self : RecordingHook,
  trigger : String,
  msg : String,
) -> Unit {
  self.abort_on[trigger] = msg
}

///|
/// Configure the hook to defer when the label contains `trigger`.
pub fn RecordingHook::defer_when(
  self : RecordingHook,
  trigger : String,
  reason : String,
) -> Unit {
  self.defer_on[trigger] = reason
}

///|
pub fn RecordingHook::records(self : RecordingHook) -> Array[HookRecord] {
  self.records.map(fn(record) {
    { label: record.label, outcome: record.outcome, }
  })
}

///|
pub impl @port.PipelineHook for RecordingHook with fn before_model(
  self,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] raise @port.HookAbort {
  let label = "before_model"
  for trigger in self.abort_on.keys() {
    if label.contains(trigger) ||
      trigger.contains("BeforeModel") ||
      trigger.contains("BeforeTurn") {
      let message = self.abort_on[trigger]
      self.records.push({ label, outcome: AbortedWith(message), })
      raise @port.HookAbort::Aborted(reason=message)
    }
  }
  self.records.push({ label, outcome: PassedThrough, })
  messages
}

///|
pub impl @port.PipelineHook for RecordingHook with fn before_tool(
  self,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  let label = "before_tool"
  let dbg = call.call_id.to_string()
  for trigger in self.abort_on.keys() {
    if dbg.contains(trigger) {
      let message = self.abort_on[trigger]
      self.records.push({ label, outcome: AbortedWith(message), })
      return Reject(reason=message)
    }
  }
  for trigger in self.defer_on.keys() {
    if dbg.contains(trigger) {
      let reason = self.defer_on[trigger]
      self.records.push({ label, outcome: DeferredWith(reason), })
      return Defer(reason~)
    }
  }
  self.records.push({ label, outcome: PassedThrough, })
  Approve(call~)
}

///|
pub impl @port.PipelineHook for RecordingHook with fn on_post_event(
  self,
  _stage : @port.HookStage,
) -> Unit {
  let label = "on_post_event"
  self.records.push({ label, outcome: PassedThrough, })
}
