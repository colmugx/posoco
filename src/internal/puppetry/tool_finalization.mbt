///|
priv struct FinalizedToolCall {
  call : ToolCall
  consent_scope : String?
  rejection : @kernel.ToolOutcome?
}

///|
/// Every hook sees a private copy; a later rewrite invalidates consent granted
/// to an earlier exact call.
async fn finalize_tool_call(
  catalog : @kernel_exec.ToolCatalogSnapshot,
  hooks : Array[&@port.PipelineHook],
  input : ToolCall,
  direct~ : Bool,
  revocations? : ToolRevocationFacts,
) -> FinalizedToolCall raise PuppetError {
  let mut current = snapshot_tool_call(input)
  let mut consented : ToolCall? = None
  let mut consent_scope : String? = None
  let mut changed_id = false
  let rejections : Array[String] = []
  for hook in hooks {
    let decision = hook.before_tool(snapshot_tool_call(current)) catch {
      error =>
        raise HookRejected(reason="pre_tool_hook raised: " + error.to_string())
    }
    match decision {
      Approve(call~) => {
        if call.call_id != input.call_id {
          changed_id = true
        }
        current = snapshot_tool_call(call)
      }
      ApproveAfterConsent(call~, consent_scope=scope) => {
        if call.call_id != input.call_id {
          changed_id = true
        }
        current = snapshot_tool_call(call)
        consented = Some(snapshot_tool_call(call))
        consent_scope = Some(scope)
      }
      Reject(reason~) => rejections.push(reason)
      Defer(reason~) =>
        raise HookRejected(
          reason="pre_tool_hook defer not yet supported: " + reason,
        )
    }
  }
  if changed_id {
    raise HookRejected(
      reason="pre_tool_hook changed call_id for a pending tool call",
    )
  }
  let invalid_consent = match consented {
    Some(call) => call != current
    None => false
  }
  // Final pre-start check AFTER the hook chain: a target whose contributing
  // version was hard-withdrawn must not start, even when a hook rewrote it into
  // that name or granted consent while the withdrawal landed.
  let revoked = match revocations {
    Some(facts) => facts.is_revoked(current.name.to_string())
    None => false
  }
  let rejection = if revoked {
    Some(
      @kernel.ToolOutcome::NotExecuted(
        reason=Revoked,
        original_call_id=input.call_id,
      ),
    )
  } else if invalid_consent {
    Some(
      @kernel.ToolOutcome::NotExecuted(
        reason=RejectedByHook(
          reason="tool call changed after consent; authorization was not reused",
        ),
        original_call_id=input.call_id,
      ),
    )
  } else if consented is None && !rejections.is_empty() {
    Some(
      @kernel.ToolOutcome::NotExecuted(
        reason=RejectedByHook(reason=rejections.join("; ")),
        original_call_id=input.call_id,
      ),
    )
  } else {
    @kernel_exec.classify_rejected_outcome(catalog, current, direct~)
  }
  { call: current, consent_scope, rejection, }
}
