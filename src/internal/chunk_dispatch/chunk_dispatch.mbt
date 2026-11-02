///|
/// Buffered, per-turn dispatcher for `StreamChunk` telemetry. Chunk payloads
/// are immutable scalar values; the two emitted events are constructed
/// directly without root event-copy callbacks.
pub struct ChunkDispatcher {
  priv queue : @aqueue.Queue[@types.TurnEvent]
  priv mut depth : Int32
  priv mut dropped : Int32
  priv observers : Array[&@port.Observer]
}

///|
let chunk_queue_capacity : Int32 = 1024

///|
pub fn ChunkDispatcher::ChunkDispatcher(
  observers : Array[&@port.Observer],
) -> ChunkDispatcher {
  {
    queue: Queue(kind=Blocking(chunk_queue_capacity)),
    depth: 0,
    dropped: 0,
    observers,
  }
}

///|
pub fn ChunkDispatcher::enqueue(
  self : ChunkDispatcher,
  chunk : @types.StreamChunk,
) -> Unit {
  let event : @types.TurnEvent = StreamChunkReceived(chunk~)
  let put_ok : Bool = self.queue.try_put(event) catch { _ => return }
  if put_ok {
    self.depth = self.depth + 1
    return
  }
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
fn ChunkDispatcher::emit(
  self : ChunkDispatcher,
  event : @types.TurnEvent,
) -> Unit {
  for observer in self.observers {
    observer.on_event(None, event)
  }
}

///|
pub fn ChunkDispatcher::flush(self : ChunkDispatcher) -> Unit {
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
    self.emit(StreamChunksDropped(count~))
  }
}

///|
pub async fn ChunkDispatcher::drain_loop(self : ChunkDispatcher) -> Unit {
  while true {
    let event : @types.TurnEvent = self.queue.get() catch { _ => break }
    self.depth = self.depth - 1
    self.emit(event)
    if self.depth < chunk_queue_capacity && self.dropped > 0 {
      let count = self.dropped
      self.dropped = 0
      self.emit(StreamChunksDropped(count~))
    }
  }
}

///|
pub fn ChunkDispatcher::close(self : ChunkDispatcher) -> Unit {
  self.queue.close()
}
