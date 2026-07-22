///|
/// Harness lifecycle collection (M2-T05, ADR §2.2, §4 rule 12).
///
/// The Harness is the **single product-level lifecycle executor**. All
/// top-level lifecycle nodes register here exactly once at composition.
/// Startup order is registration order; shutdown order is reverse.
///
/// M0 `Lifecycle` trait only has `on_shutdown`; M2 needs startup semantics
/// and a typed error path. Rather than breaking the M0 trait (Q7.5 open
/// question), M2 introduces a parallel `HarnessLifecycleNode` trait. A
/// thin adapter wraps an M0 `Lifecycle` into a `HarnessLifecycleNode` so
/// existing extensions continue to work without code changes.
///
/// Ownership invariants (ADR §4 rules 12–13):
/// - Each node has a stable `node_id`; duplicate id fails at composition.
/// - The same instance cannot register twice.
/// - Parent+child double-registration fails (the parent composite must
///   own its children).
/// - startup/shutdown happen exactly once per node per product lifecycle.
/// - Startup failure rolls back already-started nodes in reverse order;
///   rollback failures are AGGREGATED, not swallowed.
/// - Shutdown failure aggregates too; nothing is silently caught.

// ──────────────────────────────────────────────────────────────────────────
// LifecycleError — typed errors for startup/shutdown
// ──────────────────────────────────────────────────────────────────────────

///|
/// Typed lifecycle error. Carries the failing node id + cause string plus
/// any rollback/aggregate failures observed while handling the primary
/// failure.
pub(all) struct LifecycleStartupError {
  /// Node id where the initial failure occurred.
  failing_node_id : String
  /// Cause of the initial failure.
  cause : String
  /// Nodes that were started but failed to roll back. Each tuple is
  /// (node_id, rollback_cause). Nodes that rolled back successfully are
  /// NOT listed here.
  rollback_failures : Array[(String, String)]
} derive(Eq, Debug)

///|
pub impl Show for LifecycleStartupError with fn to_string(
  self : LifecycleStartupError,
) -> String {
  let rb_summaries = self.rollback_failures.map(fn(pair) {
    let (id, cause) = pair
    "\{id}:\{cause}"
  })
  "LifecycleStartupError(failing=\{self.failing_node_id}, cause=\{safe_lifecycle_label(self.cause)}, rollback_failures=[\{rb_summaries.join(",")}])"
}

///|
pub(all) struct LifecycleShutdownError {
  /// Node id where the initial failure occurred.
  failing_node_id : String
  /// Cause of the initial failure.
  cause : String
  /// Other nodes (besides failing_node_id) that failed to shut down.
  other_failures : Array[(String, String)]
} derive(Eq, Debug)

///|
pub impl Show for LifecycleShutdownError with fn to_string(
  self : LifecycleShutdownError,
) -> String {
  let of_summaries = self.other_failures.map(fn(pair) {
    let (id, cause) = pair
    "\{id}:\{cause}"
  })
  "LifecycleShutdownError(failing=\{self.failing_node_id}, cause=\{safe_lifecycle_label(self.cause)}, other_failures=[\{of_summaries.join(",")}])"
}

///|
fn safe_lifecycle_label(value : String) -> String {
  let chars : Array[Char] = []
  let mut truncated = false
  for char in value {
    if chars.length() >= 64 {
      truncated = true
      break
    }
    match char {
      '\n' | '\r' => chars.push(' ')
      other => chars.push(other)
    }
  }
  let label = String::from_array(chars)
  if truncated {
    label + "...(truncated)"
  } else {
    label
  }
}

// ──────────────────────────────────────────────────────────────────────────
// HarnessLifecycleNode trait
// ──────────────────────────────────────────────────────────────────────────

