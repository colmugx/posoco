///|
/// Chunk-dispatch tests: verify that `StreamChunk` telemetry is buffered,
/// drained in FIFO order, flushed before terminal events, and decoupled from
/// the model read loop.

///|
/// Gate the first model hook after the Puppet has accepted the turn. The
/// queue rendezvous makes the concurrent-turn regression deterministic while
/// keeping the first turn inside the pump.
struct TurnLoopGate {
  entered : @aqueue.Queue[Int]
  release : @aqueue.Queue[Int]
}

///|
impl @port.PipelineHook for TurnLoopGate with fn before_model(
  self : TurnLoopGate,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] {
  self.entered.put(1) catch {
    _ => raise Aborted(reason="turn gate enter failed")
  }
  ignore(
    self.release.get() catch {
      _ => raise Aborted(reason="turn gate release failed")
    },
  )
  messages
}

///|
/// Model fixture that yields after every stream callback. This lets the
/// dispatcher drain one chunk at a time, so the regression observes ordering
/// independently of scheduler timing at the model-response boundary.
struct YieldingStreamModel {
  chunks : Array[@types.StreamChunk]
  response : @kernel.ModelCallResult
  mut calls : Int
}

///|
fn YieldingStreamModel::YieldingStreamModel(
  chunks : Array[@types.StreamChunk],
  response : @kernel.ModelCallResult,
) -> YieldingStreamModel {
  { chunks, response, calls: 0, }
}

///|
fn YieldingStreamModel::call_count(self : YieldingStreamModel) -> Int {
  self.calls
}

///|
impl @port.ModelPort for YieldingStreamModel with fn chat(
  self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  self.calls = self.calls + 1
  match stream {
    Stream(callback) =>
      for chunk in self.chunks {
        callback(chunk)
        @async.pause() catch {
          _ => raise ResponseParse("stream fixture pause failed")
        }
      }
    NoStream => ()
  }
  self.response
}

///|
impl @port.ModelPort for YieldingStreamModel with fn compact(
  _self : YieldingStreamModel,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  raise ResponseParse("YieldingStreamModel does not implement compact")
}

///|
impl @port.ModelPort for YieldingStreamModel with fn provider_config(
  _self : YieldingStreamModel,
) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
async test "p2 concurrent run_turn rejects before side effects and preserves first stream" {
  let chunks = [
    @types.TextDelta(token="p2-0"),
    @types.TextDelta(token="p2-1"),
    @types.TextDelta(token="p2-2"),
  ]
  let model = YieldingStreamModel(chunks, tk_stop_response("done"))
  let store = RecordingSessionStore()
  let observer = RecordingObserver()
  let entered : @aqueue.Queue[Int] = Queue(kind=Unbounded)
  let release : @aqueue.Queue[Int] = Queue(kind=Unbounded)
  let gate = TurnLoopGate::{ entered, release, }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", hooks=[gate], sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  @async.with_task_group(group => {
    let first = group.spawn(async fn() {
      agent.run_turn(tk_user_msg("first"), "p2-session")
    })
    // before_model runs after Puppet::prompt acquired its lease, so the
    // second invocation exercises the Agent guard rather than a race in the
    // internal lease implementation.
    ignore(entered.get())
    assert_eq(model.call_count(), 0)

    // The first task is suspended at the gate, so this direct call is a
    // concurrent invocation while retaining the typed AgentError result.
    let second_result = Ok(agent.run_turn(tk_user_msg("second"), "p2-session")) catch {
      error => Err(error)
    }
    match second_result {
      Err(Runtime(InvocationFailed(reason))) =>
        assert_true(reason.contains("agent turn busy"))
      _ => fail("concurrent run_turn must fail with the typed busy error")
    }

    // The rejected call must not emit a turn event or load the session.
    let events_before = observer.events()
    let mut starts_before = 0
    let mut terminal_before = 0
    for event in events_before {
      match event {
        TurnStarted => starts_before = starts_before + 1
        TurnCompleted | TurnFailed(_) => terminal_before = terminal_before + 1
        _ => ()
      }
    }
    assert_eq(starts_before, 1)
    assert_eq(terminal_before, 0)
    assert_eq(model.call_count(), 0)
    let mut loads = 0
    for operation in store.ops() {
      match operation {
        OpLoad(..) => loads = loads + 1
        _ => ()
      }
    }
    assert_eq(loads, 1)

    release.put(1)
    let first_result = first.wait()
    assert_eq(first_result.final_session_id, "p2-session")
  })

  let events = observer.events()
  let mut terminal_count = 0
  for event in events {
    match event {
      TurnCompleted | TurnFailed(_) => terminal_count = terminal_count + 1
      _ => ()
    }
  }
  assert_eq(terminal_count, 1)
  assert_eq(model.call_count(), 1)
  let chunk_events = events.filter(fn(event) { event is StreamChunkReceived(_) })
  assert_eq(chunk_events.length(), chunks.length())
  for i = 0; i < chunks.length(); i = i + 1 {
    match chunk_events[i] {
      StreamChunkReceived(chunk~) =>
        match chunk {
          TextDelta(token~) => assert_eq(token, "p2-\{i}")
          _ => fail("expected text stream chunk")
        }
      _ => fail("expected the first turn's streamed chunks in FIFO order")
    }
  }
  let completed_idx = events.search_by(fn(event) { event is TurnCompleted })
  guard completed_idx is Some(idx) else { fail("first turn must complete") }
  for event in chunk_events {
    let chunk_idx = events.search_by(fn(candidate) { candidate == event })
    guard chunk_idx is Some(cidx) else { fail("chunk index not found") }
    if cidx >= idx {
      fail("stream chunk must precede the sole terminal event")
    }
  }
}

