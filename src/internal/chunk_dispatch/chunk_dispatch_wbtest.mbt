///|
/// The dispatcher owns one turn's `EventScope`: everything it publishes is
/// attributed to the turn that constructed it.

///|
fn chunk_scope(
  session : String,
  run : String,
  turn : String,
) -> @types.EventScope {
  {
    session_id: @kernel.SessionId::unchecked(session),
    run_id: @kernel.RunId::unchecked(run),
    turn_id: @kernel.TurnId::unchecked(turn),
  }
}

///|
/// Core deliveries with the scope the runtime stamped on each one.
struct ChunkScopeLog {
  received : Array[(@types.EventScope?, @types.TurnEvent)]
}

///|
fn ChunkScopeLog::subscribe(
  runtime : @event_runtime.EventRuntime,
) -> ChunkScopeLog {
  let log = ChunkScopeLog::{ received: [], }
  ignore(
    runtime.subscribe(fn(envelope) {
      match envelope.event {
        @events.Core(event) => log.received.push((envelope.scope, event))
        _ => ()
      }
    }),
  )
  log
}

///|
fn ChunkScopeLog::chunks(self : ChunkScopeLog) -> Array[String] {
  let tokens : Array[String] = []
  for entry in self.received {
    match entry.1 {
      StreamChunkReceived(chunk=TextDelta(token~)) => tokens.push(token)
      _ => ()
    }
  }
  tokens
}

///|
fn ChunkScopeLog::dropped(self : ChunkScopeLog) -> Array[Int32] {
  let counts : Array[Int32] = []
  for entry in self.received {
    match entry.1 {
      StreamChunksDropped(count~) => counts.push(count)
      _ => ()
    }
  }
  counts
}

///|
/// Whether the log already accounts for every enqueued chunk (delivered plus
/// reported drops). Used to wait for the drain loop without assuming how many
/// scheduler turns it needs.
fn ChunkScopeLog::accounted(self : ChunkScopeLog, total : Int32) -> Bool {
  let mut sum = 0
  for entry in self.received {
    match entry.1 {
      StreamChunkReceived(_) => sum = sum + 1
      StreamChunksDropped(count~) => sum = sum + count
      _ => ()
    }
  }
  sum >= total
}

///|
test "chunk dispatch: chunks carry the captured turn scope in FIFO order" {
  let scope = chunk_scope("s_scope", "run_1", "turn_1")
  let runtime = @event_runtime.EventRuntime()
  let log = ChunkScopeLog::subscribe(runtime)
  let dispatcher = ChunkDispatcher(runtime, scope)
  for token in ["a", "b", "c"] {
    dispatcher.enqueue(TextDelta(token~))
  }
  dispatcher.flush()
  assert_eq(log.chunks(), ["a", "b", "c"])
  for entry in log.received {
    assert_eq(entry.0, Some(scope))
  }
  // A flush with nothing buffered publishes nothing: the tail flush at the end
  // of a turn must not lose or repeat attribution.
  dispatcher.flush()
  assert_eq(log.received.length(), 3)
}

///|
test "chunk dispatch: overflow drop notice carries the same turn scope" {
  let scope = chunk_scope("s_scope", "run_1", "turn_1")
  let runtime = @event_runtime.EventRuntime()
  let log = ChunkScopeLog::subscribe(runtime)
  let dispatcher = ChunkDispatcher(runtime, scope)
  let capacity : Int32 = chunk_queue_capacity
  let total : Int32 = capacity + 6
  for i in 0..<total {
    dispatcher.enqueue(TextDelta(token="c\{i}"))
  }
  dispatcher.flush()
  // The bounded queue keeps the newest `capacity` chunks; the 6 evicted ones
  // are reported once, after the surviving chunks, and never re-ordered.
  assert_eq(log.dropped(), [6])
  let delivered = log.chunks()
  assert_eq(delivered.length(), capacity)
  // Item-by-item: with no drainer running, the survivors are exactly the newest
  // `capacity` chunks, in production order and with no gap.
  for i in 0..<capacity {
    assert_eq(delivered[i], "c\{total - capacity + i}")
  }
  guard log.received[log.received.length() - 1].1 is StreamChunksDropped(_) else {
    fail("the drop notice must be the last publication of a flushed turn")
  }
  for entry in log.received {
    assert_eq(entry.0, Some(scope))
  }
}

///|
async test "chunk dispatch: drain loop keeps the scope on chunks and drop notices" {
  let scope = chunk_scope("s_scope", "run_2", "turn_2")
  let runtime = @event_runtime.EventRuntime()
  let log = ChunkScopeLog::subscribe(runtime)
  let dispatcher = ChunkDispatcher(runtime, scope)
  let capacity : Int32 = chunk_queue_capacity
  let total : Int32 = capacity + 3
  for i in 0..<total {
    dispatcher.enqueue(TextDelta(token="d\{i}"))
  }
  // Wait (bounded) until delivery plus drop accounting covers the burst,
  // then close.
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() { dispatcher.drain_loop() })
    let mut spins = 0
    while !log.accounted(total) {
      if spins >= 10_000 {
        fail("drain loop did not settle within the bounded wait")
      }
      @async.pause()
      spins = spins + 1
    }
    dispatcher.close()
  })
  let delivered = log.chunks()
  let dropped = log.dropped()
  let mut dropped_total = 0
  for count in dropped {
    dropped_total = dropped_total + count
  }
  assert_eq(delivered.length() + dropped_total, total)
  assert_eq(dropped_total, 3)
  for entry in log.received {
    assert_eq(entry.0, Some(scope))
  }
}
