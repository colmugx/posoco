///|

///|
#derive(Eq, Hash, Debug)
pub(all) struct ModelId {
  value : String
}

///|
pub extend ModelId with Eq::{not_equal, equal}

///|
pub extend ModelId with Hash::{hash, hash_combine}

///|
pub extend ModelId with Debug::{to_repr}

///|
pub fn ModelId::checked(value : String) -> Result[ModelId, String] {
  if value == "" {
    Err("ModelId must be non-empty")
  } else {
    Ok({ value, })
  }
}

///|
pub fn ModelId::unchecked(value : String) -> ModelId {
  { value, }
}

///|
pub fn ModelId::to_string(self : ModelId) -> String {
  self.value
}

///|
priv struct ExecutionContext {
  host : &@kernel_exec.HostRuntime
  catalog : @kernel_exec.ToolCatalogSnapshot
  run_id : RunId
  session_id : SessionId
  mailbox : &Mailbox
  tool_scope : @kernel_exec.ToolExecutionScope?
  /// Core launch gate of the captured bindings; a refusal recorded here is the
  /// trusted "provider never entered" fact.
  launch_gate : @kernel_exec.ToolLaunchGate?
  /// Revocations of the admitted operation's captured bindings.
  revocations : ToolRevocationFacts?
}

///|
fn ExecutionContext::ExecutionContext(
  host : &@kernel_exec.HostRuntime,
  catalog~ : ToolCatalogSnapshot,
  run_id~ : RunId,
  session_id~ : SessionId,
  mailbox~ : &Mailbox,
  launch_gate? : @kernel_exec.ToolLaunchGate,
  revocations? : ToolRevocationFacts,
) -> ExecutionContext {
  {
    host,
    catalog,
    run_id,
    session_id,
    mailbox,
    tool_scope: None,
    launch_gate,
    revocations,
  }
}

///|
async fn execute_one(
  effect : @kernel_exec.Effect,
  ctx : ExecutionContext,
  on_chunk : @kernel_exec.HostChunkCallback?,
) -> @kernel_exec.RunInput raise PuppetError {
  match effect {
    CallModel(effect_id~, payload~) =>
      execute_call_model(effect_id, payload, ctx, on_chunk)
    ExecuteTool(effect_id~, payload~) =>
      execute_execute_tool(effect_id, payload, ctx)
    CancelOutstanding(..) =>
      raise EffectExecutionFailed(
        phase="executor",
        cause="CancelOutstanding must be propagated at the terminal boundary, not converted to RunInput",
      )
  }
}

///|
async fn execute_call_model(
  effect_id : @kernel_exec.EffectId,
  payload : @kernel_exec.CallModelPayload,
  ctx : ExecutionContext,
  on_chunk : @kernel_exec.HostChunkCallback?,
) -> @kernel_exec.RunInput raise PuppetError {
  let tool_definitions = ctx.catalog
    .definitions()
    .filter(def => def.exposure is Direct)
  // Chat carries no pressure advisory; only the compact path attaches one.
  let scope : InvocationScope = {
    session_id: ctx.session_id,
    run_id: ctx.run_id,
    effect_id: Some(effect_id),
    pressure: None,
  }

  let stream_failure : Array[String] = []
  let mut highest_tool_index = -1
  let checked_on_chunk : @kernel_exec.HostChunkCallback? = match on_chunk {
    None => None
    Some(sink) =>
      Some(fn(chunk : @types.StreamChunk) {
        if !stream_failure.is_empty() {
          return
        }
        match chunk.validate() {
          Err(reason) => stream_failure.push(reason)
          Ok(_) => {
            let index_result : Result[Unit, String] = match chunk {
              ToolCallDelta(index~, ..) =>
                if highest_tool_index < 0 {
                  if index == 0 {
                    highest_tool_index = 0
                    Ok(())
                  } else {
                    Err(
                      "stream tool-call index is sparse; expected index 0 for the first tool call",
                    )
                  }
                } else if index > highest_tool_index {
                  if index - highest_tool_index == 1 {
                    highest_tool_index = index
                    Ok(())
                  } else {
                    Err(
                      "stream tool-call index is sparse; expected the next contiguous 0-based index",
                    )
                  }
                } else {
                  Ok(())
                }
              _ => Ok(())
            }
            match index_result {
              Err(reason) => stream_failure.push(reason)
              Ok(_) => sink(chunk)
            }
          }
        }
      })
  }
  let attempted : Result[Result[ModelCallResult, @kernel.ModelFailure], Error] = Ok(
    ctx.host.call_model(
      scope,
      payload.messages,
      tool_definitions,
      payload.call_options,
      checked_on_chunk,
    ),
  ) catch {
    error => Err(error)
  }
  match attempted {
    // A host raise (including transport errors and async cancellation) is the
    // primary outcome; a malformed callback must not reclassify it as parse.
    Err(error) => raise execution_error("CallModel", error)
    Ok(Ok(result)) =>
      match stream_failure {
        [reason, ..] =>
          ModelFailed(payload={
            effect_id,
            model_step_id: payload.model_step_id,
            failure: Parse(reason="stream chunk validation failed: " + reason),
          })
        [] =>
          match result.completion.usage {
            Some(usage) =>
              match usage.validate() {
                Err(reason) =>
                  ModelFailed(payload={
                    effect_id,
                    model_step_id: payload.model_step_id,
                    failure: Parse(
                      reason="model usage validation failed: " + reason,
                    ),
                  })
                Ok(_) =>
                  ModelCompleted(payload={
                    effect_id,
                    model_step_id: payload.model_step_id,
                    completion: result.completion,
                    processed_messages: result.processed_messages,
                  })
              }
            None =>
              ModelCompleted(payload={
                effect_id,
                model_step_id: payload.model_step_id,
                completion: result.completion,
                processed_messages: result.processed_messages,
              })
          }
      }
    // Stream validation only governs the successful-return path; it must not
    // erase retry/rate-limit semantics from `failure`.
    Ok(Err(failure)) =>
      ModelFailed(payload={
        effect_id,
        model_step_id: payload.model_step_id,
        failure,
      })
  }
}

