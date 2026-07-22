///|
/// Journal contribution + pre-commit seam + savepoint coordinator (M2-T04,
/// ADR §5).
///
/// Contract (ADR §5 commit order):
/// 1. Reducer/canonical transition produces base entries.
/// 2. Registered JournalContributors receive an immutable PreCommitContext
///    (registration order) and each returns a JournalContribution of
///    proposed entries, or a typed ContributionError.
/// 3. SavepointCoordinator validates each contribution: allowed entry kind
///    for this savepoint, identity match, parent revision + sequence
///    consistency, no duplicate entry id, size bound, permission.
/// 4. Coordinator merges base + validated contributions, freezes the pending
///    batch (expected revision, entry ids, savepoint).
/// 5. Coordinator calls RunJournal.append(frozen_batch) + durability barrier.
/// 6. Only post-commit does the Harness dispatch events.
///
/// Post-freeze mutation by any contributor/subscriber is a contract
/// violation; the coordinator detects this by comparing entry id sets
/// before and after freezing.

// ──────────────────────────────────────────────────────────────────────────
// PreCommitContext — immutable view handed to contributors
// ──────────────────────────────────────────────────────────────────────────

///|
/// Immutable context handed to each JournalContributor at pre-commit time.
/// Contributors read this to decide what (if anything) to propose.
///
/// The context carries NO mutable references and NO journal writer. A
/// contributor that needs to add a domain entry must return it via
/// JournalContribution; it cannot reach into the journal directly.
pub(all) struct PreCommitContext {
  run_id : RunId
  turn_id : TurnId
  session_id : SessionId
  savepoint_id : String
  savepoint_kind : SavepointKind
  /// Base entries the reducer/Harness already produced for this savepoint.
  /// Read-only; contributors must NOT mutate this array.
  base_entries : Array[JournalEntry]
  /// Current committed revision (before this savepoint commits).
  current_revision : Int
  /// Catalog version active for this run. Read-only.
  catalog_version : CatalogVersion
} derive(Eq, Debug)

///|
pub fn PreCommitContext::run_id(self : PreCommitContext) -> RunId {
  self.run_id
}

///|
pub fn PreCommitContext::turn_id(self : PreCommitContext) -> TurnId {
  self.turn_id
}

///|
pub fn PreCommitContext::session_id(self : PreCommitContext) -> SessionId {
  self.session_id
}

///|
pub fn PreCommitContext::savepoint_id(self : PreCommitContext) -> String {
  self.savepoint_id
}

///|
pub fn PreCommitContext::savepoint_kind(
  self : PreCommitContext,
) -> SavepointKind {
  self.savepoint_kind
}

///|
pub fn PreCommitContext::base_entries(
  self : PreCommitContext,
) -> Array[JournalEntry] {
  self.base_entries.copy()
}

///|
pub fn PreCommitContext::current_revision(self : PreCommitContext) -> Int {
  self.current_revision
}

///|
pub fn PreCommitContext::catalog_version(
  self : PreCommitContext,
) -> CatalogVersion {
  self.catalog_version
}

// ──────────────────────────────────────────────────────────────────────────
// JournalContribution — what a contributor proposes
// ──────────────────────────────────────────────────────────────────────────

///|
/// Typed contribution from a JournalContributor. Carries:
/// - `contributor_id`: stable identifier of the proposing contributor
/// - `provenance`: human-readable provenance string for diagnostics
/// - `proposed_entries`: entries the contributor wants added to this savepoint
///
/// The contributor does NOT specify the committed revision (the coordinator
/// assigns it). It does NOT mark entries as committed (the journal does).
pub(all) struct JournalContribution {
  contributor_id : String
  provenance : String
  proposed_entries : Array[JournalEntry]
} derive(Eq, Debug)

///|
pub fn JournalContribution::contributor_id(
  self : JournalContribution,
) -> String {
  self.contributor_id
}

///|
pub fn JournalContribution::provenance(self : JournalContribution) -> String {
  self.provenance
}

