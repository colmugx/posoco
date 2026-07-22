///|
/// RunJournal — append-only, single-writer journal for Harness savepoints
/// (M2-T04, ADR §5).
///
/// Contract:
/// - Entries are append-only. No update, no delete of committed entries.
/// - Revision is monotonic: each successful append advances the revision
///   by exactly 1.
/// - Identity (run/session/turn/savepoint) is validated on append; mismatched
///   identity or post-terminal appends raise typed errors.
/// - Suspended does NOT close the journal: legal resume may append more
///   entries under the same run id.
/// - The journal stores Posoco canonical domain entries only — never provider
///   wire messages (ADR §2 non-goal).
///
/// M2 ships `InMemoryJournal` as the first adapter. M5 will add JSONL/SQLite
/// by implementing the same `RunJournal` trait.

// ──────────────────────────────────────────────────────────────────────────
// SavepointKind (ADR §5 savepoint table)
// ──────────────────────────────────────────────────────────────────────────

///|
/// The savepoint kind an entry belongs to. Each savepoint commits atomically:
/// all entries with the same (run_id, savepoint_id, kind) either all commit
/// or none do.
pub(all) enum SavepointKind {
  /// Turn start: user/control entry accepted before any model effect.
  InputAccepted
  /// Successful assistant completion folded into transcript.
  AssistantCommitted
  /// Per-tool final outcome (one entry per tool call, even in parallel batches).
  ToolCommitted
  /// Reducer entered Suspended (non-terminal savepoint).
  RunSuspended
  /// Reducer entered Terminal (final savepoint for the run).
  RunTerminal
} derive(Eq, Debug)

