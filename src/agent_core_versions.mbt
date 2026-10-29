///|
/// Minimal private immutable session-version store with source references.
///
/// Scope: this is the foundation slice only — the Agent's core fact layer
/// does not consume it yet, nothing is persisted, and it does not claim the
/// information tree is online. A version id alone is not an identity: only
/// `(sid, version)` is. Version ids are dense per-session indexes inside one
/// `CoreVersionStore` instance and carry no durable or global meaning. The
/// store does not try to detect a caller that reads an existing index under a
/// different but valid sid.
///
/// Invariants:
/// - Version 0 of every session is a `Full` body; `Append` versions extend
///   the immediately preceding version.
/// - Every stored body and metadata map is a deep snapshot taken at write
///   time; every read returns deep snapshots again, so callers can mutate
///   both inputs and returned values without touching history.
/// - A `CoreSource` pins `(sid, version)` plus a message prefix; resolving it
///   always materializes that pinned version, never the current one.
/// - A session is either a root snapshot (`source = None`) or derived from a
///   version that already existed. A derived version 0 body is either a copy
///   of the source prefix (fork) or independent content supplied atomically
///   by the caller (NewThread compact summary). The creation source stays
///   pinned across later appends and rewrites, so parent changes cannot
///   retarget it. Derivation only references existing versions, which makes a
///   cycle impossible.
///
/// These invariants are guaranteed for calls through this store's methods.
/// Same-package code can still mutate the private maps directly; that is
/// outside the method contract, so this slice stays one package instead of
/// splitting it to imitate an access boundary.

///|
/// Body of one version: either a complete message list or the tail appended
/// to the previous version of the same session. The ADT makes the illegal
/// "full plus appended" combination unrepresentable.
priv enum CoreVersionBody {
  Full(messages~ : Array[@kernel.Message])
  Append(tail~ : Array[@kernel.Message])
}

///|
priv struct CoreVersion {
  body : CoreVersionBody
  /// Deep metadata snapshot as of this version.
  metadata : Map[String, Json]
  /// Materialized message count, so prefix validation never walks the chain.
  length : Int32
  /// Creation provenance, not a per-rewrite source. Root versions carry
  /// `None`; every version of a derived lineage copies the source captured at
  /// creation unchanged.
  source : CoreSource?
}

///|
/// Dense per-session version history. Version ids are the array indexes of
/// this session only; there is no global sequence to search.
priv struct CoreSessionVersions {
  versions : Array[CoreVersion]
}

///|
/// A non-head, referenceable source snapshot. Used when the exact ModelPort
/// input differs from current committed content (for example a fixated
/// dangling tool call); it never becomes the session head.
priv struct CoreSourceSnapshot {
  sid : String
  messages : Array[@kernel.Message]
  metadata : Map[String, Json]
}

///|
/// A reference to the source content a fork or NewThread compact consumed:
/// the parent session id, a pinned positive version or negative source
/// snapshot, and how many materialized messages the diversion read.
priv struct CoreSource {
  sid : String
  version : Int32
  prefix : Int32
}

///|
/// Private failure surface for this slice. No public error variant is added;
/// an unknown session/version, a duplicate first snapshot, or an out-of-range
/// prefix fails loudly instead of degrading to an empty value.
priv suberror CoreVersionError {
  UnknownSession(sid~ : String)
  SessionExists(sid~ : String)
  UnknownVersion(sid~ : String, version~ : Int32)
  PrefixOutOfRange(
    sid~ : String,
    version~ : Int32,
    prefix~ : Int32,
    available~ : Int32
  )
} derive(Debug)

///|
/// Current view of a session: which version is current and its materialized
/// content, both deep snapshots.
priv struct CoreCurrent {
  version : Int32
  session : @types.Session
}

///|
priv struct CoreVersionStore {
  sessions : Map[String, CoreSessionVersions]
  /// Snapshot id -> detached exact source content. Negative source versions
  /// address this store; they are never materialized as the session head.
  source_snapshots : Map[String, CoreSourceSnapshot]
  source_seq : Ref[Int32]
}

