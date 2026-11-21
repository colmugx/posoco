///|
priv struct ToolVersion {
  owner : String
  revision : Int32
  entries : Array[ToolEntry]
  gate : VersionGate
  mut active : Bool
  /// Operations (and unconfirmed executions) currently using this version.
  mut refs : Int32
  retire : @port.ToolRetire?
  mut retiring : Bool
}

///|
priv struct VersionGate {
  mut revoked : Bool
}

///|
let version_retire_settle_ms : Int32 = 5_000

///|
/// One failed retire attempt, reported on the commit ACK and retried later.
pub(all) struct ToolRetireFailure {
  owner : String
  revision : Int32
  version : Int32
  detail : String
}

///|
priv struct VersionBoundProvider {
  inner : &@port.ToolProvider
  definitions : Array[@kernel.ToolDef]
  gate : VersionGate
  launcher : @kernel_exec.ToolLaunchGate
}

///|
impl @port.ToolProvider for VersionBoundProvider with fn list_tools(
  self : VersionBoundProvider,
) -> Array[@kernel.ToolDef] {
  self.definitions.map(snapshot_tool_def)
}

///|
impl @port.ToolProvider for VersionBoundProvider with fn execute(
  self : VersionBoundProvider,
  ctx : @port.ToolCallContext,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  if self.gate.revoked {
    let run_id = match ctx.scope {
      Some(scope) => scope.run_id.to_string()
      None => ""
    }
    self.launcher.record_refusal(run_id, ctx.effect_id.to_int(), Revoked)
    return NotExecuted(reason=Revoked, original_call_id=ctx.call_id)
  }
  self.inner.execute(ctx)
}

///|
fn ToolVersion::revoke(self : ToolVersion) -> Unit {
  self.gate.revoked = true
  self.active = false
}
