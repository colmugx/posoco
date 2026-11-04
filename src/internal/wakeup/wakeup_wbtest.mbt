///|
/// Whitebox tests for wakeup admission bounds.

///|
fn wakeup_fixture() -> (WakeupRuntime, @port.WakeupPort) raise @error.AgentError {
  let runtime = WakeupRuntime(events=@event_runtime.EventRuntime())
  runtime.activate()
  runtime.set_active_session(Some("session_a"))
  (runtime, runtime.capability("ext"))
}

///|
async test "wakeup/pending_cap_rejects_beyond_the_limit" {
  let (runtime, port) = wakeup_fixture()
  for i in 0..<wakeup_max_pending {
    let tag = "tag_" + i.to_string()
    assert_true(port.request(session="session_a", tag~, note="") is Ok(_))
  }
  match port.request(session="session_a", tag="tag_overflow", note="") {
    Err(PendingFull(session~, limit~)) => {
      assert_eq(session, "session_a")
      assert_eq(limit, wakeup_max_pending)
    }
    Ok(_) => fail("the ledger accepted a request past its cap")
    Err(_) => fail("unexpected rejection")
  }
  // Coalescing onto a tag that is still pending adds no entry, so it stays
  // accepted at the cap.
  assert_true(
    port.request(session="session_a", tag="tag_0", note="again") is Ok(_),
  )
  // The cap is per session, not global.
  runtime.set_active_session(Some("session_b"))
  assert_true(
    port.request(session="session_b", tag="tag_fresh", note="") is Ok(_),
  )
}