///|
fn CoreVersionStore::CoreVersionStore() -> CoreVersionStore {
  {
    sessions: Map::from_array([]),
    source_snapshots: Map::from_array([]),
    source_seq: Ref(0),
  }
}

///|
/// Record the first complete snapshot of a new session as version 0.
fn CoreVersionStore::record_full(
  self : CoreVersionStore,
  sid : String,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
) -> Int32 raise CoreVersionError {
  if self.sessions.contains(sid) {
    raise SessionExists(sid~)
  }
  self.sessions[sid] = {
    versions: [
      {
        body: Full(messages=snapshot_messages(messages)),
        metadata: snapshot_metadata(metadata),
        length: messages.length(),
        source: None,
      },
    ],
  }
  0
}

///|
/// Atomically create a derived session's version 0 from an already existing,
/// validated `CoreSource` plus caller-supplied body and metadata. The stored
/// version 0 is exactly `messages` (for NewThread compact, the summary), not
/// a source prefix followed by a rewrite. The source is creation provenance:
/// later appends/rewrites inherit it unchanged. Validation of the source and
/// the target-absence check both run before insertion, so a failure leaves
/// neither a child sid nor a new version behind.
fn CoreVersionStore::record_derived_content(
  self : CoreVersionStore,
  sid : String,
  source : CoreSource,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
) -> Int32 raise CoreVersionError {
  self.validate_source(source)
  if self.sessions.contains(sid) {
    raise SessionExists(sid~)
  }
  self.sessions[sid] = {
    versions: [
      {
        body: Full(messages=snapshot_messages(messages)),
        metadata: snapshot_metadata(metadata),
        length: messages.length(),
        source: Some(source),
      },
    ],
  }
  0
}

///|
/// Append a message tail (and its metadata snapshot) to the current version
/// of an existing session.
fn CoreVersionStore::append(
  self : CoreVersionStore,
  sid : String,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
) -> Int32 raise CoreVersionError {
  let lineage = match self.sessions.get(sid) {
    Some(lineage) => lineage
    None => raise UnknownSession(sid~)
  }
  let previous = lineage.versions[lineage.versions.length() - 1]
  let version = lineage.versions.length()
  lineage.versions.push({
    body: Append(tail=snapshot_messages(messages)),
    metadata: snapshot_metadata(metadata),
    length: previous.length + messages.length(),
    source: previous.source,
  })
  version
}

///|
/// Replace the session body wholesale as a new version. Earlier versions stay
/// addressable, so references pinned before the rewrite keep resolving to the
/// pre-rewrite content.
fn CoreVersionStore::rewrite(
  self : CoreVersionStore,
  sid : String,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
) -> Int32 raise CoreVersionError {
  let lineage = match self.sessions.get(sid) {
    Some(lineage) => lineage
    None => raise UnknownSession(sid~)
  }
  let previous = lineage.versions[lineage.versions.length() - 1]
  let version = lineage.versions.length()
  lineage.versions.push({
    body: Full(messages=snapshot_messages(messages)),
    metadata: snapshot_metadata(metadata),
    length: messages.length(),
    source: previous.source,
  })
  version
}

///|
/// Read the current version id and its materialized content.
fn CoreVersionStore::current(
  self : CoreVersionStore,
  sid : String,
) -> CoreCurrent raise CoreVersionError {
  let lineage = match self.sessions.get(sid) {
    Some(lineage) => lineage
    None => raise UnknownSession(sid~)
  }
  let version = lineage.versions.length() - 1
  { version, session: self.materialize(sid, version), }
}

///|
/// Materialize one historical version: walk the append chain back to the last
/// `Full` body iteratively (long chains must not recurse), then concatenate
/// the chunks in order with fresh deep snapshots.
fn CoreVersionStore::materialize(
  self : CoreVersionStore,
  sid : String,
  version : Int32,
) -> @types.Session raise CoreVersionError {
  let lineage = match self.sessions.get(sid) {
    Some(lineage) => lineage
    None => raise UnknownSession(sid~)
  }
  if version < 0 || version >= lineage.versions.length() {
    raise UnknownVersion(sid~, version~)
  }
  let chunks : Array[Array[@kernel.Message]] = []
  let mut index = version
  while index >= 0 {
    match lineage.versions[index].body {
      Full(messages~) => {
        chunks.push(messages)
        break
      }
      Append(tail~) => {
        chunks.push(tail)
        index = index - 1
      }
    }
  }
  let messages : Array[@kernel.Message] = []
  for i in (chunks.length() - 1)>=..0 {
    for message in chunks[i] {
      messages.push(snapshot_message(message))
    }
  }
  { messages, metadata: snapshot_metadata(lineage.versions[version].metadata), }
}

