///|
/// Harness orchestration — the single long-lived pump (M2-T06, ADR §2.1,
/// §4, §6).
///
/// The Harness is the ONLY loop in the product that drives RunState forward
/// across model/tool rounds. It composes:
/// - PhaseGate (T02) — macro-phase gating + lease
/// - TurnSnapshot (T02) — immutable turn capture
/// - ControlMailbox (T03) — steer/follow-up/resume/abort + idle barrier
/// - RunJournal + SavepointCoordinator (T04) — append-only journal
/// - LifecycleCollection (T05) — top-level lifecycle executor
/// - EventDispatcher (T05) — post-commit event dispatch
/// - M1 reducer + execute_one (M1-T08) — reused unchanged
///
/// The pump NEVER decides termination by inspecting `tool_calls.is_empty()`.
/// It only drives reducer-declared effects. If the reducer declares zero
/// effects and the state is not terminal, the pump stops and waits for
/// external input (prompt/resume).
///
/// Single-writer: only the pump advances journal revision. Only the pump
/// emits envelopes. Only the pump allocates seq.

// ──────────────────────────────────────────────────────────────────────────
// HarnessConfig — composition root
// ──────────────────────────────────────────────────────────────────────────

///|
/// Inputs to build a Harness. All fields are required; the Harness owns
/// the lifetime of every reference.
///
/// The host side is supplied as a single `&HostRuntime` (REPAIR D3/D4): the
/// root compatibility facade implements `HostRuntime`; Puppetry only sees
/// canonical Kernel values, so no root → puppetry → root package cycle exists.
pub(all) struct HarnessConfig {
  host : &@kernel.HostRuntime
  model_id : ModelId
  catalog : @kernel.ToolCatalogSnapshot
  journal : &RunJournal
  contributors : Array[&JournalContributor]
  subscribers : Array[&EventSubscriber]
  lifecycle_nodes : Array[&HarnessLifecycleNode]
  /// Default budget for new runs.
  default_budget : @kernel.Budget
  /// Max iterations before the pump declares PumpLoopExceeded.
  max_iterations : Int
}

// ──────────────────────────────────────────────────────────────────────────
// Harness — the assembled pump
// ──────────────────────────────────────────────────────────────────────────

///|
/// The Harness. Construct once via `Harness::new`; call `startup` once
/// before any prompt; call `shutdown` once at product exit.
///
/// The Harness owns:
/// - PhaseGate (mutable)
/// - ControlMailbox (mutable; includes the idle barrier)
/// - LifecycleCollection (mutable)
///
/// The Harness borrows:
/// - &HostRuntime (from config; the root adapter owns compatibility conversion)
/// - &RunJournal (from config)
/// - &JournalContributor[] (from config)
/// - &EventSubscriber[] (from config)
/// - ToolCatalogSnapshot (owned copy; snapshot immutable after capture)
pub struct Harness {
  config : HarnessConfig
  mut phase_gate : PhaseGate
  mailbox : ControlMailbox
  lifecycle : LifecycleCollection
  /// Last terminal transcript, retained only for the compatibility facade.
  /// The Kernel remains the owner of the live transcript while a run is
  /// active; Harness exposes this immutable snapshot after commit so a host
  /// can materialize the complete legacy session without reconstructing tool
  /// messages from lossy terminal summaries.
  mut last_completed_transcript : CanonicalTranscript?
  // RuntimeRegistry is built per-run from config.tool_providers; we
  // rebuild it on each prompt (it's cheap and keeps the registry fresh
  // for future dynamic-refresh in M5).
}

///|
pub fn Harness::new(config : HarnessConfig) -> Harness {
  {
    config,
    phase_gate: PhaseGate::idle(),
    mailbox: ControlMailbox::new(),
    lifecycle: LifecycleCollection::new(),
    last_completed_transcript: None,
  }
}

///|
/// Return the last terminal transcript captured by the Harness. `None` means
/// no run has completed since construction or the current run is suspended.
pub fn Harness::last_completed_transcript(
  self : Harness,
) -> CanonicalTranscript? {
  self.last_completed_transcript
}

///|
pub fn Harness::phase(self : Harness) -> HarnessPhase {
  self.phase_gate.phase()
}

///|
pub fn Harness::is_quiescent(self : Harness) -> Bool {
  self.phase_gate.is_quiescent()
}

// ──────────────────────────────────────────────────────────────────────────
// Lifecycle — startup / shutdown (single product-level executor)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Register all configured lifecycle nodes and start them in registration
/// order. Idempotent: a second call is a no-op.
pub async fn Harness::startup(self : Harness) -> Unit raise HarnessError {
  for node in self.config.lifecycle_nodes {
    self.lifecycle.register(node)
  }
  self.lifecycle.startup_all()
}

