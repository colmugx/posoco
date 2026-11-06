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
/// Model fixture that yields after every stream callback. This lets the
/// dispatcher drain one chunk at a time, so the regression observes ordering
/// independently of scheduler timing at the model-response boundary.
struct YieldingStreamModel {
  chunks : Array[@types.StreamChunk]
  response : @kernel.ModelCallResult
  mut calls : Int32
}

///|
fn YieldingStreamModel::YieldingStreamModel(
  chunks : Array[@types.StreamChunk],
  response : @kernel.ModelCallResult,
) -> YieldingStreamModel {
  { chunks, response, calls: 0, }
}

///|
fn YieldingStreamModel::call_count(self : YieldingStreamModel) -> Int32 {
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
        @async.pause()
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
  _tools : Array[@kernel.ToolDef],
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
  let model = YieldingStreamModel(
    chunks,
    @test_support.tk_stop_response("done"),
  )
  let store = @test_support.RecordingSessionPort()
  let observer = @test_support.RecordingObserver()
  let entered : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let release : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let gate = TurnLoopGate::{ entered, release, }
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", hooks=[gate], sessions=[store], observers=[
        observer,
      ]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  @async.with_task_group(group => {
    let first = group.spawn(async fn() {
      agent.run_turn(@test_support.tk_user_msg("first"), "p2-session")
    })
    // before_model runs after Puppet::prompt acquired its lease.
    ignore(entered.get())
    assert_eq(model.call_count(), 0)

    // The first task is suspended at the gate, so this direct call is a
    // concurrent invocation while retaining the typed AgentError result.
    let second_result = Ok(
      agent.run_turn(@test_support.tk_user_msg("second"), "p2-session"),
    ) catch {
      error => Err(error)
    }
    match second_result {
      Err(Busy(operation_id~, session~)) => {
        assert_eq(session, "p2-session")
        assert_true(operation_id.contains("agent_run_turn_"))
      }
      _ => fail("concurrent run_turn must fail with the typed busy error")
    }

    // The rejected call must not emit a turn event or load the session.
    let events_before = observer.events()
    let mut starts_before = 0
    let mut terminal_before = 0
    for event in events_before {
      match event {
        TurnStarted => starts_before = starts_before + 1
        TurnCompleted | TurnFailed(_) | TurnCancelled =>
          terminal_before = terminal_before + 1
        _ => ()
      }
    }
    assert_eq(starts_before, 1)
    assert_eq(terminal_before, 0)
    assert_eq(model.call_count(), 0)
    let mut loads = 0
    for operation in store.ops() {
      match operation {
        @test_support.SessionOp::OpLoad(..) => loads = loads + 1
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
      TurnCompleted | TurnFailed(_) | TurnCancelled =>
        terminal_count = terminal_count + 1
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
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Respond(
      @test_support.tk_stop_response("after-cancel"),
    ),
  ])
  let store = @test_support.RecordingSessionPort()
  let entered : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let release : @aqueue.Queue[Int32] = Queue(kind=Unbounded)
  let gate = TurnLoopGate::{ entered, release, }
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", hooks=[gate], sessions=[store]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  @async.with_task_group(group => {
    let first = group.spawn(
      async fn() {
        let result : Result[@types.TurnResult, Error] = Ok(
          agent.run_turn(@test_support.tk_user_msg("cancel-me"), "p2-cancel"),
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
      agent.run_turn(@test_support.tk_user_msg("after-cancel"), "p2-cancel"),
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
    Map::from_array([
      (
        "noop",
        @test_support.ScriptedToolOutcome::OutcomeOk(
          @test_support.tk_ok_result("done"),
        ),
      ),
    ]),
  )
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Stream(
      chunks~,
      response=@test_support.tk_tool_call_response(
        "noop",
        "call_1",
        Json::object(Map::from_array([])),
      ),
    ),
    @test_support.ScriptedModelStep::Fail(Transport("boom")),
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
    @test_support.ScriptedModelStep::Stream(
      chunks~,
      response=@test_support.tk_stop_response("ok"),
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
    @test_support.ScriptedModelStep::Stream(
      chunks=[
        @types.TextDelta(token="first-0"),
        @types.TextDelta(token="first-1"),
      ],
      response=@test_support.tk_stop_response("first"),
    ),
    @test_support.ScriptedModelStep::Stream(
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

///|
/// Overflow is telemetry loss, not identity loss: the drop notice carries the
/// turn scope and precedes the terminal event.
async test "chunk dispatch: overflow drop notice carries the turn scope" {
  let total_chunks = 2500
  let chunks = []
  for i in 0..<total_chunks {
    chunks.push(@types.TextDelta(token="c\{i}"))
  }
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::Stream(
      chunks~,
      response=@test_support.tk_stop_response("ok"),
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
  let _ = agent.run_turn(@test_support.tk_user_msg("hello"), "s_overflow")
  let events = observer.turn_events()
  let turn_scope = turn_started_scope(events)
  let response_idx = events.search_by(fn(entry) {
    entry.1 is ModelResponseReceived(_)
  })
  guard response_idx is Some(ridx) else {
    fail("ModelResponseReceived not found")
  }
  let mut delivered = 0
  let mut dropped_total = 0
  // Per-item FIFO: forward walk through the production order; gaps allowed.
  let mut cursor = 0
  for i, entry in events {
    match entry.1 {
      StreamChunkReceived(chunk=TextDelta(token~)) => {
        assert_eq(entry.0, Some(turn_scope))
        let mut found = false
        while cursor < total_chunks {
          let expected = "c\{cursor}"
          cursor = cursor + 1
          if expected == token {
            found = true
            break
          }
        }
        if !found {
          fail("delivered chunk #\{delivered} breaks production order")
        }
        delivered = delivered + 1
      }
      StreamChunkReceived(_) => fail("expected TextDelta")
      StreamChunksDropped(count~) => {
        assert_eq(entry.0, Some(turn_scope))
        dropped_total = dropped_total + count
        if i >= ridx {
          fail("StreamChunksDropped must precede ModelResponseReceived")
        }
      }
      _ => ()
    }
  }
  assert_true(dropped_total > 0)
  assert_true(delivered > 0)
  assert_eq(delivered + dropped_total, total_chunks)
}

///|
/// Cancellation flushes the tail chunks; they still carry the turn's scope.
async test "chunk dispatch: cancelled stream keeps the turn scope on flushed chunks" {
  let chunks = [@types.TextDelta(token="p0"), @types.TextDelta(token="p1")]
  let model = @test_support.ScriptedModel([
    @test_support.ScriptedModelStep::StreamParked(chunks~),
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
  @async.with_task_group(async fn(group) {
    let turn = group.spawn(
      async fn() {
        let result : Result[@types.TurnResult, Error] = Ok(
          agent.run_turn(@test_support.tk_user_msg("cancel-me"), "s_cancel"),
        ) catch {
          error => Err(error)
        }
        result
      },
      allow_failure=true,
    )
    while model.parked_calls == 0 {
      @async.pause()
    }
    turn.cancel()
    match turn.wait() {
      Err(_) => ()
      Ok(_) => fail("cancelled turn must not complete")
    }
  })
  let events = observer.turn_events()
  let turn_scope = turn_started_scope(events)
  assert_eq(turn_scope.session_id.to_string(), "s_cancel")
  let chunk_scopes = events.filter(fn(entry) {
    entry.1 is StreamChunkReceived(_)
  })
  assert_eq(chunk_scopes.length(), chunks.length())
  for entry in chunk_scopes {
    assert_eq(entry.0, Some(turn_scope))
  }
}
