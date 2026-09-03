///|
/// Chunk-dispatch tests: verify that `StreamChunk` telemetry is buffered,
/// drained in FIFO order, flushed before terminal events, and decoupled from
/// the model read loop.

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
