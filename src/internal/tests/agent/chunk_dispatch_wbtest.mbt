///|
/// Chunk-dispatch tests: verify that `StreamChunk` telemetry is buffered,
/// drained in FIFO order, flushed before terminal events, and decoupled from
/// the model read loop.

///|
/// The operation projection (started/settled) brackets every turn stream;
/// position assertions below are about the TURN event sequence.
fn without_operation_events(
  events : Array[@types.TurnEvent],
) -> Array[@types.TurnEvent] {
  events.filter(fn(event) {
    match event {
      Custom(source~, ..) => source != "posoco.operation"
      _ => true
    }
  })
}

///|
/// Gate the first model hook after the Puppet has accepted the turn. The
/// queue rendezvous makes the concurrent-turn regression deterministic while
/// keeping the first turn inside the pump.
struct TurnLoopGate {
  entered : @aqueue.Queue[Int32]
  release : @aqueue.Queue[Int32]
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
async test "chunk dispatch: streaming turn delivers chunks in order before TurnCompleted" {
  let chunks = []
  for i in 0..<10 {
    chunks.push(@types.TextDelta(token="t\{i}"))
  }
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Stream(
      chunks~,
      response=@test_support.tk_stop_response("ok"),
    ),
  ])
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let _ = agent.run_turn(@test_support.tk_user_msg("hello"), "s1")
  let events = without_operation_events(observer.events())
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
/// When the buffer overflows, the oldest chunks are dropped and a single
/// `StreamChunksDropped` event is emitted before the terminal event.
async test "chunk dispatch: overflow drops oldest and emits StreamChunksDropped" {
  // Feed enough chunks to overflow the default 1024 capacity several times.
  let total_chunks = 2500
  let chunks = []
  for i in 0..<total_chunks {
    chunks.push(@types.TextDelta(token="c\{i}"))
  }
  let model = @test_support.ScriptedModel([
    Stream(chunks~, response=@test_support.tk_stop_response("ok")),
  ])
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let _ = agent.run_turn(@test_support.tk_user_msg("hello"), "s1")
  let events = without_operation_events(observer.events())
  // Terminal event is last.
  guard events[events.length() - 1] is TurnCompleted else {
    fail("last event must be TurnCompleted")
  }
  // The synchronous 2500-chunk burst against the 1024-slot queue guarantees
  // overflow regardless of drain interleaving.
  let chunk_events = events.filter(fn(e) { e is StreamChunkReceived(_) })
  assert_true(chunk_events.length() > 0)
  assert_true(chunk_events.length() < total_chunks)
  // Total dropped + delivered must account for every chunk.
  let drop_events = events.filter(fn(e) { e is StreamChunksDropped(_) })
  assert_true(drop_events.length() >= 1)
  let mut total_dropped = 0
  for event in drop_events {
    match event {
      StreamChunksDropped(count~) => total_dropped = total_dropped + count
      _ => fail("expected StreamChunksDropped")
    }
  }
  assert_eq(total_dropped + chunk_events.length(), total_chunks)
  // The drop event must come before TurnCompleted.
  let drop_idx = events.search_by(fn(e) { e is StreamChunksDropped(_) })
  let completed_idx = events.search_by(fn(e) { e is TurnCompleted })
  guard drop_idx is Some(didx) && completed_idx is Some(cidx) else {
    fail("drop or completed index missing")
  }
  if didx >= cidx {
    fail("StreamChunksDropped must precede TurnCompleted")
  }
  // Delivered chunks preserve production (FIFO) order; gaps are allowed.
  let source_tokens : Array[String] = []
  for chunk in chunks {
    match chunk {
      TextDelta(token~) => source_tokens.push(token)
      _ => fail("expected source TextDelta")
    }
  }
  let mut cursor = 0
  for i = 0; i < chunk_events.length(); i = i + 1 {
    match chunk_events[i] {
      StreamChunkReceived(chunk~) =>
        match chunk {
          TextDelta(token~) => {
            let mut found = false
            while cursor < total_chunks {
              let current = source_tokens[cursor]
              cursor = cursor + 1
              if current == token {
                found = true
                break
              }
            }
            if !found {
              fail("delivered chunk #\{i} breaks production order")
            }
          }
          _ => fail("expected TextDelta")
        }
      _ => fail("expected chunk")
    }
  }
  // The newest chunk is never a drop victim: it is enqueued last.
  match chunk_events[chunk_events.length() - 1] {
    StreamChunkReceived(chunk=TextDelta(token~)) =>
      assert_eq(token, "c\{total_chunks - 1}")
    _ => fail("expected final delivered chunk to be the newest")
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
  let tool_def = @test_support.tk_tool_def("noop", "no-op tool")
  let tool = @test_support.RecordingToolProvider(
    [tool_def],
    Map::from_array([("noop", OutcomeOk(@test_support.tk_ok_result("done")))]),
  )
  let model = @test_support.ScriptedModel([
    Stream(
      chunks~,
      response=@test_support.tk_tool_call_response(
        "noop",
        "call_1",
        Json::object(Map::from_array([])),
      ),
    ),
    Fail(Transport("boom")),
  ])
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="tools", tools=[tool]),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let result = Ok(agent.run_turn(@test_support.tk_user_msg("hello"), "s1")) catch {
    e => Err(e)
  }
  // The turn should fail with the model transport error, not a swallowed one.
  guard result is Err(Model(msg)) else { fail("expected turn to fail") }
  assert_true(msg.contains("boom"))
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
/// Duplicate-chunk invariant: adjacent identical tokens are legal model
/// output and must cross the dispatch path verbatim.
async test "chunk dispatch: adjacent identical tokens pass through 1:1 without dedup or duplication" {
  let sent = ["、", "、", "。", "。", "`", "`", "`"]
  let chunks = []
  for token in sent {
    chunks.push(@types.TextDelta(token~))
  }
  let model = @test_support.ScriptedModel([
    Stream(chunks~, response=@test_support.tk_stop_response("ok")),
  ])
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let _ = agent.run_turn(@test_support.tk_user_msg("hello"), "s1")
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
/// Observer double that keeps the scope stamped on every turn event.
struct ChunkScopeObserver {
  received : Array[(@types.EventScope?, @types.TurnEvent)]
}

///|
impl @port.Observer for ChunkScopeObserver with fn on_event(
  self,
  scope,
  event : @types.TurnEvent,
) -> Unit {
  self.received.push((scope, event))
}

///|
fn ChunkScopeObserver::turn_events(
  self : ChunkScopeObserver,
) -> Array[(@types.EventScope?, @types.TurnEvent)] {
  self.received.filter(fn(entry) {
    match entry.1 {
      Custom(source~, ..) => source != "posoco.operation"
      _ => true
    }
  })
}

///|
/// The scope's `TurnStarted` identity, asserted to be present.
fn turn_started_scope(
  events : Array[(@types.EventScope?, @types.TurnEvent)],
) -> @types.EventScope raise {
  guard events[0].1 is TurnStarted else {
    fail("first event must be TurnStarted")
  }
  guard events[0].0 is Some(scope) else {
    fail("TurnStarted must carry Some(scope)")
  }
  scope
}

///|
/// A streamed turn attributes every chunk to its own run, in production
/// order, before `ModelResponseReceived`.
async test "chunk dispatch: chunks carry the TurnStarted scope and precede the final response" {
  let chunks = []
  for i in 0..<5 {
    chunks.push(@types.TextDelta(token="s\{i}"))
  }
  let model = @test_support.ScriptedModel([
    Stream(chunks~, response=@test_support.tk_stop_response("ok")),
  ])
  let observer = ChunkScopeObserver::{ received: [], }
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let _ = agent.run_turn(@test_support.tk_user_msg("hello"), "s_scope")
  let events = observer.turn_events()
  let turn_scope = turn_started_scope(events)
  assert_eq(turn_scope.session_id.to_string(), "s_scope")
  let response_idx = events.search_by(fn(entry) {
    entry.1 is ModelResponseReceived(_)
  })
  guard response_idx is Some(ridx) else {
    fail("ModelResponseReceived not found")
  }
  let completed_idx = events.search_by(fn(entry) { entry.1 is TurnCompleted })
  guard completed_idx is Some(cidx) else { fail("TurnCompleted not found") }
  assert_true(ridx < cidx)
  let chunk_tokens : Array[String] = []
  for i, entry in events {
    match entry.1 {
      StreamChunkReceived(chunk=TextDelta(token~)) => {
        assert_eq(entry.0, Some(turn_scope))
        chunk_tokens.push(token)
        if i >= ridx {
          fail("stream chunk observed at or after ModelResponseReceived")
        }
      }
      StreamChunkReceived(_) => fail("expected TextDelta")
      _ => ()
    }
  }
  assert_eq(chunk_tokens, ["s0", "s1", "s2", "s3", "s4"])
}

///|
/// Two turns on one Agent are two runs: each turn's chunks carry its own
/// scope.
async test "chunk dispatch: consecutive turns keep separate chunk scopes" {
  let model = @test_support.ScriptedModel([
    Stream(
      chunks=[
        @types.TextDelta(token="first-0"),
        @types.TextDelta(token="first-1"),
      ],
      response=@test_support.tk_stop_response("first"),
    ),
    Stream(
      chunks=[@types.TextDelta(token="second-0")],
      response=@test_support.tk_stop_response("second"),
    ),
  ])
  let observer = ChunkScopeObserver::{ received: [], }
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let _ = agent.run_turn(@test_support.tk_user_msg("one"), "s_turns")
  let _ = agent.run_turn(@test_support.tk_user_msg("two"), "s_turns")
  let started : Array[@types.EventScope] = []
  let per_turn_chunks : Array[Array[@types.EventScope?]] = []
  for entry in observer.turn_events() {
    match entry.1 {
      TurnStarted => {
        guard entry.0 is Some(scope) else {
          fail("TurnStarted must carry Some(scope)")
        }
        started.push(scope)
        per_turn_chunks.push([])
      }
      StreamChunkReceived(_) => {
        if per_turn_chunks.length() == 0 {
          fail("chunk telemetry before the first TurnStarted")
        }
        per_turn_chunks[per_turn_chunks.length() - 1].push(entry.0)
      }
      _ => ()
    }
  }
  assert_eq(started.length(), 2)
  assert_eq(per_turn_chunks[0].length(), 2)
  assert_eq(per_turn_chunks[1].length(), 1)
  assert_eq(per_turn_chunks[0][0], Some(started[0]))
  assert_eq(per_turn_chunks[0][1], Some(started[0]))
  assert_eq(per_turn_chunks[1][0], Some(started[1]))
  // Same session, different run/turn: identity is per turn, not per agent.
  assert_eq(started[0].session_id.to_string(), "s_turns")
  assert_eq(started[1].session_id.to_string(), "s_turns")
  assert_true(started[0].run_id.to_string() != started[1].run_id.to_string())
  assert_true(started[0].turn_id.to_string() != started[1].turn_id.to_string())
}