///|
/// Shut all started nodes in reverse order. Idempotent.
pub async fn Harness::shutdown(self : Harness) -> Unit raise HarnessError {
  // Transition the phase gate to ShuttingDown so any in-flight command
  // is rejected. Active runs are not forcibly aborted (M2 single-threaded
  // means there is no in-flight run when shutdown is called).
  self.phase_gate = self.phase_gate.transition(ShuttingDown)
  let shutdown_result : Result[Unit, HarnessError] = Ok(
    self.lifecycle.shutdown_all(),
  ) catch {
    e => Err(e)
  }
  match shutdown_result {
    Err(e) => {
      // Even on failure, transition to Shutdown so further commands fail
      // loudly with AfterShutdown.
      self.phase_gate = self.phase_gate.transition(Shutdown)
      raise e
    }
    Ok(_) => ()
  }
  self.phase_gate = self.phase_gate.transition(Shutdown)
  // Wake any wait_idle callers so they observe Shutdown.
  self.mailbox.set_quiescent(Shutdown)
}

// ──────────────────────────────────────────────────────────────────────────
// prompt — start a new run
// ──────────────────────────────────────────────────────────────────────────

///|
/// Result of `prompt`.
pub(all) enum PromptResult {
  /// Run accepted; the harness has entered Active phase and is driving.
  Accepted(run_id~ : RunId, turn_id~ : TurnId)
  /// Rejected because a lease is already held.
  LeaseBusy(held_by~ : String)
  /// Rejected for another typed reason.
  Rejected(error~ : HarnessError)
}

///|
pub impl Show for PromptResult with fn to_string(self : PromptResult) -> String {
  match self {
    Accepted(run_id~, turn_id~) =>
      "Accepted(run=\{run_id.to_string()}, turn=\{turn_id.to_string()})"
    LeaseBusy(held_by~) => "LeaseBusy(held_by=\{held_by})"
    Rejected(error~) => "Rejected(\{error.to_string()})"
  }
}

