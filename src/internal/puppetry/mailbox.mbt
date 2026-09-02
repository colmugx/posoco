// ──────────────────────────────────────────────────────────────────────────
// ControlMailbox — holds the three queues + abort flag + idle barrier
// ──────────────────────────────────────────────────────────────────────────

///|
/// Default max queue depth per mailbox. Beyond this, enqueue returns
/// `RejectedQueueFull`. M2 picks a conservative bound; M4/M5 may tune.
let default_max_queue_depth : Int = 64

///|
/// The control mailbox bundle. One instance per Puppet; tracks the
/// currently-active run_id (so stale commands targeting an old run are
/// rejected at enqueue time without needing to consult the phase gate).
///
/// The steer and follow-up queues are `@aqueue.Queue` (MPMC, async-safe)
/// so that a sibling task in the same `TaskGroup` can enqueue commands
/// while the pump is mid-run (e.g. blocked on a model HTTP call). The
/// pump drains them at safe points via `try_get` (non-blocking).
/// `resume_pending` stays a `Map` because resume is addressed by
/// `suspension_id`, not FIFO.
pub struct ControlMailbox {
  mut steer_queue : @aqueue.Queue[SteerCommand]
  mut follow_up_queue : @aqueue.Queue[FollowUpCommand]
  /// Manual depth counters (`@aqueue.Queue` exposes no `length()`). The
  /// enqueue path increments; the consume path decrements. Tests assert
  /// on these to verify drain behaviour.
  mut steer_depth : Int
  mut follow_up_depth : Int
  /// M3.5: fork command queue. OneAtATime policy — the pump consumes one
  /// fork per safe point (a fork creates a new session and returns
  /// PromptResult::ForkCompleted; batching makes no sense).
  mut fork_queue : @aqueue.Queue[ForkCommand]
  mut fork_depth : Int
  /// M3.5: compact command queue. OneAtATime policy — compact is expensive
  /// (LLM call or structural rewrite); batching multiple compacts back-to-
  /// back on the same transcript is a no-op.
  mut compact_queue : @aqueue.Queue[CompactCommand]
  mut compact_depth : Int
  /// Resume commands keyed by suspension_id. At most one per suspension.
  resume_pending : Map[String, ResumeCommand]
  /// Set if abort has been issued for the active run. Subsequent aborts
  /// return `AbortAlreadyRequested`.
  mut abort_requested : Bool
  /// Currently-active run_id. None when Idle.
  mut active_run_id : RunId?
  /// Currently-active turn_id. None when Idle.
  mut active_turn_id : TurnId?
  /// Condition variable for the idle barrier. `wait_idle` waits on this;
  /// the Puppet signals it when reaching a quiescent phase.
  idle_cond : @cond_var.Cond
  /// Current quiescent status — set by the Puppet when it reaches Idle /
  /// Suspended / Shutdown. `wait_idle` reads this upon wake.
  mut quiescent_status : QuiescentStatus
  max_depth : Int
}

///|
/// Typed quiescent status returned by `wait_idle`. Distinct from
/// `PuppetPhase` because it carries suspension details and the terminal
/// outcome (ADR §6.7).
pub(all) enum QuiescentStatus {
  /// No run was active.
  Idle
  /// Run is suspended; carries the details needed to resume.
  Suspended(
    run_id~ : RunId,
    suspension_id~ : String,
    requirement_kind~ : String
  )
  /// Run reached terminal outcome; carries the outcome for the caller.
  Terminal(outcome~ : RunOutcome)
  /// Puppet has shut down. No further commands will be accepted.
  Shutdown
} derive(Eq, Debug)

///|
pub impl Show for QuiescentStatus with fn to_string(self : QuiescentStatus) -> String {
  match self {
    Idle => "Idle"
    Suspended(run_id~, suspension_id~, requirement_kind~) =>
      "Suspended(run=\{run_id.to_string()}, susp=\{suspension_id}, kind=\{requirement_kind})"
    Terminal(outcome~) => "Terminal(\{outcome.to_string()})"
    Shutdown => "Shutdown"
  }
}

