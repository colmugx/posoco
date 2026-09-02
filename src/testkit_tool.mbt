// ---------------------------------------------------------------------------
// RecordingToolProvider — records list/execute order and configurable outcomes.
// ---------------------------------------------------------------------------

///|
/// Configurable outcome for a tool call: success outcome, or raised runtime
/// error. Constructors are prefixed with `Outcome` to avoid ambiguity with
/// `Result::Ok`/`Result::Err` at unqualified call sites.
pub(all) enum ScriptedToolOutcome {
  OutcomeOk(@kernel.ToolOutcome)
  OutcomeErr(@error.RuntimeError)
} derive(Debug)

///|
/// A recorded tool execution: call id, tool name, and outcome.
pub(all) struct ToolExecRecord {
  requested_name : String
  call_id : String
  tool_name : String
  arguments : Json
  outcome : ScriptedToolOutcome
} derive(Debug)

///|
/// Unified provider operation trace, preserving list/execute interleaving.
pub(all) enum ToolProviderOp {
  ListTools
  ExecuteTool(requested_name~ : String, call~ : @kernel.ToolCall)
} derive(Debug)

///|
fn testkit_snapshot_tool_outcome(
  outcome : ScriptedToolOutcome,
) -> ScriptedToolOutcome {
  match outcome {
    OutcomeOk(value) => OutcomeOk(snapshot_tool_outcome(value))
    OutcomeErr(error) => OutcomeErr(error)
  }
}

///|
/// ToolProvider fake that declares a fixed tool list and routes execute() by
/// tool name through a configurable outcome map. Unknown tools raise
/// `RuntimeError::UnknownTool`. Every execute is recorded with its call id.
pub(all) struct RecordingToolProvider {
  tool_defs : Array[@kernel.ToolDef]
  outcomes : Map[String, ScriptedToolOutcome]
  mut list_calls : Int
  mut exec_records : Array[ToolExecRecord]
  mut ops : Array[ToolProviderOp]
}

///|
pub fn RecordingToolProvider::RecordingToolProvider(
  tool_defs : Array[@kernel.ToolDef],
  outcomes : Map[String, ScriptedToolOutcome],
) -> RecordingToolProvider {
  let copied_outcomes : Map[String, ScriptedToolOutcome] = Map::from_array([])
  for key in outcomes.keys() {
    copied_outcomes[key] = testkit_snapshot_tool_outcome(outcomes[key])
  }
  {
    tool_defs: tool_defs.map(testkit_snapshot_tool_def),
    outcomes: copied_outcomes,
    list_calls: 0,
    exec_records: [],
    ops: [],
  }
}

///|
/// Number of times list_tools was called.
pub fn RecordingToolProvider::list_call_count(
  self : RecordingToolProvider,
) -> Int {
  self.list_calls
}

///|
/// Snapshot of recorded executions (call id, tool name, outcome).
pub fn RecordingToolProvider::exec_records(
  self : RecordingToolProvider,
) -> Array[ToolExecRecord] {
  self.exec_records.map(fn(record) {
    {
      requested_name: record.requested_name,
      call_id: record.call_id,
      tool_name: record.tool_name,
      arguments: snapshot_json(record.arguments),
      outcome: testkit_snapshot_tool_outcome(record.outcome),
    }
  })
}

///|
/// Snapshot of list/execute operations in their exact observed order.
pub fn RecordingToolProvider::ops(
  self : RecordingToolProvider,
) -> Array[ToolProviderOp] {
  self.ops.map(fn(op) {
    match op {
      ListTools => ListTools
      ExecuteTool(requested_name~, call~) =>
        ExecuteTool(requested_name~, call=snapshot_tool_call(call))
    }
  })
}

///|
/// Direct (non-trait) execute entry point for testkit self-tests.
pub async fn RecordingToolProvider::execute_direct(
  self : RecordingToolProvider,
  name : String,
  call : @kernel.ToolCall,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  (self as &@port.ToolProvider).execute(name, call)
}

///|
pub impl @port.ToolProvider for RecordingToolProvider with fn list_tools(self) {
  self.list_calls = self.list_calls + 1
  self.ops.push(ListTools)
  self.tool_defs.map(testkit_snapshot_tool_def)
}

///|
pub impl @port.ToolProvider for RecordingToolProvider with fn execute(
  self,
  name : String,
  call : @kernel.ToolCall,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  let key = call.name.to_string()
  let outcome = match self.outcomes.get(key) {
    Some(o) => o
    None =>
      OutcomeErr(
        UnknownTool("recording_tool: no outcome configured for '\{key}'"),
      )
  }
  self.ops.push(ExecuteTool(requested_name=name, call=snapshot_tool_call(call)))
  self.exec_records.push({
    requested_name: name,
    call_id: call.call_id.to_string(),
    tool_name: call.name.to_string(),
    arguments: snapshot_json(call.arguments),
    outcome: testkit_snapshot_tool_outcome(outcome),
  })
  match outcome {
    OutcomeOk(value) => snapshot_tool_outcome(value)
    OutcomeErr(e) => raise e
  }
}