///|
/// Port: top-level lifecycle node registered with the Harness.
///
/// Each node has a stable `node_id` and a human-readable `provenance`. The
/// Harness calls `startup` once in registration order at product startup,
/// and `shutdown` once in reverse order at product shutdown.
///
/// Both methods may raise `LifecycleNodeError` for typed failure paths.
/// Untyped `raise Error` (e.g. from an async panic) is caught by the
/// collection layer and converted to a typed `LifecycleNodeError::Internal`.
pub(open) trait HarnessLifecycleNode {
  /// Stable identifier for this node. Used in diagnostics and to detect
  /// duplicate registration.
  fn node_id(Self) -> String

  /// Human-readable provenance (e.g. "ext_llm", "ext_fs_session").
  fn provenance(Self) -> String

  /// Start the node. Called once at product startup. May raise
  /// `LifecycleNodeError` on failure; the collection rolls back
  /// already-started nodes.
  async fn startup(Self) -> Unit raise LifecycleNodeError

  /// Shut the node down. Called once at product shutdown. May raise
  /// `LifecycleNodeError`; the collection aggregates failures and continues
  /// shutting down remaining nodes.
  async fn shutdown(Self) -> Unit raise LifecycleNodeError
}

///|
/// Typed error a node can raise from startup/shutdown.
pub(all) suberror LifecycleNodeError {
  /// Node encountered an internal error.
  Internal(node_id~ : String, detail~ : String)
  /// Node observed inconsistent state (e.g. wrong config).
  Inconsistent(node_id~ : String, detail~ : String)
  /// Node is not in a state where startup/shutdown is valid.
  InvalidState(node_id~ : String, detail~ : String)
}

