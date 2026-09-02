///|
/// Boundary-journal contracts: effects must observe their intent boundary as
/// already durable, and the next model intent joins the final tool outcome
/// boundary instead of paying for a separate append.

///|
struct BoundaryProbeHost {
  journal : InMemoryJournal
  model_results : Array[Result[@kernel.Completion, ModelFailure]]
  mut model_index : Int
  append_counts_at_model_call : Array[Int]
}

///|
fn BoundaryProbeHost::BoundaryProbeHost(
  journal : InMemoryJournal,
  model_results : Array[Result[@kernel.Completion, ModelFailure]],
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
pub impl @kernel_exec.HostRuntime for BoundaryProbeHost with fn call_model(
  self,
  _scope : InvocationScope,
  messages : ArrayView[Message],
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
        Ok({ completion, processed_messages: messages.to_owned(), })
      Err(failure) => Err(failure)
    }
  }
}

///|
pub impl @kernel_exec.HostRuntime for BoundaryProbeHost with fn execute_tool(
  _self,
  _effect_id : EffectId,
  _owner_id : OwnerId,
  call_id : CallId,
  _tool_name : ToolName,
  _arguments : Json,
) -> @kernel.ToolOutcome {
  Success(content=call_id.to_string(), structured=None)
}

///|
pub impl @kernel_exec.HostRuntime for BoundaryProbeHost with fn cancel_effects(
  self : BoundaryProbeHost,
  effect_ids : Array[EffectId],
  _reason : CancelReason,
) -> Array[(EffectId, CancelDisposition)] {
  ignore(self)
  effect_ids.map(id => (id, NotPropagated))
}

///|
/// M3.5: compact stub — BoundaryProbeHost does not exercise compact.
pub impl @kernel_exec.HostRuntime for BoundaryProbeHost with fn compact(
  self : BoundaryProbeHost,
  _scope : InvocationScope,
  _messages : ArrayView[Message],
  _call_options : Json,
  _trigger : @kernel.CompactTrigger,
) -> Result[CompactResult, ModelFailure] {
  ignore(self)
  Err(Parse(reason="BoundaryProbeHost does not implement compact"))
}

///|
async test "puppet/boundary_commits_intent_before_each_model_effect" {
  let journal = InMemoryJournal()
  let host = BoundaryProbeHost(journal, [
    Ok(fixture_tool_calls([fixture_call("echo", "tool_1")])),
    Ok(fixture_stop("done")),
  ])
  let catalog = fixture_tool_catalog("echo")
  let puppet = Puppet(
    canonical_puppet_config(
      host as &@kernel_exec.HostRuntime,
      catalog,
      journal,
      [],
      [],
      None,
    ),
  )
  assert_true(fixture_prompt(puppet, "boundary") is Accepted(_))
  // Initial InputAccepted boundary exists before the first model effect. The
  // final tool outcome and second model intent share the third boundary.
  assert_eq(host.append_counts_at_model_call(), [1, 3])
  assert_eq(journal.append_count(), 4)
}

// ──────────────────────────────────────────────────────────────────────────
// Transcript rewrite observability (W1.1 — reducer is the sole transcript
// writer; rewrites must surface as TranscriptRewritten facts, not silent
// mutations)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Recording EventSubscriber for rewrite-observability tests.
struct RewriteProbeSubscriber {
  events : Array[KernelEvent]
}

///|
pub impl EventSubscriber for RewriteProbeSubscriber with fn subscriber_id(_self) -> String {
  "rewrite_probe"
}

///|
pub impl EventSubscriber for RewriteProbeSubscriber with fn provenance(_self) -> String {
  "test"
}

///|
pub impl EventSubscriber for RewriteProbeSubscriber with fn on_event(
  self,
  envelope : EventEnvelope,
) -> Unit raise SubscriberError {
  self.events.push(envelope.event())
}

///|
/// Host whose compact returns a Replace result with a one-message summary.
struct CompactReplaceHost {
  model_results : Array[Result[@kernel.Completion, ModelFailure]]
  mut model_index : Int
  messages_at_model_call : Array[Array[Message]]
}

///|
fn CompactReplaceHost::CompactReplaceHost(
  model_results : Array[Result[@kernel.Completion, ModelFailure]],
) -> CompactReplaceHost {
  {
    model_results: model_results.copy(),
    model_index: 0,
    messages_at_model_call: [],
  }
}

///|
pub impl @kernel_exec.HostRuntime for CompactReplaceHost with fn call_model(
  self,
  _scope : InvocationScope,
  messages : ArrayView[Message],
  _tool_definitions : Array[ToolDef],
  _call_options : Json,
  _on_chunk : HostChunkCallback?,
) -> Result[ModelCallResult, ModelFailure] {
  self.messages_at_model_call.push(messages.to_owned())
  let index = self.model_index
  self.model_index = index + 1
  if index >= self.model_results.length() {
    Err(Runtime(reason="compact probe exhausted model results"))
  } else {
    match self.model_results[index] {
      Ok(completion) =>
        Ok({ completion, processed_messages: messages.to_owned(), })
      Err(failure) => Err(failure)
    }
  }
}