///|
pub impl Show for SavepointKind with fn to_string(self : SavepointKind) -> String {
  match self {
    InputAccepted => "InputAccepted"
    AssistantCommitted => "AssistantCommitted"
    ToolCommitted => "ToolCommitted"
    RunSuspended => "RunSuspended"
    RunTerminal => "RunTerminal"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// JournalEntryIdentity — typed identity for each entry
// ──────────────────────────────────────────────────────────────────────────

///|
/// Stable identifier for a journal entry. The (run_id, savepoint_id,
/// entry_seq) triple uniquely locates an entry within the journal.
pub(all) struct JournalEntryIdentity {
  run_id : RunId
  turn_id : TurnId
  session_id : SessionId
  savepoint_id : String
  /// Monotonic within the savepoint. The Harness assigns this when freezing
  /// the pending batch.
  entry_seq : Int
  kind : SavepointKind
} derive(Eq, Debug)

///|
pub impl Show for JournalEntryIdentity with fn to_string(
  self : JournalEntryIdentity,
) -> String {
  "EntryId(run=\{self.run_id.to_string()}, sp=\{self.savepoint_id}, seq=\{self.entry_seq}, kind=\{self.kind.to_string()})"
}

///|
pub fn JournalEntryIdentity::run_id(self : JournalEntryIdentity) -> RunId {
  self.run_id
}

///|
pub fn JournalEntryIdentity::turn_id(self : JournalEntryIdentity) -> TurnId {
  self.turn_id
}

///|
pub fn JournalEntryIdentity::session_id(
  self : JournalEntryIdentity,
) -> SessionId {
  self.session_id
}

///|
pub fn JournalEntryIdentity::savepoint_id(
  self : JournalEntryIdentity,
) -> String {
  self.savepoint_id
}

///|
pub fn JournalEntryIdentity::entry_seq(self : JournalEntryIdentity) -> Int {
  self.entry_seq
}

///|
pub fn JournalEntryIdentity::kind(self : JournalEntryIdentity) -> SavepointKind {
  self.kind
}

// ──────────────────────────────────────────────────────────────────────────
// JournalEntry — the stored record
// ──────────────────────────────────────────────────────────────────────────

///|
/// A single journal entry. Carries identity + a redacted summary string +
/// an opaque canonical payload (Json). The journal never interprets the
/// payload — it's pure storage.
///
/// Payload size is bounded; oversize entries fail validation at the
/// coordinator (pre-write).
pub(all) struct JournalEntry {
  identity : JournalEntryIdentity
  /// Revision assigned at commit time. Monotonic across the whole journal.
  revision : Int
  /// Single-line redacted summary for diagnostics. Excludes secrets,
  /// prompts, tool arguments.
  summary : String
  /// Opaque canonical payload. The journal does not interpret this.
  payload : Json
} derive(Eq, Debug)

///|
pub fn JournalEntry::identity(self : JournalEntry) -> JournalEntryIdentity {
  self.identity
}

///|
pub fn JournalEntry::revision(self : JournalEntry) -> Int {
  self.revision
}

///|
pub fn JournalEntry::summary(self : JournalEntry) -> String {
  self.summary
}

///|
pub fn JournalEntry::payload(self : JournalEntry) -> Json {
  self.payload
}

// ──────────────────────────────────────────────────────────────────────────
// RunJournal trait (port — Q7.2 recommendation: pub(open) trait)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Port: append-only journal with monotonic revision and identity validation.
///
/// M2 ships `InMemoryJournal`. M5 will add JSONL/SQLite by implementing this.
///
/// The trait intentionally exposes ONLY:
/// - `append`: commit a frozen batch (advances revision)
/// - `revision`: read current committed revision
/// - `entries_for_run`: read projection (replay)
/// - `entries_for_savepoint`: read a single savepoint's entries
///
/// It does NOT expose:
/// - any mutation of committed entries
/// - any writer handle that subscribers could obtain
/// - any "propose" or "contribute" method (that's the coordinator's job)
pub(open) trait RunJournal {
  /// Append a frozen batch of entries atomically. All entries commit at the
  /// same revision window (each gets revision = current+N). Returns the new
  /// committed revision (the revision of the LAST entry in the batch), or a
  /// typed error describing why the append failed.
  ///
  /// Raises:
  /// - `HarnessError::SavepointFailed(_, BarrierFailed(_))` if the append
  ///   itself fails (e.g. I/O error in M5).
  /// - Identity mismatch / post-terminal append also raise SavepointFailed.
  fn append(Self, Array[JournalEntry]) -> Int raise HarnessError

  /// Current committed revision. 0 means "no entries yet".
  fn revision(Self) -> Int

  /// Read all entries for a given run id, ordered by revision. Used by
  /// projection / replay.
  fn entries_for_run(Self, RunId) -> Array[JournalEntry]

  /// Read all entries for a given savepoint id within a run. Used by
  /// conformance tests to verify atomic commit.
  fn entries_for_savepoint(Self, RunId, String) -> Array[JournalEntry]
}

// ──────────────────────────────────────────────────────────────────────────
// InMemoryJournal — first adapter
// ──────────────────────────────────────────────────────────────────────────

///|
/// Append-only in-memory journal. Stores entries in an Array; revision is
/// derived from the array length (entry N has revision N).
///
/// Thread-safety: M2 runs single-threaded; the Harness is the only writer.
/// M5's durable adapter will add its own concurrency control.
pub struct InMemoryJournal {
  // Field visibility is package-private: only this file constructs the
  // journal. The Harness holds a `&RunJournal` reference; callers cannot
  // reach into fields.
  entries : Array[JournalEntry]
  /// Set of (run_id, savepoint_id, entry_seq) triples already committed.
  /// Used to reject duplicate entry ids at append time.
  seen_ids : Map[String, Bool]
  /// Set of run_ids that have committed a RunTerminal entry. Further
  /// appends for these runs are rejected (terminal is terminal).
  terminal_runs : Map[String, Bool]
}

///|
pub fn InMemoryJournal::new() -> InMemoryJournal {
  {
    entries: [],
    seen_ids: Map::from_array([]),
    terminal_runs: Map::from_array([]),
  }
}

///|
/// Internal: build the dedup key for an entry identity.
fn entry_dedup_key(id : JournalEntryIdentity) -> String {
  "\{id.run_id.to_string()}|\{id.savepoint_id}|\{id.entry_seq}"
}

///|
pub impl RunJournal for InMemoryJournal with fn append(
  self,
  batch : Array[JournalEntry],
) -> Int raise HarnessError {
  InMemoryJournal::append_impl(self, batch)
}

///|
pub impl RunJournal for InMemoryJournal with fn revision(self) -> Int {
  InMemoryJournal::revision_impl(self)
}

///|
pub impl RunJournal for InMemoryJournal with fn entries_for_run(
  self,
  run_id : RunId,
) -> Array[JournalEntry] {
  InMemoryJournal::entries_for_run_impl(self, run_id)
}

///|
pub impl RunJournal for InMemoryJournal with fn entries_for_savepoint(
  self,
  run_id : RunId,
  savepoint_id : String,
) -> Array[JournalEntry] {
  InMemoryJournal::entries_for_savepoint_impl(self, run_id, savepoint_id)
}

///|
/// Internal: append implementation. Split from the trait method so other
/// in-file helpers (e.g. FailOnNthJournal) can call it directly without
/// going through trait dispatch.
pub fn InMemoryJournal::append_impl(
  self : InMemoryJournal,
  batch : Array[JournalEntry],
) -> Int raise HarnessError {
  if batch.is_empty() {
    return self.revision_impl()
  }
  // Phase 1: validate the entire batch BEFORE mutating any state.
  for entry in batch {
    let key = entry_dedup_key(entry.identity)
    if self.seen_ids.contains(key) {
      raise SavepointFailed(
        kind=entry.identity.kind.to_string(),
        cause=BarrierFailed(detail="duplicate entry id: \{key}"),
      )
    }
    if self.terminal_runs.contains(entry.identity.run_id.to_string()) {
      raise SavepointFailed(
        kind=entry.identity.kind.to_string(),
        cause=BarrierFailed(
          detail="run '\{entry.identity.run_id.to_string()}' is already terminal",
        ),
      )
    }
  }
  // Phase 2: commit.
  let mut next_rev = self.revision_impl() + 1
  for entry in batch {
    let key = entry_dedup_key(entry.identity)
    self.seen_ids[key] = true
    let committed : JournalEntry = {
      identity: entry.identity,
      revision: next_rev,
      summary: entry.summary,
      payload: entry.payload,
    }
    self.entries.push(committed)
    match entry.identity.kind {
      RunTerminal =>
        self.terminal_runs[entry.identity.run_id.to_string()] = true
      _ => ()
    }
    next_rev = next_rev + 1
  }
  self.revision_impl()
}

///|
pub fn InMemoryJournal::revision_impl(self : InMemoryJournal) -> Int {
  self.entries.length()
}

///|
pub fn InMemoryJournal::entries_for_run_impl(
  self : InMemoryJournal,
  run_id : RunId,
) -> Array[JournalEntry] {
  let out : Array[JournalEntry] = []
  for entry in self.entries {
    if entry.identity.run_id == run_id {
      out.push(entry)
    }
  }
  out
}

///|
pub fn InMemoryJournal::entries_for_savepoint_impl(
  self : InMemoryJournal,
  run_id : RunId,
  savepoint_id : String,
) -> Array[JournalEntry] {
  let out : Array[JournalEntry] = []
  for entry in self.entries {
    if entry.identity.run_id == run_id &&
      entry.identity.savepoint_id == savepoint_id {
      out.push(entry)
    }
  }
  out
}

// ──────────────────────────────────────────────────────────────────────────
// Test helpers — fail-on-Nth append adapter
// ──────────────────────────────────────────────────────────────────────────

///|
/// Test adapter: wraps an InMemoryJournal and fails on the Nth append call
/// with a typed barrier failure. Used by the C-JOURNAL-APPEND-FAIL fixture.
///
/// The wrapped journal is NOT mutated when the failure triggers (the outer
/// adapter raises before delegating).
pub struct FailOnNthJournal {
  inner : InMemoryJournal
  fail_on : Int
  mut call_count : Int
}

///|
pub fn FailOnNthJournal::new(
  inner : InMemoryJournal,
  fail_on : Int,
) -> FailOnNthJournal {
  { inner, fail_on, call_count: 0 }
}

///|
pub impl RunJournal for FailOnNthJournal with fn append(
  self,
  batch : Array[JournalEntry],
) -> Int raise HarnessError {
  self.call_count = self.call_count + 1
  if self.call_count == self.fail_on {
    raise SavepointFailed(
      kind="FailOnNth",
      cause=BarrierFailed(detail="injected failure on append #\{self.fail_on}"),
    )
  }
  self.inner.append_impl(batch)
}

///|
pub impl RunJournal for FailOnNthJournal with fn revision(self) -> Int {
  self.inner.revision_impl()
}

///|
pub impl RunJournal for FailOnNthJournal with fn entries_for_run(
  self,
  run_id : RunId,
) -> Array[JournalEntry] {
  self.inner.entries_for_run_impl(run_id)
}

///|
pub impl RunJournal for FailOnNthJournal with fn entries_for_savepoint(
  self,
  run_id : RunId,
  savepoint_id : String,
) -> Array[JournalEntry] {
  self.inner.entries_for_savepoint_impl(run_id, savepoint_id)
}
