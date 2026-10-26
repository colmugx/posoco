///|
/// Owner-bound dynamic tool contribution capability.
///
/// The Agent composes one value per declaring extension and delivers it
/// through `CompositionView::tool_contributions`, gated on
/// `Capability::ToolContribution`. It is a concrete value rather than a
/// public trait on purpose: contribution commits are Agent-owned, and there
/// is no host-replaceable registry port. Unlike `Tasks`, the capability is
/// bound to the manifest that declared it — the caller cannot publish for
/// another owner.
///
/// Contract:
/// - `replace` validates the whole provider group atomically against the
///   complete candidate directory (static composition tools plus every other
///   owner's active group). A rejected group changes nothing.
/// - `replace` reads the provider's definitions exactly once and deep-copies
///   them; the accepted revision is bound to that provider as its executor.
/// - Both `replace` and `withdraw` are async because the committed change can
///   immediately retire superseded versions that no operation references.
///   Every candidate check and the authoritative publish/withdraw happen
///   before the first await, so a failure never half-changes the directory.
/// - Accepted changes affect future operations only. An operation that was
///   already admitted keeps the catalog and execution table it captured at
///   admission, including follow-up turns drained by the same operation.
/// - `withdraw` defaults to a soft withdrawal: future operations no longer see
///   the group, admitted operations keep using it. A hard withdrawal revokes
///   every live version of the owner, so no operation can start a new call
///   through them and affected in-flight effects are cancelled.
/// - Retire callbacks must be bounded and safe to retry. A failed retire keeps
///   the version in the pending-cleanup set, is reported on the actual commit
///   ACK, and is retried by later commits, operation settlement and shutdown.
/// - After `Agent::shutdown` every change is rejected with `Closed`.

///|
/// What a withdraw request means for still-live versions of the owner.
pub(all) enum ToolWithdrawMode {
  /// Hide the group from future operations. Admitted operations keep working.
  Soft
  /// Hide the group and revoke every live version: no operation may start a
  /// new call through them, and affected in-flight effects are cancelled.
  Hard
} derive(Eq, Debug)

///|
pub extend ToolWithdrawMode with Eq::{not_equal, equal}

///|
pub extend ToolWithdrawMode with Debug::{to_repr}

///|
pub extend ToolWithdrawMode with Show::{to_string, output}

///|
pub impl Show for ToolWithdrawMode with fn to_string(self : ToolWithdrawMode) -> String {
  match self {
    Soft => "Soft"
    Hard => "Hard"
  }
}

///|
/// Directory state of one owner slot, as reported by an ACK or a query.
pub(all) enum ToolContributionState {
  /// The owner's group is part of the captured directory.
  Active
  /// The owner's group is no longer captured. Its versions stay alive only
  /// while an operation or an unconfirmed execution still references them.
  Withdrawn
  /// The Agent shut down; contribution handles are closed.
  Closed
} derive(Eq, Debug)

///|
pub extend ToolContributionState with Eq::{not_equal, equal}

///|
pub extend ToolContributionState with Debug::{to_repr}

///|
pub extend ToolContributionState with Show::{to_string, output}

///|
pub impl Show for ToolContributionState with fn to_string(
  self : ToolContributionState,
) -> String {
  match self {
    Active => "Active"
    Withdrawn => "Withdrawn"
    Closed => "Closed"
  }
}

///|
/// Optional version cleanup callback supplied by the publishing owner. Core
/// calls it once the version is neither active nor referenced by any operation
/// or unconfirmed execution. Return `Err(detail)` for a failed cleanup; core
/// also bounds the call. Either failure keeps the version pending for a later
/// retry, so the callback must be safe to run again.
pub type ToolRetire = async () -> Result[Unit, String]

///|
/// Acknowledgement of one accepted contribution commit. `revision` is
/// core-owned and monotonic per owner; it is distinct from the catalog
/// version an operation captures at admission. `state` is the owner slot's
/// state after the commit.
pub(all) struct ToolContributionCommit {
  owner : String
  revision : Int32
  state : ToolContributionState
} derive(Eq, Debug)

///|
pub extend ToolContributionCommit with Eq::{not_equal, equal}

