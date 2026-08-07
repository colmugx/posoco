///|
/// Puppet orchestration — the single long-lived pump (ADR §2.1, §4, §6).
///
/// The Puppet is the ONLY loop in the product that drives RunState forward
/// across model/tool rounds. It composes:
/// - PhaseGate — macro-phase gating + lease
/// - TurnSnapshot — immutable turn capture
/// - ControlMailbox — steer/follow-up/resume/abort + idle barrier
/// - RunJournal + SavepointCoordinator — append-only journal
/// - EventDispatcher — post-commit event dispatch
/// - reducer + execute_one — reused unchanged
///
/// The pump NEVER decides termination by inspecting `tool_calls.is_empty()`.
/// It only drives reducer-declared effects. If the reducer declares zero
/// effects and the state is not terminal, the pump stops and waits for
/// external input (prompt/resume).
///
/// Single-writer: only the pump advances journal revision. Only the pump
/// emits envelopes. Only the pump allocates seq.

// ──────────────────────────────────────────────────────────────────────────
// PuppetConfig — composition root
// ──────────────────────────────────────────────────────────────────────────

///|
/// Inputs to build a Puppet. All fields are required; the Puppet owns
/// the lifetime of every reference.
///
/// The host is an `&HostRuntime` — any implementation (port adapter, direct
/// fixture, external host) that satisfies the canonical effect-execution
/// contract. Catalog-composition validation is the caller's responsibility.
pub(all) struct PuppetConfig {
  host : &@kernel_exec.HostRuntime
  /// Mutable so the Agent can swap in a refreshed snapshot at prompt
  /// boundaries via `Puppet::replace_catalog`. An in-flight run is
  /// unaffected: its RunState pinned the catalog version it started with.
  mut catalog : @kernel_exec.ToolCatalogSnapshot
  journal : &RunJournal
  contributors : Array[&JournalContributor]
  subscribers : Array[&EventSubscriber]
  /// Optional live chunk sink. `None` is the default product path and tells
  /// the HostRuntime to avoid chunk JSON conversion altogether.
  stream_chunks : @kernel_exec.HostChunkCallback?
  /// Pipeline interception hooks, in registration order. The pump calls
  /// `Hook::before_model` before the reducer declares a CallModel effect
  /// (first abort wins; chained rewrite), `Hook::before_tool` before each
  /// tool execution (first non-Approve decision wins), and
  /// `Hook::on_post_event` after each effect commits (read-only).
  hooks : Array[&Hook]
  /// Livelock backstop only: max pump iterations before the pump declares
  /// PumpLoopExceeded. `None` disables the backstop. The kernel budget is
  /// the sole semantic limit; when a budget is configured this is derived
  /// generously from it (2 iterations per round + terminal iteration) so the
  /// budget always fires first.
  max_iterations : Int?
  /// Slash command processors. The pump does NOT invoke these —
  /// `BuiltinCommandPort` is registered here so product code can reach it
  /// through `puppet.commands()`. The BuiltinCommandPort holds a reference
  /// to the Puppet's ControlMailbox so its `/compact` and `/fork-here`
  /// enqueue fork/compact signals for the pump's safe points.
  commands : Array[&CommandPort]
  /// Session store used by fork (and by compact::NewThread) to write the
  /// new session carrying `parent_thread_id` lineage. `None` means the
  /// product did not configure persistence — fork still works in-memory
  /// (the new session id is returned via `PromptResult::ForkCompleted`),
  /// but nothing is durably saved.
  session_store : &SessionStore?
  /// The shared control mailbox. Product composition owns the concrete
  /// `ControlMailbox` instance and lends the same mailbox to the Puppet,
  /// command ports, and any product-layer controllers. Signals enqueued by
  /// those callers reach the pump's safe points.
  mailbox : &Mailbox
}

// ──────────────────────────────────────────────────────────────────────────
// Puppet — the assembled pump
// ──────────────────────────────────────────────────────────────────────────

///|
/// The Puppet. Construct once via `Puppet::new`; call `startup` once
/// before any prompt; call `shutdown` once at product exit.
///
/// The Puppet owns:
/// - PhaseGate (mutable)
/// - &Mailbox (borrowed from `PuppetConfig`; product composition owns the
///   concrete mailbox)
///
/// The Puppet borrows:
/// - &HostRuntime (from config)
/// - &RunJournal (from config)
/// - &JournalContributor[] (from config)
/// - &EventSubscriber[] (from config)
/// - ToolCatalogSnapshot (owned copy; snapshot immutable after capture)
pub struct Puppet {
  config : PuppetConfig
  mut phase_gate : PhaseGate
  /// Borrowed from `PuppetConfig.mailbox` so the Puppet, command ports, and
  /// product layer all share the SAME `ControlMailbox` instance.
  mailbox : &Mailbox
  /// Last terminal transcript. The Kernel owns the live transcript while a
  /// run is active; after a terminal commit the Puppet exposes this immutable
  /// snapshot so products can materialize their canonical session state.
  mut last_completed_transcript : Transcript?
  /// Last terminal outcome captured by the Puppet. `None` means no run has
  /// completed or the current run is suspended.
  mut last_outcome : RunOutcome?
}

///|
pub fn Puppet::Puppet(config : PuppetConfig) -> Puppet {
  {
    config,
    phase_gate: PhaseGate::idle(),
    mailbox: config.mailbox,
    last_completed_transcript: None,
    last_outcome: None,
  }
}

///|
/// Return the last terminal transcript captured by the Puppet. `None` means
/// no run has completed since construction or the current run is suspended.
pub fn Puppet::last_completed_transcript(self : Puppet) -> Transcript? {
  self.last_completed_transcript
}

///|
/// Return the last terminal outcome captured by the Puppet. `None` means no
/// run has completed since construction or the current run is suspended.
pub fn Puppet::last_terminal_outcome(self : Puppet) -> RunOutcome? {
  self.last_outcome
}

///|
/// Swap the tool catalog snapshot between runs. Returns `false` without
/// swapping when a run is active — an in-flight run always keeps the
/// snapshot (and catalog version) its RunState started with. Callers are
/// expected to swap only at prompt boundaries; the active-run guard is
/// defence in depth.
pub fn Puppet::replace_catalog(
  self : Puppet,
  catalog : @kernel_exec.ToolCatalogSnapshot,
) -> Bool {
  match self.mailbox.active_run_id() {
    Some(_) => false
    None => {
      self.config.catalog = catalog
      true
    }
  }
}

///|
pub fn Puppet::phase(self : Puppet) -> PuppetPhase {
  self.phase_gate.phase()
}

///|
/// Borrow the Puppet's mailbox. Product code (BuiltinCommandPort, test
/// harness) uses this to enqueue fork/compact/steer/abort commands that
/// the pump consumes at its safe points. Returns `&Mailbox` so the caller
/// and the pump observe the same underlying `ControlMailbox` instance —
/// mutation through the returned reference is visible to the pump.
pub fn Puppet::mailbox(self : Puppet) -> &Mailbox {
  self.mailbox
}

///|
pub fn Puppet::is_quiescent(self : Puppet) -> Bool {
  self.phase_gate.is_quiescent()
}

// ──────────────────────────────────────────────────────────────────────────
// Shutdown — phase gate + idle barrier wake
// ──────────────────────────────────────────────────────────────────────────

///|
/// Shut the pump down. Idempotent.
pub fn Puppet::shutdown(self : Puppet) -> Unit raise PuppetError {
  // Transition the phase gate to ShuttingDown so any in-flight command
  // is rejected. Active runs are not forcibly aborted (M2 single-threaded
  // means there is no in-flight run when shutdown is called).
  self.phase_gate = self.phase_gate.transition(ShuttingDown)
  self.phase_gate = self.phase_gate.transition(Shutdown)
  // Wake any wait_idle callers so they observe Shutdown.
  self.mailbox.set_quiescent(Shutdown)
}

