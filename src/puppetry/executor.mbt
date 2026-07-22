///|
/// Stateless single-effect executor for the M1 functional Kernel (ADR §2.1,
/// §2.5, §2.9).
///
/// This is the imperative shell that turns ONE reducer-declared Effect into
/// ONE structured RunInput. It executes no business logic, owns no RunState,
/// holds no queues, journals or barriers. The M2 Harness reuses `execute_one`
/// verbatim and supplies the queue/savepoint/barrier pump around it.
///
/// Three responsibilities:
/// 1. `ModelId`: identifier for the model binding carried for observability.
/// 2. `execute_one(effect, host, model_id, ctx)`: dispatch one Effect to the
///    host runtime. Convert every host result to a typed RunInput.
/// 3. `ScriptedHostRuntime`: a fake host for conformance tests, configured by
///    effect_id.
///
/// The executor imports async (it is the imperative shell) but it does NOT
/// import root compatibility wire types. Those live in the root facade; the
/// host-side conversion is delegated to
/// `@kernel.HostRuntime`, which root implements by adapting legacy providers
/// (ADR §5, §6; REPAIR D3/D4 — compatibility direction is root → Kernel, never
/// the reverse, so no package cycle).
///
/// The REDUCER remains the pure part and never calls into this module.

// ──────────────────────────────────────────────────────────────────────────
// ModelId (observability key carried alongside HostRuntime)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Identifier for a model binding. M1 supports a single model per Run
/// (host-supplied); M2 may add multi-model routing. The Kernel reducer never
/// references this; it only sees the model step id. The executor carries it
/// purely so telemetry/events can name the model that produced a completion.
pub(all) struct ModelId {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn ModelId::new(value : String) -> Result[ModelId, String] {
  if value == "" {
    Err("ModelId must be non-empty")
  } else {
    Ok(ModelId::{ value, })
  }
}

///|
pub fn ModelId::unchecked(value : String) -> ModelId {
  ModelId::{ value, }
}

///|
pub fn ModelId::to_string(self : ModelId) -> String {
  self.value
}

// ──────────────────────────────────────────────────────────────────────────
// execute_one — stateless single-effect dispatch via HostRuntime
// ──────────────────────────────────────────────────────────────────────────

///|
/// Context passed to `execute_one`: the host runtime that actually calls the
/// model/tool adapters, the model id for observability, and the catalog
/// snapshot to source tool definitions from for `CallModel` effects.
///
/// The snapshot is carried here (not re-resolved from a registry) because the
/// reducer already validated against `catalog_version`; the executor forwards
/// the same definitions so the model sees what was validated (ADR §2.7, §6.3 —
/// forbidden to substitute an empty tool list).
pub(all) struct ExecutionContext {
  host : &@kernel.HostRuntime
  model_id : ModelId
  catalog : @kernel.ToolCatalogSnapshot
}

///|
pub fn ExecutionContext::new(
  host : &@kernel.HostRuntime,
  model_id~ : ModelId,
  catalog~ : @kernel.ToolCatalogSnapshot,
) -> ExecutionContext {
  { host, model_id, catalog }
}

///|
/// Execute ONE Effect and return ONE structured RunInput. The executor holds
/// no state; every call is independent. The result is fed straight back to
/// `reduce`.
///
/// Categorisation:
/// - `CallModel` → delegates to `HostRuntime::call_model`, passing the catalog
///   definitions (forwarding them is mandatory — never an empty array). On
///   `Ok(completion)` returns `ModelCompleted`; on `Err(failure)` returns
///   `ModelFailed`.
/// - `ExecuteTool` → delegates to `HostRuntime::execute_tool`. The host owns
///   owner-resolution; a missing owner / stale registration surfaces as a
///   typed `ToolOutcome::RuntimeFailure` from the host, which the reducer
///   converts to the canonical outcome (ADR §2.4).
/// - `CancelOutstanding` → delegates to `HostRuntime::cancel_effects`. The
///   reducer treats cancel as fire-and-forget (it has already terminal-
///   transitioned); the driver therefore drops the returned RunInput.
pub async fn execute_one(
  effect : @kernel.Effect,
  ctx : ExecutionContext,
  on_chunk : @kernel.HostChunkCallback,
) -> @kernel.RunInput {
  match effect {
    @kernel.CallModel(effect_id~, payload~) =>
      execute_call_model(effect_id, payload, ctx, on_chunk)
    @kernel.ExecuteTool(effect_id~, payload~) =>
      execute_execute_tool(effect_id, payload, ctx)
    @kernel.CancelOutstanding(effect_id~, payload~) => {
      // Cancel is best-effort. The reducer has already terminal-transitioned
      // by the time this effect is dispatched; it does not require a
      // completion. We still drive the host so M3 adapters can propagate to
      // in-flight HTTP/process calls, then return a synthetic ToolCompleted
      // against a sentinel call id so the driver has a well-typed RunInput to
      // discard. Real adapter cancellation hardening belongs to M3.
      let _dispositions = ctx.host.cancel_effects(
        payload.effect_ids,
        payload.reason,
      )
      ignore(effect_id)
      @kernel.ToolCompleted(payload=@kernel.ToolCompletedPayload::{
        effect_id: @kernel.EffectId::first(),
        call_id: @kernel.CallId::unchecked("__cancel_ack__"),
        outcome: @kernel.RuntimeFailure(
          error_category="CancelAck",
          message="cancel recorded (M1 fake)",
        ),
      })
    }
  }
}

///|
async fn execute_call_model(
  effect_id : @kernel.EffectId,
  payload : @kernel.CallModelPayload,
  ctx : ExecutionContext,
  on_chunk : @kernel.HostChunkCallback,
) -> @kernel.RunInput {
  // Forward the REAL catalog definitions the reducer validated against. It is
  // explicitly forbidden (REPAIR §6.3) to pass an empty array here — that
  // would hide a missing-catalog bug as a successful but tool-blind model
  // call. The snapshot owns the definitions; we project them out.
  let tool_definitions : Array[@kernel.CanonicalToolDef] = ctx.catalog.definitions()
  let result : Result[@kernel.AssistantCompletion, @kernel.ModelFailure] = ctx.host.call_model(
    payload.messages,
    tool_definitions,
    payload.call_options,
    on_chunk,
  )
  match result {
    Ok(completion) =>
      @kernel.ModelCompleted(payload=@kernel.ModelCompletedPayload::{
        effect_id,
        model_step_id: payload.model_step_id,
        completion,
      })
    Err(failure) =>
      @kernel.ModelFailed(payload=@kernel.ModelFailedPayload::{
        effect_id,
        model_step_id: payload.model_step_id,
        failure,
      })
  }
}

///|
async fn execute_execute_tool(
  effect_id : @kernel.EffectId,
  payload : @kernel.ExecuteToolPayload,
  ctx : ExecutionContext,
) -> @kernel.RunInput {
  // Owner resolution lives in the host (root adapter maps OwnerId back to the
  // legacy provider). The host returns a typed ToolOutcome for every path:
  //   Success | ToolReportedError | RuntimeFailure.
  // `NotExecuted` is a reducer-side category (unknown tool / schema mismatch)
  // that the reducer produces BEFORE declaring an ExecuteTool effect, so a
  // well-formed host never returns it here. If a host does return NotExecuted,
  // we treat it as a host contract violation and surface a typed
  // ToolFailed so the reducer sees an explicit signal rather than a silent
  // success — REPAIR §11 forbids masking such cases.
  let outcome : @kernel.ToolOutcome = ctx.host.execute_tool(
    payload.owner,
    payload.call_id,
    payload.tool_name,
    payload.arguments,
  )
  match outcome {
    @kernel.NotExecuted(reason~, ..) =>
      // Host contract violation: NotExecuted crossed the host boundary.
      // Surface as a typed ToolFailed with a Parse-flavoured runtime failure
      // so the reducer records an explicit, observable signal.
      @kernel.ToolFailed(payload=@kernel.ToolFailedPayload::{
        effect_id,
        call_id: payload.call_id,
        runtime: Some(
          @kernel.Parse(
            reason="host returned NotExecuted: " + reason.to_string(),
          ),
        ),
        invariant_failure: None,
      })
    @kernel.RuntimeFailure(error_category="MissingOwner", ..) =>
      // A missing owner is a Kernel composition/runtime invariant, not a
      // tool-level failure. Do not let the reducer turn it into a normal
      // RuntimeFailure message and continue with a broken catalog binding.
      @kernel.ToolFailed(payload=@kernel.ToolFailedPayload::{
        effect_id,
        call_id: payload.call_id,
        runtime: None,
        invariant_failure: Some(@kernel.MissingOwner(owner=payload.owner)),
      })
    _ =>
      @kernel.ToolCompleted(payload=@kernel.ToolCompletedPayload::{
        effect_id,
        call_id: payload.call_id,
        outcome,
      })
  }
}