///|
pub extend ToolContributionCommit with Debug::{to_repr}

///|
pub(all) enum ToolContributionError {
  /// The Agent is shut down; contribution handles are closed.
  Closed
  /// `withdraw` was called for an owner with no accepted commit.
  NotContributed
  /// The candidate group failed atomic validation (name collision, reserved
  /// or empty name, malformed schema). The previously accepted revision, if
  /// any, stays in effect.
  Rejected(reason~ : String)
  /// The change committed and stays committed, but retiring a superseded
  /// version failed or timed out. `revision`/`state` describe the committed
  /// slot; the version stays in the pending-cleanup set for a later retry.
  CleanupPending(
    revision~ : Int32,
    state~ : ToolContributionState,
    detail~ : String
  )
} derive(Eq, Debug)

///|
pub extend ToolContributionError with Eq::{not_equal, equal}

///|
pub extend ToolContributionError with Debug::{to_repr}

///|
pub extend ToolContributionError with Show::{to_string, output}

///|
pub impl Show for ToolContributionError with fn to_string(
  self : ToolContributionError,
) -> String {
  match self {
    Closed => "ToolContributionError::Closed"
    NotContributed => "ToolContributionError::NotContributed"
    Rejected(reason~) => "ToolContributionError::Rejected(\{reason})"
    CleanupPending(revision~, state~, detail~) =>
      "ToolContributionError::CleanupPending(revision=\{revision}, state=\{state.to_string()}, detail=\{detail})"
  }
}

///|
pub struct ToolContributions {
  priv owner_ : String
  priv replace_ : async (&ToolProvider, ToolRetire?) -> Result[
    ToolContributionCommit,
    ToolContributionError,
  ] noraise
  priv withdraw_ : async (ToolWithdrawMode) -> Result[
    ToolContributionCommit,
    ToolContributionError,
  ] noraise
  priv revision_ : () -> Int32?
  priv state_ : () -> ToolContributionState
}

///|
/// The manifest id this capability is bound to.
pub fn ToolContributions::owner(self : ToolContributions) -> String {
  self.owner_
}

///|
/// Atomically replace this owner's contributed group. `retire` becomes the
/// cleanup callback for the newly published version's own resources.
pub async fn ToolContributions::replace(
  self : ToolContributions,
  provider~ : &ToolProvider,
  retire? : ToolRetire,
) -> Result[ToolContributionCommit, ToolContributionError] noraise {
  (self.replace_)(provider, retire)
}

///|
/// Withdraw this owner's contributed group. The transition increments
/// revision; repeating the same withdrawal mode returns the current revision
/// unchanged. A hard withdrawal after a soft one is a new revocation fact and
/// therefore advances the revision. The tombstone retains the sequence so a
/// later `replace` continues it.
pub async fn ToolContributions::withdraw(
  self : ToolContributions,
  mode~ : ToolWithdrawMode = Soft,
) -> Result[ToolContributionCommit, ToolContributionError] noraise {
  (self.withdraw_)(mode)
}

///|
/// The accepted revision this owner currently contributes, or `None` when
/// nothing is contributed (never published or withdrawn).
pub fn ToolContributions::revision(self : ToolContributions) -> Int32? {
  (self.revision_)()
}

///|
/// The owner slot's current state: `Active`, `Withdrawn` or `Closed`.
pub fn ToolContributions::state(
  self : ToolContributions,
) -> ToolContributionState {
  (self.state_)()
}

///|
/// Framework construction hook. Product extensions obtain the value through
/// `CompositionView` and do not need this constructor.
pub fn ToolContributions::from_callbacks(
  owner~ : String,
  replace~ : async (&ToolProvider, ToolRetire?) -> Result[
    ToolContributionCommit,
    ToolContributionError,
  ] noraise,
  withdraw~ : async (ToolWithdrawMode) -> Result[
    ToolContributionCommit,
    ToolContributionError,
  ] noraise,
  revision~ : () -> Int32?,
  state~ : () -> ToolContributionState,
) -> ToolContributions {
  {
    owner_: owner,
    replace_: replace,
    withdraw_: withdraw,
    revision_: revision,
    state_: state,
  }
}