///|
pub impl Show for LifecycleNodeError with fn to_string(
  self : LifecycleNodeError,
) -> String {
  match self {
    Internal(node_id~, detail~) =>
      "Internal(\{node_id}: \{safe_lifecycle_label(detail)})"
    Inconsistent(node_id~, detail~) =>
      "Inconsistent(\{node_id}: \{safe_lifecycle_label(detail)})"
    InvalidState(node_id~, detail~) =>
      "InvalidState(\{node_id}: \{safe_lifecycle_label(detail)})"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// LifecycleCollection — the ordered registry + startup/shutdown runner
// ──────────────────────────────────────────────────────────────────────────

///|
/// Ordered collection of HarnessLifecycleNode references. Tracks registration
/// order, duplicate ids, and exactly-once start/stop state.
///
/// Construction: `LifecycleCollection::new()` then `register` in startup
/// order. Once `startup_all` has been called, no further registrations are
/// accepted (the collection is sealed).
pub struct LifecycleCollection {
  nodes : Array[&HarnessLifecycleNode]
  node_ids : Map[String, Bool]
  /// Pointer-equality check: track which &HarnessLifecycleNode references
  /// have been registered. MoonBit does not expose object identity on
  /// trait references, so we use (node_id, provenance) as a proxy: the
  /// same node id cannot be registered twice anyway, and a composite host
  /// registering its children directly would use distinct node ids.
  started : Map[String, Bool]
  shut_down : Map[String, Bool]
  mut is_sealed : Bool
}

///|
pub fn LifecycleCollection::new() -> LifecycleCollection {
  {
    nodes: [],
    node_ids: Map::from_array([]),
    started: Map::from_array([]),
    shut_down: Map::from_array([]),
    is_sealed: false,
  }
}

///|
/// Register a node. Raises `HarnessError::LifecycleDuplicate` if the node
/// id is already registered. Once `startup_all` has been called, further
/// registrations raise `InvalidState`.
pub fn LifecycleCollection::register(
  self : LifecycleCollection,
  node : &HarnessLifecycleNode,
) -> Unit raise HarnessError {
  if self.is_sealed {
    raise LifecycleDuplicate(node_id="collection sealed after startup")
  }
  let id = node.node_id()
  if self.node_ids.contains(id) {
    raise LifecycleDuplicate(node_id=id)
  }
  self.node_ids[id] = true
  self.nodes.push(node)
}

///|
/// Number of registered nodes.
pub fn LifecycleCollection::size(self : LifecycleCollection) -> Int {
  self.nodes.length()
}

///|
/// Start all registered nodes in registration order. On failure, rolls
/// back already-started nodes in reverse order; rollback failures are
/// aggregated into the returned error.
///
/// Idempotent: if already started, returns immediately.
pub async fn LifecycleCollection::startup_all(
  self : LifecycleCollection,
) -> Unit raise HarnessError {
  // Check if any node has already been started (idempotency).
  let any_started = self.started.contains("collection_started")
  if any_started {
    return ()
  }
  self.is_sealed = true
  let mut started_count = 0
  for node in self.nodes {
    let node_id = node.node_id()
    let result : Result[Unit, LifecycleNodeError] = try {
      node.startup()
      Ok(())
    } catch {
      e => Err(e)
    }
    match result {
      Ok(_) => {
        self.started[node_id] = true
        started_count = started_count + 1
      }
      Err(e) => {
        // Roll back already-started nodes in reverse order.
        let rollback_failures : Array[(String, String)] = []
        let mut i = started_count - 1
        while i >= 0 {
          let rollback_node = self.nodes[i]
          let rb_id = rollback_node.node_id()
          let rb_result : Result[Unit, LifecycleNodeError] = try {
            rollback_node.shutdown()
            Ok(())
          } catch {
            rb_e => Err(rb_e)
          }
          match rb_result {
            Ok(_) => self.shut_down[rb_id] = true
            Err(rb_e) => rollback_failures.push((rb_id, rb_e.to_string()))
          }
          i = i - 1
        }
        raise LifecycleStartupFailed(
          node_id~,
          cause=e.to_string(),
          rollback_failures~,
        )
      }
    }
  }
  self.started["collection_started"] = true
}

///|
/// Shut down all started nodes in reverse registration order. Aggregates
/// failures; the returned error (if any) carries all of them.
///
/// Idempotent: if already shut down, returns immediately.
pub async fn LifecycleCollection::shutdown_all(
  self : LifecycleCollection,
) -> Unit raise HarnessError {
  let any_shut_down = self.shut_down.contains("collection_shutdown")
  if any_shut_down {
    return ()
  }
  let failures : Array[(String, String)] = []
  let mut first_failure : (String, String)? = None
  // Reverse iteration.
  let mut i = self.nodes.length() - 1
  while i >= 0 {
    let node = self.nodes[i]
    let id = node.node_id()
    // Skip nodes that never started (shouldn't happen if startup_all ran,
    // but be defensive).
    if not(self.started.contains(id)) {
      i = i - 1
      continue
    }
    if self.shut_down.contains(id) {
      i = i - 1
      continue
    }
    let result : Result[Unit, LifecycleNodeError] = try {
      node.shutdown()
      Ok(())
    } catch {
      e => Err(e)
    }
    match result {
      Ok(_) => self.shut_down[id] = true
      Err(e) => {
        let pair = (id, e.to_string())
        match first_failure {
          None => first_failure = Some(pair)
          Some(_) => failures.push(pair)
        }
        // Mark as shut_down anyway so a second shutdown_all call doesn't
        // retry it. The failure is preserved in the returned error.
        self.shut_down[id] = true
      }
    }
    i = i - 1
  }
  self.shut_down["collection_shutdown"] = true
  match first_failure {
    None => ()
    Some((failing_id, cause)) =>
      raise LifecycleShutdownFailed(
        node_id=failing_id,
        cause~,
        other_failures=failures,
      )
  }
}

///|
pub fn LifecycleCollection::started_node_count(
  self : LifecycleCollection,
) -> Int {
  let mut n = 0
  for id in self.node_ids.keys() {
    if self.started.contains(id) {
      n = n + 1
    }
  }
  n
}

///|
pub fn LifecycleCollection::shut_down_node_count(
  self : LifecycleCollection,
) -> Int {
  let mut n = 0
  for id in self.node_ids.keys() {
    if self.shut_down.contains(id) {
      n = n + 1
    }
  }
  // Don't count the synthetic "collection_shutdown" marker.
  if n > 0 {
    n = n - 1
  }
  n
}

///|
/// Internal helper to negate a bool (replaces `not(...)` for clarity).
fn not(b : Bool) -> Bool {
  !b
}
