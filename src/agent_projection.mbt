///|
/// Per-turn stream-chunk callback wiring. The two committed-envelope
/// projections the Agent installs as subscribers live in
/// `@event_projection.EventProjection` (observers) and
/// `@session_checkpoint.SessionCheckpointSubscriber` (session stores).

///|
/// Wrap the puppet's `HostChunkCallback` so each `StreamChunk` is re-emitted
/// to observers as `StreamChunkReceived`. The chunk is already the canonical
/// typed shape; no JSON decoding is needed here.
fn create_agent_stream_callback(
  observers : Array[&@port.Observer],
  dispatcher_ref : Ref[@chunk_dispatch.ChunkDispatcher?],
) -> @kernel_exec.HostChunkCallback? {
  if observers.is_empty() {
    return None
  }
  let cb = fn(chunk : @types.StreamChunk) {
    // Route to the active turn's dispatcher. If no turn is active (should not
    // happen for chunks produced by the Puppet), drop silently.
    match dispatcher_ref.val {
      Some(dispatcher) => dispatcher.enqueue(chunk)
      None => ()
    }
  }
  Some(cb)
}
