///|

///|
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
priv struct CoreSessionVersions {
  versions : Array[CoreVersion]
}

///|
priv struct CoreSourceSnapshot {
  sid : String
  messages : Array[@kernel.Message]
  metadata : Map[String, Json]
}

///|
priv struct CoreSource {
  sid : String
  version : Int32
  prefix : Int32
}

///|
#derive(Debug)
priv suberror CoreVersionError {
  UnknownSession(sid~ : String)
  SessionExists(sid~ : String)
  UnknownVersion(sid~ : String, version~ : Int32)
  PrefixOutOfRange(
    sid~ : String,
    version~ : Int32,
    prefix~ : Int32,
    available~ : Int32,
  )
}

///|
priv struct CoreCurrent {
  version : Int32
  session : @types.Session
}

///|
priv struct CoreVersionStore {
  sessions : Map[String, CoreSessionVersions]
  /// Snapshot id -> detached exact source content. Negative source versions
  /// address this store; they are never materialized as the session head.
  source_snapshots : Map[(String, Int32), CoreSourceSnapshot]
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
        body: Full(messages=@message_snapshot.snapshot_messages(messages)),
        metadata: @message_snapshot.snapshot_metadata(metadata),
        length: messages.length(),
        source: None,
      },
    ],
  }
  0
}

///|
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
        body: Full(messages=@message_snapshot.snapshot_messages(messages)),
        metadata: @message_snapshot.snapshot_metadata(metadata),
        length: messages.length(),
        source: Some(source),
      },
    ],
  }
  0
}

///|
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
    body: Append(tail=@message_snapshot.snapshot_messages(messages)),
    metadata: @message_snapshot.snapshot_metadata(metadata),
    length: previous.length + messages.length(),
    source: previous.source,
  })
  version
}

///|
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
    body: Full(messages=@message_snapshot.snapshot_messages(messages)),
    metadata: @message_snapshot.snapshot_metadata(metadata),
    length: messages.length(),
    source: previous.source,
  })
  version
}

///|
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
fn CoreVersionStore::head_messages_readonly(
  self : CoreVersionStore,
  sid : String,
) -> Array[@kernel.Message] raise CoreVersionError {
  let lineage = match self.sessions.get(sid) {
    Some(lineage) => lineage
    None => raise UnknownSession(sid~)
  }
  let version = lineage.versions.length() - 1
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
      messages.push(message)
    }
  }
  messages
}

///|
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
      messages.push(@message_snapshot.snapshot_message(message))
    }
  }
  {
    messages,
    metadata: @message_snapshot.snapshot_metadata(
      lineage.versions[version].metadata,
    ),
  }
}

///|
fn CoreVersionStore::record_source_snapshot(
  self : CoreVersionStore,
  sid : String,
  messages : Array[@kernel.Message],
  metadata : Map[String, Json],
) -> Int32 {
  let version = @proof_versions.next_source_snapshot_ver(self.source_seq.val)
  self.source_seq.val = self.source_seq.val + 1
  self.source_snapshots[(sid, version)] = {
    sid,
    messages: @message_snapshot.snapshot_messages(messages),
    metadata: @message_snapshot.snapshot_metadata(metadata),
  }
  version
}

///|
fn CoreVersionStore::remove_source_snapshot(
  self : CoreVersionStore,
  sid : String,
  version : Int32,
) -> Unit {
  self.source_snapshots.remove((sid, version))
}

///|
fn CoreVersionStore::validate_source(
  self : CoreVersionStore,
  source : CoreSource,
) -> Unit raise CoreVersionError {
  if source.version < 0 {
    let snapshot = match
      self.source_snapshots.get((source.sid, source.version)) {
      Some(value) => value
      None => raise UnknownVersion(sid=source.sid, version=source.version)
    }
    if snapshot.sid != source.sid {
      raise UnknownSession(sid=source.sid)
    }
    let available = snapshot.messages.length()
    if !@proof_versions.validate_prefix(source.prefix, available) {
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
  if !@proof_versions.validate_prefix(source.prefix, available) {
    raise PrefixOutOfRange(
      sid=source.sid,
      version=source.version,
      prefix=source.prefix,
      available~,
    )
  }
}

///|
fn CoreVersionStore::resolve_source(
  self : CoreVersionStore,
  source : CoreSource,
) -> @types.Session raise CoreVersionError {
  self.validate_source(source)
  if source.version < 0 {
    let snapshot = match
      self.source_snapshots.get((source.sid, source.version)) {
      Some(value) => value
      None => raise UnknownVersion(sid=source.sid, version=source.version)
    }
    let windowed : Array[@kernel.Message] = []
    for message in snapshot.messages[0:source.prefix].to_owned() {
      windowed.push(@message_snapshot.snapshot_message(message))
    }
    return {
      messages: windowed,
      metadata: @message_snapshot.snapshot_metadata(snapshot.metadata),
    }
  }
  let full = self.materialize(source.sid, source.version)
  let windowed : Array[@kernel.Message] = []
  for message in full.messages[0:source.prefix].to_owned() {
    windowed.push(message)
  }
  { messages: windowed, metadata: full.metadata, }
}
