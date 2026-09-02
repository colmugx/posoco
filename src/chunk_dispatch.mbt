///|
/// Buffered, per-turn dispatcher for `StreamChunk` telemetry.
///
/// The model's read loop calls `enqueue` synchronously; the event is put into
/// a bounded `@aqueue.Queue` and the callback returns immediately. A drain
/// task spawned at the start of each turn consumes the queue and emits each
/// chunk to observers in FIFO order. When the queue overflows, the oldest
/// undrained chunk is dropped and a running count is kept; a single
/// `StreamChunksDropped(count~)` event is emitted when the queue drains below
/// capacity or at flush so observers can detect loss without one event per
/// dropped chunk.

///|
let chunk_queue_capacity : Int = 1024

///|
/// Per-turn chunk dispatcher. Created by `run_turn_via_puppet` and wired into
/// the Puppet's stream callback through `AgentRuntime::chunk_dispatcher`.
priv struct ChunkDispatcher {
  queue : @aqueue.Queue[@types.TurnEvent]
  /// Manual depth counter: `@aqueue.Queue` exposes no length accessor and we
  /// need to know when the buffer transitions from full to non-full.
  mut depth : Int
  /// Number of chunks dropped since the last `StreamChunksDropped` emission.
  mut dropped : Int
  observers : Array[&@port.Observer]
}

///|
fn ChunkDispatcher::ChunkDispatcher(
  observers : Array[&@port.Observer],
) -> ChunkDispatcher {
  {
    queue: @aqueue.Queue(kind=@aqueue.Blocking(chunk_queue_capacity)),
    depth: 0,
    dropped: 0,
    observers,
  }
}

///|
/// Synchronously enqueue one chunk. Never blocks the producer: if the buffer
/// is full the oldest event is dropped and `dropped` is incremented.
fn ChunkDispatcher::enqueue(
  self : ChunkDispatcher,
  chunk : @types.StreamChunk,
) -> Unit {
  let event : @types.TurnEvent = @types.StreamChunkReceived(chunk~)
  let put_ok : Bool = self.queue.try_put(event) catch {
    _ =>
      // Queue closed (turn already terminal) — drop silently.
      return
  }
  if put_ok {
    self.depth = self.depth + 1
    return
  }
  // Buffer full: drop oldest, count the loss, then enqueue the new chunk.
  let evicted : @types.TurnEvent? = self.queue.try_get() catch { _ => None }
  match evicted {
    Some(_) => {
      self.dropped = self.dropped + 1
      self.depth = self.depth - 1
    }
    None => ()
  }
  let put_ok2 : Bool = self.queue.try_put(event) catch { _ => false }
  if put_ok2 {
    self.depth = self.depth + 1
  }
}

///|
/// Emit a single event to every observer with `None` scope, exactly like the
/// previous synchronous callback path.
fn ChunkDispatcher::emit(
  self : ChunkDispatcher,
  event : @types.TurnEvent,
) -> Unit {
  for observer in self.observers {
    observer.on_event_at(None, snapshot_turn_event(event))
  }
}

///|
/// Drain all buffered events and emit a synthesized `StreamChunksDropped` if
/// any chunks were lost since the last emit. Called at committed-event
/// boundaries and at turn termination so no chunk is observed after a terminal
/// event.
fn ChunkDispatcher::flush(self : ChunkDispatcher) -> Unit {
  while true {
    let event : @types.TurnEvent? = self.queue.try_get() catch { _ => break }
    match event {
      Some(e) => {
        self.depth = self.depth - 1
        self.emit(e)
      }
      None => break
    }
  }
  if self.dropped > 0 {
    let count = self.dropped
    self.dropped = 0
    self.emit(@types.StreamChunksDropped(count~))
  }
}

///|
/// Background drain loop. Runs for the lifetime of one turn. It normally
/// blocks on `get()`; the turn ends by closing the queue, which wakes the
/// loop so `with_task_group` can reap the task.
async fn ChunkDispatcher::drain_loop(self : ChunkDispatcher) -> Unit {
  while true {
    let event : @types.TurnEvent = self.queue.get() catch {
      _ =>
        // Queue closed: turn is ending.
        break
    }
    self.depth = self.depth - 1
    self.emit(event)
    // If the buffer just drained below capacity and we dropped chunks while
    // it was full, emit one synthesized drop event now.
    if self.depth < chunk_queue_capacity && self.dropped > 0 {
      let count = self.dropped
      self.dropped = 0
      self.emit(@types.StreamChunksDropped(count~))
    }
  }
}

///|
/// Close the queue. Idempotent; wakes the drain loop so the task terminates.
fn ChunkDispatcher::close(self : ChunkDispatcher) -> Unit {
  self.queue.close()
}
