///|
/// Whitebox tests for contribution + coordinator (companion to
/// journal_wbtest.mbt).

///|

///|
/// Test contributor that proposes one additional entry.
pub(all) struct ProposingContributor {
  id : String
  extra_entry : JournalEntry
}

///|
pub fn ProposingContributor::ProposingContributor(
  id : String,
  extra : JournalEntry,
) -> ProposingContributor {
  { id, extra_entry: extra, }
}

///|
pub extend ProposingContributor with JournalContributor::{
  contribute,
  contributor_id,
  provenance,
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
pub fn FailingContributor::FailingContributor(
  id : String,
) -> FailingContributor {
  { id, }
}

///|
pub extend FailingContributor with JournalContributor::{
  contribute,
  contributor_id,
  provenance,
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
  entry_seq : Int32,
) -> JournalEntry {
  let identity : JournalEntryIdentity = {
    run_id: c_run_id(),
    turn_id: c_turn_id(),
    session_id: c_session_id(),
    savepoint_id,
    kind,
    entry_seq,
  }
  { identity, revision: 0, summary: "c entry", payload: Json::null(), }
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
    catalog_version: CatalogVersion(1),
  }
}

///|
test "puppet_contribution/prepare_batch_rejects_wrong_kind" {
  // Context says InputAccepted, but base entry is ToolCommitted.
  let wrong = make_c_entry(ToolCommitted, "sp1", 0)
  let ctx = make_c_ctx("sp1", InputAccepted, [wrong])
  let result : Result[FrozenBatch, PuppetError] = Ok(prepare_batch(ctx, [])) catch {
    e => Err(e)
  }
  assert_true(result is Err(SavepointFailed(..)))
  match result {
    Err(SavepointFailed(cause=ValidationFailed(detail~), ..)) =>
      assert_true(detail.contains("does not match savepoint kind"))
    _ => fail("expected SavepointFailed(ValidationFailed)")
  }
}

///|
test "puppet_contribution/prepare_batch_rejects_wrong_savepoint_id" {
  let wrong = make_c_entry(InputAccepted, "sp_other", 0)
  let ctx = make_c_ctx("sp1", InputAccepted, [wrong])
  let result : Result[FrozenBatch, PuppetError] = Ok(prepare_batch(ctx, [])) catch {
    e => Err(e)
  }
  assert_true(result is Err(SavepointFailed(..)))
  match result {
    Err(SavepointFailed(kind~, cause=ValidationFailed(detail~))) => {
      assert_true(kind == "InputAccepted")
      // The cause names both the offending and the expected savepoint id.
      assert_true(detail.contains("sp_other"))
      assert_true(detail.contains("sp1"))
    }
    _ =>
      fail("expected SavepointFailed(ValidationFailed) for wrong savepoint id")
  }
}

///|
test "puppet_contribution/prepare_batch_rejects_wrong_run_id_in_contributor" {
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
  let contributor = ProposingContributor("bad", bad_entry)
  let contributors : Array[&JournalContributor] = [contributor]
  let result : Result[FrozenBatch, PuppetError] = Ok(
    prepare_batch(ctx, contributors),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(SavepointFailed(..)))
  match result {
    Err(SavepointFailed(cause=ValidationFailed(detail~), ..)) =>
      assert_true(detail.contains("mismatch"))
    _ => fail("expected SavepointFailed(ValidationFailed) for wrong run id")
  }
}

///|
test "puppet_contribution/prepare_batch_rejects_duplicate_entry_id" {
  let e1 = make_c_entry(InputAccepted, "sp1", 0)
  let ctx = make_c_ctx("sp1", InputAccepted, [e1])
  // Contributor proposes the SAME entry_seq — duplicate dedup key.
  let dup = make_c_entry(InputAccepted, "sp1", 0)
  let contributor = ProposingContributor("dup", dup)
  let contributors : Array[&JournalContributor] = [contributor]
  let result : Result[FrozenBatch, PuppetError] = Ok(
    prepare_batch(ctx, contributors),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(SavepointFailed(..)))
  match result {
    Err(SavepointFailed(cause=ValidationFailed(detail~), ..)) =>
      assert_true(detail.contains("duplicate"))
    _ => fail("expected SavepointFailed(ValidationFailed) for duplicate")
  }
}