///|
pub fn ControlMailbox::ControlMailbox() -> ControlMailbox {
  {
    steer_queue: @aqueue.Queue(kind=Unbounded),
    follow_up_queue: @aqueue.Queue(kind=Unbounded),
    steer_depth: 0,
    follow_up_depth: 0,
    fork_queue: @aqueue.Queue(kind=Unbounded),
    fork_depth: 0,
    compact_queue: @aqueue.Queue(kind=Unbounded),
    compact_depth: 0,
    resume_pending: Map::from_array([]),
    abort_requested: false,
    active_run_id: None,
    active_turn_id: None,
    idle_cond: @cond_var.Cond(),
    quiescent_status: Idle,
    max_depth: default_max_queue_depth,
  }
}

///|
pub impl Mailbox for ControlMailbox with fn bind_run(
  self : ControlMailbox,
  run_id : RunId,
  turn_id : TurnId,
) -> Unit {
  self.active_run_id = Some(run_id)
  self.active_turn_id = Some(turn_id)
  self.abort_requested = false
  // `@aqueue.Queue` has no `clear()`: rebuild fresh instances. Old queued
  // commands targeting the previous run are dropped (their command_ids
  // were already Accepted; callers correlate via wait_idle).
  self.steer_queue = @aqueue.Queue(kind=Unbounded)
  self.follow_up_queue = @aqueue.Queue(kind=Unbounded)
  self.steer_depth = 0
  self.follow_up_depth = 0
  self.fork_queue = @aqueue.Queue(kind=Unbounded)
  self.fork_depth = 0
  self.compact_queue = @aqueue.Queue(kind=Unbounded)
  self.compact_depth = 0
  self.resume_pending.clear()
}

///|
/// Clear the active run binding. Called by the Puppet when the run
/// reaches terminal. Any queued commands targeting the now-terminal run
/// are dropped.
pub impl Mailbox for ControlMailbox with fn clear_run(self : ControlMailbox) -> Unit {
  self.active_run_id = None
  self.active_turn_id = None
  self.abort_requested = false
  self.steer_queue = @aqueue.Queue(kind=Unbounded)
  self.follow_up_queue = @aqueue.Queue(kind=Unbounded)
  self.steer_depth = 0
  self.follow_up_depth = 0
  self.fork_queue = @aqueue.Queue(kind=Unbounded)
  self.fork_depth = 0
  self.compact_queue = @aqueue.Queue(kind=Unbounded)
  self.compact_depth = 0
  self.resume_pending.clear()
}

///|
pub impl Mailbox for ControlMailbox with fn active_run_id(self : ControlMailbox) -> RunId? {
  self.active_run_id
}

///|
pub impl Mailbox for ControlMailbox with fn active_turn_id(
  self : ControlMailbox,
) -> TurnId? {
  self.active_turn_id
}

///|
pub impl Mailbox for ControlMailbox with fn abort_requested(
  self : ControlMailbox,
) -> Bool {
  self.abort_requested
}

///|
pub impl Mailbox for ControlMailbox with fn steer_depth(self : ControlMailbox) -> Int {
  self.steer_depth
}

///|
pub impl Mailbox for ControlMailbox with fn follow_up_depth(
  self : ControlMailbox,
) -> Int {
  self.follow_up_depth
}

///|
pub impl Mailbox for ControlMailbox with fn fork_depth(self : ControlMailbox) -> Int {
  self.fork_depth
}

///|
pub impl Mailbox for ControlMailbox with fn compact_depth(self : ControlMailbox) -> Int {
  self.compact_depth
}

// ──────────────────────────────────────────────────────────────────────────
// Enqueue — steer / follow_up / resume / abort
// ──────────────────────────────────────────────────────────────────────────