// ──────────────────────────────────────────────────────────────────────────
// prompt — start a new run
// ──────────────────────────────────────────────────────────────────────────

///|
/// Complete input for one prompt on a long-lived Puppet. Composition-static
/// ports and catalog wiring remain in `PuppetConfig`; every value that may
/// differ from one turn to the next travels through this request.
pub(all) struct PromptRequest {
  run_id : RunId
  turn_id : TurnId
  session_id : SessionId
  initial_messages : Array[Message]
  operation_id : String
  policy : RunPolicy
} derive(Eq, Debug)

///|
/// Result of `prompt`.
pub(all) enum PromptResult {
  /// Run accepted; the puppet has entered Active phase and is driving.
  Accepted(run_id~ : RunId, turn_id~ : TurnId)
  /// Rejected because a lease is already held.
  LeaseBusy(held_by~ : String)
  /// Rejected for another typed reason.
  Rejected(error~ : PuppetError)
  /// M3.5: Fork completed. The pump consumed a `ForkCommand` at a safe
  /// point, snapshotted the transcript's first `fork_index` messages,
  /// wrote them as a new session (carrying `parent_thread_id` lineage) to
  /// the configured SessionStore if any, and stopped the current turn.
  /// Product code should switch its active thread to `new_session_id`.
  /// `forked_messages` is the new thread's body (deep copy of the parent's
  /// transcript prefix). The original thread is untouched and may continue
  /// accepting turns (copy-on-write semantics).
  ForkCompleted(
    run_id~ : RunId,
    turn_id~ : TurnId,
    parent_session_id~ : String,
    new_session_id~ : String,
    forked_messages~ : Array[@kernel.Message]
  )
  /// M3.5: Compact completed. The pump consumed a `CompactCommand`
  /// (manual `/compact`) or auto-triggered compact (90% context-window
  /// pressure) and applied the modelport's `CompactResult` to the current
  /// transcript. `mode` reports how the modelport asked posoco to apply
  /// the result:
  /// - **NewThread**: a new session was created with `parent_thread_id`
  ///   lineage. `new_session_id` is `Some(id)`; product code should switch
  ///   its active thread. The original thread is preserved unchanged.
  /// - **Replace**: the current session's message body was replaced in
  ///   place. `new_session_id` is `None`; product code keeps the same
  ///   active thread. The current turn continues with the compacted body.
  /// - **Append**: the compacted body was appended to the current session.
  ///   `new_session_id` is `None`; product code keeps the same active
  ///   thread. The current turn continues with the appended body.
  CompactCompleted(
    run_id~ : RunId,
    turn_id~ : TurnId,
    mode~ : @kernel.CompactMode,
    trigger~ : @kernel.CompactTrigger,
    new_session_id~ : String?,
    compacted_messages~ : Array[@kernel.Message]
  )
}

///|
pub impl Show for PromptResult with fn to_string(self : PromptResult) -> String {
  match self {
    Accepted(run_id~, turn_id~) =>
      "Accepted(run=\{run_id.to_string()}, turn=\{turn_id.to_string()})"
    LeaseBusy(held_by~) => "LeaseBusy(held_by=\{held_by})"
    Rejected(error~) => "Rejected(\{error.to_string()})"
    ForkCompleted(
      run_id~,
      turn_id~,
      parent_session_id~,
      new_session_id~,
      forked_messages~
    ) =>
      "ForkCompleted(run=\{run_id.to_string()}, turn=\{turn_id.to_string()}, parent=\{parent_session_id}, new=\{new_session_id}, msgs=\{forked_messages.length()})"
    CompactCompleted(
      run_id~,
      turn_id~,
      mode~,
      trigger~,
      new_session_id~,
      compacted_messages~
    ) =>
      "CompactCompleted(run=\{run_id.to_string()}, turn=\{turn_id.to_string()}, mode=\{mode}, trigger=\{trigger}, new=\{match new_session_id { Some(id) => id; None => "-" }}, msgs=\{compacted_messages.length()})"
  }
}

///|
/// Prompt the Puppet with an initial user message. Only legal when the
/// phase is Idle.
///
/// Steps (ADR §6.1):
/// 1. Acquire prompt lease via the phase gate.
/// 2. Capture TurnSnapshot.
/// 3. Bind ControlMailbox to the new run/turn.
/// 4. Transition to Active.
/// 5. Let the pump atomically commit the initial boundary (`InputAccepted`,
///    `RunStarted`, and first model intent) before any model effect.
/// 6. Run the pump until terminal or suspended.
/// 7. On terminal, dispatch terminal event, release lease, return.
///
/// `run_id` / `turn_id` are caller-supplied (host generates them; the
/// Puppet does not allocate). This keeps cross-process resume (M5)
/// possible without a central id factory.
pub async fn Puppet::prompt(
  self : Puppet,
  request : PromptRequest,
) -> PromptResult raise PuppetError {
  let run_id = request.run_id
  let turn_id = request.turn_id
  let session_id = request.session_id
  // Step 1: acquire lease.
  let acquire_result : Result[(PhaseGate, OperationLease), PuppetError] = Ok(
    self.phase_gate.acquire_prompt(request.operation_id, run_id, turn_id),
  ) catch {
    e => Err(e)
  }
  let (gate_with_lease, _lease) = match acquire_result {
    Err(e) => return Rejected(error=e)
    Ok(pair) => pair
  }
  self.phase_gate = gate_with_lease
  self.last_completed_transcript = None
  // Step 2: capture snapshot (validation happens here).
  let snap_input : TurnSnapshotInput = {
    run_id,
    turn_id,
    session_id,
    catalog: self.config.catalog,
    policy: request.policy,
    deadline: None,
    hook_provenance: [],
    lifecycle_provenance: [],
    subscriber_provenance: [],
  }
  let snap_result : Result[TurnSnapshot, PuppetError] = Ok(
    TurnSnapshot::capture(snap_input),
  ) catch {
    e => Err(e)
  }
  let snap = match snap_result {
    Err(e) => {
      // Roll back the lease on snapshot failure.
      self.phase_gate = PhaseGate::idle()
      self.mailbox.set_quiescent(Idle)
      return Rejected(error=e)
    }
    Ok(s) => s
  }
  // Step 3: bind mailbox.
  self.mailbox.bind_run(run_id, turn_id)
  // Step 4: transition to Active. `drive_run` commits the initial boundary
  // before it can dispatch the first model effect.
  self.phase_gate = self.phase_gate.transition(Active)
  // Step 5: run the pump.
  let result = self.drive_run(
    run_id,
    turn_id,
    session_id,
    request.initial_messages.copy(),
    snap,
  )
  // Step 7: release lease and return.
  result
}

// ──────────────────────────────────────────────────────────────────────────
// drive_run — the single long-lived pump
// ──────────────────────────────────────────────────────────────────────────