///|
/// Cancellation must release the synchronous Agent guard even when the turn
/// is suspended inside the Puppet path. The release token is deliberately
/// withheld until the first task has been cancelled; the second turn uses the
/// same Agent and gate to prove no stale `turn_active` bit remains.
async test "p2 cancelled turn releases Agent guard for the next turn" {
  let model = ScriptedModel([Respond(tk_stop_response("after-cancel"))])
  let store = RecordingSessionStore()
  let entered : @aqueue.Queue[Int] = Queue(kind=Unbounded)
  let release : @aqueue.Queue[Int] = Queue(kind=Unbounded)
  let gate = TurnLoopGate::{ entered, release, }
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", hooks=[gate], sessions=[store]),
    ],
    config=tk_config(),
  )
  @async.with_task_group(group => {
    let first = group.spawn(
      async fn() {
        let result : Result[@types.TurnResult, Error] = Ok(
          agent.run_turn(tk_user_msg("cancel-me"), "p2-cancel"),
        ) catch {
          error => Err(error)
        }
        result
      },
      allow_failure=true,
    )
    ignore(entered.get())
    first.cancel()
    let first_result = first.wait()
    match first_result {
      Err(_) => ()
      Ok(_) => fail("cancelled turn unexpectedly completed")
    }

    // The cancelled gate no longer owns the release wait. Supplying the
    // token lets the same hook admit the second turn if the Agent guard was
    // correctly released.
    release.put(1)
    let second_result : Result[@types.TurnResult, @error.AgentError] = Ok(
      agent.run_turn(tk_user_msg("after-cancel"), "p2-cancel"),
    ) catch {
      error => Err(error)
    }
    match second_result {
      Ok(result) => assert_eq(result.final_session_id, "p2-cancel")
      Err(Runtime(InvocationFailed(_))) =>
        fail("turn guard was not released after cancellation")
      Err(_) => fail("second turn failed after cancellation")
    }
  })
}