///|
/// Enqueue a steer command. Rejects if:
/// - no active run (RejectedStale)
/// - target_run_id / target_turn_id don't match active
/// - queue full
///
/// Uses `try_put` (non-blocking) on the underlying `@aqueue.Queue`. The
/// queue is `Unbounded`, so we enforce `max_depth` manually via the
/// `steer_depth` counter to preserve `RejectedQueueFull` semantics.
pub impl Mailbox for ControlMailbox with fn enqueue_steer(
  self : ControlMailbox,
  cmd : SteerCommand,
) -> EnqueueResult {
  match (self.active_run_id, self.active_turn_id) {
    (Some(run), Some(turn)) => {
      if run != cmd.target_run_id || turn != cmd.target_turn_id {
        return RejectedStale(
          command_id=cmd.command_id,
          reason="steer targets stale run/turn",
        )
      }
      if self.steer_depth >= self.max_depth {
        return RejectedQueueFull(
          command_id=cmd.command_id,
          depth=self.steer_depth,
        )
      }
      let put_ok : Bool = self.steer_queue.try_put(cmd) catch {
        _ => false // queue closed — treat as full for caller simplicity
      }
      if !put_ok {
        return RejectedQueueFull(
          command_id=cmd.command_id,
          depth=self.steer_depth,
        )
      }
      self.steer_depth = self.steer_depth + 1
      Accepted(command_id=cmd.command_id)
    }
    _ => RejectedStale(command_id=cmd.command_id, reason="no active run")
  }
}

///|
/// Enqueue a follow-up command. Rejects if no active run or stale ids.
pub impl Mailbox for ControlMailbox with fn enqueue_follow_up(
  self : ControlMailbox,
  cmd : FollowUpCommand,
) -> EnqueueResult {
  match (self.active_run_id, self.active_turn_id) {
    (Some(run), Some(turn)) => {
      if run != cmd.target_run_id || turn != cmd.source_turn_id {
        return RejectedStale(
          command_id=cmd.command_id,
          reason="follow_up targets stale run/turn",
        )
      }
      if self.follow_up_depth >= self.max_depth {
        return RejectedQueueFull(
          command_id=cmd.command_id,
          depth=self.follow_up_depth,
        )
      }
      let put_ok : Bool = self.follow_up_queue.try_put(cmd) catch { _ => false }
      if !put_ok {
        return RejectedQueueFull(
          command_id=cmd.command_id,
          depth=self.follow_up_depth,
        )
      }
      self.follow_up_depth = self.follow_up_depth + 1
      Accepted(command_id=cmd.command_id)
    }
    _ => RejectedStale(command_id=cmd.command_id, reason="no active run")
  }
}

///|
/// Enqueue a resume command. Rejects if no active run or run id mismatch.
/// Multiple resumes for the same suspension_id: the first wins, subsequent
/// are rejected as stale.
pub impl Mailbox for ControlMailbox with fn enqueue_resume(
  self : ControlMailbox,
  cmd : ResumeCommand,
) -> EnqueueResult {
  match self.active_run_id {
    Some(run) => {
      if run != cmd.target_run_id {
        return RejectedStale(
          command_id=cmd.command_id,
          reason="resume targets stale run",
        )
      }
      if self.resume_pending.contains(cmd.suspension_id) {
        return RejectedStale(
          command_id=cmd.command_id,
          reason="resume already pending for this suspension_id",
        )
      }
      self.resume_pending[cmd.suspension_id] = cmd
      Accepted(command_id=cmd.command_id)
    }
    None => RejectedStale(command_id=cmd.command_id, reason="no active run")
  }
}

///|
/// Enqueue an abort. Idempotent: the first call sets `abort_requested`
/// and returns Accepted; subsequent calls return `AbortAlreadyRequested`.
/// Rejects if no active run.
pub impl Mailbox for ControlMailbox with fn enqueue_abort(
  self : ControlMailbox,
  cmd : AbortCommand,
) -> EnqueueResult {
  match self.active_run_id {
    None =>
      RejectedStale(command_id=cmd.command_id, reason="no active run to abort")
    Some(run) => {
      if run != cmd.target_run_id {
        return RejectedStale(
          command_id=cmd.command_id,
          reason="abort targets stale run",
        )
      }
      if self.abort_requested {
        return AbortAlreadyRequested(command_id=cmd.command_id)
      }
      self.abort_requested = true
      // Signal the idle barrier so a wait_idle blocked on this run wakes
      // up (the pump will observe abort_requested on its next tick).
      self.idle_cond.broadcast()
      Accepted(command_id=cmd.command_id)
    }
  }
}

