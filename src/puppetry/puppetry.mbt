///|
/// Puppet orchestration — the single long-lived pump (M2-T06, ADR §2.1,
/// §4, §6).
///
/// The Puppet is the ONLY loop in the product that drives RunState forward
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
// PuppetConfig — composition root
// ──────────────────────────────────────────────────────────────────────────

///|
/// Inputs to build a Puppet. All fields are required; the Puppet owns
/// the lifetime of every reference.
///
/// The host is an owned `CanonicalHost`, assembled once from direct extension
/// bindings and an already-validated catalog. No product entry can bypass
/// catalog-checked canonical composition.
pub(all) struct PuppetConfig {
  host : CanonicalHost
  catalog : @kernel.ToolCatalogSnapshot
  journal : &RunJournal
  contributors : Array[&JournalContributor]
  subscribers : Array[&EventSubscriber]
  lifecycle_nodes : Array[&PuppetLifecycleNode]
  /// Optional live chunk sink. `None` is the default product path and tells
  /// the HostRuntime to avoid chunk JSON conversion altogether.
  stream_chunks : @kernel.HostChunkCallback?
  /// Opaque provider options captured at composition. They are carried into
  /// every reducer-declared CallModel effect unchanged.
  call_options : Json
  /// Default budget for new runs.
  default_budget : @kernel.Budget
  /// Max iterations before the pump declares PumpLoopExceeded.
  max_iterations : Int
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
/// - ControlMailbox (mutable; includes the idle barrier)
/// - LifecycleCollection (mutable)
///
/// The Puppet borrows:
/// - CanonicalHost (from config)
/// - &RunJournal (from config)
/// - &JournalContributor[] (from config)
/// - &EventSubscriber[] (from config)
/// - ToolCatalogSnapshot (owned copy; snapshot immutable after capture)
pub struct Puppet {
  config : PuppetConfig
  mut phase_gate : PhaseGate
  mailbox : ControlMailbox
  lifecycle : LifecycleCollection
  /// Last terminal transcript. The Kernel owns the live transcript while a
  /// run is active; after a terminal commit the Puppet exposes this immutable
  /// snapshot so products can materialize their canonical session state.
  mut last_completed_transcript : CanonicalTranscript?
}

///|
pub fn Puppet::new(config : PuppetConfig) -> Puppet {
  {
    config,
    phase_gate: PhaseGate::idle(),
    mailbox: ControlMailbox::new(),
    lifecycle: LifecycleCollection::new(),
    last_completed_transcript: None,
  }
}

///|
/// Return the last terminal transcript captured by the Puppet. `None` means
/// no run has completed since construction or the current run is suspended.
pub fn Puppet::last_completed_transcript(self : Puppet) -> CanonicalTranscript? {
  self.last_completed_transcript
}

///|
pub fn Puppet::phase(self : Puppet) -> PuppetPhase {
  self.phase_gate.phase()
}

///|
pub fn Puppet::is_quiescent(self : Puppet) -> Bool {
  self.phase_gate.is_quiescent()
}

// ──────────────────────────────────────────────────────────────────────────
// Lifecycle — startup / shutdown (single product-level executor)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Register all configured lifecycle nodes and start them in registration
/// order. Idempotent: a second call is a no-op.
pub async fn Puppet::startup(self : Puppet) -> Unit raise PuppetError {
  for node in self.config.lifecycle_nodes {
    self.lifecycle.register(node)
  }
  self.lifecycle.startup_all()
}

///|
/// Shut all started nodes in reverse order. Idempotent.
pub async fn Puppet::shutdown(self : Puppet) -> Unit raise PuppetError {
  // Transition the phase gate to ShuttingDown so any in-flight command
  // is rejected. Active runs are not forcibly aborted (M2 single-threaded
  // means there is no in-flight run when shutdown is called).
  self.phase_gate = self.phase_gate.transition(ShuttingDown)
  let shutdown_result : Result[Unit, PuppetError] = Ok(
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
  /// Run accepted; the puppet has entered Active phase and is driving.
  Accepted(run_id~ : RunId, turn_id~ : TurnId)
  /// Rejected because a lease is already held.
  LeaseBusy(held_by~ : String)
  /// Rejected for another typed reason.
  Rejected(error~ : PuppetError)
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
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  initial_messages : Array[CanonicalMessage],
  operation_id : String,
) -> PromptResult raise PuppetError {
  // Step 1: acquire lease.
  let acquire_result : Result[(PhaseGate, OperationLease), PuppetError] = Ok(
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
    model_id: self.config.host.model_id().to_string(),
    call_options: self.config.call_options,
    budget: self.config.default_budget,
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
async fn Puppet::drive_run(
  self : Puppet,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  initial_messages : Array[CanonicalMessage],
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
  let exec_ctx = ExecutionContext::new(
    self.config.host as &@kernel.HostRuntime,
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
    if iter > max_iter {
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
    match state.phase() {
      ReadyForModel => {
        let declared : Result[(RunState, Array[KernelEvent]), PuppetError] = Ok(
          declare_model_effect_if_ready(
            state,
            [],
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
        let folded : Result[RunState, PuppetError] = Ok(
          self.fold_effect_input(
            state,
            input,
            dispatcher,
            run_id,
            turn_id,
            session_id,
            "sp_model_effect_\{iter}",
            snap.call_options(),
          ),
        ) catch {
          error => Err(error)
        }
        match folded {
          Err(error) => return self.reject_run(error~)
          Ok(next_state) => state = next_state
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
            let folded : Result[RunState, PuppetError] = Ok(
              self.fold_effect_input(
                state,
                input,
                dispatcher,
                run_id,
                turn_id,
                session_id,
                "sp_tool_wave_\{wave_index}",
                snap.call_options(),
              ),
            ) catch {
              error => Err(error)
            }
            match folded {
              Err(error) => return self.reject_run(error~)
              Ok(next_state) => state = next_state
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
// Effect completion folding — reducer then durable savepoint
// ──────────────────────────────────────────────────────────────────────────

///|
/// Fold one completed effect through the reducer, declare the next model
/// effect when the reducer reaches `ReadyForModel`, and commit the complete
/// side-effect boundary before returning. Execution and scheduling remain
/// outside this helper; it is only the reducer → boundary-journal seam.
async fn Puppet::fold_effect_input(
  self : Puppet,
  state : RunState,
  input : RunInput,
  dispatcher : EventDispatcher,
  run_id : RunId,
  turn_id : TurnId,
  session_id : SessionId,
  savepoint_id_prefix : String,
  call_options : Json,
) -> RunState raise PuppetError {
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
  let boundary_kind = boundary_kind_for_events(output.events())
  let (next_state, boundary_events) = declare_model_effect_if_ready(
    output.next_state(),
    output.events(),
    self.config.catalog,
    call_options,
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
    Ok(_) => next_state
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
async fn execute_model_effect(
  effect : Effect,
  context : ExecutionContext,
  on_chunk : @kernel.HostChunkCallback?,
) -> RunInput raise PuppetError {
  let attempted : Result[RunInput, Error] = Ok(
    execute_one(effect, context, on_chunk),
  ) catch {
    error => Err(error)
  }
  match attempted {
    Ok(input) => input
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
    Ok(inputs) => inputs
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
      @kernel.CancelOutstanding(payload~, ..) => {
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
    ModelStepCompleted(model_step_id~, completion_summary~) =>
      Json::object(
        Map::from_array([
          ("kind", Json::string("ModelStepCompleted")),
          ("model_step_id", Json::number(model_step_id.to_int().to_double())),
          ("summary", Json::string(completion_summary)),
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