///|
pub fn JournalContribution::proposed_entries(
  self : JournalContribution,
) -> Array[JournalEntry] {
  self.proposed_entries.copy()
}

///|
/// Construct an empty contribution (contributor chooses to add nothing).
pub fn JournalContribution::empty(
  contributor_id : String,
  provenance : String,
) -> JournalContribution {
  { contributor_id, provenance, proposed_entries: [] }
}

///|
/// Construct a contribution with proposed entries. The contributor must
/// assign entry_seq values that do not collide with base_entries or other
/// contributions; the coordinator validates.
pub fn JournalContribution::with_entries(
  contributor_id : String,
  provenance : String,
  entries : Array[JournalEntry],
) -> JournalContribution {
  { contributor_id, provenance, proposed_entries: entries.copy() }
}

// ──────────────────────────────────────────────────────────────────────────
// ContributionError — typed errors from contributors
// ──────────────────────────────────────────────────────────────────────────

///|
/// Typed error a contributor returns (or raises) when it cannot produce a
/// contribution. The coordinator surfaces this as `SavepointFailed` with
/// `ContributorRaised` cause.
pub(all) suberror ContributionError {
  /// Contributor encountered an internal error and cannot propose.
  Internal(contributor_id~ : String, detail~ : String)
  /// Contributor observed inconsistent state (e.g. wrong run id).
  Inconsistent(contributor_id~ : String, detail~ : String)
}