///|
/// Prompt the Harness with an initial user message. Only legal when the
/// phase is Idle.
///
/// Steps (ADR §6.1):
/// 1. Acquire prompt lease via the phase gate.
/// 2. Capture TurnSnapshot.
/// 3. Bind ControlMailbox to the new run/turn.
/// 4. Commit `InputAccepted` savepoint BEFORE any model effect.
/// 5. Transition to Active.
/// 6. Run the pump until terminal or suspended.
/// 7. On terminal, dispatch terminal event, release lease, return.
///
/// `run_id` / `turn_id` are caller-supplied (host generates them; the
/// Harness does not allocate). This keeps cross-process resume (M5)
/// possible without a central id factory.
pub async fn Harness::prompt(
  self : Harness,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  initial_messages : Array[CanonicalMessage],
  operation_id : String,
) -> PromptResult raise HarnessError {
  // Step 1: acquire lease.
  let acquire_result : Result[(PhaseGate, OperationLease), HarnessError] = Ok(
    self.phase_gate.acquire_prompt(operation_id, run_id, turn_id),
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
    model_id: self.config.model_id.to_string(),
    call_options: Json::null(),
    budget: self.config.default_budget,
    deadline: None,
    hook_provenance: [],
    lifecycle_provenance: [],
    subscriber_provenance: [],
  }
  let snap_result : Result[TurnSnapshot, HarnessError] = Ok(
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
  // Step 4: commit InputAccepted BEFORE any model effect.
  let input_accepted_entry : JournalEntry = {
    identity: {
      run_id,
      turn_id,
      session_id,
      savepoint_id: "sp_input_\{turn_id.to_string()}",
      kind: InputAccepted,
      entry_seq: 0,
    },
    revision: 0, // assigned by journal
    summary: "InputAccepted(run=\{run_id.to_string()})",
    payload: Json::object(
      Map::from_array([
        ("kind", Json::string("InputAccepted")),
        ("run_id", Json::string(run_id.to_string())),
        ("turn_id", Json::string(turn_id.to_string())),
        ("session_id", Json::string(session_id.to_string())),
        (
          "catalog_version",
          Json::number(snap.catalog_version().to_int().to_double()),
        ),
      ]),
    ),
  }
  let ctx : PreCommitContext = {
    run_id,
    turn_id,
    session_id,
    savepoint_id: "sp_input_\{turn_id.to_string()}",
    savepoint_kind: InputAccepted,
    base_entries: [input_accepted_entry],
    current_revision: self.config.journal.revision(),
    catalog_version: snap.catalog_version(),
  }
  let batch_result : Result[FrozenBatch, HarnessError] = Ok(
    prepare_batch(ctx, self.config.contributors),
  ) catch {
    e => Err(e)
  }
  let batch = match batch_result {
    Err(e) => return self.reject_run(error=e)
    Ok(b) => b
  }
  let commit_result : Result[Int, HarnessError] = Ok(
    commit_batch(self.config.journal, batch),
  ) catch {
    e => Err(e)
  }
  match commit_result {
    Err(e) => return self.reject_run(error=e)
    Ok(_) => ()
  }
  // Step 5: transition to Active.
  self.phase_gate = self.phase_gate.transition(Active)
  // Step 6: run the pump.
  let result = self.drive_run(
    run_id, turn_id, session_id, initial_messages, snap,
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
/// M1-T08's `execute_one` (stateless single-effect executor) and never
/// inspects `tool_calls.is_empty()` to decide termination.
async fn Harness::drive_run(
  self : Harness,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  initial_messages : Array[CanonicalMessage],
  snap : TurnSnapshot,
) -> PromptResult raise HarnessError {
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
  // The host owns owner resolution and legacy conversion; puppetry only
  // forwards canonical types (REPAIR D3/D4).
  let exec_ctx = ExecutionContext::new(
    self.config.host,
    model_id=self.config.model_id,
    catalog=self.config.catalog,
  )
  // Build the event dispatcher.
  let dispatcher = EventDispatcher::new(run_id, turn_id, session_id)
  for sub in self.config.subscribers {
    dispatcher.register(sub)
  }
  // Seed the reducer with Start.
  let start_input : RunInput = Start(payload={
    initial_messages: initial_messages.copy(),
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
  state = out0.next_state()
  // Commit RunStarted savepoint and dispatch events.
  let commit_result : Result[Unit, HarnessError] = Ok(
    self.commit_savepoint(
      state,
      out0.events(),
      dispatcher,
      run_id,
      turn_id,
      session_id,
      "sp_start",
    ),
  ) catch {
    e => Err(e)
  }
  match commit_result {
    Err(e) => return self.reject_run(error=e)
    Ok(_) => ()
  }
  // Drive the loop.
  let mut iter = 0
  let max_iter = self.config.max_iterations
  while state.phase() != Terminal && state.phase() != Suspended {
    iter = iter + 1
    if iter > max_iter {
      return self.reject_run(error=PumpLoopExceeded(iterations=iter))
    }
    // Defensive: if the pump task is being cancelled (e.g. by an outer
    // `with_timeout` wrapping the whole run), re-raise instead of looping.
    // Without this, the catch blocks below would swallow `Cancelled` into
    // `Rejected(...)` and the loop would spin forever. See
    // `moonbitlang/async` `is_being_cancelled` doc.
    if @async.is_being_cancelled() {
      return self.reject_run(error=PumpLoopExceeded(iterations=iter))
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
          let cr : Result[Unit, HarnessError] = Ok(
            self.commit_savepoint(
              state,
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
    match state.phase() {
      ReadyForModel => {
        let r : Result[ReduceOutput, KernelError] = Ok(
          run_model_step(state, self.config.catalog, snap.call_options()),
        ) catch {
          e => Err(e)
        }
        match r {
          Err(e) =>
            return self.reject_run(
              error=ReducerInvariantViolation(
                category=IllegalPhase(
                  phase="run_model_step",
                  detail=e.to_string(),
                ),
              ),
            )
          Ok(out) => {
            state = out.next_state()
            let cr : Result[Unit, HarnessError] = Ok(
              self.commit_savepoint(
                state,
                out.events(),
                dispatcher,
                run_id,
                turn_id,
                session_id,
                "sp_model_step_\{iter}",
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
      AwaitingModel | AwaitingTools => {
        let pending = state.pending_effects()
        for eff in pending {
          // execute_one may raise untyped Error (async fn semantics).
          let exec_result : Result[RunInput, Error] = Ok(
            execute_one(eff, exec_ctx, fn(_chunk : Json) { () }),
          ) catch {
            e => Err(e)
          }
          let input = match exec_result {
            Err(e) =>
              return self.reject_run(
                error=ReducerInvariantViolation(
                  category=IllegalPhase(
                    phase="execute_one",
                    detail=e.to_string(),
                  ),
                ),
              )
            Ok(i) => i
          }
          let r : Result[ReduceOutput, KernelError] = Ok(
            reduce(state, self.config.catalog, input),
          ) catch {
            e => Err(e)
          }
          match r {
            Err(e) =>
              return self.reject_run(
                error=ReducerInvariantViolation(
                  category=IllegalPhase(phase="effect", detail=e.to_string()),
                ),
              )
            Ok(out) => {
              state = out.next_state()
              let cr : Result[Unit, HarnessError] = Ok(
                self.commit_savepoint(
                  state,
                  out.events(),
                  dispatcher,
                  run_id,
                  turn_id,
                  session_id,
                  "sp_effect_\{iter}",
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
          // Re-check abort between effects.
          if self.mailbox.abort_requested() {
            let cancel_input : RunInput = CancelRequested(payload={
              detail: None,
            })
            let r2 : Result[ReduceOutput, KernelError] = Ok(
              reduce(state, self.config.catalog, cancel_input),
            ) catch {
              e => Err(e)
            }
            match r2 {
              Err(e) =>
                return self.reject_run(
                  error=ReducerInvariantViolation(
                    category=IllegalPhase(
                      phase="cancel-mid",
                      detail=e.to_string(),
                    ),
                  ),
                )
              Ok(out) => {
                state = out.next_state()
                let cr : Result[Unit, HarnessError] = Ok(
                  self.commit_savepoint(
                    state,
                    out.events(),
                    dispatcher,
                    run_id,
                    turn_id,
                    session_id,
                    "sp_cancel_mid",
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
            break
          }
          if state.phase() == Terminal || state.phase() == Suspended {
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
// commit_savepoint — the deterministic pre-commit → freeze → commit → dispatch
// ──────────────────────────────────────────────────────────────────────────

///|
/// For each KernelEvent the reducer emitted, derive a JournalEntry, run
/// the pre-commit → freeze → commit pipeline, then dispatch the event
/// post-commit. Each event becomes one savepoint; the savepoint_id is
/// derived from the prefix + the journal's pre-commit revision (which is
/// monotonic, guaranteeing unique dedup keys across the run).
async fn Harness::commit_savepoint(
  self : Harness,
  state : RunState,
  events : Array[KernelEvent],
  dispatcher : EventDispatcher,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  savepoint_id_prefix : String,
) -> Unit raise HarnessError {
  for event in events {
    let kind = event_to_savepoint_kind(event)
    // Derive a unique savepoint_id using the current journal revision as
    // a monotonic suffix. This guarantees no collision with previous
    // savepoints even when the same prefix is used multiple times.
    let pre_commit_rev = self.config.journal.revision()
    let savepoint_id = "\{savepoint_id_prefix}_r\{pre_commit_rev}"
    let entry : JournalEntry = {
      identity: {
        run_id,
        turn_id,
        session_id,
        savepoint_id,
        kind,
        entry_seq: 0,
      },
      revision: 0,
      summary: event.to_string(),
      payload: kernel_event_payload(event),
    }
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
    // Dispatch the event post-commit.
    dispatcher.dispatch(event, committed_rev)
  }
}

///|
/// Map a KernelEvent to its SavepointKind. Terminal events → RunTerminal;
/// RunSuspended → RunSuspended; everything else maps by heuristic.
fn event_to_savepoint_kind(event : KernelEvent) -> SavepointKind {
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
    ModelStepCompleted(model_step_id~, completion_summary~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("ModelStepCompleted")),
          ("model_step_id", Json::number(model_step_id.to_int().to_double())),
          ("summary", Json::string(completion_summary)),
        ]),
      )
    ToolBatchStarted(model_step_id~, call_ids~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("ToolBatchStarted")),
          ("model_step_id", Json::number(model_step_id.to_int().to_double())),
          ("call_count", Json::number(call_ids.length().to_double())),
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
/// Put the Harness back into a quiescent, retryable state on a host-level
/// failure that prevents the reducer from producing a terminal outcome. The
/// typed error remains the caller-visible diagnostic; cleanup must not leave a
/// stale lease or an active mailbox behind.
fn Harness::reject_run(self : Harness, error~ : HarnessError) -> PromptResult {
  self.phase_gate = PhaseGate::idle()
  self.mailbox.clear_run()
  self.mailbox.set_quiescent(Idle)
  Rejected(error~)
}

// ──────────────────────────────────────────────────────────────────────────
// wait_idle — delegate to mailbox
// ──────────────────────────────────────────────────────────────────────────

///|
/// Wait until the Harness reaches a quiescent status. Returns Idle,
/// Suspended, Terminal, or Shutdown (typed, distinct). Implemented via
/// `@cond_var.Cond::wait` — NOT polling.
pub async fn Harness::wait_idle(self : Harness) -> QuiescentStatus {
  self.mailbox.wait_idle()
}
