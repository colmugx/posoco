///|
/// Whitebox tests for M2-T04 contribution + coordinator (companion to
/// harness_journal_wbtest.mbt).
///
/// Coverage:
/// - NoopContributor returns empty contribution
/// - prepare_batch merges base + contributions
/// - prepare_batch freezes (entry keys captured)
/// - commit_batch advances revision
/// - contributor raise surfaces as SavepointFailed(ContributorRaised)
/// - validation failure (wrong kind) surfaces as SavepointFailed(ValidationFailed)
/// - validation failure (wrong savepoint id)
/// - validation failure (wrong run id from contributor)
/// - commit_batch detects post-freeze mutation (entry count changed)
/// - FailOnNthJournal propagates barrier failure

// ──────────────────────────────────────────────────────────────────────────
// Test contributors
// ──────────────────────────────────────────────────────────────────────────

///|
/// Test contributor that proposes one additional entry.
pub(all) struct ProposingContributor {
  id : String
  extra_entry : JournalEntry
}

///|
pub fn ProposingContributor::new(
  id : String,
  extra : JournalEntry,
) -> ProposingContributor {
  { id, extra_entry: extra }
}

///|
pub impl JournalContributor for ProposingContributor with fn contributor_id(
  self,
) -> String {
  self.id
}

///|
pub impl JournalContributor for ProposingContributor with fn provenance(_self) -> String {
  "proposing"
}

///|
pub impl JournalContributor for ProposingContributor with fn contribute(
  self,
  _ctx : PreCommitContext,
) -> JournalContribution raise ContributionError {
  JournalContribution::with_entries(self.id, "proposing", [self.extra_entry])
}

///|
/// Test contributor that always raises Internal.
pub(all) struct FailingContributor {
  id : String
}

///|
pub fn FailingContributor::new(id : String) -> FailingContributor {
  { id, }
}

///|
pub impl JournalContributor for FailingContributor with fn contributor_id(self) -> String {
  self.id
}

///|
pub impl JournalContributor for FailingContributor with fn provenance(_self) -> String {
  "failing"
}

///|
pub impl JournalContributor for FailingContributor with fn contribute(
  self,
  _ctx : PreCommitContext,
) -> JournalContribution raise ContributionError {
  raise Internal(contributor_id=self.id, detail="injected failure")
}

// ──────────────────────────────────────────────────────────────────────────
// Fixtures
// ──────────────────────────────────────────────────────────────────────────

///|
fn c_run_id() -> RunId {
  RunId::unchecked("run_c1")
}

///|
fn c_turn_id() -> TurnId {
  TurnId::unchecked("turn_c1")
}

///|
fn c_session_id() -> SessionId {
  SessionId::unchecked("sess_c1")
}

///|
fn make_c_entry(
  kind : SavepointKind,
  savepoint_id : String,
  entry_seq : Int,
) -> JournalEntry {
  let identity : JournalEntryIdentity = {
    run_id: c_run_id(),
    turn_id: c_turn_id(),
    session_id: c_session_id(),
    savepoint_id,
    kind,
    entry_seq,
  }
  { identity, revision: 0, summary: "c entry", payload: Json::null() }
}

///|
fn make_c_ctx(
  savepoint_id : String,
  kind : SavepointKind,
  base : Array[JournalEntry],
) -> PreCommitContext {
  {
    run_id: c_run_id(),
    turn_id: c_turn_id(),
    session_id: c_session_id(),
    savepoint_id,
    savepoint_kind: kind,
    base_entries: base,
    current_revision: 0,
    catalog_version: CatalogVersion::new(1),
  }
}

// ──────────────────────────────────────────────────────────────────────────
// NoopContributor
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_contribution/noop_returns_empty" {
  let ctx = make_c_ctx("sp1", InputAccepted, [])
  let noop = NoopContributor::new()
  let c = noop.contribute(ctx)
  assert_true(c.proposed_entries().length() == 0)
  assert_true(c.contributor_id() == "noop")
}

// ──────────────────────────────────────────────────────────────────────────
// prepare_batch
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_contribution/prepare_batch_with_no_contributors" {
  let base = [make_c_entry(InputAccepted, "sp1", 0)]
  let ctx = make_c_ctx("sp1", InputAccepted, base)
  let batch = prepare_batch(ctx, [])
  assert_true(batch.length() == 1)
  assert_true(batch.expected_revision() == 0)
}

///|
test "harness_contribution/prepare_batch_merges_contributor_entries" {
  let base = [make_c_entry(InputAccepted, "sp1", 0)]
  let ctx = make_c_ctx("sp1", InputAccepted, base)
  // Contributor proposes an extra entry.
  let extra = make_c_entry(InputAccepted, "sp1", 1)
  let contributor = ProposingContributor::new("ext_a", extra)
  let contributors : Array[&JournalContributor] = [contributor]
  let batch = prepare_batch(ctx, contributors)
  assert_true(batch.length() == 2)
}

///|
test "harness_contribution/prepare_batch_contributor_raise_surfaces_as_savepoint_failed" {
  let ctx = make_c_ctx("sp1", InputAccepted, [])
  let failing = FailingContributor::new("bad")
  let contributors : Array[&JournalContributor] = [failing]
  let result : Result[FrozenBatch, HarnessError] = Ok(
    prepare_batch(ctx, contributors),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(SavepointFailed(kind~, cause~)) => {
      assert_true(kind == "InputAccepted")
      match cause {
        ContributorRaised(contributor_id~, detail~) => {
          assert_true(contributor_id == "bad")
          assert_true(detail.contains("injected failure"))
        }
        _ => fail("expected ContributorRaised")
      }
    }
    _ => fail("expected SavepointFailed")
  }
}

