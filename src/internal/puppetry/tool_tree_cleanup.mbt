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
/// cancellation is not a provider stop receipt, so retain each real report.
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
