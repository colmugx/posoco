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
  // The resolved window/threshold and the latest verified occupancy ride
  // along so modelports size their compact strategy from real numbers
  // instead of re-estimating from characters.
  let pressure : @kernel.ContextPressure = {
    window_tokens: snap.context_window(),
    occupancy_tokens: state.budget_consumed().last_context_tokens,
    compact_threshold: snap.compact_threshold(),
  }
  let scope : InvocationScope = {
    session_id,
    run_id,
    effect_id: None,
    pressure: Some(pressure),
  }
  let attempted : Result[Result[CompactResult, @kernel.ModelFailure], Error] = Ok(
    self.config.host.compact(
      scope,
      messages[:],
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
    @kernel.Replace =>
      self.rewrite_transcript_for_compact(
        state,
        compact_result.compacted_messages,
        "compact_replace",
        "compact-replace",
      )
    @kernel.Append => {
      let current = state.transcript().messages_snapshot()
      let combined : Array[@kernel.Message] = current +
        compact_result.compacted_messages
      self.rewrite_transcript_for_compact(
        state, combined, "compact_append", "compact-append",
      )
    }
  }
}

///|
/// Fold a compact transcript change through the reducer — the sole
/// transcript writer — as a `TranscriptRewrite` input, so the compact is
/// journaled as a `TranscriptRewritten` event instead of an untracked
/// mutation. `commit_boundary` is NOT called here; the caller commits the
/// returned events at the next boundary.
fn Puppet::rewrite_transcript_for_compact(
  self : Puppet,
  state : RunState,
  rewritten_messages : Array[@kernel.Message],
  reason : String,
  phase : String,
) -> CompactFlow {
  let rewrite_input : RunInput = TranscriptRewrite(payload={
    rewritten_messages,
    reason,
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
          category=IllegalPhase(phase~, detail=e.to_string()),
        ),
      )
    Ok(out) => CompactFlow::UpdatedState(out.next_state(), out.events())
  }
}

///|
/// Check whether auto-compact should fire on this iteration. Returns
/// `Some(CompactCommand{trigger=Auto})` when the LATEST verified context
/// occupancy crossed `context_window * compact_threshold`. Returns `None`
/// when:
/// - `context_window` is `None` (auto-compact disabled), OR
/// - occupancy is unknown (no computable usage reading yet, or the
///   transcript was just rewritten by a compact), OR
/// - occupancy is below the threshold, OR
/// - this run already spent its single auto-compact attempt.
///
/// Occupancy is the latest call's own usage, NOT the run-wide cumulative
/// total: several large-but-far-from-full calls must not sum into a false
/// trigger, and `max_total_tokens` keeps policing the cumulative account.
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
  // Single-shot latch per run: fired once, success or failure. A compact
  // that cannot shrink the transcript below the limit must not loop.
  if self.auto_compact_fired_run is Some(run) && run == state.run_id() {
    return None
  }
  // Without a verified occupancy reading we cannot honestly claim the
  // threshold has been crossed. The reducer maintains this account.
  let occupancy = match state.budget_consumed().last_context_tokens {
    Some(n) => n
    None => return None
  }
  // threshold * 100 rounded — compact_threshold is validated at capture.
  let threshold_units = (snap.compact_threshold() * 100.0).to_int()
  // total_units = context_window * threshold; floor at 0.
  let limit = context_window * threshold_units / 100
  if occupancy >= limit {
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