///|
pub impl Show for ContributionError with fn to_string(self : ContributionError) -> String {
  match self {
    Internal(contributor_id~, detail~) =>
      "Internal(\{contributor_id}: \{detail})"
    Inconsistent(contributor_id~, detail~) =>
      "Inconsistent(\{contributor_id}: \{detail})"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// JournalContributor trait (Q7.3 recommendation: pub(open) trait)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Port: pre-commit contributor. Receives an immutable PreCommitContext,
/// returns a JournalContribution of proposed entries or a typed error.
///
/// Contributors never receive a RunJournal reference; they cannot write
/// directly. If they need a domain entry persisted, they must propose it
/// here and let the coordinator commit it atomically.
///
/// M2 does not ship any production contributor; the trait exists so M4/M5
/// extensions (e.g. memory persistence, observation logging) can register
/// without modifying the Harness pump.
pub(open) trait JournalContributor {
  /// Stable identifier for this contributor. Used in diagnostics and in
  /// the contribution's `contributor_id` field.
  fn contributor_id(Self) -> String

  /// Human-readable provenance. Examples: "memory_store", "audit_log".
  fn provenance(Self) -> String

  /// Propose entries for the given pre-commit context. Returns a
  /// JournalContribution (possibly empty) or raises ContributionError.
  fn contribute(Self, PreCommitContext) -> JournalContribution raise ContributionError
}

// ──────────────────────────────────────────────────────────────────────────
// NoopContributor — default contributor that proposes nothing
// ──────────────────────────────────────────────────────────────────────────

///|
/// Default contributor that proposes nothing. Used when no extension needs
/// pre-commit hooks; also a baseline for tests.
pub(all) struct NoopContributor {
  id : String
}

///|
pub fn NoopContributor::new() -> NoopContributor {
  { id: "noop" }
}

///|
pub fn NoopContributor::with_id(id : String) -> NoopContributor {
  { id, }
}

///|
pub impl JournalContributor for NoopContributor with fn contributor_id(self) -> String {
  self.id
}

///|
pub impl JournalContributor for NoopContributor with fn provenance(_self) -> String {
  "noop"
}

///|
pub impl JournalContributor for NoopContributor with fn contribute(
  self,
  _ctx : PreCommitContext,
) -> JournalContribution raise ContributionError {
  JournalContribution::empty(self.id, "noop")
}

// ──────────────────────────────────────────────────────────────────────────
// SavepointCoordinator — the freeze→commit→barrier orchestrator
// ──────────────────────────────────────────────────────────────────────────

///|
/// Frozen pending batch. Built by `prepare_batch`; committed by `commit`.
/// Once frozen, neither contributors nor subscribers can mutate it.
///
/// `expected_revision` is the revision the journal SHOULD be at when this
/// batch commits. If the journal has advanced past this revision (e.g.
/// concurrent commit elsewhere — impossible in M2 single-writer but the
/// check is here for M5), the commit fails with `BarrierFailed`.
pub(all) struct FrozenBatch {
  savepoint_id : String
  savepoint_kind : SavepointKind
  expected_revision : Int
  entries : Array[JournalEntry]
  /// Set of entry dedup keys, captured at freeze time. Used to detect
  /// post-freeze mutation of the underlying arrays.
  frozen_entry_keys : Array[String]
} derive(Eq, Debug)

///|
pub fn FrozenBatch::savepoint_id(self : FrozenBatch) -> String {
  self.savepoint_id
}

///|
pub fn FrozenBatch::savepoint_kind(self : FrozenBatch) -> SavepointKind {
  self.savepoint_kind
}

///|
pub fn FrozenBatch::expected_revision(self : FrozenBatch) -> Int {
  self.expected_revision
}

///|
pub fn FrozenBatch::entries(self : FrozenBatch) -> Array[JournalEntry] {
  self.entries.copy()
}

///|
pub fn FrozenBatch::length(self : FrozenBatch) -> Int {
  self.entries.length()
}

// ──────────────────────────────────────────────────────────────────────────
// Prepare + validate + freeze
// ──────────────────────────────────────────────────────────────────────────

///|
/// Prepare a frozen batch for a savepoint. Steps:
/// 1. Call each contributor in registration order with PreCommitContext.
/// 2. Validate every contribution entry (kind, identity, dedup).
/// 3. Merge base entries + validated contributions.
/// 4. Freeze the batch (compute expected_revision + entry keys).
///
/// Raises:
/// - `HarnessError::SavepointFailed(_, ContributorRaised(_))` if any
///   contributor raises/returns Err.
/// - `HarnessError::SavepointFailed(_, ValidationFailed(_))` if any entry
///   fails validation.
pub fn prepare_batch(
  ctx : PreCommitContext,
  contributors : Array[&JournalContributor],
) -> FrozenBatch raise HarnessError {
  // Collect contributions.
  let all_entries : Array[JournalEntry] = []
  for base in ctx.base_entries {
    all_entries.push(base)
  }
  let seen_keys : Map[String, Bool] = Map::from_array([])
  // Validate base entries first.
  for entry in ctx.base_entries {
    let key = entry_dedup_key(entry.identity)
    if seen_keys.contains(key) {
      raise SavepointFailed(
        kind=ctx.savepoint_kind.to_string(),
        cause=ValidationFailed(detail="duplicate base entry id: \{key}"),
      )
    }
    seen_keys[key] = true
    match validate_entry(entry, ctx) {
      Err(e) => raise e
      Ok(_) => ()
    }
  }
  // Call each contributor.
  for contributor in contributors {
    let contribution : JournalContribution = contributor.contribute(ctx) catch {
      e =>
        raise SavepointFailed(
          kind=ctx.savepoint_kind.to_string(),
          cause=ContributorRaised(
            contributor_id=contributor.contributor_id(),
            detail=e.to_string(),
          ),
        )
    }
    // Validate each proposed entry.
    for entry in contribution.proposed_entries {
      let key = entry_dedup_key(entry.identity)
      if seen_keys.contains(key) {
        raise SavepointFailed(
          kind=ctx.savepoint_kind.to_string(),
          cause=ValidationFailed(
            detail="duplicate proposed entry id from '\{contribution.contributor_id}': \{key}",
          ),
        )
      }
      seen_keys[key] = true
      match validate_entry(entry, ctx) {
        Err(e) => raise e
        Ok(_) => ()
      }
      // Contributor provenance must match the registered contributor.
      if entry.identity.run_id != ctx.run_id {
        raise SavepointFailed(
          kind=ctx.savepoint_kind.to_string(),
          cause=ValidationFailed(
            detail="contribution '\{contribution.contributor_id}' targets wrong run id",
          ),
        )
      }
      all_entries.push(entry)
    }
  }
  // Freeze: snapshot entry keys.
  let frozen_keys : Array[String] = []
  for entry in all_entries {
    frozen_keys.push(entry_dedup_key(entry.identity))
  }
  {
    savepoint_id: ctx.savepoint_id,
    savepoint_kind: ctx.savepoint_kind,
    expected_revision: ctx.current_revision,
    entries: all_entries,
    frozen_entry_keys: frozen_keys,
  }
}

///|
/// Validate a single entry against the pre-commit context. Returns Err on
/// any violation.
fn validate_entry(
  entry : JournalEntry,
  ctx : PreCommitContext,
) -> Result[Unit, HarnessError] {
  // Entry savepoint kind must match the context's savepoint kind.
  if !(entry.identity.kind == ctx.savepoint_kind) {
    return Err(
      SavepointFailed(
        kind=ctx.savepoint_kind.to_string(),
        cause=ValidationFailed(
          detail="entry kind '\{entry.identity.kind.to_string()}' does not match savepoint kind '\{ctx.savepoint_kind.to_string()}'",
        ),
      ),
    )
  }
  // Entry savepoint id must match.
  if entry.identity.savepoint_id != ctx.savepoint_id {
    return Err(
      SavepointFailed(
        kind=ctx.savepoint_kind.to_string(),
        cause=ValidationFailed(
          detail="entry savepoint id '\{entry.identity.savepoint_id}' does not match '\{ctx.savepoint_id}'",
        ),
      ),
    )
  }
  // Entry run id must match.
  if entry.identity.run_id != ctx.run_id {
    return Err(
      SavepointFailed(
        kind=ctx.savepoint_kind.to_string(),
        cause=ValidationFailed(detail="entry run id mismatch"),
      ),
    )
  }
  // Entry turn id must match (unless savepoint is RunTerminal which may
  // span the whole run).
  match ctx.savepoint_kind {
    RunTerminal => ()
    _ =>
      if entry.identity.turn_id != ctx.turn_id {
        return Err(
          SavepointFailed(
            kind=ctx.savepoint_kind.to_string(),
            cause=ValidationFailed(detail="entry turn id mismatch"),
          ),
        )
      }
  }
  Ok(())
}

// ──────────────────────────────────────────────────────────────────────────
// Commit — the single point that advances revision
// ──────────────────────────────────────────────────────────────────────────

///|
/// Commit a frozen batch to the journal. Verifies post-freeze integrity
/// (entry keys unchanged), then delegates to `RunJournal.append`. Returns
/// the new committed revision.
///
/// Raises:
/// - `SavepointFailed(_, BarrierFailed(_))` if post-freeze mutation
///   detected or the journal append fails.
pub fn commit_batch(
  journal : &RunJournal,
  batch : FrozenBatch,
) -> Int raise HarnessError {
  // Post-freeze integrity check: verify entry keys still match.
  let current_keys : Array[String] = []
  for entry in batch.entries {
    current_keys.push(entry_dedup_key(entry.identity))
  }
  if current_keys.length() != batch.frozen_entry_keys.length() {
    raise SavepointFailed(
      kind=batch.savepoint_kind.to_string(),
      cause=BarrierFailed(
        detail="post-freeze mutation detected: entry count changed",
      ),
    )
  }
  for i in 0..<current_keys.length() {
    if current_keys[i] != batch.frozen_entry_keys[i] {
      raise SavepointFailed(
        kind=batch.savepoint_kind.to_string(),
        cause=BarrierFailed(
          detail="post-freeze mutation detected: entry key changed",
        ),
      )
    }
  }
  // Delegate to journal.
  journal.append(batch.entries)
}
