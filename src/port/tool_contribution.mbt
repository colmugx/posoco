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
/// - Accepted changes affect future operations only. An operation that was
///   already admitted keeps the catalog and execution table it captured at
///   admission, including follow-up turns drained by the same operation.
/// - `withdraw` is a soft withdrawal: future operations no longer see the
///   group, admitted operations keep using it.
/// - After `Agent::shutdown` every change is rejected with `Closed`.

///|
/// Acknowledgement of one accepted contribution commit. `revision` is
/// core-owned and monotonic per owner; it is distinct from the catalog
/// version an operation captures at admission.
pub(all) struct ToolContributionCommit {
  owner : String
  revision : Int32
} derive(Eq, Debug)

///|
pub extend ToolContributionCommit with Eq::{not_equal, equal}

///|
pub extend ToolContributionCommit with Debug::{to_repr}

///|
/// Contribution change failures. Each one is explicit so an extension never
/// mistakes a rejected group for a published one.
pub(all) enum ToolContributionError {
  /// The Agent is shut down; contribution handles are closed.
  Closed
  /// `withdraw` was called for an owner with no accepted commit.
  NotContributed
  /// The candidate group failed atomic validation (name collision, reserved
  /// or empty name, malformed schema). The previously accepted revision, if
  /// any, stays in effect.
  Rejected(reason~ : String)
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
  }
}

///|
pub struct ToolContributions {
  priv owner_ : String
  priv replace_ : (&ToolProvider) -> Result[
    ToolContributionCommit,
    ToolContributionError,
  ]
  priv withdraw_ : () -> Result[ToolContributionCommit, ToolContributionError]
  priv revision_ : () -> Int32?
}

///|
/// The manifest id this capability is bound to.
pub fn ToolContributions::owner(self : ToolContributions) -> String {
  self.owner_
}

///|
/// Atomically replace this owner's contributed provider group.
pub fn ToolContributions::replace(
  self : ToolContributions,
  provider~ : &ToolProvider,
) -> Result[ToolContributionCommit, ToolContributionError] {
  (self.replace_)(provider)
}

///|
/// Soft-withdraw this owner's contributed group. The transition increments
/// revision; a repeated withdrawal returns the same revision. The tombstone
/// retains the sequence so a later `replace` continues it.
pub fn ToolContributions::withdraw(
  self : ToolContributions,
) -> Result[ToolContributionCommit, ToolContributionError] {
  (self.withdraw_)()
}

///|
/// The accepted revision this owner currently contributes, or `None` when
/// nothing is contributed (never published or withdrawn).
pub fn ToolContributions::revision(self : ToolContributions) -> Int32? {
  (self.revision_)()
}

///|
/// Framework construction hook. Product extensions obtain the value through
/// `CompositionView` and do not need this constructor.
pub fn ToolContributions::from_callbacks(
  owner~ : String,
  replace~ : (&ToolProvider) -> Result[
    ToolContributionCommit,
    ToolContributionError,
  ],
  withdraw~ : () -> Result[ToolContributionCommit, ToolContributionError],
  revision~ : () -> Int32?,
) -> ToolContributions {
  {
    owner_: owner,
    replace_: replace,
    withdraw_: withdraw,
    revision_: revision,
  }
}
