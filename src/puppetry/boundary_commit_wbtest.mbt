///|
/// Boundary-journal contracts: effects must observe their intent boundary as
/// already durable, and the next model intent joins the final tool outcome
/// boundary instead of paying for a separate append.

///|
struct BoundaryProbeHost {
  journal : InMemoryJournal
  model_results : Array[Result[Completion, ModelFailure]]
  mut model_index : Int
  append_counts_at_model_call : Array[Int]
}

///|
fn BoundaryProbeHost::new(
  journal : InMemoryJournal,
  model_results : Array[Result[Completion, ModelFailure]],
) -> BoundaryProbeHost {
  {
    journal,
    model_results: model_results.copy(),
    model_index: 0,
    append_counts_at_model_call: [],
  }
}

///|
fn BoundaryProbeHost::append_counts_at_model_call(
  self : BoundaryProbeHost,
) -> Array[Int] {
  self.append_counts_at_model_call.copy()
}

///|
pub impl @kernel.HostRuntime for BoundaryProbeHost with fn call_model(
  self,
  messages : Array[Message],
  _tool_definitions : Array[ToolDef],
  _call_options : Json,
  _on_chunk : HostChunkCallback?,
) -> Result[ModelCallResult, ModelFailure] {
  self.append_counts_at_model_call.push(self.journal.append_count())
  let index = self.model_index
  self.model_index = index + 1
  if index >= self.model_results.length() {
    Err(Runtime(reason="boundary probe exhausted model results"))
  } else {
    match self.model_results[index] {
      Ok(completion) =>
        Ok(ModelCallResult::{ completion, processed_messages: messages })
      Err(failure) => Err(failure)
    }
  }
}

///|
pub impl @kernel.HostRuntime for BoundaryProbeHost with fn execute_tool(
  _self,
  _owner_id : OwnerId,
  call_id : CallId,
  _tool_name : ToolName,
  _arguments : Json,
) -> ToolOutcome {
  Success(content=call_id.to_string(), structured=None)
}

///|
pub impl @kernel.HostRuntime for BoundaryProbeHost with fn cancel_effects(
  self : BoundaryProbeHost,
  effect_ids : Array[EffectId],
  _reason : CancelReason,
) -> Array[(EffectId, CancelDisposition)] {
  ignore(self)
  effect_ids.map(id => (id, NotPropagated))
}

///|
/// M3.5: compact stub — BoundaryProbeHost does not exercise compact.
pub impl @kernel.HostRuntime for BoundaryProbeHost with fn compact(
  self : BoundaryProbeHost,
  _messages : Array[Message],
  _call_options : Json,
  _trigger : @kernel.CompactTrigger,
) -> Result[CompactResult, ModelFailure] {
  ignore(self)
  Err(
    ModelFailure::Parse(reason="BoundaryProbeHost does not implement compact"),
  )
}

///|
async test "puppet/boundary_commits_intent_before_each_model_effect" {
  let journal = InMemoryJournal()
  let host = BoundaryProbeHost::new(journal, [
    Ok(fixture_tool_calls([fixture_call("echo", "tool_1")])),
    Ok(fixture_stop("done")),
  ])
  let catalog = fixture_tool_catalog("echo")
  let puppet = Puppet(
    canonical_puppet_config(
      host as &@kernel.HostRuntime,
      "boundary-probe",
      catalog,
      journal,
      [],
      [],
      None,
      Json::null(),
    ),
  )
  assert_true(fixture_prompt(puppet, "boundary") is Accepted(_))
  // Initial InputAccepted boundary exists before the first model effect. The
  // final tool outcome and second model intent share the third boundary.
  assert_eq(host.append_counts_at_model_call(), [1, 3])
  assert_eq(journal.append_count(), 4)
}
