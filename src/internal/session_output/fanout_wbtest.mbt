///|
/// Fanout execution tests: all stores are dispatched, the first failure in port
/// order is the one reported, and each store receives its own deep snapshot.
/// The doubles below implement `SessionPort` locally so nothing depends on the
/// root package.

///|
/// Store double that records the payload it received and optionally fails.
priv struct FanoutStore {
  label : String
  fail : Bool
  saves : Array[(@types.Session, Map[String, Json])]
  checkpoints : Array[@port.SessionCheckpoint]
}

///|
impl @port.SessionPort for FanoutStore with fn load(_self, _id : String) -> @types.Session raise @error.SessionError {
  raise Save("fanout double has no canonical body")
}

///|
impl @port.SessionPort for FanoutStore with fn save(
  self,
  _id : String,
  session : @types.Session,
) -> Unit raise @error.SessionError {
  if self.fail {
    raise Save("save refused by " + self.label)
  }
  self.saves.push((session, Map::from_array([])))
}

///|
impl @port.SessionPort for FanoutStore with fn checkpoint(
  self,
  _id : String,
  checkpoint : @port.SessionCheckpoint,
) -> Unit raise @error.SessionError {
  if self.fail {
    raise Save("checkpoint refused by " + self.label)
  }
  self.checkpoints.push(checkpoint)
}

///|
fn fanout_store(label : String, fail : Bool) -> FanoutStore {
  { label, fail, saves: [], checkpoints: [], }
}

///|
fn fanout_message(text : String) -> @kernel.Message {
  @kernel.UserMessage(content=[@kernel.Text(text)])
}

///|
/// Deep, nested metadata so a shared reference would be observable.
fn fanout_metadata(tag : String) -> Map[String, Json] {
  Map::from_array([
    (
      "title",
      Json::object(
        Map::from_array([("tag", Json::string(tag)), ("n", Json::number(1.0))]),
      ),
    ),
    ("tags", Json::array([Json::string(tag)])),
  ])
}

///|
async test "session_output/fanout save dispatches every store and reports the first failure" {
  let first = fanout_store("first", false)
  let second = fanout_store("second", true)
  let third = fanout_store("third", true)
  let outcome : Result[Unit, @error.AgentError] = try {
    save_all(
      [first, second, third],
      "s_fanout",
      [fanout_message("body")],
      fanout_metadata("t"),
      "fanout_save",
    )
    Ok(())
  } catch {
    error => Err(error)
  }
  // Every store was dispatched, including the one after the first failure.
  assert_eq(first.saves.length(), 1)
  assert_eq(second.saves.length(), 0)
  assert_eq(third.saves.length(), 0)
  guard outcome is Err(Session(Save(detail))) else {
    fail("a refused save must surface as SessionException::Save")
  }
  assert_true(detail.contains("operation='fanout_save'"))
  assert_true(detail.contains("save refused by second"))
  assert_false(detail.contains("third"))
}

///|
async test "session_output/fanout checkpoint reports the first port-order failure" {
  let first = fanout_store("first", true)
  let second = fanout_store("second", true)
  let third = fanout_store("third", false)
  let outcome : Result[Unit, @error.AgentError] = try {
    checkpoint_all(
      [first, second, third],
      "s_fanout",
      4,
      [fanout_message("tail")],
      Some(fanout_metadata("t")),
      "fanout_checkpoint",
    )
    Ok(())
  } catch {
    error => Err(error)
  }
  assert_eq(third.checkpoints.length(), 1)
  assert_eq(third.checkpoints[0].from_index, 4)
  guard outcome is Err(Session(Save(detail))) else {
    fail("a refused checkpoint must surface as SessionException::Save")
  }
  assert_true(detail.contains("operation='fanout_checkpoint'"))
  assert_true(detail.contains("checkpoint refused by first"))
  assert_false(detail.contains("second"))
}

///|
async test "session_output/fanout empty store list is a no-op for both waves" {
  // The double only models the write side; a read attempt is an explicit
  // failure rather than a silent empty body.
  let reader = fanout_store("reader", false)
  let read : Result[@types.Session, @error.SessionError] = try {
    ignore(@port.SessionPort::load(reader, "s_none"))
    Ok({ messages: [], metadata: Map::from_array([]), })
  } catch {
    error => Err(error)
  }
  guard read is Err(Save(_)) else {
    fail("the fanout double must refuse reads")
  }
  let stores : Array[&@port.SessionPort] = []
  save_all(
    stores,
    "s_none",
    [fanout_message("x")],
    fanout_metadata("t"),
    "noop_save",
  )
  checkpoint_all(
    stores,
    "s_none",
    0,
    [fanout_message("x")],
    None,
    "noop_checkpoint",
  )
}

///|
async test "session_output/fanout snapshots messages and nested metadata per store" {
  let first = fanout_store("first", false)
  let second = fanout_store("second", false)
  let messages = [fanout_message("one")]
  let metadata = fanout_metadata("t")
  save_all([first, second], "s_snap", messages, metadata, "snap_save")
  assert_eq(first.saves.length(), 1)
  assert_eq(second.saves.length(), 1)
  // Mutating one store's received payload cannot reach the other store, the
  // caller's arrays, or the nested metadata object.
  first.saves[0].0.messages.clear()
  first.saves[0].0.metadata.clear()
  assert_eq(second.saves[0].0.messages.length(), 1)
  assert_eq(second.saves[0].0.metadata.length(), 2)
  assert_eq(messages.length(), 1)
  assert_eq(metadata.length(), 2)
  // The checkpoint wave snapshots its optional metadata the same way.
  let check_store = fanout_store("check", false)
  checkpoint_all(
    [check_store],
    "s_snap",
    0,
    messages,
    Some(metadata),
    "snap_checkpoint",
  )
  let received = match check_store.checkpoints[0].metadata {
    Some(value) => value
    None => fail("metadata replacement must survive as Some")
  }
  received.clear()
  assert_eq(metadata.length(), 2)
}