///|
/// A streaming turn still delivers every chunk to observers, in order, and
/// every chunk arrives before `TurnCompleted`.
async test "chunk dispatch: streaming turn delivers chunks in order before TurnCompleted" {
  let chunks = []
  for i in 0..<10 {
    chunks.push(@types.TextDelta(token="t\{i}"))
  }
  let model = ScriptedModel([Stream(chunks~, response=tk_stop_response("ok"))])
  let store = RecordingSessionStore()
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let _ = agent.run_turn(tk_user_msg("hello"), "s1")
  let events = observer.events()
  guard events[0] is TurnStarted else {
    fail("first event must be TurnStarted")
  }
  guard events[events.length() - 1] is TurnCompleted else {
    fail("last event must be TurnCompleted")
  }
  let chunk_events = events.filter(fn(e) { e is StreamChunkReceived(_) })
  assert_eq(chunk_events.length(), 10)
  for i = 0; i < 10; i = i + 1 {
    match chunk_events[i] {
      StreamChunkReceived(chunk~) =>
        match chunk {
          TextDelta(token~) => assert_eq(token, "t\{i}")
          _ => fail("expected TextDelta")
        }
      _ => fail("expected StreamChunkReceived at index \{i}")
    }
  }
  // Every chunk must precede TurnCompleted.
  let completed_index = events.search_by(fn(e) { e is TurnCompleted })
  guard completed_index is Some(idx) else { fail("TurnCompleted not found") }
  for chunk_event in chunk_events {
    let chunk_idx = events.search_by(fn(e) { e == chunk_event })
    guard chunk_idx is Some(cidx) else { fail("chunk index not found") }
    if cidx >= idx {
      fail("chunk observed at or after TurnCompleted")
    }
  }
}

///|
/// The dispatcher's `enqueue` is synchronous and returns immediately: it does
/// not wait for observers. This white-box test exercises the queue directly.
test "chunk dispatch: enqueue does not call observer synchronously" {
  let observer = RecordingObserver()
  let dispatcher = ChunkDispatcher([observer])
  dispatcher.enqueue(TextDelta(token="x"))
  assert_eq(observer.events().length(), 0)
}

///|
/// When the buffer overflows, the oldest chunks are dropped and a single
/// `StreamChunksDropped` event is emitted before the terminal event.
async test "chunk dispatch: overflow drops oldest and emits StreamChunksDropped" {
  // Feed enough chunks to overflow the default 1024 capacity several times.
  let total_chunks = 2500
  let chunks = []
  for i in 0..<total_chunks {
    chunks.push(@types.TextDelta(token="c\{i}"))
  }
  let model = ScriptedModel([Stream(chunks~, response=tk_stop_response("ok"))])
  let store = RecordingSessionStore()
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let _ = agent.run_turn(tk_user_msg("hello"), "s1")
  let events = observer.events()
  // Terminal event is last.
  guard events[events.length() - 1] is TurnCompleted else {
    fail("last event must be TurnCompleted")
  }
  // Some chunks were delivered.
  let chunk_events = events.filter(fn(e) { e is StreamChunkReceived(_) })
  assert_true(chunk_events.length() > 0)
  assert_true(chunk_events.length() <= 1024)
  // A drop event was synthesized and appears before TurnCompleted.
  let drop_events = events.filter(fn(e) { e is StreamChunksDropped(_) })
  assert_eq(drop_events.length(), 1)
  match drop_events[0] {
    StreamChunksDropped(count~) => {
      let delivered = chunk_events.length()
      assert_eq(count + delivered, total_chunks)
    }
    _ => fail("expected StreamChunksDropped")
  }
  // The drop event must come before TurnCompleted.
  let drop_idx = events.search_by(fn(e) { e is StreamChunksDropped(_) })
  let completed_idx = events.search_by(fn(e) { e is TurnCompleted })
  guard drop_idx is Some(didx) && completed_idx is Some(cidx) else {
    fail("drop or completed index missing")
  }
  if didx >= cidx {
    fail("StreamChunksDropped must precede TurnCompleted")
  }
  // Delivered chunks preserve FIFO order (they are the newest ones).
  for i = 0; i < chunk_events.length(); i = i + 1 {
    match chunk_events[i] {
      StreamChunkReceived(chunk~) =>
        match chunk {
          TextDelta(token~) =>
            assert_eq(token, "c\{total_chunks - chunk_events.length() + i}")
          _ => fail("expected TextDelta")
        }
      _ => fail("expected chunk")
    }
  }
}

