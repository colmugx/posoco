///|
fn ToolTree::record_cancellations(
  self : ToolTree,
  reports : Array[(EffectId, CancelDisposition)],
) -> Unit {
  for report in reports {
    let (id, disposition) = report
    self.cancellations[id.to_int()] = disposition
  }
}

///|
/// Runs after the structured group has stopped its provider tasks. Fibre
/// cancellation is not a provider stop receipt, so keep each real report.
async fn ToolTree::cleanup(self : ToolTree, context : ExecutionContext) -> Unit {
  self.active.val = false
  let ids = self.executing.values().to_array()
  if ids.is_empty() {
    return
  }
  try {
    let reports = context.host.cancel_effects(
      ids,
      HostRequested(detail=Some("tool subtree failed")),
    )
    validate_cancel_dispositions(ids, reports)
    self.record_cancellations(reports)
  } catch {
    error => self.cleanup_error = Some(error.to_string())
  }
}

///|
fn tool_tree_error(error : Error) -> PuppetError {
  match error {
    HookRejected(reason~) => HookRejected(reason~)
    SavepointFailed(kind~, cause~) => SavepointFailed(kind~, cause~)
    SubscriberFailed(subscriber_id~, cause~, committed_revision~) =>
      SubscriberFailed(subscriber_id~, cause~, committed_revision~)
    ContributionInvalid(contributor_id~, detail~) =>
      ContributionInvalid(contributor_id~, detail~)
    SubscriberJournalMutation(subscriber_id~) =>
      SubscriberJournalMutation(subscriber_id~)
    ReducerInvariantViolation(category~) => ReducerInvariantViolation(category~)
    EffectExecutionFailed(phase~, cause~) =>
      EffectExecutionFailed(phase~, cause~)
    EffectExecutionCancelled(phase~) => EffectExecutionCancelled(phase~)
    ExecutionCleanupFailed(primary~, detail~) =>
      ExecutionCleanupFailed(primary~, detail~)
    other => execution_error("ToolTree", other)
  }
}

///|
fn ToolTree::is_revoked(
  self : ToolTree,
  id : EffectId,
  facts : ToolRevocationFacts,
) -> Bool {
  let mut current = Some(id)
  while current is Some(id) {
    let effect = match self.running.get(id.to_int()) {
      Some(effect) => Some(effect)
      None => self.waiting.get(id.to_int())
    }
    guard effect is Some(ExecuteTool(payload~, ..)) else { return false }
    if facts.is_revoked(payload.tool_name.to_string()) {
      return true
    }
    current = payload.parent.map(parent => parent.0)
  }
  false
}

///|
/// Cancel hard-withdrawn bindings and their descendants, not unrelated roots.
/// Only the actual `cancel_effects` report is recorded: a `Propagated` signal is
/// not a stop, and the executor keeps waiting for the provider's own result
/// instead of fabricating one.
async fn cancel_revoked_effects(
  tree : ToolTree,
  context : ExecutionContext,
) -> Unit raise PuppetError {
  let facts = match context.revocations {
    Some(facts) => facts
    None => return
  }
  let ids : Array[EffectId] = []
  for key, id in tree.executing {
    if tree.is_revoked(id, facts) && !tree.cancellations.contains(key) {
      ids.push(id)
    }
  }
  if ids.is_empty() {
    return
  }
  let reported = context.host.cancel_effects(
    ids,
    HostRequested(detail=Some("tool version revoked")),
  ) catch {
    error => raise execution_error("ToolRevocation", error)
  }
  validate_cancel_dispositions(ids, reported)
  tree.record_cancellations(reported)
}