///|
test "harness_contribution/prepare_batch_rejects_wrong_kind" {
  // Context says InputAccepted, but base entry is ToolCommitted.
  let wrong = make_c_entry(ToolCommitted, "sp1", 0)
  let ctx = make_c_ctx("sp1", InputAccepted, [wrong])
  let result : Result[FrozenBatch, HarnessError] = Ok(prepare_batch(ctx, [])) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(SavepointFailed(cause=ValidationFailed(detail~), ..)) =>
      assert_true(detail.contains("does not match savepoint kind"))
    _ => fail("expected SavepointFailed(ValidationFailed)")
  }
}

///|
test "harness_contribution/prepare_batch_rejects_wrong_savepoint_id" {
  let wrong = make_c_entry(InputAccepted, "sp_other", 0)
  let ctx = make_c_ctx("sp1", InputAccepted, [wrong])
  let result : Result[FrozenBatch, HarnessError] = Ok(prepare_batch(ctx, [])) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
}

///|
test "harness_contribution/prepare_batch_rejects_wrong_run_id_in_contributor" {
  let ctx = make_c_ctx("sp1", InputAccepted, [])
  // Build an entry with a DIFFERENT run id.
  let identity : JournalEntryIdentity = {
    run_id: RunId::unchecked("run_OTHER"),
    turn_id: c_turn_id(),
    session_id: c_session_id(),
    savepoint_id: "sp1",
    kind: InputAccepted,
    entry_seq: 0,
  }
  let bad_entry : JournalEntry = {
    identity,
    revision: 0,
    summary: "wrong run",
    payload: Json::null(),
  }
  let contributor = ProposingContributor::new("bad", bad_entry)
  let contributors : Array[&JournalContributor] = [contributor]
  let result : Result[FrozenBatch, HarnessError] = Ok(
    prepare_batch(ctx, contributors),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(SavepointFailed(cause=ValidationFailed(detail~), ..)) =>
      assert_true(detail.contains("mismatch"))
    _ => fail("expected SavepointFailed(ValidationFailed) for wrong run id")
  }
}

///|
test "harness_contribution/prepare_batch_rejects_duplicate_entry_id" {
  let e1 = make_c_entry(InputAccepted, "sp1", 0)
  let ctx = make_c_ctx("sp1", InputAccepted, [e1])
  // Contributor proposes the SAME entry_seq — duplicate dedup key.
  let dup = make_c_entry(InputAccepted, "sp1", 0)
  let contributor = ProposingContributor::new("dup", dup)
  let contributors : Array[&JournalContributor] = [contributor]
  let result : Result[FrozenBatch, HarnessError] = Ok(
    prepare_batch(ctx, contributors),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(SavepointFailed(cause=ValidationFailed(detail~), ..)) =>
      assert_true(detail.contains("duplicate"))
    _ => fail("expected SavepointFailed(ValidationFailed) for duplicate")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// commit_batch
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_contribution/commit_batch_advances_revision" {
  let journal = InMemoryJournal::new()
  let base = [make_c_entry(InputAccepted, "sp1", 0)]
  let ctx = make_c_ctx("sp1", InputAccepted, base)
  let batch = prepare_batch(ctx, [])
  let r = commit_batch(journal, batch)
  assert_true(r == 1)
  assert_true(journal.revision() == 1)
}

///|
test "harness_contribution/commit_batch_via_fail_on_nth" {
  // FailOnNthJournal fails on the 1st append.
  let inner = InMemoryJournal::new()
  let failing = FailOnNthJournal::new(inner, 1)
  let base = [make_c_entry(InputAccepted, "sp1", 0)]
  let ctx = make_c_ctx("sp1", InputAccepted, base)
  let batch = prepare_batch(ctx, [])
  let result : Result[Int, HarnessError] = Ok(commit_batch(failing, batch)) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(SavepointFailed(cause=BarrierFailed(detail~), ..)) =>
      assert_true(detail.contains("injected failure"))
    _ => fail("expected SavepointFailed(BarrierFailed)")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Post-freeze mutation detection
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_contribution/commit_batch_detects_post_freeze_count_change" {
  // We build a batch by hand (not via prepare_batch) so we can mutate it
  // after freeze to simulate contract violation.
  let base = [make_c_entry(InputAccepted, "sp1", 0)]
  let frozen_keys = [entry_dedup_key(base[0].identity)]
  let batch : FrozenBatch = {
    savepoint_id: "sp1",
    savepoint_kind: InputAccepted,
    expected_revision: 0,
    entries: base,
    frozen_entry_keys: frozen_keys,
  }
  // Inject an extra entry into batch.entries post-freeze.
  batch.entries.push(make_c_entry(InputAccepted, "sp1", 1))
  let journal = InMemoryJournal::new()
  let result : Result[Int, HarnessError] = Ok(commit_batch(journal, batch)) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(SavepointFailed(cause=BarrierFailed(detail~), ..)) =>
      assert_true(detail.contains("post-freeze"))
    _ => fail("expected SavepointFailed(BarrierFailed) post-freeze")
  }
  // Journal must be unchanged.
  assert_true(journal.revision() == 0)
}
