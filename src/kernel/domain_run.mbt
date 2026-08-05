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
pub fn RunId::new(value : String) -> Result[RunId, String] {
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
pub fn TurnId::new(value : String) -> Result[TurnId, String] {
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
pub fn SessionId::new(value : String) -> Result[SessionId, String] {
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
pub fn EffectId::first() -> EffectId {
  { value: 1 }
}

///|
pub fn EffectId::next(self : EffectId) -> EffectId {
  { value: self.value + 1 }
}

///|
pub fn EffectId::to_int(self : EffectId) -> Int {
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
pub fn CatalogVersion::CatalogVersion(value : Int) -> CatalogVersion {
  CatalogVersion::{ value, }
}

///|
pub fn CatalogVersion::to_int(self : CatalogVersion) -> Int {
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
