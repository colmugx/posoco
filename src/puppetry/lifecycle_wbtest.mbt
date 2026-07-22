///|
/// Whitebox tests for M2-T05 lifecycle collection.
///
/// Coverage:
/// - register + startup_all in registration order
/// - shutdown_all in reverse registration order
/// - exactly-once: second startup/shutdown is no-op
/// - duplicate id rejected
/// - register after startup rejected (sealed)
/// - startup failure rolls back already-started nodes
/// - rollback failure aggregated into the returned error
/// - shutdown failure aggregated
/// - composite ownership: child double-registration detected via duplicate id

// ──────────────────────────────────────────────────────────────────────────
// Spy infrastructure
// ──────────────────────────────────────────────────────────────────────────

///|
/// Shared recording of start/stop events for inspection. Stored as a
/// plain `Array[String]` so it can be passed by reference (MoonBit arrays
/// are reference types) and shared between multiple spies.
pub(all) struct LifecycleSpyLog {
  events : Array[String]
}

///|
pub fn LifecycleSpyLog::new() -> LifecycleSpyLog {
  { events: [] }
}

///|
pub fn LifecycleSpyLog::record(self : LifecycleSpyLog, event : String) -> Unit {
  self.events.push(event)
}

///|
pub fn LifecycleSpyLog::snapshot(self : LifecycleSpyLog) -> Array[String] {
  self.events.copy()
}

///|
/// Synthetic lifecycle node that records start/stop into a shared log.
/// Can be configured to fail on Nth startup or Mth shutdown.
pub(all) struct SpyLifecycleNode {
  node_id_value : String
  provenance_value : String
  log : LifecycleSpyLog
  mut fail_on_startup : Int?
  mut fail_on_shutdown : Int?
  mut startup_count : Int
  mut shutdown_count : Int
}

///|
pub fn SpyLifecycleNode::new(
  node_id : String,
  provenance : String,
  log : LifecycleSpyLog,
) -> SpyLifecycleNode {
  {
    node_id_value: node_id,
    provenance_value: provenance,
    log,
    fail_on_startup: None,
    fail_on_shutdown: None,
    startup_count: 0,
    shutdown_count: 0,
  }
}

///|
pub fn SpyLifecycleNode::fail_on_startup_at(
  self : SpyLifecycleNode,
  n : Int,
) -> SpyLifecycleNode {
  self.fail_on_startup = Some(n)
  self
}

///|
pub fn SpyLifecycleNode::fail_on_shutdown_at(
  self : SpyLifecycleNode,
  n : Int,
) -> SpyLifecycleNode {
  self.fail_on_shutdown = Some(n)
  self
}

///|
pub fn SpyLifecycleNode::startup_count(self : SpyLifecycleNode) -> Int {
  self.startup_count
}

///|
pub fn SpyLifecycleNode::shutdown_count(self : SpyLifecycleNode) -> Int {
  self.shutdown_count
}

///|
pub impl HarnessLifecycleNode for SpyLifecycleNode with fn node_id(self) -> String {
  self.node_id_value
}

///|
pub impl HarnessLifecycleNode for SpyLifecycleNode with fn provenance(self) -> String {
  self.provenance_value
}

///|
pub impl HarnessLifecycleNode for SpyLifecycleNode with fn startup(self) -> Unit raise LifecycleNodeError {
  self.startup_count = self.startup_count + 1
  self.log.record("start:" + self.node_id_value)
  match self.fail_on_startup {
    Some(n) => {
      if self.startup_count == n {
        raise Internal(
          node_id=self.node_id_value,
          detail="injected startup failure",
        )
      }
      ()
    }
    None => ()
  }
}

///|
pub impl HarnessLifecycleNode for SpyLifecycleNode with fn shutdown(self) -> Unit raise LifecycleNodeError {
  self.shutdown_count = self.shutdown_count + 1
  self.log.record("stop:" + self.node_id_value)
  match self.fail_on_shutdown {
    Some(n) => {
      if self.shutdown_count == n {
        raise Internal(
          node_id=self.node_id_value,
          detail="injected shutdown failure",
        )
      }
      ()
    }
    None => ()
  }
}

