///|
/// Rewind primitive regression tests: `SessionStore::truncate`.
///
/// The Agent reloads persisted history from the store at the start of every
/// turn, so truncating the store changes what the next turn sees. These tests
/// pin the trait default implementation (load → slice → full save), the
/// RecordingSessionStore override, and the Agent-level end-to-end behaviour.

// ---------------------------------------------------------------------------
// Minimal store implementing only load/save — drives the trait default impl.
// ---------------------------------------------------------------------------

///|
struct TruncateFallbackStore {
  session : @types.Session
  saved : Array[@types.Session]
  mut fail_load : Bool
  mut fail_save : Bool
}

///|
fn TruncateFallbackStore::make(
  session : @types.Session,
) -> TruncateFallbackStore {
  { session, saved: [], fail_load: false, fail_save: false, }
}

///|
pub impl @port.SessionStore for TruncateFallbackStore with fn load(
  self,
  _id : String,
) -> @types.Session raise @error.SessionError {
  if self.fail_load {
    raise @error.SessionError::Load("backend unavailable")
  }
  self.session
}

///|
pub impl @port.SessionStore for TruncateFallbackStore with fn save(
  self,
  _id : String,
  session : @types.Session,
) -> Unit raise @error.SessionError {
  if self.fail_save {
    raise @error.SessionError::Save("backend unavailable")
  }
  self.saved.push({
    messages: session.messages.copy(),
    metadata: session.metadata.copy(),
  })
}

///|
fn truncate_test_session() -> @types.Session {
  {
    messages: [
      tk_user_msg("hello"),
      truncate_first_assistant(),
      tk_user_msg("world"),
      @kernel.AssistantMessage(
        content=[@kernel.Text("second")],
        tool_calls=[],
        reasoning=None,
        finish_reason=@kernel.Stop,
      ),
    ],
    metadata: Map::from_array([("lineage", Json::string("kept"))]),
  }
}

///|
/// The assistant reply persisted by turn 1 in the scripted two-turn history.
fn truncate_first_assistant() -> @kernel.Message {
  @kernel.AssistantMessage(
    content=[@kernel.Text("first")],
    tool_calls=[],
    reasoning=None,
    finish_reason=@kernel.Stop,
  )
}

// ---------------------------------------------------------------------------
// Default impl: load → slice → full save, metadata preserved.
// ---------------------------------------------------------------------------

///|
async test "rewind_truncate_default_impl_keeps_prefix_and_metadata" {
  let store = TruncateFallbackStore::make(truncate_test_session())
  store.truncate("s1", 2)
  assert_eq(store.saved.length(), 1)
  let saved = store.saved[0]
  assert_eq(saved.messages.length(), 2)
  assert_true(saved.messages[0] == tk_user_msg("hello"))
  assert_true(saved.messages[1] == truncate_first_assistant())
  assert_true(saved.metadata["lineage"] == Json::string("kept"))
}

///|
async test "rewind_truncate_default_impl_clamps_from_index" {
  let zero = TruncateFallbackStore::make(truncate_test_session())
  zero.truncate("s1", 0)
  assert_eq(zero.saved[0].messages.length(), 0)
  let over = TruncateFallbackStore::make(truncate_test_session())
  over.truncate("s1", 99)
  assert_eq(over.saved[0].messages.length(), 4)
  let negative = TruncateFallbackStore::make(truncate_test_session())
  negative.truncate("s1", -3)
  assert_eq(negative.saved[0].messages.length(), 0)
}

///|
async test "rewind_truncate_default_impl_labels_load_and_save_failures" {
  let store = TruncateFallbackStore::make(truncate_test_session())
  store.fail_load = true
  let load_result = Ok(store.truncate("s1", 1)) catch { e => Err(e) }
  match load_result {
    Err(@error.SessionError::Load(msg)) =>
      assert_true(msg.contains("operation='truncate'"))
    _ => fail("expected SessionError::Load from truncate")
  }
  store.fail_load = false
  store.fail_save = true
  let save_result = Ok(store.truncate("s1", 1)) catch { e => Err(e) }
  match save_result {
    Err(@error.SessionError::Save(msg)) =>
      assert_true(msg.contains("operation='truncate'"))
    _ => fail("expected SessionError::Save from truncate")
  }
}

// ---------------------------------------------------------------------------
// RecordingSessionStore: in-memory slice + OpTruncate recording.
// ---------------------------------------------------------------------------

///|
async test "rewind_recording_store_truncate_slices_and_records_op" {
  let store = RecordingSessionStore()
  store.seed("s1", truncate_test_session())
  store.truncate("s1", 1)
  let mut recorded = 0
  for op in store.ops() {
    match op {
      OpTruncate(id~, from_index~, result~) => {
        assert_eq(id, "s1")
        assert_eq(from_index, 1)
        match result {
          Ok(_) => ()
          Err(error) => fail("expected successful truncate, got \{error}")
        }
        recorded = recorded + 1
      }
      _ => ()
    }
  }
  assert_eq(recorded, 1)
  let session = store.load("s1")
  assert_eq(session.messages.length(), 1)
  assert_true(session.messages[0] == tk_user_msg("hello"))
  assert_true(session.metadata["lineage"] == Json::string("kept"))
}

// ---------------------------------------------------------------------------
// Agent end-to-end: truncate between turns rewires the next turn's prompt.
// ---------------------------------------------------------------------------

///|
async test "rewind_truncate_changes_history_seen_by_next_agent_turn" {
  let model = ScriptedModel([
    Respond(tk_stop_response("first")),
    Respond(tk_stop_response("second")),
    Respond(tk_stop_response("third")),
  ])
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=tk_config(),
  )
  let _ = agent.run_turn(tk_user_msg("hello"), "s1")
  let _ = agent.run_turn(tk_user_msg("world"), "s1")
  // Rewind to just after the first user/assistant pair.
  store.truncate("s1", 2)
  let _ = agent.run_turn(tk_user_msg("more"), "s1")
  assert_eq(model.received_messages.length(), 3)
  let prompt = model.received_messages[2]
  assert_eq(prompt.length(), 3)
  assert_true(prompt[0] == tk_user_msg("hello"))
  assert_true(prompt[1] == truncate_first_assistant())
  assert_true(prompt[2] == tk_user_msg("more"))
}
