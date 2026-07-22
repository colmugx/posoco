///|
/// Whitebox tests for M2-T04 journal + contribution + coordinator.
///
/// Coverage:
/// - InMemoryJournal append-only semantics; revision monotonic
/// - duplicate entry id rejected
/// - post-terminal append rejected
/// - Suspended does not close journal (resume can append)
/// - prepare_batch validates contributor entries
/// - prepare_batch freezes (post-freeze mutation detected)
/// - commit_batch delegates to journal and advances revision
/// - FailOnNthJournal raises on Nth append
/// - contributor raise surfaces as SavepointFailed(ContributorRaised)
/// - validation failure surfaces as SavepointFailed(ValidationFailed)
/// - identity mismatch (wrong run id) rejected

// ──────────────────────────────────────────────────────────────────────────
// Fixtures
// ──────────────────────────────────────────────────────────────────────────

fn j_run_id() -> RunId {
  RunId::unchecked("run_j1")
}

///|
fn j_turn_id() -> TurnId {
  TurnId::unchecked("turn_j1")
}

///|
fn j_session_id() -> SessionId {
  SessionId::unchecked("sess_j1")
}

///|
/// Build a single journal entry with the given kind and seq.
fn make_entry(
  kind : SavepointKind,
  savepoint_id : String,
  entry_seq : Int,
) -> JournalEntry {
  let identity : JournalEntryIdentity = {
    run_id: j_run_id(),
    turn_id: j_turn_id(),
    session_id: j_session_id(),
    savepoint_id,
    kind,
    entry_seq,
  }
  {
    identity,
    revision: 0,
    summary: "test entry",
    // Revision is assigned at commit; 0 here is ignored by InMemoryJournal.
    payload: Json::null(),
  }
}

// ──────────────────────────────────────────────────────────────────────────
// InMemoryJournal basics
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_journal/append_only_monotonic_revision" {
  let j = InMemoryJournal::new()
  assert_true(j.revision() == 0)
  let e1 = make_entry(InputAccepted, "sp1", 0)
  let r1 = j.append([e1])
  assert_true(r1 == 1)
  assert_true(j.revision() == 1)
  let e2 = make_entry(AssistantCommitted, "sp2", 0)
  let r2 = j.append([e2])
  assert_true(r2 == 2)
  assert_true(j.revision() == 2)
}

///|
test "harness_journal/empty_batch_noop" {
  let j = InMemoryJournal::new()
  let r = j.append([])
  assert_true(r == 0)
  assert_true(j.revision() == 0)
}

///|
test "harness_journal/multi_entry_batch_single_revision_window" {
  let j = InMemoryJournal::new()
  // Two ToolCommitted entries in one batch (parallel tool batch).
  let e1 = make_entry(ToolCommitted, "sp1", 0)
  let e2 = make_entry(ToolCommitted, "sp1", 1)
  let r = j.append([e1, e2])
  assert_true(r == 2)
  assert_true(j.revision() == 2)
  // Both entries are queryable via the savepoint.
  let sp = j.entries_for_savepoint(j_run_id(), "sp1")
  assert_true(sp.length() == 2)
}

// ──────────────────────────────────────────────────────────────────────────
// duplicate entry id
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_journal/duplicate_entry_id_rejected" {
  let j = InMemoryJournal::new()
  let e1 = make_entry(InputAccepted, "sp1", 0)
  let _ = j.append([e1])
  // Re-append the same entry (same dedup key) — must fail.
  let result : Result[Int, HarnessError] = Ok(j.append([e1])) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(SavepointFailed(kind~, cause~)) => {
      assert_true(kind == "InputAccepted")
      let _ = match cause {
        BarrierFailed(_) => ()
        _ => fail("expected BarrierFailed")
      }
    }
    _ => fail("expected SavepointFailed")
  }
  // Journal unchanged.
  assert_true(j.revision() == 1)
}

// ──────────────────────────────────────────────────────────────────────────
// post-terminal append
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_journal/post_terminal_append_rejected" {
  let j = InMemoryJournal::new()
  // First commit a RunTerminal entry.
  let terminal = make_entry(RunTerminal, "sp_final", 0)
  let _ = j.append([terminal])
  assert_true(j.revision() == 1)
  // Now try to append more for the same run.
  let later = make_entry(ToolCommitted, "sp_late", 0)
  let result : Result[Int, HarnessError] = Ok(j.append([later])) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(SavepointFailed(cause=BarrierFailed(detail~), ..)) =>
      assert_true(detail.contains("already terminal"))
    _ => fail("expected SavepointFailed(BarrierFailed)")
  }
}

///|
test "harness_journal/suspended_does_not_close_journal" {
  let j = InMemoryJournal::new()
  // Commit a RunSuspended entry.
  let suspended = make_entry(RunSuspended, "sp_susp", 0)
  let _ = j.append([suspended])
  // Resume should be able to append more entries under the same run.
  let after_resume = make_entry(AssistantCommitted, "sp_after", 0)
  let r = j.append([after_resume])
  assert_true(r == 2)
}

// ──────────────────────────────────────────────────────────────────────────
// entries_for_run / entries_for_savepoint
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_journal/entries_for_run_filters_by_run" {
  let j = InMemoryJournal::new()
  let e1 = make_entry(InputAccepted, "sp1", 0)
  let _ = j.append([e1])
  let run_entries = j.entries_for_run(j_run_id())
  assert_true(run_entries.length() == 1)
  let other_run = j.entries_for_run(RunId::unchecked("run_other"))
  assert_true(other_run.length() == 0)
}