///|
/// Drive a run to terminal or suspended. Returns a PromptResult carrying
/// the terminal outcome or a typed failure.
///
/// The pump loops over reducer transitions. Each iteration:
/// 1. If ReadyForModel: call `run_model_step` to declare CallModel.
/// 2. If AwaitingModel/AwaitingTools: for each pending effect, execute_one
///    and feed the resulting RunInput back to reduce.
/// 3. After each transition: commit savepoint entries, dispatch events.
/// 4. Check for abort: if mailbox.abort_requested, inject CancelRequested.
/// 5. If Suspended: stop the pump and wait for resume.
/// 6. If Terminal: dispatch terminal event, release lease, set quiescent.
///
/// This is the ONLY loop in the product that drives RunState. It reuses
/// `execute_one` (stateless single-effect executor) and never inspects
/// `tool_calls.is_empty()` to decide termination.
async fn Puppet::drive_run(
  self : Puppet,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  initial_messages : Array[Message],
  snap : TurnSnapshot,
) -> PromptResult raise PuppetError {
  // Build the initial RunState.
  let initial_result : Result[RunState, KernelError] = Ok(
    RunState::initial(run_id~, session_id~, budget=snap.budget()),
  ) catch {
    e => Err(e)
  }
  let initial_state = match initial_result {
    Err(e) =>
      return self.reject_run(
        error=ReducerInvariantViolation(
          category=IllegalPhase(phase="initial", detail=e.to_string()),
        ),
      )
    Ok(s) => s
  }
  // Build the execution context from the host runtime + catalog snapshot.
  // Puppetry forwards canonical values without product-specific conversion.
  // The Run identity is carried so CallModel effects can be scoped.
  let exec_ctx = ExecutionContext::new(
    self.config.host,
    catalog=self.config.catalog,
    run_id~,
    session_id~,
  )
  // Build the event dispatcher.
  let dispatcher = EventDispatcher(run_id, turn_id, session_id)
  for sub in self.config.subscribers {
    dispatcher.register(sub)
  }
  // Seed the reducer with Start.
  // Run before_model hooks on the initial messages — they can modify or abort.
  let mut seeded_messages = initial_messages.copy()
  for hook in self.config.hooks {
    seeded_messages = hook.before_model(seeded_messages) catch {
      HookAbort::Aborted(reason~) =>
        return self.reject_run(
          error=HookRejected(reason="pre_model_hook: " + reason),
        )
    }
  }
  let start_input : RunInput = Start(payload={
    initial_messages: seeded_messages,
    catalog_version: snap.catalog_version(),
  })
  let mut state = initial_state
  let out0_result : Result[ReduceOutput, KernelError] = Ok(
    reduce(state, self.config.catalog, start_input),
  ) catch {
    e => Err(e)
  }
  let out0 = match out0_result {
    Err(e) =>
      return self.reject_run(
        error=ReducerInvariantViolation(
          category=IllegalPhase(phase="Start", detail=e.to_string()),
        ),
      )
    Ok(o) => o
  }
  let initial_boundary : Result[(RunState, Array[KernelEvent]), PuppetError] = Ok(
    declare_model_effect_if_ready(
      out0.next_state(),
      out0.events(),
      self.config.catalog,
      snap.call_options(),
    ),
  ) catch {
    error => Err(error)
  }
  let (initial_state, initial_events) = match initial_boundary {
    Err(error) => return self.reject_run(error~)
    Ok(value) => value
  }
  // The initial boundary durably accepts input, starts the run, and declares
  // the first model intent in one append before the effect can execute.
  let commit_result : Result[Unit, PuppetError] = Ok(
    self.commit_boundary(
      initial_state,
      InputAccepted,
      initial_events,
      dispatcher,
      run_id,
      turn_id,
      session_id,
      "sp_input",
    ),
  ) catch {
    e => Err(e)
  }
  match commit_result {
    Err(e) => return self.reject_run(error=e)
    Ok(_) => ()
  }
  state = initial_state
  // Drive the loop.
  let mut iter = 0
  let max_iter = self.config.max_iterations
  while state.phase() != Terminal && state.phase() != Suspended {
    iter = iter + 1
    match max_iter {
      Some(m) if iter > m =>
        return self.reject_run(error=PumpLoopExceeded(iterations=iter))
      _ => ()
    }
    // Check abort.
    if self.mailbox.abort_requested() {
      let cancel_input : RunInput = CancelRequested(payload={ detail: None })
      let r : Result[ReduceOutput, KernelError] = Ok(
        reduce(state, self.config.catalog, cancel_input),
      ) catch {
        e => Err(e)
      }
      match r {
        Err(e) =>
          return self.reject_run(
            error=ReducerInvariantViolation(
              category=IllegalPhase(phase="cancel", detail=e.to_string()),
            ),
          )
        Ok(out) => {
          state = out.next_state()
          let propagated : Result[Unit, PuppetError] = Ok(
            propagate_terminal_cancellations(out.effects(), exec_ctx),
          ) catch {
            error => Err(error)
          }
          match propagated {
            Err(error) => return self.reject_run(error~)
            Ok(_) => ()
          }
          let cr : Result[Unit, PuppetError] = Ok(
            self.commit_boundary(
              state,
              RunTerminal,
              out.events(),
              dispatcher,
              run_id,
              turn_id,
              session_id,
              "sp_cancel",
            ),
          ) catch {
            e => Err(e)
          }
          match cr {
            Err(e) => return self.reject_run(error=e)
            Ok(_) => ()
          }
        }
      }
      continue
    }
    // ── M3.5 SAFE POINT A2: fork.
    // Consume one fork command. Fork is copy-on-write: the original
    // transcript is never mutated. We snapshot the transcript's first
    // `fork_index` messages, write them as a new session (carrying
    // `parent_thread_id` lineage) if a session_store is configured, and
    // return PromptResult::ForkCompleted. The current turn stops; the
    // product layer may then drive the new session as a separate turn.
    match self.mailbox.consume_one_fork() {
      Some(fork_cmd) => {
        let transcript_msgs = state.transcript().messages_snapshot()
        let len = transcript_msgs.length()
        let fork_index = if fork_cmd.fork_index < 0 {
          0
        } else if fork_cmd.fork_index > len {
          len
        } else {
          fork_cmd.fork_index
        }
        let forked_messages : Array[@kernel.Message] = []
        for i in 0..<fork_index {
          forked_messages.push(transcript_msgs[i])
        }
        let parent_session_id = session_id.to_string()
        let new_session_id = parent_session_id +
          "_fork_" +
          fork_cmd.command_id().to_string()
        // Persist the new session if a session_store is configured. The
        // new session carries `parent_thread_id` lineage so callers can
        // walk the DAG.
        match self.config.session_store {
          Some(store) => {
            let new_session : @types.Session = {
              messages: forked_messages.copy(),
              metadata: Map::from_array([]),
            }
            let with_lineage = new_session.with_parent_thread_id(
              parent_session_id,
            )
            store.save(new_session_id, with_lineage) catch {
              error =>
                return self.reject_run(
                  error=EffectExecutionFailed(
                    phase="fork",
                    cause="session save failed: " + error.to_string(),
                  ),
                )
            }
          }
          None => ()
        }
        // Release lease + clear mailbox before returning ForkCompleted so
        // the next prompt can bind cleanly.
        self.phase_gate = self.phase_gate.transition(Terminalizing)
        self.phase_gate = self.phase_gate.transition(Idle)
        self.mailbox.clear_run()
        return ForkCompleted(
          run_id~,
          turn_id~,
          parent_session_id~,
          new_session_id~,
          forked_messages~,
        )
      }
      None => ()
    }
    // ── M3.5 SAFE POINT A3: compact (manual).
    // Consume one compact command from the queue. Manual compacts come
    // from `/compact` (the BuiltinCommandPort enqueued them with
    // trigger=Manual). Auto compacts (trigger=Auto from context-window
    // pressure) are checked separately inside the ReadyForModel branch.
    match self.mailbox.consume_one_compact() {
      Some(compact_cmd) => {
        let compact_outcome = self.handle_compact(
          state, compact_cmd, run_id, turn_id, session_id, dispatcher, snap,
        )
        match compact_outcome {
          CompactFlow::ReturnedResult(r) => return r
          CompactFlow::UpdatedState(new_state, rewrite_events) => {
            // Journal the compact rewrite before the loop continues; the
            // rewritten transcript is the durable fact the next model step
            // builds on.
            let cr : Result[Unit, PuppetError] = Ok(
              self.commit_boundary(
                new_state,
                boundary_kind_for_events(rewrite_events),
                rewrite_events,
                dispatcher,
                run_id,
                turn_id,
                session_id,
                "sp_compact_\{iter}",
              ),
            ) catch {
              e => Err(e)
            }
            match cr {
              Err(e) => return self.reject_run(error=e)
              Ok(_) => ()
            }
            state = new_state
            continue
          }
          CompactFlow::Failed(error) => return self.reject_run(error~)
        }
      }
      None => ()
    }
    match state.phase() {
      ReadyForModel => {
        // Run before_model hooks — they can rewrite the transcript messages
        // or abort the turn before the model is called. Each hook sees the
        // previous hook's output (chained rewrite). The rewritten messages
        // replace the reducer state's transcript so the next CallModel
        // effect uses them.
        let mut current_messages = state.transcript().messages_snapshot()
        let mut hook_aborted = false
        let mut abort_reason = ""
        for hook in self.config.hooks {
          current_messages = hook.before_model(current_messages) catch {
            HookAbort::Aborted(reason~) => {
              hook_aborted = true
              abort_reason = reason
              []
            }
          }
          if hook_aborted {
            break
          }
        }
        if hook_aborted {
          return self.reject_run(
            error=HookRejected(reason="pre_model_hook: " + abort_reason),
          )
        }
        // Fold the hook-rewritten transcript through the reducer — the sole
        // transcript writer — so the rewrite is journaled as a
        // TranscriptRewritten event in the same boundary as the next model
        // intent. Comparison is by content, not length: a same-length
        // rewrite (e.g. system-prompt replacement) is a real rewrite and
        // must not be silently dropped.
        let rewrite_events : Array[KernelEvent] = []
        if current_messages != state.transcript().messages_snapshot() {
          let rewrite_input : RunInput = TranscriptRewrite(payload={
            rewritten_messages: current_messages,
            reason: "pre_model_hook",
          })
          let reduced : Result[ReduceOutput, KernelError] = Ok(
            reduce(state, self.config.catalog, rewrite_input),
          ) catch {
            e => Err(e)
          }
          match reduced {
            Err(e) =>
              return self.reject_run(
                error=ReducerInvariantViolation(
                  category=IllegalPhase(
                    phase="ReadyForModel",
                    detail="pre_model_hook transcript rewrite: " + e.to_string(),
                  ),
                ),
              )
            Ok(out) => {
              state = out.next_state()
              for event in out.events() {
                rewrite_events.push(event)
              }
            }
          }
        }
        // M3.5: auto-compact threshold check runs INSIDE fold_effect_input
        // (the path the pump takes through AwaitingModel / AwaitingTools),
        // not here. The ReadyForModel branch only fires on the very first
        // model step (the Start input lands in ReadyForModel and
        // declare_model_effect_if_ready moves it to AwaitingModel before
        // the loop iterates), so a check here would never see post-tool
        // usage observations. Auto compact therefore lives in
        // fold_effect_input where the reducer's budget update is
        // observable before the next model effect is declared.
        let declared : Result[(RunState, Array[KernelEvent]), PuppetError] = Ok(
          declare_model_effect_if_ready(
            state,
            rewrite_events,
            self.config.catalog,
            snap.call_options(),
          ),
        ) catch {
          error => Err(error)
        }
        match declared {
          Err(error) => return self.reject_run(error~)
          Ok((next_state, events)) => {
            state = next_state
            let cr : Result[Unit, PuppetError] = Ok(
              self.commit_boundary(
                state,
                AssistantCommitted,
                events,
                dispatcher,
                run_id,
                turn_id,
                session_id,
                "sp_ready_\{iter}",
              ),
            ) catch {
              e => Err(e)
            }
            match cr {
              Err(e) => return self.reject_run(error=e)
              Ok(_) => ()
            }
          }
        }
      }
      AwaitingModel => {
        let pending = state.pending_effects()
        if pending.length() != 1 {
          return self.reject_run(
            error=ReducerInvariantViolation(
              category=IllegalPhase(
                phase="AwaitingModel",
                detail="expected exactly one pending model effect",
              ),
            ),
          )
        }
        let executed : Result[RunInput, PuppetError] = Ok(
          execute_model_effect(pending[0], exec_ctx, self.config.stream_chunks),
        ) catch {
          error => Err(error)
        }
        let input = match executed {
          Err(error) => return self.reject_run(error~)
          Ok(value) => value
        }
        let folded : Result[FoldOutcome, PuppetError] = Ok(
          self.fold_effect_input(
            state,
            input,
            dispatcher,
            run_id,
            turn_id,
            session_id,
            "sp_model_effect_\{iter}",
            snap,
          ),
        ) catch {
          error => Err(error)
        }
        match folded {
          Err(error) => return self.reject_run(error~)
          Ok(FoldOutcome::Return(r)) => return r
          Ok(FoldOutcome::Continue(next_state)) => {
            self.fire_post_event_hooks(input)
            state = next_state
          }
        }
      }
      AwaitingTools => {
        let wave_result : Result[Array[Array[Effect]], PuppetError] = Ok(
          scheduled_tool_effect_waves(
            state.pending_effects(),
            self.config.catalog,
            state.catalog_version(),
          ),
        ) catch {
          error => Err(error)
        }
        let waves = match wave_result {
          Err(error) => return self.reject_run(error~)
          Ok(value) => value
        }
        for wave_index, wave in waves {
          // Run pre-tool hooks on each ExecuteTool effect in the wave.
          // Hooks can rewrite the call (chained — each hook sees the previous
          // hook's output), defer it (suspend), or reject (abort). The
          // rewritten call replaces the payload passed to the executor so the
          // host sees the hook-modified name/arguments. call_id is preserved
          // so reducer correlation stays intact.
          let rewritten_wave : Array[Effect] = []
          for effect in wave {
            match effect {
              @kernel_exec.ExecuteTool(effect_id~, payload~) => {
                let mut current_call : ToolCall = {
                  call_id: payload.call_id,
                  name: payload.tool_name,
                  arguments: payload.arguments,
                }
                let mut aborted = false
                let mut deferred_reason : String? = None
                for hook in self.config.hooks {
                  let decision = hook.before_tool(current_call) catch {
                    err => {
                      // Keep the `execution_error` classification: a
                      // cancellation raised inside the hook (e.g. the host
                      // aborts an approval prompt) is NOT a hook defect.
                      if @async.is_cancellation_error(err) {
                        return self.reject_run(
                          error=EffectExecutionCancelled(phase="AwaitingTools"),
                        )
                      }
                      return self.reject_run(
                        error=HookRejected(
                          reason="pre_tool_hook raised: " + err.to_string(),
                        ),
                      )
                    }
                  }
                  match decision {
                    Approve(call~) => {
                      current_call = call
                      continue
                    }
                    Defer(reason~) => {
                      deferred_reason = Some(reason)
                      aborted = true
                      break
                    }
                    Reject(reason~) =>
                      return self.reject_run(
                        error=HookRejected(reason="pre_tool_hook: " + reason),
                      )
                  }
                }
                if aborted {
                  match deferred_reason {
                    // Frozen wording: extensions (e.g. posoco-ext-permission)
                    // document this exact terminal-reject behavior; M5 will
                    // replace it with real suspension.
                    Some(reason) =>
                      return self.reject_run(
                        error=HookRejected(
                          reason="pre_tool_hook defer not yet supported: " +
                            reason,
                        ),
                      )
                    None => ()
                  }
                }
                // Reconstruct the effect with the rewritten name/arguments.
                // call_id, owner, model_step_id, catalog_version are preserved.
                rewritten_wave.push(
                  @kernel_exec.ExecuteTool(effect_id~, payload=@kernel_exec.ExecuteToolPayload::{
                    call_id: payload.call_id,
                    tool_name: current_call.name,
                    arguments: current_call.arguments,
                    owner: payload.owner,
                    model_step_id: payload.model_step_id,
                    catalog_version: payload.catalog_version,
                  }),
                )
              }
              _ => rewritten_wave.push(effect)
            }
          }
          let wave = rewritten_wave
          // `@async.all` starts every effect in the reducer-approved wave,
          // waits at its barrier, and returns inputs in source order. The
          // reducer remains the sole owner of transcript/result ordering.
          let executed : Result[Array[RunInput], PuppetError] = Ok(
            execute_tool_wave(wave, exec_ctx),
          ) catch {
            error => Err(error)
          }
          let inputs = match executed {
            Err(error) => return self.reject_run(error~)
            Ok(value) => value
          }
          for input in inputs {
            let folded : Result[FoldOutcome, PuppetError] = Ok(
              self.fold_effect_input(
                state,
                input,
                dispatcher,
                run_id,
                turn_id,
                session_id,
                "sp_tool_wave_\{wave_index}",
                snap,
              ),
            ) catch {
              error => Err(error)
            }
            match folded {
              Err(error) => return self.reject_run(error~)
              Ok(FoldOutcome::Return(r)) => return r
              Ok(FoldOutcome::Continue(next_state)) => {
                self.fire_post_event_hooks(input)
                state = next_state
              }
            }
            if state.phase() == Terminal || state.phase() == Suspended {
              break
            }
          }
          // Abort is observed at a side-effect boundary. Do not launch a
          // later wave after it was requested; the next pump iteration feeds
          // CancelRequested into the reducer.
          if state.phase() == Terminal ||
            state.phase() == Suspended ||
            self.mailbox.abort_requested() {
            break
          }
        }
      }
      _ => break
    }
  }
  // Handle terminal / suspended outcomes.
  match state.phase() {
    Terminal => {
      let outcome = match state.outcome() {
        Some(o) => o
        None =>
          return self.reject_run(
            error=ReducerInvariantViolation(
              category=IllegalPhase(
                phase="Terminal",
                detail="outcome is None at Terminal",
              ),
            ),
          )
      }
      self.mailbox.set_quiescent(Terminal(outcome~))
      self.last_completed_transcript = Some(state.transcript())
      self.last_outcome = Some(outcome)
      // Release lease + clear mailbox.
      self.phase_gate = self.phase_gate.transition(Terminalizing)
      self.phase_gate = self.phase_gate.transition(Idle)
      self.mailbox.clear_run()
      Accepted(run_id~, turn_id~)
    }
    Suspended => {
      let req = match state.suspension_requirement() {
        Some(r) => r
        None =>
          return self.reject_run(
            error=ReducerInvariantViolation(
              category=IllegalPhase(
                phase="Suspended",
                detail="requirement is None",
              ),
            ),
          )
      }
      // Generate a suspension_id (deterministic; M5 will use a durable id).
      let suspension_id = "susp_\{run_id.to_string()}_\{state.current_model_step_id().to_int()}"
      self.phase_gate = self.phase_gate.enter_suspended(suspension_id)
      self.mailbox.set_quiescent(
        Suspended(run_id~, suspension_id~, requirement_kind=req.kind),
      )
      // Lease is NOT released: resume will continue under the same lease.
      Accepted(run_id~, turn_id~)
    }
    _ =>
      // Pump exited without reaching terminal or suspended.
      self.reject_run(error=PumpLoopExceeded(iterations=iter))
  }
}

