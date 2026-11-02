///|
priv struct LocalObserver {
  events : Array[@types.TurnEvent]
}

///|
impl @port.Observer for LocalObserver with fn on_event(self, _scope, event) -> Unit {
  self.events.push(event)
}

///|
test "chunk dispatch: enqueue does not call observer synchronously" {
  let observer = LocalObserver::{ events: [], }
  let dispatcher = ChunkDispatcher([observer])
  dispatcher.enqueue(@types.TextDelta(token="x"))
  assert_eq(observer.events.length(), 0)
}

///|
async test "chunk dispatch: drain_loop delivers queued events in order" {
  let observer = LocalObserver::{ events: [], }
  let dispatcher = ChunkDispatcher([observer])
  for i in 0..<5 {
    dispatcher.enqueue(@types.TextDelta(token="d\{i}"))
  }
  @async.with_task_group(async fn(group) {
    group.spawn_bg(async fn() { dispatcher.drain_loop() })
    @async.pause()
    dispatcher.close()
  })
  assert_eq(observer.events.length(), 5)
  for i = 0; i < 5; i = i + 1 {
    match observer.events[i] {
      @types.StreamChunkReceived(chunk~) =>
        match chunk {
          @types.TextDelta(token~) => assert_eq(token, "d\{i}")
          _ => fail("expected TextDelta")
        }
      _ => fail("expected StreamChunkReceived")
    }
  }
}