///|
/// Helper: run a closure that may raise HarnessError; capture as Result.
/// Lets assertions pattern-match on the result without a `raise` context.
fn try_harness(r : () -> Unit raise HarnessError) -> Result[Unit, HarnessError] {
  try {
    r()
    Ok(())
  } catch {
    e => Err(e)
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Happy path
// ──────────────────────────────────────────────────────────────────────────

///|
async test "harness_lifecycle/happy_path" {
  let log = LifecycleSpyLog::new()
  let a = SpyLifecycleNode::new("a", "pa", log)
  let b = SpyLifecycleNode::new("b", "pb", log)
  let c = SpyLifecycleNode::new("c", "pc", log)
  let col = LifecycleCollection::new()
  col.register(a)
  col.register(b)
  col.register(c)
  col.startup_all()
  col.shutdown_all()
  let events = log.snapshot()
  assert_true(events.length() == 6)
  assert_true(events[0] == "start:a")
  assert_true(events[1] == "start:b")
  assert_true(events[2] == "start:c")
  assert_true(events[3] == "stop:c")
  assert_true(events[4] == "stop:b")
  assert_true(events[5] == "stop:a")
}

// ──────────────────────────────────────────────────────────────────────────
// Exactly-once
// ──────────────────────────────────────────────────────────────────────────

///|
async test "harness_lifecycle/exactly_once" {
  let log = LifecycleSpyLog::new()
  let a = SpyLifecycleNode::new("a", "pa", log)
  let col = LifecycleCollection::new()
  col.register(a)
  col.startup_all()
  // Second startup is a no-op.
  col.startup_all()
  col.shutdown_all()
  // Second shutdown is a no-op.
  col.shutdown_all()
  let events = log.snapshot()
  assert_true(events.length() == 2)
  assert_true(a.startup_count() == 1)
  assert_true(a.shutdown_count() == 1)
}

// ──────────────────────────────────────────────────────────────────────────
// Duplicate id rejected
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_lifecycle/duplicate_id_rejected" {
  let log = LifecycleSpyLog::new()
  let a = SpyLifecycleNode::new("a", "pa", log)
  let a_again = SpyLifecycleNode::new("a", "pa2", log)
  let col = LifecycleCollection::new()
  col.register(a)
  let result = try_harness(() => col.register(a_again))
  assert_true(result is Err(_))
  match result {
    Err(LifecycleDuplicate(node_id~)) => assert_true(node_id == "a")
    _ => assert_true(false)
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Register after startup rejected (sealed)
// ──────────────────────────────────────────────────────────────────────────

///|
async test "harness_lifecycle/register_after_startup_rejected" {
  let log = LifecycleSpyLog::new()
  let a = SpyLifecycleNode::new("a", "pa", log)
  let b = SpyLifecycleNode::new("b", "pb", log)
  let col = LifecycleCollection::new()
  col.register(a)
  col.startup_all()
  let result = try_harness(() => col.register(b))
  assert_true(result is Err(_))
}

// ──────────────────────────────────────────────────────────────────────────
// Startup failure rolls back
// ──────────────────────────────────────────────────────────────────────────

///|
async test "harness_lifecycle/startup_failure_rolls_back" {
  let log = LifecycleSpyLog::new()
  let a = SpyLifecycleNode::new("a", "pa", log)
  let b = SpyLifecycleNode::new("b", "pb", log).fail_on_shutdown_at(1)
  let c = SpyLifecycleNode::new("c", "pc", log).fail_on_startup_at(1)
  let col = LifecycleCollection::new()
  col.register(a)
  col.register(b)
  col.register(c)
  let result : Result[Unit, HarnessError] = Ok(col.startup_all()) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(LifecycleStartupFailed(node_id~, cause~, rollback_failures~)) => {
      assert_true(node_id == "c")
      assert_true(cause.contains("injected startup failure"))
      assert_true(rollback_failures.length() == 1)
      let (rb_id, _) = rollback_failures[0]
      assert_true(rb_id == "b")
    }
    _ => assert_true(false)
  }
  let events = log.snapshot()
  // start:a, start:b, start:c (fails), stop:b (fails), stop:a.
  assert_true(events.length() == 5)
  assert_true(events[0] == "start:a")
  assert_true(events[1] == "start:b")
  assert_true(events[2] == "start:c")
  assert_true(events[3] == "stop:b")
  assert_true(events[4] == "stop:a")
}

// ──────────────────────────────────────────────────────────────────────────
// Shutdown failure aggregated
// ──────────────────────────────────────────────────────────────────────────

///|
async test "harness_lifecycle/shutdown_failure_aggregated" {
  let log = LifecycleSpyLog::new()
  let a = SpyLifecycleNode::new("a", "pa", log)
  let b = SpyLifecycleNode::new("b", "pb", log).fail_on_shutdown_at(1)
  let c = SpyLifecycleNode::new("c", "pc", log).fail_on_shutdown_at(1)
  let col = LifecycleCollection::new()
  col.register(a)
  col.register(b)
  col.register(c)
  col.startup_all()
  let result : Result[Unit, HarnessError] = Ok(col.shutdown_all()) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(LifecycleShutdownFailed(node_id~, cause~, other_failures~)) => {
      assert_true(node_id == "c")
      assert_true(cause.contains("injected shutdown failure"))
      assert_true(other_failures.length() == 1)
      let (of_id, _) = other_failures[0]
      assert_true(of_id == "b")
    }
    _ => assert_true(false)
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Composite ownership: child double-registration detected via duplicate id
// ──────────────────────────────────────────────────────────────────────────

///|
test "harness_lifecycle/composite_child_double_registration_detected" {
  let log = LifecycleSpyLog::new()
  let host = SpyLifecycleNode::new("host", "host", log)
  let child_direct = SpyLifecycleNode::new("child", "child", log)
  let col = LifecycleCollection::new()
  col.register(host)
  let result = try_harness(() => col.register(child_direct))
  assert_true(result is Ok(_))
  // Registering the same id again must fail.
  let child_again = SpyLifecycleNode::new("child", "child2", log)
  let result2 = try_harness(() => col.register(child_again))
  assert_true(result2 is Err(_))
}
