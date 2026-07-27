///|
/// Stateless single-effect executor for the functional Kernel (ADR §2.1,
/// §2.5, §2.9).
///
/// This is the imperative shell that turns ONE reducer-declared Effect into
/// ONE structured RunInput. It executes no business logic, owns no RunState,
/// holds no queues, journals or barriers. The Puppet reuses `execute_one`
/// verbatim and supplies the queue/savepoint/barrier pump around it.
///
/// Three responsibilities:
/// 1. `execute_one(effect, host, ctx)`: dispatch one Effect to the
///    host runtime. Convert every host result to a typed RunInput.
/// 2. reject any effect kind that does not produce a reducer input.
///
/// The executor imports async (it is the imperative shell) and delegates all
/// provider interaction to `@kernel.HostRuntime`, preserving a clean package
/// boundary.
///
/// The REDUCER remains the pure part and never calls into this module.

// ──────────────────────────────────────────────────────────────────────────
// ModelId (binding identity)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Identifier for a model binding. A Run uses one host-supplied model. The
/// Kernel reducer never
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
/// model/tool adapters and the catalog snapshot to source tool definitions
/// from for `CallModel` effects.
///
/// The snapshot is carried here (not re-resolved from a registry) because the
/// reducer already validated against `catalog_version`; the executor forwards
/// the same definitions so the model sees what was validated (ADR §2.7, §6.3 —
/// forbidden to substitute an empty tool list).
priv struct ExecutionContext {
  host : &@kernel.HostRuntime
  catalog : @kernel.ToolCatalogSnapshot
}

///|
fn ExecutionContext::new(
  host : &@kernel.HostRuntime,
  catalog~ : @kernel.ToolCatalogSnapshot,
) -> ExecutionContext {
  { host, catalog }
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
async fn execute_one(
  effect : @kernel.Effect,
  ctx : ExecutionContext,
  on_chunk : @kernel.HostChunkCallback?,
) -> @kernel.RunInput raise PuppetError {
  match effect {
    @kernel.CallModel(effect_id~, payload~) =>
      execute_call_model(effect_id, payload, ctx, on_chunk)
    @kernel.ExecuteTool(effect_id~, payload~) =>
      execute_execute_tool(effect_id, payload, ctx)
    @kernel.CancelOutstanding(..) =>
      raise EffectExecutionFailed(
        phase="executor",
        cause="CancelOutstanding must be propagated at the terminal boundary, not converted to RunInput",
      )
  }
}

///|
async fn execute_call_model(
  effect_id : @kernel.EffectId,
  payload : @kernel.CallModelPayload,
  ctx : ExecutionContext,
  on_chunk : @kernel.HostChunkCallback?,
) -> @kernel.RunInput raise PuppetError {
  // Forward the REAL catalog definitions the reducer validated against. It is
  // explicitly forbidden (REPAIR §6.3) to pass an empty array here — that
  // would hide a missing-catalog bug as a successful but tool-blind model
  // call. The snapshot owns the definitions; we project them out.
  let tool_definitions : Array[@kernel.CanonicalToolDef] = ctx.catalog.definitions()
  let attempted : Result[
    Result[@kernel.AssistantCompletion, @kernel.ModelFailure],
    Error,
  ] = Ok(
    ctx.host.call_model(
      payload.messages,
      tool_definitions,
      payload.call_options,
      on_chunk,
    ),
  ) catch {
    error => Err(error)
  }
  match attempted {
    Err(error) =>
      raise EffectExecutionFailed(phase="CallModel", cause=error.to_string())
    Ok(Ok(completion)) =>
      @kernel.ModelCompleted(payload=@kernel.ModelCompletedPayload::{
        effect_id,
        model_step_id: payload.model_step_id,
        completion,
      })
    Ok(Err(failure)) =>
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
) -> @kernel.RunInput raise PuppetError {
  // Owner resolution lives in the host. The host returns a typed ToolOutcome
  // for every path:
  //   Success | ToolReportedError | RuntimeFailure.
  // `NotExecuted` is a reducer-side category (unknown tool / schema mismatch)
  // that the reducer produces BEFORE declaring an ExecuteTool effect, so a
  // well-formed host never returns it here. If a host does return NotExecuted,
  // we treat it as a host contract violation and surface a typed
  // ToolFailed so the reducer sees an explicit signal rather than a silent
  // success — REPAIR §11 forbids masking such cases.
  let attempted : Result[@kernel.ToolOutcome, Error] = Ok(
    ctx.host.execute_tool(
      payload.owner,
      payload.call_id,
      payload.tool_name,
      payload.arguments,
    ),
  ) catch {
    error => Err(error)
  }
  let outcome = match attempted {
    Ok(value) => value
    Err(error) =>
      raise EffectExecutionFailed(phase="ExecuteTool", cause=error.to_string())
  }
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