///|
fn core_source_snapshot_key(sid : String, version : Int32) -> String {
  sid + "\u0000" + version.to_string()
}

///|
/// Store an exact non-head source snapshot and return its negative version.
fn CoreVersionStore::record_source_snapshot(
  self : CoreVersionStore,
  sid : String,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
) -> Int32 {
  let version = -1 - self.source_seq.val
  self.source_seq.val = self.source_seq.val + 1
  self.source_snapshots[core_source_snapshot_key(sid, version)] = {
    sid,
    messages: snapshot_messages(messages),
    metadata: snapshot_metadata(metadata),
  }
  version
}

///|
/// Revoke a just-allocated, not-yet-referenced source snapshot. Used only when
/// child creation fails; the source sequence is not reused.
fn CoreVersionStore::remove_source_snapshot(
  self : CoreVersionStore,
  sid : String,
  version : Int32,
) -> Unit {
  self.source_snapshots.remove(core_source_snapshot_key(sid, version))
}

///|
/// Validate a source reference without materializing its full body: the
/// session/version must exist and `prefix` must fit the recorded length. Used
/// by callers that already hold the child body and only need provenance checks.
fn CoreVersionStore::validate_source(
  self : CoreVersionStore,
  source : CoreSource,
) -> Unit raise CoreVersionError {
  if source.version < 0 {
    let snapshot = match
      self.source_snapshots.get(
        core_source_snapshot_key(source.sid, source.version),
      ) {
      Some(value) => value
      None => raise UnknownVersion(sid=source.sid, version=source.version)
    }
    if snapshot.sid != source.sid {
      raise UnknownSession(sid=source.sid)
    }
    let available = snapshot.messages.length()
    if source.prefix < 0 || source.prefix > available {
      raise PrefixOutOfRange(
        sid=source.sid,
        version=source.version,
        prefix=source.prefix,
        available~,
      )
    }
    return
  }
  let lineage = match self.sessions.get(source.sid) {
    Some(lineage) => lineage
    None => raise UnknownSession(sid=source.sid)
  }
  if source.version < 0 || source.version >= lineage.versions.length() {
    raise UnknownVersion(sid=source.sid, version=source.version)
  }
  let available = lineage.versions[source.version].length
  if source.prefix < 0 || source.prefix > available {
    raise PrefixOutOfRange(
      sid=source.sid,
      version=source.version,
      prefix=source.prefix,
      available~,
    )
  }
}

///|
/// Resolve a fork/compact source reference to the pinned window it consumed:
/// the source version's first `prefix` messages plus that version's metadata
/// snapshot. The prefix is validated against the version's recorded length;
/// unknown sessions/versions and illegal prefixes fail instead of yielding an
/// empty or partial result.
fn CoreVersionStore::resolve_source(
  self : CoreVersionStore,
  source : CoreSource,
) -> @types.Session raise CoreVersionError {
  self.validate_source(source)
  if source.version < 0 {
    let snapshot = match
      self.source_snapshots.get(
        core_source_snapshot_key(source.sid, source.version),
      ) {
      Some(value) => value
      None => raise UnknownVersion(sid=source.sid, version=source.version)
    }
    let windowed : Array[@kernel.Message] = []
    for message in snapshot.messages[0:source.prefix].to_owned() {
      windowed.push(snapshot_message(message))
    }
    return {
      messages: windowed,
      metadata: snapshot_metadata(snapshot.metadata),
    }
  }
  let full = self.materialize(source.sid, source.version)
  let windowed : Array[@kernel.Message] = []
  for message in full.messages[0:source.prefix].to_owned() {
    windowed.push(message)
  }
  { messages: windowed, metadata: full.metadata, }
}
