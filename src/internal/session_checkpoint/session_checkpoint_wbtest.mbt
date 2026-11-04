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
/// A steer committed at a step boundary: the transcript grows by one
/// user-authored message, so the projection must append it incrementally
/// instead of waiting for the terminal full save.
fn appended_user_event(text : String) -> @kernel_exec.KernelEvent {
  UserMessageAppended(
    command_id="steer_1",
    message=UserMessage(content=[Text(text)]),
  )
}

///|
async test "session checkpoint: a steer message is projected incrementally" {
  let store = RecordingStore::{ checkpoints: [], }
  let progress = @session_state.SessionProgress::SessionProgress()
  let subscriber = SessionCheckpointSubscriber([store], progress)
  subscriber.on_event(checkpoint_envelope(committed_tool_event("call_1")))
  subscriber.on_event(
    checkpoint_envelope(appended_user_event("keep to analysis only")),
  )
  assert_eq(store.checkpoints.map(fn(c) { c.from_index }), [0, 1])
  assert_eq(progress.cursor_or_zero("sess_checkpoint"), 2)
  let steered = store.checkpoints[1]
  assert_eq(steered.messages.length(), 1)
  guard steered.messages[0] is UserMessage(content~) else {
    fail("expected the steer as a user message")
  }
  guard content[0] is Text(text) else { fail("expected text content") }
  assert_eq(text, "keep to analysis only")
}

///|
async test "session checkpoint: a dirty session skips the steer projection" {
  let store = RecordingStore::{ checkpoints: [], }
  let progress = @session_state.SessionProgress::SessionProgress()
  let subscriber = SessionCheckpointSubscriber([store], progress)
  subscriber.on_event(
    checkpoint_envelope(
      TranscriptRewritten(messages_before=3, messages_after=2, reason="compact"),
    ),
  )
  subscriber.on_event(
    checkpoint_envelope(appended_user_event("keep to analysis only")),
  )
  // The terminal full save re-establishes the canonical prefix; projecting
  // here would append onto a prefix the store no longer matches.
  assert_eq(store.checkpoints.length(), 0)
  assert_eq(progress.cursor_or_zero("sess_checkpoint"), 0)
}
