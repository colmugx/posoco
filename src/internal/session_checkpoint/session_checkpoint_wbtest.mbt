///|
/// Direct subscriber tests for the committed-envelope checkpoint projection.
/// They drive only the exported `EventSubscriber` surface over real
/// `SessionPort` doubles: cursor continuity, the dirty gate across a restart,
/// all-store dispatch with first-failure ordering, and per-store snapshots.

///|
/// Session store double that records every checkpoint it receives.
priv struct RecordingStore {
  checkpoints : Array[@port.SessionCheckpoint]
}

///|
impl @port.SessionPort for RecordingStore with fn load(_self, _id : String) -> @types.Session raise @error.SessionError {
  raise Save("RecordingStore has no canonical body")
}

///|
impl @port.SessionPort for RecordingStore with fn save(
  _self,
  _id : String,
  _session : @types.Session,
) -> Unit raise @error.SessionError {
  raise Save("RecordingStore only accepts checkpoints")
}

///|
impl @port.SessionPort for RecordingStore with fn checkpoint(
  self,
  _id : String,
  checkpoint : @port.SessionCheckpoint,
) -> Unit raise @error.SessionError {
  self.checkpoints.push({
    from_index: checkpoint.from_index,
    messages: checkpoint.messages.copy(),
    metadata: checkpoint.metadata,
  })
}

///|
/// Session store double that refuses every checkpoint, standing in for a store
/// whose write failed after the event already committed.
priv struct FailingStore {
  attempts : Ref[Int32]
}

///|
impl @port.SessionPort for FailingStore with fn load(_self, _id : String) -> @types.Session raise @error.SessionError {
  raise Save("FailingStore has no canonical body")
}

///|
impl @port.SessionPort for FailingStore with fn save(
  _self,
  _id : String,
  _session : @types.Session,
) -> Unit raise @error.SessionError {
  raise Save("FailingStore rejects every write")
}

///|
impl @port.SessionPort for FailingStore with fn checkpoint(
  self,
  _id : String,
  _checkpoint : @port.SessionCheckpoint,
) -> Unit raise @error.SessionError {
  self.attempts.val = self.attempts.val + 1
  raise Save("checkpoint refused")
}

///|
fn checkpoint_envelope(
  event : @kernel_exec.KernelEvent,
) -> @puppetry.EventEnvelope {
  @puppetry.EventEnvelope::EventEnvelope(
    run_id=@kernel.RunId::unchecked("run_checkpoint"),
    turn_id=@kernel.TurnId::unchecked("turn_checkpoint"),
    session_id=@kernel.SessionId::unchecked("sess_checkpoint"),
    seq=1,
    committed_revision=0,
    event~,
  )
}

///|
fn committed_tool_event(id : String) -> @kernel_exec.KernelEvent {
  ToolCompleted(
    call={
      call_id: @kernel.CallId::unchecked(id),
      name: @kernel.ToolName::unchecked("echo"),
      arguments: Json::null(),
    },
    outcome=Success(content="ok", structured=None),
    parent_effect_id=None,
  )
}

///|
async test "session checkpoint: consecutive completions advance the cursor" {
  let store = RecordingStore::{ checkpoints: [], }
  let progress = @session_state.SessionProgress::SessionProgress()
  let subscriber = SessionCheckpointSubscriber([store], progress)
  subscriber.on_event(checkpoint_envelope(committed_tool_event("call_1")))
  subscriber.on_event(checkpoint_envelope(committed_tool_event("call_2")))
  assert_eq(store.checkpoints.map(fn(c) { c.from_index }), [0, 1])
  assert_eq(progress.cursor_or_zero("sess_checkpoint"), 2)
  for checkpoint in store.checkpoints {
    assert_eq(checkpoint.messages.length(), 1)
    assert_true(checkpoint.metadata is None)
  }
}

///|
async test "session checkpoint: a rewrite keeps the dirty gate across RunStarted" {
  let store = RecordingStore::{ checkpoints: [], }
  let progress = @session_state.SessionProgress::SessionProgress()
  let subscriber = SessionCheckpointSubscriber([store], progress)
  subscriber.on_event(
    checkpoint_envelope(
      TranscriptRewritten(
        messages_before=3,
        messages_after=2,
        reason="hook rewrite",
      ),
    ),
  )
  // A new run does not clear the dirty mark: only the terminal full save
  // re-establishes a canonical prefix, so nothing is projected here.
  subscriber.on_event(
    checkpoint_envelope(
      RunStarted(details={
        run_id: @kernel.RunId::unchecked("run_checkpoint"),
        session_id: @kernel.SessionId::unchecked("sess_checkpoint"),
      }),
    ),
  )
  subscriber.on_event(checkpoint_envelope(committed_tool_event("call_dirty")))
  assert_eq(store.checkpoints.length(), 0)
  assert_eq(progress.cursor_or_zero("sess_checkpoint"), 0)
  assert_true(progress.is_dirty("sess_checkpoint"))
}

///|
async test "session checkpoint: every store runs, first failure blocks the advance" {
  let ok_store = RecordingStore::{ checkpoints: [], }
  let attempts : Ref[Int32] = Ref(0)
  let failing = FailingStore::{ attempts, }
  let progress = @session_state.SessionProgress::SessionProgress()
  let subscriber = SessionCheckpointSubscriber([ok_store, failing], progress)
  let outcome : Result[Unit, @puppetry.SubscriberError] = try {
    subscriber.on_event(checkpoint_envelope(committed_tool_event("call_fail")))
    Ok(())
  } catch {
    error => Err(error)
  }
  guard outcome is Err(Internal(detail~, ..)) else {
    fail("a refused checkpoint must fail the subscriber")
  }
  assert_true(detail.contains("sess_checkpoint"))
  // Both stores were dispatched (the healthy one recorded the append), but the
  // cursor stays put so the next boundary retries from the same position.
  assert_eq(ok_store.checkpoints.map(fn(c) { c.from_index }), [0])
  assert_eq(attempts.val, 1)
  assert_eq(progress.cursor_or_zero("sess_checkpoint"), 0)
}

///|
async test "session checkpoint: an empty store list never advances" {
  let progress = @session_state.SessionProgress::SessionProgress()
  let subscriber = SessionCheckpointSubscriber([], progress)
  subscriber.on_event(checkpoint_envelope(committed_tool_event("call_none")))
  assert_eq(progress.cursor_or_zero("sess_checkpoint"), 0)
}

///|
async test "session checkpoint: each store receives its own message snapshot" {
  let first = RecordingStore::{ checkpoints: [], }
  let second = RecordingStore::{ checkpoints: [], }
  let progress = @session_state.SessionProgress::SessionProgress()
  let subscriber = SessionCheckpointSubscriber([first, second], progress)
  subscriber.on_event(
    checkpoint_envelope(committed_tool_event("call_snapshot")),
  )
  assert_eq(first.checkpoints.length(), 1)
  assert_eq(second.checkpoints.length(), 1)
  // The two arrays are independent copies: mutating one store's received tail
  // cannot reach the other store or the caller's event.
  first.checkpoints[0].messages.clear()
  assert_eq(second.checkpoints[0].messages.length(), 1)
}