///|
/// Enqueue a fork command (M3.5). Rejects if no active run or stale ids
/// or queue full. The pump consumes one fork per safe point — fork is
/// OneAtATime policy, not All (a fork creates a new session, batching
/// makes no sense).
pub impl Mailbox for ControlMailbox with fn enqueue_fork(
  self : ControlMailbox,
  cmd : ForkCommand,
) -> EnqueueResult {
  match (self.active_run_id, self.active_turn_id) {
    (Some(run), Some(turn)) => {
      if run != cmd.target_run_id || turn != cmd.target_turn_id {
        return RejectedStale(
          command_id=cmd.command_id,
          reason="fork targets stale run/turn",
        )
      }
      if self.fork_depth >= self.max_depth {
        return RejectedQueueFull(
          command_id=cmd.command_id,
          depth=self.fork_depth,
        )
      }
      let put_ok : Bool = self.fork_queue.try_put(cmd) catch { _ => false }
      if !put_ok {
        return RejectedQueueFull(
          command_id=cmd.command_id,
          depth=self.fork_depth,
        )
      }
      self.fork_depth = self.fork_depth + 1
      Accepted(command_id=cmd.command_id)
    }
    _ => RejectedStale(command_id=cmd.command_id, reason="no active run")
  }
}

///|
/// Enqueue a compact command (M3.5). Rejects if no active run or stale ids
/// or queue full. The pump consumes one compact per safe point — compact
/// is OneAtATime policy (batching multiple compacts back-to-back on the
/// same transcript is a no-op).
pub impl Mailbox for ControlMailbox with fn enqueue_compact(
  self : ControlMailbox,
  cmd : CompactCommand,
) -> EnqueueResult {
  match (self.active_run_id, self.active_turn_id) {
    (Some(run), Some(turn)) => {
      if run != cmd.target_run_id || turn != cmd.target_turn_id {
        return RejectedStale(
          command_id=cmd.command_id,
          reason="compact targets stale run/turn",
        )
      }
      if self.compact_depth >= self.max_depth {
        return RejectedQueueFull(
          command_id=cmd.command_id,
          depth=self.compact_depth,
        )
      }
      let put_ok : Bool = self.compact_queue.try_put(cmd) catch { _ => false }
      if !put_ok {
        return RejectedQueueFull(
          command_id=cmd.command_id,
          depth=self.compact_depth,
        )
      }
      self.compact_depth = self.compact_depth + 1
      Accepted(command_id=cmd.command_id)
    }
    _ => RejectedStale(command_id=cmd.command_id, reason="no active run")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Consume — called by the Puppet at safe points
// ──────────────────────────────────────────────────────────────────────────

///|
/// Consume all steer commands at one safe point. The Puppet calls this
/// after a complete tool batch commits and before allocating the next
/// model_step_id. Returns the commands in FIFO order; the queue is
/// drained.
///
/// Uses `try_get` (non-blocking) in a loop until the queue is empty.
pub impl Mailbox for ControlMailbox with fn consume_steers(
  self : ControlMailbox,
) -> Array[SteerCommand] {
  let out : Array[SteerCommand] = []
  while true {
    let next : SteerCommand? = self.steer_queue.try_get() catch {
      _ => None // closed — treat as drained
    }
    match next {
      Some(cmd) => {
        out.push(cmd)
        self.steer_depth = self.steer_depth - 1
      }
      None => break
    }
  }
  out
}

///|
/// Consume one follow-up command (OneAtATime policy). Returns the oldest
/// if any, else None. The Puppet calls this at a turn boundary.
pub impl Mailbox for ControlMailbox with fn consume_one_follow_up(
  self : ControlMailbox,
) -> FollowUpCommand? {
  let next : FollowUpCommand? = self.follow_up_queue.try_get() catch {
    _ => None
  }
  match next {
    Some(cmd) => {
      self.follow_up_depth = self.follow_up_depth - 1
      Some(cmd)
    }
    None => None
  }
}

///|
/// Consume one fork command (OneAtATime policy, M3.5). The Puppet calls
/// this at the safe point after abort check. Returns the oldest fork if
/// any, else None.
pub impl Mailbox for ControlMailbox with fn consume_one_fork(
  self : ControlMailbox,
) -> ForkCommand? {
  let next : ForkCommand? = self.fork_queue.try_get() catch { _ => None }
  match next {
    Some(cmd) => {
      self.fork_depth = self.fork_depth - 1
      Some(cmd)
    }
    None => None
  }
}

///|
/// Consume one compact command (OneAtATime policy, M3.5). The Puppet calls
/// this at the safe point after fork check. Auto compacts (triggered by
/// context-window pressure) bypass this queue and call `execute_compact`
/// directly, but they still go through the same `HostRuntime::compact`
/// path. Returns the oldest compact if any, else None.
pub impl Mailbox for ControlMailbox with fn consume_one_compact(
  self : ControlMailbox,
) -> CompactCommand? {
  let next : CompactCommand? = self.compact_queue.try_get() catch { _ => None }
  match next {
    Some(cmd) => {
      self.compact_depth = self.compact_depth - 1
      Some(cmd)
    }
    None => None
  }
}

///|
/// Take the resume command for a given suspension_id. Returns None if no
/// resume is pending for this suspension (the run stays suspended).
pub impl Mailbox for ControlMailbox with fn take_resume(
  self : ControlMailbox,
  suspension_id : String,
) -> ResumeCommand? {
  match self.resume_pending.get(suspension_id) {
    Some(cmd) => {
      let c = cmd
      self.resume_pending.remove(suspension_id)
      Some(c)
    }
    None => None
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Idle barrier — wait_idle / notify
// ──────────────────────────────────────────────────────────────────────────

///|
/// Current quiescent status. Set by the Puppet via `set_quiescent`.
pub impl Mailbox for ControlMailbox with fn quiescent_status(
  self : ControlMailbox,
) -> QuiescentStatus {
  self.quiescent_status
}

///|
/// Update the quiescent status and wake all waiters. Called by the Puppet
/// when it reaches Idle / Suspended / Terminal / Shutdown. The status is
/// read by `wait_idle` upon wake.
pub impl Mailbox for ControlMailbox with fn set_quiescent(
  self : ControlMailbox,
  status : QuiescentStatus,
) -> Unit {
  self.quiescent_status = status
  self.idle_cond.broadcast()
}

///|
/// Wait until the mailbox reaches a quiescent status. Implemented via
/// `@cond_var.Cond::wait` — NOT polling, NOT sleep. Multiple waiters all
/// wake on `set_quiescent`.
///
/// Returns the quiescent status (never `Idle`-but-still-active — the
/// Puppet only sets quiescent when truly quiescent).
pub impl Mailbox for ControlMailbox with fn wait_idle(self : ControlMailbox) -> QuiescentStatus {
  // Loop because @cond_var may have spurious wakeups; we re-check the
  // status each time. The status starts as Idle (the initial state) so
  // a wait_idle call when already quiescent returns immediately.
  while true {
    match self.quiescent_status {
      Idle =>
        // Idle is quiescent — return immediately.
        return Idle
      Suspended(..) => return self.quiescent_status
      Terminal(..) => return self.quiescent_status
      Shutdown => return Shutdown
    }
    // Active state: wait for the Puppet to signal.
    self.idle_cond.wait()
  }
  // Unreachable; MoonBit needs a return at the end.
  Idle
}