// ──────────────────────────────────────────────────────────────────────────
// M3.5 — Fork + Compact safe-point handlers
// ──────────────────────────────────────────────────────────────────────────

///|
/// Outcome of `handle_compact`: either the pump should return the given
/// `PromptResult` (compact::NewThread stops the turn with CompactCompleted),
/// or it should adopt the new `RunState` and continue the loop (Replace /
/// Append), or it should reject the run (compact failed). `UpdatedState`
/// carries the reducer-emitted rewrite events; the CALLER commits them into
/// the next boundary so journal order stays causal (the rewrite follows the
/// facts that produced the pre-compact state).
priv enum CompactFlow {
  ReturnedResult(PromptResult)
  UpdatedState(RunState, Array[KernelEvent])
  Failed(PuppetError)
}

///|
/// Apply one compact command. Calls `HostRuntime::compact` (which forwards
/// to `ModelPort::compact`) and applies the result according to its
/// `CompactMode`:
/// - **NewThread**: write a new session with lineage, release lease, and
///   return `PromptResult::CompactCompleted(new_session_id=Some(...))`.
///   The current turn stops.
/// - **Replace**: rebuild the transcript from `compacted_messages` and
///   return `UpdatedState`. The loop continues on the same session id.
/// - **Append**: append `compacted_messages` to the current transcript and
///   return `UpdatedState`. The loop continues on the same session id.
///
/// Replace/Append fold the transcript change through the reducer — the sole
/// transcript writer — as a `TranscriptRewrite` input, so the compact is
/// journaled as a `TranscriptRewritten` event instead of an untracked
/// mutation. `commit_boundary` is NOT called here; the caller commits the
/// returned events at the next boundary.
async fn Puppet::handle_compact(
  self : Puppet,
  state : RunState,
  compact_cmd : CompactCommand,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  _dispatcher : EventDispatcher,
  snap : TurnSnapshot,
) -> CompactFlow raise PuppetError {
  let messages = state.transcript().messages_snapshot()
  // Compact is host-driven (a mailbox command), not a reducer-allocated
  // effect — hence `effect_id: None`. Run/session identity still applies.
  let scope : InvocationScope = { session_id, run_id, effect_id: None }
  let attempted : Result[Result[CompactResult, @kernel.ModelFailure], Error] = Ok(
    self.config.host.compact(
      scope,
      messages,
      snap.call_options(),
      compact_cmd.trigger(),
    ),
  ) catch {
    error => Err(error)
  }
  let compact_result = match attempted {
    Err(error) =>
      return CompactFlow::Failed(
        EffectExecutionFailed(
          phase="compact",
          cause="host compact raised: " + error.to_string(),
        ),
      )
    Ok(Err(failure)) =>
      return CompactFlow::Failed(
        EffectExecutionFailed(
          phase="compact",
          cause="modelport compact failed: " + failure.to_string(),
        ),
      )
    Ok(Ok(result)) => result
  }
  match compact_result.mode {
    @kernel.NewThread => {
      let new_session_id = session_id.to_string() +
        "_compact_" +
        compact_cmd.command_id().to_string()
      // Persist the new session if configured.
      match self.config.session_store {
        Some(store) => {
          let new_session : @types.Session = {
            messages: compact_result.compacted_messages.copy(),
            metadata: Map::from_array([]),
          }
          let with_lineage = new_session.with_parent_thread_id(
            session_id.to_string(),
          )
          store.save(new_session_id, with_lineage) catch {
            error =>
              return CompactFlow::Failed(
                EffectExecutionFailed(
                  phase="compact",
                  cause="session save failed: " + error.to_string(),
                ),
              )
          }
        }
        None => ()
      }
      // Release lease + clear mailbox before returning.
      self.phase_gate = self.phase_gate.transition(Terminalizing)
      self.phase_gate = self.phase_gate.transition(Idle)
      self.mailbox.clear_run()
      CompactFlow::ReturnedResult(
        CompactCompleted(
          run_id~,
          turn_id~,
          mode=@kernel.NewThread,
          trigger=compact_cmd.trigger(),
          new_session_id=Some(new_session_id),
          compacted_messages=compact_result.compacted_messages,
        ),
      )
    }
    @kernel.Replace => {
      let rewrite_input : RunInput = TranscriptRewrite(payload={
        rewritten_messages: compact_result.compacted_messages,
        reason: "compact_replace",
      })
      let reduced : Result[ReduceOutput, KernelError] = Ok(
        reduce(state, self.config.catalog, rewrite_input),
      ) catch {
        e => Err(e)
      }
      match reduced {
        Err(e) =>
          CompactFlow::Failed(
            ReducerInvariantViolation(
              category=IllegalPhase(
                phase="compact-replace",
                detail=e.to_string(),
              ),
            ),
          )
        Ok(out) => CompactFlow::UpdatedState(out.next_state(), out.events())
      }
    }
    @kernel.Append => {
      let current = state.transcript().messages_snapshot()
      let combined : Array[@kernel.Message] = []
      for m in current {
        combined.push(m)
      }
      for m in compact_result.compacted_messages {
        combined.push(m)
      }
      let rewrite_input : RunInput = TranscriptRewrite(payload={
        rewritten_messages: combined,
        reason: "compact_append",
      })
      let reduced : Result[ReduceOutput, KernelError] = Ok(
        reduce(state, self.config.catalog, rewrite_input),
      ) catch {
        e => Err(e)
      }
      match reduced {
        Err(e) =>
          CompactFlow::Failed(
            ReducerInvariantViolation(
              category=IllegalPhase(
                phase="compact-append",
                detail=e.to_string(),
              ),
            ),
          )
        Ok(out) => CompactFlow::UpdatedState(out.next_state(), out.events())
      }
    }
  }
}