///|
async fn execute_execute_tool(
  effect_id : @kernel_exec.EffectId,
  payload : @kernel_exec.ExecuteToolPayload,
  ctx : ExecutionContext,
) -> @kernel_exec.RunInput raise PuppetError {
  guard ctx.tool_scope is Some(scope) else {
    raise EffectExecutionFailed(
      phase="ExecuteTool",
      cause="missing tool execution scope",
    )
  }
  let attempted : Result[@kernel.ToolOutcome, Error] = Ok(
    ctx.host.execute_tool(
      effect_id,
      payload.owner,
      payload.call_id,
      payload.tool_name,
      payload.arguments,
      scope,
    ),
  ) catch {
    error => Err(error)
  }
  let outcome = match attempted {
    Ok(value) => value
    Err(error) =>
      raise EffectExecutionFailed(phase="ExecuteTool", cause=error.to_string())
  }
  let gated = match outcome {
    NotExecuted(..) =>
      match ctx.launch_gate {
        Some(gate) =>
          gate.take_refusal(ctx.run_id.to_string(), effect_id.to_int())
        None => None
      }
    _ => None
  }
  match gated {
    Some(reason) =>
      ToolCompleted(payload={
        effect_id,
        call_id: payload.call_id,
        tool_name: payload.tool_name,
        arguments: payload.arguments,
        outcome: NotExecuted(reason~, original_call_id=payload.call_id),
      })
    None =>
      match outcome {
        NotExecuted(reason~, ..) =>
          // Host contract violation: surface a typed, observable failure.
          ToolFailed(payload={
            effect_id,
            call_id: payload.call_id,
            tool_name: payload.tool_name,
            arguments: payload.arguments,
            reason: "host returned NotExecuted: " + reason.to_string(),
            runtime: Some(
              Parse(reason="host returned NotExecuted: " + reason.to_string()),
            ),
            invariant_failure: None,
          })
        RuntimeFailure(error_category="MissingOwner", ..) =>
          // A missing owner is a composition invariant, not a tool-level failure;
          // the run must not continue with a broken catalog binding.
          ToolFailed(payload={
            effect_id,
            call_id: payload.call_id,
            tool_name: payload.tool_name,
            arguments: payload.arguments,
            reason: "missing owner: " + payload.owner.to_string(),
            runtime: None,
            invariant_failure: Some(MissingOwner(owner=payload.owner)),
          })
        _ =>
          ToolCompleted(payload={
            effect_id,
            call_id: payload.call_id,
            tool_name: payload.tool_name,
            arguments: payload.arguments,
            outcome,
          })
      }
  }
}