///|
/// A failed turn must not leave buffered chunks after TurnFailed. The model
/// streams chunks on the first call, requests a tool so a second call is made,
/// then fails on that second call.
async test "chunk dispatch: flush drains chunks before TurnFailed" {
  let chunks = []
  for i in 0..<10 {
    chunks.push(@types.TextDelta(token="f\{i}"))
  }
  let tool_def = tk_tool_def("noop", "no-op tool")
  let tool = RecordingToolProvider(
    [tool_def],
    Map::from_array([("noop", OutcomeOk(tk_ok_result("done")))]),
  )
  let model = ScriptedModel([
    Stream(
      chunks~,
      response=tk_tool_call_response(
        "noop",
        "call_1",
        Json::object(Map::from_array([])),
      ),
    ),
    Fail(Transport("boom")),
  ])
  let store = RecordingSessionStore()
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="tools", tools=[tool]),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("hello"), "s1")) catch {
    e => Err(e)
  }
  // The turn should fail.
  guard result is Err(_) else { fail("expected turn to fail") }
  let events = observer.events()
  // Find TurnFailed.
  let failed_idx = events.search_by(fn(e) { e is TurnFailed(_) })
  guard failed_idx is Some(fidx) else { fail("TurnFailed not found") }
  // Some chunks were delivered before the failure.
  let chunk_events = events.filter(fn(e) { e is StreamChunkReceived(_) })
  assert_eq(chunk_events.length(), 10)
  // No chunk may appear at or after TurnFailed.
  for i, event in events {
    if i >= fidx && event is StreamChunkReceived(_) {
      fail("chunk observed at or after TurnFailed")
    }
  }
}

///|
/// R5-w2 duplicate-chunk investigation: adjacent identical tokens (CJK
/// punctuation, backticks) are legal model output and must cross the dispatch
/// path verbatim — one observer event per streamed chunk, no dedup and no
/// duplication. A duplicate seen in outbound telemetry therefore enters at or
/// below the ModelPort stream boundary, never in posoco core.
async test "chunk dispatch: adjacent identical tokens pass through 1:1 without dedup or duplication" {
  let sent = ["、", "、", "。", "。", "`", "`", "`"]
  let chunks = []
  for token in sent {
    chunks.push(@types.TextDelta(token~))
  }
  let model = ScriptedModel([Stream(chunks~, response=tk_stop_response("ok"))])
  let store = RecordingSessionStore()
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=tk_config(),
  )
  let _ = agent.run_turn(tk_user_msg("hello"), "s1")
  let chunk_events = observer
    .events()
    .filter(fn(e) { e is StreamChunkReceived(_) })
  assert_eq(chunk_events.length(), sent.length())
  for i = 0; i < sent.length(); i = i + 1 {
    match chunk_events[i] {
      StreamChunkReceived(chunk~) =>
        match chunk {
          TextDelta(token~) => assert_eq(token, sent[i])
          _ => fail("expected TextDelta")
        }
      _ => fail("expected StreamChunkReceived at index \{i}")
    }
  }
}

///|
/// Direct white-box drain test: a small dispatcher delivers queued events in
/// FIFO order and terminates when the queue is closed.
async test "chunk dispatch: drain_loop delivers queued events in order" {
  let observer = RecordingObserver()
  let dispatcher = ChunkDispatcher([observer])
  for i in 0..<5 {
    dispatcher.enqueue(TextDelta(token="d\{i}"))
  }
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() { dispatcher.drain_loop() })
    // Yield so the drain task processes the queue, then close it.
    @async.pause()
    dispatcher.close()
  })
  let events = observer.events()
  assert_eq(events.length(), 5)
  for i = 0; i < 5; i = i + 1 {
    match events[i] {
      StreamChunkReceived(chunk~) =>
        match chunk {
          TextDelta(token~) => assert_eq(token, "d\{i}")
          _ => fail("expected TextDelta")
        }
      _ => fail("expected StreamChunkReceived at index \{i}")
    }
  }
}