///|
/// Check whether auto-compact should fire on this iteration. Returns
/// `Some(CompactCommand{trigger=Auto})` when `observed_total_tokens >=
/// context_window * compact_threshold`. Returns `None` when:
/// - `context_window` is `None` (auto-compact disabled), OR
/// - `any_usage_verified` is false (no model step reported usage yet), OR
/// - usage is below the threshold.
///
/// The command_id is deterministic per (run_id, model_step_id) so two
/// checks in the same step cannot enqueue duplicates.
fn Puppet::check_auto_compact(
  self : Puppet,
  state : RunState,
  snap : TurnSnapshot,
) -> CompactCommand? {
  let context_window = match snap.context_window() {
    Some(w) => w
    None => return None
  }
  if context_window <= 0 {
    return None
  }
  let consumed = state.budget_consumed()
  // Without a verified usage observation we cannot honestly claim the
  // threshold has been crossed. The reducer explicitly tracks this.
  if !consumed.any_usage_verified {
    return None
  }
  // threshold * 100 rounded — compact_threshold is validated at capture.
  let threshold_units = (snap.compact_threshold() * 100.0).to_int()
  // total_units = context_window * threshold; floor at 0.
  let limit = context_window * threshold_units / 100
  if consumed.observed_total_tokens >= limit {
    let cid = "auto_" +
      state.run_id().to_string() +
      "_" +
      state.current_model_step_id().to_int().to_string()
    Some({
      command_id: CommandId::unchecked(cid),
      target_run_id: state.run_id(),
      target_turn_id: match self.mailbox.active_turn_id() {
        Some(t) => t
        None =>
          // Defensive: if mailbox is unbound we cannot correlate. The
          // pump is inside drive_run so the mailbox MUST be bound; this
          // branch is unreachable in practice.
          return None
      },
      trigger: @kernel.Auto,
    })
  } else {
    None
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Effect completion folding — reducer then durable savepoint
// ──────────────────────────────────────────────────────────────────────────

///|
/// Fold one completed effect through the reducer, declare the next model
/// effect when the reducer reaches `ReadyForModel`, and commit the complete
/// side-effect boundary before returning. Execution and scheduling remain
/// outside this helper; it is only the reducer → boundary-journal seam.

///|
/// Outcome of `fold_effect_input`. Either the next state to drive, or a
/// terminal PromptResult to return early (used by auto-compact when the
/// modelport chose NewThread — the run stops with CompactCompleted).
priv enum FoldOutcome {
  Continue(RunState)
  Return(PromptResult)
}

///|
async fn Puppet::fold_effect_input(
  self : Puppet,
  state : RunState,
  input : RunInput,
  dispatcher : EventDispatcher,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  savepoint_id_prefix : String,
  snap : TurnSnapshot,
) -> FoldOutcome raise PuppetError {
  let reduced : Result[ReduceOutput, KernelError] = Ok(
    reduce(state, self.config.catalog, input),
  ) catch {
    error => Err(error)
  }
  let output = match reduced {
    Err(error) =>
      raise ReducerInvariantViolation(
        category=IllegalPhase(phase="effect", detail=error.to_string()),
      )
    Ok(value) => value
  }
  // M3.5: auto-compact threshold check. If the reducer just landed in
  // ReadyForModel AND observed token usage crossed the threshold, fire
  // a compact (trigger=Auto) BEFORE declaring the next model effect.
  // NewThread mode stops the turn with CompactCompleted; Replace / Append
  // updates the state and we proceed to declare_model_effect_if_ready
  // on the post-compact transcript.
  let rewrite_events : Array[KernelEvent] = []
  let state_after_auto_compact = if output.next_state().phase() == ReadyForModel {
    match self.check_auto_compact(output.next_state(), snap) {
      Some(compact_cmd) => {
        let compact_outcome = self.handle_compact(
          output.next_state(),
          compact_cmd,
          run_id,
          turn_id,
          session_id,
          dispatcher,
          snap,
        )
        match compact_outcome {
          CompactFlow::ReturnedResult(r) => return FoldOutcome::Return(r)
          CompactFlow::UpdatedState(new_state, events) => {
            for event in events {
              rewrite_events.push(event)
            }
            new_state
          }
          CompactFlow::Failed(error) =>
            return FoldOutcome::Return(self.reject_run(error~))
        }
      }
      None => output.next_state()
    }
  } else {
    output.next_state()
  }
  // Journal order stays causal: the effect-completion events that produced
  // the pre-compact state come first, then the compact rewrite, then the
  // next declared model intent — all committed in one boundary.
  let prior_events = output.events()
  for event in rewrite_events {
    prior_events.push(event)
  }
  let boundary_kind = boundary_kind_for_events(prior_events)
  let (next_state, boundary_events) = declare_model_effect_if_ready(
    state_after_auto_compact,
    prior_events,
    self.config.catalog,
    snap.call_options(),
  )
  let committed : Result[Unit, PuppetError] = Ok(
    self.commit_boundary(
      next_state, boundary_kind, boundary_events, dispatcher, run_id, turn_id, session_id,
      savepoint_id_prefix,
    ),
  ) catch {
    error => Err(error)
  }
  match committed {
    Err(error) => raise error
    Ok(_) => FoldOutcome::Continue(next_state)
  }
}

///|
/// The pump is allowed to request a model step only after the reducer has
/// reached `ReadyForModel`. Merge that declared intent into the same durable
/// boundary as the fact that made it ready; the model effect is never
/// dispatched before this boundary commits.
fn declare_model_effect_if_ready(
  state : RunState,
  prior_events : Array[KernelEvent],
  catalog : ToolCatalogSnapshot,
  call_options : Json,
) -> (RunState, Array[KernelEvent]) raise PuppetError {
  if state.phase() != ReadyForModel {
    return (state, prior_events.copy())
  }
  let declared : Result[ReduceOutput, KernelError] = Ok(
    run_model_step(state, catalog, call_options),
  ) catch {
    error => Err(error)
  }
  let output = match declared {
    Err(error) =>
      raise ReducerInvariantViolation(
        category=IllegalPhase(phase="run_model_step", detail=error.to_string()),
      )
    Ok(value) => value
  }
  let events = prior_events.copy()
  for event in output.events() {
    events.push(event)
  }
  (output.next_state(), events)
}

///|
/// Execute the single reducer-declared model effect. Expected provider
/// failures travel as `ModelFailed` data; raised host defects are surfaced as
/// a distinct Puppet error and never fabricated into a completion.
///
/// (R3 M3.7: the previous `(RunInput, NewThreadSpec?)` tuple has been removed
/// — compact is now a separate `ModelPort::compact` method driven by posoco,
/// not a side-channel of `CallModel`.)
async fn execute_model_effect(
  effect : Effect,
  context : ExecutionContext,
  on_chunk : @kernel_exec.HostChunkCallback?,
) -> RunInput raise PuppetError {
  let attempted : Result[RunInput, Error] = Ok(
    execute_one(effect, context, on_chunk),
  ) catch {
    error => Err(error)
  }
  match attempted {
    Ok(value) => value
    Err(error) => raise execution_error("AwaitingModel", error)
  }
}

///|
/// Execute one already-scheduled tool wave. `@async.all` supplies the actual
/// parallelism and cancels peers if one task raises. Its result array remains
/// in source order, which the caller feeds to the reducer deterministically.
async fn execute_tool_wave(
  effects : Array[Effect],
  context : ExecutionContext,
) -> Array[RunInput] raise PuppetError {
  let attempted : Result[Array[RunInput], Error] = Ok(
    @async.all(
      effects.map(fn(effect) { () => execute_one(effect, context, None) }),
    ),
  ) catch {
    error => Err(error)
  }
  match attempted {
    Ok(values) => values
    Err(error) => raise execution_error("AwaitingTools", error)
  }
}

///|
/// Propagate reducer-declared cancellation effects at their terminal boundary.
/// Cancellation has no reducer completion input: converting it into a tool or
/// model result would fabricate a fact. The host must return one disposition
/// for every requested effect id; malformed reports fail the run loudly.
async fn propagate_terminal_cancellations(
  effects : Array[Effect],
  context : ExecutionContext,
) -> Unit raise PuppetError {
  for effect in effects {
    match effect {
      @kernel_exec.CancelOutstanding(payload~, ..) => {
        let attempted : Result[Array[(EffectId, CancelDisposition)], Error] = Ok(
          context.host.cancel_effects(payload.effect_ids, payload.reason),
        ) catch {
          error => Err(error)
        }
        let dispositions = match attempted {
          Ok(value) => value
          Err(error) =>
            raise EffectExecutionFailed(
              phase="CancelOutstanding",
              cause=error.to_string(),
            )
        }
        validate_cancel_dispositions(payload.effect_ids, dispositions)
      }
      other =>
        raise EffectExecutionFailed(
          phase="CancelOutstanding",
          cause="terminal cancellation boundary received non-cancellation effect: " +
            other.to_string(),
        )
    }
  }
}

///|
/// Verify that a host reported exactly one disposition for every requested
/// effect. `NotPropagated` is an explicit adapter fact; missing, duplicate,
/// or foreign ids are contract failures.
fn validate_cancel_dispositions(
  expected : Array[EffectId],
  reported : Array[(EffectId, CancelDisposition)],
) -> Unit raise PuppetError {
  if expected.length() != reported.length() {
    raise EffectExecutionFailed(
      phase="CancelOutstanding",
      cause="host returned a cancellation disposition count different from the request",
    )
  }
  let expected_ids : Map[String, Bool] = Map::from_array([])
  for effect_id in expected {
    let key = effect_id.to_string()
    if expected_ids.contains(key) {
      raise EffectExecutionFailed(
        phase="CancelOutstanding",
        cause="reducer declared duplicate cancellation effect id " + key,
      )
    }
    expected_ids[key] = true
  }
  let reported_ids : Map[String, Bool] = Map::from_array([])
  for entry in reported {
    let (effect_id, _disposition) = entry
    let key = effect_id.to_string()
    if !expected_ids.contains(key) {
      raise EffectExecutionFailed(
        phase="CancelOutstanding",
        cause="host reported cancellation for unknown effect id " + key,
      )
    }
    if reported_ids.contains(key) {
      raise EffectExecutionFailed(
        phase="CancelOutstanding",
        cause="host reported duplicate cancellation disposition for effect id " +
          key,
      )
    }
    reported_ids[key] = true
  }
}

///|
/// Convert an executor-raised error into an observable typed product error.
/// Cancellation stays distinct from a host defect; neither becomes a normal
/// tool result or a synthetic model completion.
fn execution_error(phase : String, error : Error) -> PuppetError {
  if @async.is_cancellation_error(error) {
    EffectExecutionCancelled(phase~)
  } else {
    EffectExecutionFailed(phase~, cause=error.to_string())
  }
}

// ──────────────────────────────────────────────────────────────────────────
// commit_boundary — the deterministic pre-commit → freeze → commit → dispatch
// ──────────────────────────────────────────────────────────────────────────

///|
/// Commit one fixed side-effect boundary. The boundary emits every KernelEvent
/// only after the single journal barrier succeeds, but persists only its
/// recovery-relevant primary fact. This keeps append count proportional to
/// side effects rather than the number of observer events.
async fn Puppet::commit_boundary(
  self : Puppet,
  state : RunState,
  kind : SavepointKind,
  events : Array[KernelEvent],
  dispatcher : EventDispatcher,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  boundary_id_prefix : String,
) -> Unit raise PuppetError {
  let pre_commit_rev = self.config.journal.revision()
  let savepoint_id = "\{boundary_id_prefix}_r\{pre_commit_rev}"
  let entry = boundary_entry(
    state, kind, events, run_id, turn_id, session_id, savepoint_id,
  )
  let ctx : PreCommitContext = {
    run_id,
    turn_id,
    session_id,
    savepoint_id,
    savepoint_kind: kind,
    base_entries: [entry],
    current_revision: pre_commit_rev,
    catalog_version: state.catalog_version(),
  }
  let batch = prepare_batch(ctx, self.config.contributors)
  let committed_rev = commit_batch(self.config.journal, batch)
  // Every event is published after the one boundary commit. They share its
  // committed revision while EventDispatcher preserves a strict event seq.
  for event in events {
    dispatcher.dispatch(event, committed_rev)
  }
}

///|
/// Select the one boundary category for a reducer transition. Priority is
/// terminal → suspension → tool outcome → assistant completion → input.
/// This is a fixed runtime rule, not an extension-selectable policy.
fn boundary_kind_for_events(events : Array[KernelEvent]) -> SavepointKind {
  for event in events {
    match event {
      RunCompleted(..) | RunFailed(..) | RunCancelled(..) => return RunTerminal
      _ => ()
    }
  }
  for event in events {
    match event {
      RunSuspended(..) => return RunSuspended
      _ => ()
    }
  }
  for event in events {
    match event {
      ToolCompleted(..) => return ToolCommitted
      _ => ()
    }
  }
  for event in events {
    match event {
      ModelStepCompleted(..) => return AssistantCommitted
      _ => ()
    }
  }
  for event in events {
    match event {
      RunStarted(..) => return InputAccepted
      _ => ()
    }
  }
  // `ModelStepStarted` is an intent attached to an existing boundary in the
  // normal pump flow. If it is ever committed alone, retain it as an
  // assistant boundary rather than silently omitting it.
  AssistantCommitted
}

///|
/// Map one event to its natural boundary category. Used solely to choose the
/// persisted primary fact within a multi-event boundary.
fn event_to_boundary_kind(event : KernelEvent) -> SavepointKind {
  match event {
    RunStarted(..) => InputAccepted
    ModelStepCompleted(..) => AssistantCommitted
    ToolCompleted(..) => ToolCommitted
    RunSuspended(..) => RunSuspended
    RunCompleted(..) | RunFailed(..) | RunCancelled(..) => RunTerminal
    _ => AssistantCommitted
  }
}

///|
/// Construct the one durable entry for a boundary. The entry kind describes
/// the recovery boundary; event payloads retain their exact event kind for
/// inspection without forcing a durability barrier per observer event.
fn boundary_entry(
  state : RunState,
  kind : SavepointKind,
  events : Array[KernelEvent],
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  savepoint_id : String,
) -> JournalEntry raise PuppetError {
  if events.is_empty() {
    raise ReducerInvariantViolation(
      category=IllegalPhase(
        phase="commit_boundary",
        detail="boundary has no events",
      ),
    )
  }
  let (summary, payload) = if kind == InputAccepted {
    (
      "InputAccepted(run=\{run_id.to_string()})",
      Json::object(
        Map::from_array([
          ("kind", Json::string("InputAccepted")),
          ("run_id", Json::string(run_id.to_string())),
          ("turn_id", Json::string(turn_id.to_string())),
          ("session_id", Json::string(session_id.to_string())),
          (
            "catalog_version",
            Json::number(state.catalog_version().to_int().to_double()),
          ),
        ]),
      ),
    )
  } else {
    let primary = boundary_primary_event(events, kind)
    (primary.to_string(), kernel_event_payload(primary))
  }
  {
    identity: { run_id, turn_id, session_id, savepoint_id, kind, entry_seq: 0 },
    revision: 0,
    summary,
    payload,
  }
}

///|
/// Find the event that represents the durable fact for its boundary.
fn boundary_primary_event(
  events : Array[KernelEvent],
  kind : SavepointKind,
) -> KernelEvent raise PuppetError {
  for event in events {
    if event_to_boundary_kind(event) == kind {
      return event
    }
  }
  if events.is_empty() {
    raise ReducerInvariantViolation(
      category=IllegalPhase(
        phase="commit_boundary",
        detail="boundary has no primary event",
      ),
    )
  }
  events[0]
}

///|
/// Convert a committed domain event into a bounded, machine-readable journal
/// payload. This intentionally carries event facts and safe summaries only;
/// prompts, tool arguments, image data and tool result bodies remain outside
/// the journal payload.
fn kernel_event_payload(event : KernelEvent) -> Json {
  match event {
    RunStarted(details~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("RunStarted")),
          ("run_id", Json::string(details.run_id.to_string())),
          ("session_id", Json::string(details.session_id.to_string())),
        ]),
      )
    ModelStepStarted(model_step_id~, effect_id~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("ModelStepStarted")),
          ("model_step_id", Json::number(model_step_id.to_int().to_double())),
          ("effect_id", Json::number(effect_id.to_int().to_double())),
        ]),
      )
    ModelStepCompleted(model_step_id~, ..) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("ModelStepCompleted")),
          ("model_step_id", Json::number(model_step_id.to_int().to_double())),
          // KernelEvent::Show intentionally excludes message/provider payloads.
          ("summary", Json::string(event.to_string())),
        ]),
      )
    ToolBatchStarted(model_step_id~, calls~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("ToolBatchStarted")),
          ("model_step_id", Json::number(model_step_id.to_int().to_double())),
          ("call_count", Json::number(calls.length().to_double())),
        ]),
      )
    ToolCompleted(call_id~, outcome~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("ToolCompleted")),
          ("call_id", Json::string(call_id.to_string())),
          ("outcome", Json::string(outcome.summary())),
        ]),
      )
    RunSuspended(requirement~, model_step_id~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("RunSuspended")),
          ("requirement_kind", Json::string(requirement.kind)),
          ("model_step_id", Json::number(model_step_id.to_int().to_double())),
        ]),
      )
    RunResumed(model_step_id~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("RunResumed")),
          ("model_step_id", Json::number(model_step_id.to_int().to_double())),
        ]),
      )
    CancelRequested(effect_ids~, reason~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("CancelRequested")),
          ("effect_count", Json::number(effect_ids.length().to_double())),
          ("reason", Json::string(reason.to_string())),
        ]),
      )
    BudgetExhausted(dimension~, consumed~, limit~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("BudgetExhausted")),
          ("dimension", Json::string(dimension.to_string())),
          ("consumed", Json::number(consumed.to_double())),
          ("limit", Json::number(limit.to_double())),
        ]),
      )
    InputRejected(input_kind~, reason~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("InputRejected")),
          ("input_kind", Json::string(input_kind)),
          ("reason", Json::string(reason)),
        ]),
      )
    TranscriptRewritten(messages_before~, messages_after~, reason~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("TranscriptRewritten")),
          ("messages_before", Json::number(messages_before.to_double())),
          ("messages_after", Json::number(messages_after.to_double())),
          ("reason", Json::string(reason)),
        ]),
      )
    RunCompleted(final_message_summary~, model_steps~, tool_calls~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("RunCompleted")),
          ("summary", Json::string(final_message_summary)),
          ("model_steps", Json::number(model_steps.to_double())),
          ("tool_calls", Json::number(tool_calls.to_double())),
        ]),
      )
    RunFailed(reason~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("RunFailed")),
          ("reason", Json::string(reason.to_string())),
        ]),
      )
    RunCancelled(reason~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("RunCancelled")),
          ("reason", Json::string(reason.to_string())),
        ]),
      )
  }
}