///|
pub impl @kernel_exec.HostRuntime for CompactReplaceHost with fn execute_tool(
  _self,
  _effect_id : EffectId,
  _owner_id : OwnerId,
  call_id : CallId,
  _tool_name : ToolName,
  _arguments : Json,
) -> @kernel.ToolOutcome {
  Success(content=call_id.to_string(), structured=None)
}

///|
pub impl @kernel_exec.HostRuntime for CompactReplaceHost with fn cancel_effects(
  self : CompactReplaceHost,
  effect_ids : Array[EffectId],
  _reason : CancelReason,
) -> Array[(EffectId, CancelDisposition)] {
  ignore(self)
  effect_ids.map(id => (id, NotPropagated))
}

///|
pub impl @kernel_exec.HostRuntime for CompactReplaceHost with fn compact(
  _self,
  _scope : InvocationScope,
  _messages : ArrayView[Message],
  _call_options : Json,
  _trigger : @kernel.CompactTrigger,
) -> Result[CompactResult, ModelFailure] {
  Ok({
    compacted_messages: [UserMessage(content=[Text("compacted summary")])],
    mode: Replace,
  })
}

///|
fn fixture_tool_calls_with_usage(
  calls : Array[ToolCall],
  total : Int,
) -> @kernel.Completion {
  Completion(
    content=[],
    tool_calls=calls,
    reasoning=None,
    finish_reason=ToolCalls,
    usage=Some({
      input_tokens: Some(total),
      output_tokens: Some(0),
      total_tokens: Some(total),
      cached_input_tokens: None,
      uncached_input_tokens: None,
    }),
  )
}

///|
async test "puppet/boundary_journals_auto_compact_replace_rewrite" {
  let journal = InMemoryJournal()
  let host = CompactReplaceHost([
    Ok(fixture_tool_calls_with_usage([fixture_call("echo", "tool_1")], 95)),
    Ok(fixture_stop("done")),
  ])
  let catalog = fixture_tool_catalog("echo")
  let subscriber = RewriteProbeSubscriber::{ events: [], }
  let mailbox_instance = ControlMailbox()
  let config : PuppetConfig = {
    host: host as &@kernel_exec.HostRuntime,
    catalog,
    journal,
    contributors: [],
    subscribers: [subscriber as &EventSubscriber],
    stream_chunks: None,
    hooks: [],
    max_iterations: Some(50),
    commands: [],
    session_store: None,
    mailbox: mailbox_instance as &Mailbox,
  }
  let puppet = Puppet(config)
  let result = puppet.prompt({
    run_id: RunId::unchecked("run_auto_compact_rewrite"),
    turn_id: TurnId::unchecked("turn_auto_compact_rewrite"),
    session_id: SessionId::unchecked("session_auto_compact_rewrite"),
    initial_messages: [UserMessage(content=[Text("hello")])],
    operation_id: "operation_auto_compact_rewrite",
    policy: {
      model_id: "fixture-model",
      call_options: Json::null(),
      budget: Budget::default_run(),
      context_window: Some(100),
      compact_threshold: 0.9,
    },
  })
  assert_true(result is Accepted(_))
  // Auto-compact fired after the first model step (usage 95 >= 90% of 100);
  // the second model call must observe the compacted transcript.
  assert_eq(host.messages_at_model_call.length(), 2)
  let second_call = host.messages_at_model_call[1]
  assert_eq(second_call.length(), 1)
  match second_call[0] {
    UserMessage(content~) =>
      match content[0] {
        Text(text) => assert_eq(text, "compacted summary")
        _ => fail("expected text content")
      }
    _ => fail("expected compacted user message")
  }
  // The rewrite event lands causally: after the tool outcome that brought
  // the run to ReadyForModel, before the second declared model intent.
  let mut tool_idx = -1
  let mut rewrite_idx = -1
  let step_starts : Array[Int] = []
  for i, event in subscriber.events {
    match event {
      ToolCompleted(..) => tool_idx = i
      TranscriptRewritten(messages_before~, messages_after~, reason~) => {
        rewrite_idx = i
        assert_eq(reason, "compact_replace")
        assert_eq(messages_before, 3)
        assert_eq(messages_after, 1)
      }
      ModelStepStarted(..) => step_starts.push(i)
      _ => ()
    }
  }
  assert_true(tool_idx >= 0 && rewrite_idx > tool_idx)
  assert_eq(step_starts.length(), 2)
  assert_true(rewrite_idx < step_starts[1])
}
