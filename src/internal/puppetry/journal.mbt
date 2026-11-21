///|

///|
/// The savepoint kind an entry belongs to. Each savepoint commits atomically:
/// all entries with the same (run_id, savepoint_id, kind) either all commit
/// or none do.
#derive(Eq, Debug)
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
}

///|
pub extend SavepointKind with Eq::{not_equal, equal}

///|
pub extend SavepointKind with Debug::{to_repr}

///|
pub extend SavepointKind with Show::{output}

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

///|
/// Stable identifier for a journal entry. The (run_id, savepoint_id,
/// entry_seq) triple uniquely locates an entry within the journal.
#derive(Eq, Debug)
pub(all) struct JournalEntryIdentity {
  run_id : RunId
  turn_id : TurnId
  session_id : SessionId
  savepoint_id : String
  /// Monotonic within the savepoint. The Puppet assigns this when freezing
  /// the pending batch.
  entry_seq : Int32
  kind : SavepointKind
}

///|
pub extend JournalEntryIdentity with Eq::{not_equal, equal}

///|
pub extend JournalEntryIdentity with Debug::{to_repr}

///|
pub extend JournalEntryIdentity with Show::{to_string, output}

///|
pub impl Show for JournalEntryIdentity with fn to_string(
  self : JournalEntryIdentity,
) -> String {
  "EntryId(run=\{self.run_id.to_string()}, sp=\{self.savepoint_id}, seq=\{self.entry_seq}, kind=\{self.kind.to_string()})"
}

///|
/// A single journal entry. Carries identity + a redacted summary string +
/// an opaque canonical payload (Json). The journal never interprets the
#derive(Eq, Debug)
pub(all) struct JournalEntry {
  identity : JournalEntryIdentity
  /// Revision assigned at commit time. Monotonic across the whole journal.
  revision : Int32
  /// Single-line redacted summary for diagnostics. Excludes secrets,
  /// prompts, tool arguments.
  summary : String
  /// Opaque canonical payload. The journal does not interpret this.
  payload : Json
}

///|
pub extend JournalEntry with Eq::{not_equal, equal}

///|
pub extend JournalEntry with Debug::{to_repr}

///|
/// Port: append-only journal with monotonic revision and identity validation.
pub(open) trait RunJournal {
  /// Append a frozen batch of entries atomically. All entries commit at the
  /// same revision window (each gets revision = current+N). Returns the new
  /// committed revision (the revision of the LAST entry in the batch), or a
  /// typed error describing why the append failed.
  ///
  /// Raises:
  /// - `PuppetError::SavepointFailed(_, BarrierFailed(_))` if the append
  ///   itself fails (e.g. an I/O error in a durable adapter).
  /// - Identity mismatch / post-terminal append also raise SavepointFailed.
  fn append(Self, Array[JournalEntry]) -> Int32 raise PuppetError

  /// Current committed revision. 0 means "no entries yet".
  fn revision(Self) -> Int32

  /// Read all entries for a given run id, ordered by revision. Used by
  /// projection / replay.
  fn entries_for_run(Self, RunId) -> Array[JournalEntry]

  /// Read all entries for a given savepoint id within a run. Used by
  /// conformance tests to verify atomic commit.
  fn entries_for_savepoint(Self, RunId, String) -> Array[JournalEntry]
}

///|
/// Append-only in-memory journal. Stores entries in an Array; revision is
/// derived from the array length (entry N has revision N).
pub struct InMemoryJournal {
  entries : Array[JournalEntry]
  /// Set of (run_id, savepoint_id, entry_seq) triples already committed.
  /// Used to reject duplicate entry ids at append time.
  seen_ids : Map[String, Bool]
  /// Set of run_ids that have committed a RunTerminal entry. Further
  /// appends for these runs are rejected (terminal is terminal).
  terminal_runs : Map[String, Bool]
  /// Successful non-empty append calls. This is deliberately distinct from
  /// `revision`: one boundary may contain multiple entries/contributions but
  /// must still cross the durability barrier exactly once.
  mut append_count : Int32
}

///|
pub fn InMemoryJournal::InMemoryJournal() -> InMemoryJournal {
  {
    entries: [],
    seen_ids: Map::from_array([]),
    terminal_runs: Map::from_array([]),
    append_count: 0,
  }
}

///|
/// Number of successful non-empty append barriers. Exposed for deterministic
/// performance-gate fixtures; production code relies on journal revisions.
pub fn InMemoryJournal::append_count(self : InMemoryJournal) -> Int32 {
  self.append_count
}

///|
fn entry_dedup_key(id : JournalEntryIdentity) -> String {
  "\{id.run_id.to_string()}|\{id.savepoint_id}|\{id.entry_seq}"
}

///|
pub impl RunJournal for InMemoryJournal with fn append(
  self,
  batch : Array[JournalEntry],
) -> Int32 raise PuppetError {
  InMemoryJournal::append_impl(self, batch)
}

///|
pub impl RunJournal for InMemoryJournal with fn revision(self) -> Int32 {
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
fn InMemoryJournal::append_impl(
  self : InMemoryJournal,
  batch : Array[JournalEntry],
) -> Int32 raise PuppetError {
  if batch.is_empty() {
    return self.revision_impl()
  }
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
  self.append_count = self.append_count + 1
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
fn InMemoryJournal::revision_impl(self : InMemoryJournal) -> Int32 {
  self.entries.length()
}

///|
fn InMemoryJournal::entries_for_run_impl(
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
fn InMemoryJournal::entries_for_savepoint_impl(
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

///|
/// Test adapter: wraps an InMemoryJournal and fails on the Nth append call
/// with a typed barrier failure. Used by the C-JOURNAL-APPEND-FAIL fixture.
pub struct FailOnNthJournal {
  inner : InMemoryJournal
  fail_on : Int32
  mut call_count : Int32
}

///|
pub fn FailOnNthJournal::FailOnNthJournal(
  inner : InMemoryJournal,
  fail_on : Int32,
) -> FailOnNthJournal {
  { inner, fail_on, call_count: 0, }
}

///|
pub extend FailOnNthJournal with RunJournal::{
  entries_for_run,
  entries_for_savepoint,
  append,
  revision,
}

///|
pub impl RunJournal for FailOnNthJournal with fn append(
  self,
  batch : Array[JournalEntry],
) -> Int32 raise PuppetError {
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
pub impl RunJournal for FailOnNthJournal with fn revision(self) -> Int32 {
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