///|
/// Put the Puppet back into a quiescent, retryable state on a host-level
/// failure that prevents the reducer from producing a terminal outcome. The
/// typed error remains the caller-visible diagnostic; cleanup must not leave a
/// stale lease or an active mailbox behind.
fn Puppet::reject_run(self : Puppet, error~ : PuppetError) -> PromptResult {
  self.phase_gate = PhaseGate::idle()
  self.mailbox.clear_run()
  self.mailbox.set_quiescent(Idle)
  Rejected(error~)
}

// ──────────────────────────────────────────────────────────────────────────
// wait_idle — delegate to mailbox
// ──────────────────────────────────────────────────────────────────────────

///|
/// Wait until the Puppet reaches a quiescent status. Returns Idle,
/// Suspended, Terminal, or Shutdown (typed, distinct). Implemented via
/// `@cond_var.Cond::wait` — NOT polling.
pub async fn Puppet::wait_idle(self : Puppet) -> QuiescentStatus {
  self.mailbox.wait_idle()
}

// ──────────────────────────────────────────────────────────────────────────
// Post-event hook fire helper
// ──────────────────────────────────────────────────────────────────────────

///|
/// Fire every registered hook's `on_post_event` for a completed effect.
/// The `Hook::on_post_event` contract is non-raising: handlers cannot fail
/// in a typed way, and a contract violation aborts loudly (aborts are not
/// catchable). Components with fallible internal work must catch it
/// themselves and surface it as a `secondary_failure` observer event —
/// see `MemoryRetrievalHook`.

///|
fn Puppet::fire_post_event_hooks(self : Puppet, input : RunInput) -> Unit {
  // Fast path: skip stage translation entirely when no hook could care
  // about post-effect events.
  if self.config.hooks.is_empty() {
    return
  }
  let stage : HookStage = match input {
    ModelCompleted(payload~) =>
      HookStage::ModelCompleted(completion=payload.completion)
    ModelFailed(payload~) => HookStage::ModelFailed(failure=payload.failure)
    ToolCompleted(payload~) =>
      HookStage::ToolCompleted(
        call=ToolCall::{
          call_id: payload.call_id,
          name: payload.tool_name,
          arguments: payload.arguments,
        },
        outcome=payload.outcome,
      )
    ToolFailed(payload~) =>
      HookStage::ToolFailed(
        call=ToolCall::{
          call_id: payload.call_id,
          name: payload.tool_name,
          arguments: payload.arguments,
        },
        reason=payload.reason,
      )
    _ => return
  }
  for hook in self.config.hooks {
    hook.on_post_event(stage)
  }
}
