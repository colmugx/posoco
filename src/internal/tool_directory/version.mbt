///|
/// One live contributed version. The owner slot points at the active version;
/// a superseded or withdrawn version survives only while an operation or an
/// unconfirmed execution still references it, or while its retire is pending.
///
/// The bound provider wrapper consults `gate` synchronously immediately before
/// the real `execute`, so a hard revocation applies even to an operation that
/// was admitted earlier and to a host runtime decorator that awaited before
/// forwarding the effect.
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
/// Shared revocation flag: written by the registry, read by the version's bound
/// provider wrapper at launch time.
priv struct VersionGate {
  mut revoked : Bool
}

///|
/// Bounded budget for one retire attempt, matching the existing operation
/// settlement budget. No new configuration is introduced.
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
/// The executor the captured binding actually holds for a contributed version:
/// the owner's provider, fixed at publish time and gated by the version's
/// revocation flag right before the real execute.
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
    // Trusted core fact: the provider was never entered for this effect. The
    // ledger lets the executor settle this as the typed `Revoked` rejection
    // instead of a host contract violation.
    let run_id = match ctx.scope {
      Some(scope) => scope.run_id.to_string()
      None => ""
    }
    self.launcher.record_refusal(
      run_id,
      ctx.effect_id.to_int(),
      @kernel.NotExecutedReason::Revoked,
    )
    return @kernel.ToolOutcome::NotExecuted(
      reason=@kernel.NotExecutedReason::Revoked,
      original_call_id=ctx.call_id,
    )
  }
  self.inner.execute(ctx)
}

///|
/// Hard revocation is irreversible: the gate refuses every later launch, and
/// the version can no longer become active again.
fn ToolVersion::revoke(self : ToolVersion) -> Unit {
  self.gate.revoked = true
  self.active = false
}
