///|
/// Canonical run/turn/effect identity and cancel contracts (M1, ADR §2.5,
/// §2.6, §2.9). These types are part of the public wire contract: advanced
/// runtimes correlate effect execution and cancellation with them, while the
/// reducer remains their sole allocator.
///
/// Promoted from `internal/kernel_exec`/`internal/puppetry` so the public
/// runtime seam (`colmugx/posoco/runtime`) can name effect/run/turn identity
/// without importing internal packages. Internal packages alias these
/// definitions — this file is the single source of truth.

///|
/// Stable identifier for a single Run. Supplied by the host in the `Start`
/// input and carried through every state.
pub(all) struct RunId {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn RunId::checked(value : String) -> Result[RunId, String] {
  if value == "" {
    Err("RunId must be non-empty")
  } else {
    Ok(RunId::{ value, })
  }
}

///|
pub fn RunId::unchecked(value : String) -> RunId {
  RunId::{ value, }
}

///|
pub fn RunId::to_string(self : RunId) -> String {
  self.value
}

///|
pub impl Show for RunId with fn to_string(self : RunId) -> String {
  "RunId(\{self.value})"
}

///|
/// Identifier for a single turn within a Run. A Run may contain multiple
/// turns (initial prompt + follow-ups); turns never outlive their Run.
/// follow_up allocates a new TurnId under the same RunId.
pub(all) struct TurnId {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn TurnId::checked(value : String) -> Result[TurnId, String] {
  if value == "" {
    Err("TurnId must be non-empty")
  } else {
    Ok(TurnId::{ value, })
  }
}

///|
pub fn TurnId::unchecked(value : String) -> TurnId {
  TurnId::{ value, }
}

///|
pub fn TurnId::to_string(self : TurnId) -> String {
  self.value
}

///|
pub impl Show for TurnId with fn to_string(self : TurnId) -> String {
  self.value
}

///|
/// Stable identifier for a product session. The Kernel never opens or
/// materializes session storage; it carries this identity through effects,
/// journal entries, and committed event envelopes.
pub(all) struct SessionId {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn SessionId::checked(value : String) -> Result[SessionId, String] {
  if value == "" {
    Err("SessionId must be non-empty")
  } else {
    Ok(SessionId::{ value, })
  }
}

///|
pub fn SessionId::unchecked(value : String) -> SessionId {
  SessionId::{ value, }
}

///|
pub fn SessionId::to_string(self : SessionId) -> String {
  self.value
}

///|
/// Identifier for a single declared Effect. Monotonic per Run. Each completion
/// input must correlate to a pending effect with this id; a mismatch is
/// `InvariantViolation::StaleCorrelation`.
pub(all) struct EffectId {
  value : Int
} derive(Eq, Hash, Debug)

///|
/// Contract: the counter origin is exactly 1 (strictly positive start).
pub fn EffectId::first() -> EffectId where {
  proof_ensure: result => effect_id_first_ok(result),
} {
  { value: 1, }
}

///|
/// Contract: strictly monotonic — the next id is exactly the current id
/// plus 1, so ids never repeat going forward.
pub fn EffectId::next(
  self : EffectId,
) -> EffectId where {
  proof_ensure: result => effect_id_next_ok(self, result),
} {
  { value: self.value + 1, }
}

///|
/// Contract: projection identity — `to_int` exposes the underlying counter
/// unchanged.
pub fn EffectId::to_int(
  self : EffectId,
) -> Int where {
  proof_ensure: result => effect_id_to_int_ok(self, result),
} {
  self.value
}

///|
pub impl Show for EffectId with fn to_string(self : EffectId) -> String {
  "EffectId(\{self.value})"
}

///|
/// Catalog version — bumped every time a snapshot is built. The reducer and
/// executor correlate `CallModel` and `ExecuteTool` effects back to the exact
/// snapshot version the model was prompted against; a mismatch is a kernel
/// invariant failure (`InvariantViolation::StaleSnapshot`).
pub(all) struct CatalogVersion {
  value : Int
} derive(Eq, Debug)

///|
/// Contract: the canonical constructor wraps its argument unchanged.
pub fn CatalogVersion::CatalogVersion(
  value : Int,
) -> CatalogVersion where {
  proof_ensure: result => catalog_version_mk_ok(result, value),
} {
  CatalogVersion::{ value, }
}

///|
/// Contract: projection identity — `to_int` exposes the wrapped version
/// unchanged.
pub fn CatalogVersion::to_int(
  self : CatalogVersion,
) -> Int where {
  proof_ensure: result => catalog_version_to_int_ok(self, result),
} {
  self.value
}

///|
pub impl Show for CatalogVersion with fn to_string(self : CatalogVersion) -> String {
  "CatalogVersion(\{self.value})"
}

///|
/// Why a Run was cancelled.
pub(all) enum CancelReason {
  /// Host explicitly cancelled.
  HostRequested(detail~ : String?)
  /// Adapter/host observed the deadline.
  DeadlineReached
} derive(Eq, Debug)

///|
fn detail_or_empty(detail : String?) -> String {
  match detail {
    Some(s) => s
    None => ""
  }
}

///|
pub impl Show for CancelReason with fn to_string(self : CancelReason) -> String {
  match self {
    HostRequested(detail~) => "HostRequested(\{detail_or_empty(detail)})"
    DeadlineReached => "DeadlineReached"
  }
}

///|
/// What an adapter reports after a `CancelOutstanding` effect. The reducer
/// never waits for this.
pub(all) enum CancelDisposition {
  /// Cancel signal propagated.
  Propagated
  /// Cancel not propagated; only stops the reducer waiting.
  NotPropagated
  /// Effect already settled before cancel arrived.
  AlreadySettled
} derive(Eq, Debug)

///|
pub impl Show for CancelDisposition with fn to_string(self : CancelDisposition) -> String {
  match self {
    Propagated => "Propagated"
    NotPropagated => "NotPropagated"
    AlreadySettled => "AlreadySettled"
  }
}

///|
/// Invocation identity for a single model-side call (`ModelPort::chat` /
/// `ModelPort::compact`, and their `Runtime` correspondences). Constructed by
/// posoco at the effect-interpretation layer and passed down unchanged; ports
/// and hosts MUST treat it as read-only.
///
/// This is the canonical answer to "which session/run is this call serving":
/// adapters that key behaviour on session identity (continuity, telemetry,
/// cost attribution, per-session policy) read it from here instead of
/// smuggling it through messages or config.
///
/// Invariants:
/// - `session_id` / `run_id` always identify the Run that issued the call,
///   including `compact` (compact is host-driven but still scoped to a Run).
/// - `effect_id` is `Some` iff the call executes a reducer-allocated
///   `CallModel` effect; it is `None` for `compact`, which is not an effect.
///   Hosts that propagate cancellation key in-flight model calls by this id,
///   mirroring the tool side's `EffectContext.effect_id`.
/// - `pressure` is `Some` only where posoco has a reading worth sharing
///   (the compact path); ports treat it as advisory read-only input.
pub(all) struct InvocationScope {
  session_id : SessionId
  run_id : RunId
  effect_id : EffectId?
  pressure : ContextPressure?
} derive(Eq, Debug)
