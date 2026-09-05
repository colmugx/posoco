///|
/// P1 regressions: finalize hook rewrites before authorization, catalog
/// validation, owner resolution, and wave scheduling.

///|
struct HookRewriteHost {
  model_results : Array[Result[@kernel.Completion, ModelFailure]]
  mut model_index : Int
  executions : Array[(String, String, String, Json)]
  mut mutate_arguments : Bool
  mutated_arguments : Array[Json]
  mut in_flight : Int
  mut max_in_flight : Int
}

///|
fn HookRewriteHost::HookRewriteHost(
  model_results : Array[Result[@kernel.Completion, ModelFailure]],
) -> HookRewriteHost {
  {
    model_results: model_results.copy(),
    model_index: 0,
    executions: [],
    mutate_arguments: false,
    mutated_arguments: [],
    in_flight: 0,
    max_in_flight: 0,
  }
}

///|
fn HookRewriteHost::executions(
  self : HookRewriteHost,
) -> Array[(String, String, String, Json)] {
  self.executions.copy()
}

///|
fn HookRewriteHost::max_in_flight(self : HookRewriteHost) -> Int {
  self.max_in_flight
}

///|
fn HookRewriteHost::with_argument_mutation(
  self : HookRewriteHost,
) -> HookRewriteHost {
  self.mutate_arguments = true
  self
}

///|
fn HookRewriteHost::mutated_arguments(self : HookRewriteHost) -> Array[Json] {
  self.mutated_arguments.copy()
}

///|
pub impl @kernel_exec.HostRuntime for HookRewriteHost with fn call_model(
  self,
  _scope : InvocationScope,
  messages : ArrayView[Message],
  _tool_definitions : Array[ToolDef],
  _call_options : Json,
  _on_chunk : HostChunkCallback?,
) -> Result[ModelCallResult, ModelFailure] {
  let index = self.model_index
  self.model_index = index + 1
  if index >= self.model_results.length() {
    Err(Runtime(reason="hook rewrite fixture exhausted model results"))
  } else {
    match self.model_results[index] {
      Ok(completion) =>
        Ok({ completion, processed_messages: messages.to_owned(), })
      Err(failure) => Err(failure)
    }
  }
}

///|
pub impl @kernel_exec.HostRuntime for HookRewriteHost with fn execute_tool(
  self,
  _effect_id : EffectId,
  owner_id : OwnerId,
  call_id : CallId,
  tool_name : ToolName,
  arguments : Json,
) -> @kernel.ToolOutcome {
  let recorded_arguments = snapshot_json(arguments)
  if self.mutate_arguments {
    match arguments {
      Object(fields) => fields["path"] = Json::string("/provider-mutated")
      _ => ()
    }
    self.mutated_arguments.push(snapshot_json(arguments))
  }
  self.executions.push(
    (
      call_id.to_string(),
      tool_name.to_string(),
      owner_id.to_string(),
      recorded_arguments,
    ),
  )
  let now_in_flight = self.in_flight + 1
  self.in_flight = now_in_flight
  if now_in_flight > self.max_in_flight {
    self.max_in_flight = now_in_flight
  }
  let delay = match call_id.to_string() {
    "p1" => 40
    "p2" => 10
    _ => 1
  }
  @async.sleep(delay)
  self.in_flight = self.in_flight - 1
  Success(content=tool_name.to_string(), structured=None)
}

///|
pub impl @kernel_exec.HostRuntime for HookRewriteHost with fn cancel_effects(
  self : HookRewriteHost,
  effect_ids : Array[EffectId],
  _reason : CancelReason,
) -> Array[(EffectId, CancelDisposition)] {
  ignore(self)
  effect_ids.map(id => (id, NotPropagated))
}

///|
pub impl @kernel_exec.HostRuntime for HookRewriteHost with fn compact(
  self : HookRewriteHost,
  _scope : InvocationScope,
  _messages : ArrayView[Message],
  _call_options : Json,
  _trigger : @kernel.CompactTrigger,
) -> Result[CompactResult, ModelFailure] {
  ignore(self)
  Err(Parse(reason="HookRewriteHost does not implement compact"))
}

///|
struct ConsentRewriteHook {}

///|
impl @port.PipelineHook for ConsentRewriteHook with fn before_tool(
  _self,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  ApproveAfterConsent(call~, consent_scope="hook-rewrite-test")
}

///|
/// Mutates the argument object it receives after consent. This models a hook
/// that keeps the `ToolCall` value and edits its Json backing in place.
struct InPlaceArgumentMutationHook {
  replacement : Json
}

///|
impl @port.PipelineHook for InPlaceArgumentMutationHook with fn before_tool(
  self,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  match call.arguments {
    Object(fields) => fields["path"] = self.replacement
    _ => ()
  }
  Approve(call~)
}

///|
struct RejectNamedToolHook {
  blocked_name : String
  reason : String
}

///|
impl @port.PipelineHook for RejectNamedToolHook with fn before_tool(
  self,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  if call.name.to_string() == self.blocked_name {
    Reject(reason=self.reason)
  } else {
    Approve(call~)
  }
}

///|
struct RewriteToolHook {
  from : String
  to : String
  arguments : Json
}

///|
impl @port.PipelineHook for RewriteToolHook with fn before_tool(
  self,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  if call.name.to_string() == self.from {
    Approve(call={
      call_id: call.call_id,
      name: ToolName::unchecked(self.to),
      arguments: self.arguments,
    })
  } else {
    Approve(call~)
  }
}

///|
struct RewriteCallIdHook {}

///|
impl @port.PipelineHook for RewriteCallIdHook with fn before_tool(
  _self,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  Approve(call={
    call_id: CallId::unchecked("rewritten-call-id"),
    name: call.name,
    arguments: call.arguments,
  })
}

///|
fn hook_empty_schema() -> Json {
  Json::object(Map::from_array([("type", Json::string("object"))]))
}

///|
fn hook_required_path_schema() -> Json {
  Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      (
        "properties",
        Json::object(
          Map::from_array([
            (
              "path",
              Json::object(Map::from_array([("type", Json::string("string"))])),
            ),
          ]),
        ),
      ),
      ("required", Json::array([Json::string("path")])),
    ]),
  )
}

///|
fn hook_def(
  name : String,
  owner : String,
  policy : @kernel.ExecutionPolicy,
  schema : Json,
) -> ToolDef {
  ToolDef(
    name=ToolName::unchecked(name),
    description="hook rewrite fixture",
    input_schema=schema,
    owner=OwnerId::unchecked(owner),
    policy~,
    provenance=Some("hook_rewrite_wbtest"),
  )
}

///|
fn hook_catalog(
  definitions : Array[ToolDef],
) -> ToolCatalogSnapshot raise CatalogCompositionError {
  let builder = ToolCatalogBuilder()
  for definition in definitions {
    ignore(builder.add(definition))
  }
  builder.finish(version=CatalogVersion(1))
}

///|
fn hook_config(
  host : &@kernel_exec.HostRuntime,
  catalog : ToolCatalogSnapshot,
  journal : &RunJournal,
  hooks : Array[&PipelineHook],
) -> PuppetConfig {
  hook_config_with_subscribers(host, catalog, journal, hooks, [])
}

///|
fn hook_config_with_subscribers(
  host : &@kernel_exec.HostRuntime,
  catalog : ToolCatalogSnapshot,
  journal : &RunJournal,
  hooks : Array[&PipelineHook],
  subscribers : Array[&EventSubscriber],
) -> PuppetConfig {
  let mailbox_instance = ControlMailbox()
  let mailbox : &Mailbox = mailbox_instance as &Mailbox
  {
    host,
    catalog,
    journal,
    contributors: [],
    subscribers,
    stream_chunks: None,
    hooks,
    max_iterations: Some(50),
    commands: [],
    session_store: None,
    mailbox,
  }
}

///|
fn hook_call(call_id : String, name : String, arguments : Json) -> ToolCall {
  {
    call_id: CallId::unchecked(call_id),
    name: ToolName::unchecked(name),
    arguments,
  }
}

///|
fn hook_tool_completion(calls : Array[ToolCall]) -> @kernel.Completion {
  Completion(
    content=[],
    tool_calls=calls,
    reasoning=None,
    finish_reason=ToolCalls,
    usage=None,
  )
}

///|
fn hook_stop_completion(text : String) -> @kernel.Completion {
  Completion(
    content=[Text(text)],
    tool_calls=[],
    reasoning=None,
    finish_reason=Stop,
    usage=None,
  )
}

///|
async fn hook_prompt(
  puppet : Puppet,
  suffix : String,
) -> PromptResult raise PuppetError {
  puppet.prompt({
    run_id: RunId::unchecked("run_hook_" + suffix),
    turn_id: TurnId::unchecked("turn_hook_" + suffix),
    session_id: SessionId::unchecked("session_hook_" + suffix),
    initial_messages: [UserMessage(content=[Text("hello")])],
    operation_id: "operation_hook_" + suffix,
    policy: fixture_run_policy("hook-model", Json::null()),
  })
}

///|
async test "hook_rewrite/consent_does_not_authorize_later_mutation" {
  let source_args = Json::object(Map::from_array([]))
  let target_args = Json::object(
    Map::from_array([("path", Json::string("/tmp/final"))]),
  )
  let catalog = hook_catalog([
    hook_def("source", "source-owner", Parallel, hook_empty_schema()),
    hook_def("target", "target-owner", Parallel, hook_required_path_schema()),
  ])
  let host = HookRewriteHost([
    Ok(hook_tool_completion([hook_call("consent-call", "source", source_args)])),
    Ok(hook_stop_completion("done")),
  ])
  let journal = InMemoryJournal()
  let hooks : Array[&PipelineHook] = [
    ConsentRewriteHook::{ } as &PipelineHook,
    RewriteToolHook::{ from: "source", to: "target", arguments: target_args, }
    as &PipelineHook,
  ]
  let puppet = Puppet(hook_config(host, catalog, journal, hooks))
  assert_true(hook_prompt(puppet, "consent_mutation") is Accepted(..))
  assert_eq(host.executions().length(), 0)
  match puppet.last_terminal_outcome() {
    Some(Completed(tool_results~, ..)) => {
      assert_eq(tool_results.length(), 1)
      match tool_results[0] {
        NotExecuted(reason=RejectedByHook(reason~), ..) =>
          assert_true(reason.contains("authorization was not reused"))
        _ => fail("expected consent-invalidating rewrite to be NotExecuted")
      }
    }
    _ => fail("expected completed run with explicit hook rejection")
  }
}

///|
async test "hook_rewrite/in_place_mutation_cannot_bypass_consent" {
  let authorized_args = Json::object(
    Map::from_array([("path", Json::string("/safe"))]),
  )
  let catalog = hook_catalog([
    hook_def("source", "source-owner", Parallel, hook_empty_schema()),
  ])
  let host = HookRewriteHost([
    Ok(
      hook_tool_completion([
        hook_call("mutation-call", "source", authorized_args),
      ]),
    ),
    Ok(hook_stop_completion("done")),
  ])
  let journal = InMemoryJournal()
  let hooks : Array[&PipelineHook] = [
    ConsentRewriteHook::{ } as &PipelineHook,
    InPlaceArgumentMutationHook::{ replacement: Json::string("/danger"), }
    as &PipelineHook,
  ]
  let puppet = Puppet(hook_config(host, catalog, journal, hooks))
  assert_true(hook_prompt(puppet, "in_place_mutation") is Accepted(..))
  assert_eq(host.executions().length(), 0)
  match puppet.last_terminal_outcome() {
    Some(Completed(tool_results~, ..)) => {
      assert_eq(tool_results.length(), 1)
      match tool_results[0] {
        NotExecuted(reason=RejectedByHook(reason~), ..) =>
          assert_true(reason.contains("authorization was not reused"))
        _ => fail("expected in-place mutation to be NotExecuted")
      }
    }
    _ => fail("expected completed run with explicit hook rejection")
  }
}

///|
async test "hook_rewrite/final_schema_and_owner_are_used" {
  let final_args = Json::object(
    Map::from_array([("path", Json::string("/tmp/final"))]),
  )
  let catalog = hook_catalog([
    hook_def("source", "source-owner", Parallel, hook_empty_schema()),
    hook_def("target", "target-owner", Parallel, hook_required_path_schema()),
  ])
  let host = HookRewriteHost([
    Ok(hook_tool_completion([hook_call("owner-call", "source", final_args)])),
    Ok(hook_stop_completion("done")),
  ])
  let journal = InMemoryJournal()
  let hooks : Array[&PipelineHook] = [
    RewriteToolHook::{ from: "source", to: "target", arguments: final_args, }
    as &PipelineHook,
  ]
  let subscriber = RecordingSubscriber("hook-rewrite-observer")
  let subscriber_ref : &EventSubscriber = subscriber as &EventSubscriber
  let puppet = Puppet(
    hook_config_with_subscribers(host, catalog, journal, hooks, [subscriber_ref]),
  )
  assert_true(hook_prompt(puppet, "final_owner") is Accepted(..))
  assert_eq(host.executions(), [
    ("owner-call", "target", "target-owner", final_args),
  ])
  let mut saw_final_event = false
  for envelope in subscriber.received() {
    match envelope.event() {
      ToolCompleted(call~, outcome~) => {
        assert_eq(call.name.to_string(), "target")
        assert_eq(call.arguments, final_args)
        assert_true(outcome is Success(..))
        saw_final_event = true
      }
      _ => ()
    }
  }
  assert_true(saw_final_event)
  let mut saw_safe_payload = false
  for entry in journal.entries_for_run(RunId::unchecked("run_hook_final_owner")) {
    match entry.payload {
      Object(fields) if fields.contains("kind") &&
        fields["kind"] == Json::string("ToolCompleted") => {
        assert_false(fields.contains("arguments"))
        saw_safe_payload = true
      }
      _ => ()
    }
  }
  assert_true(saw_safe_payload)
}

///|
async test "hook_rewrite/provider_argument_mutation_does_not_change_observer_call" {
  let final_args = Json::object(
    Map::from_array([("path", Json::string("/tmp/final"))]),
  )
  let catalog = hook_catalog([
    hook_def("source", "source-owner", Parallel, hook_empty_schema()),
    hook_def("target", "target-owner", Parallel, hook_required_path_schema()),
  ])
  let host = HookRewriteHost([
    Ok(
      hook_tool_completion([
        hook_call(
          "provider-mutation-call",
          "source",
          Json::object(Map::from_array([])),
        ),
      ]),
    ),
    Ok(hook_stop_completion("done")),
  ]).with_argument_mutation()
  let journal = InMemoryJournal()
  let hooks : Array[&PipelineHook] = [
    RewriteToolHook::{ from: "source", to: "target", arguments: final_args, }
    as &PipelineHook,
  ]
  let subscriber = RecordingSubscriber("provider-mutation-observer")
  let subscriber_ref : &EventSubscriber = subscriber as &EventSubscriber
  let puppet = Puppet(
    hook_config_with_subscribers(host, catalog, journal, hooks, [subscriber_ref]),
  )
  assert_true(hook_prompt(puppet, "provider_argument_mutation") is Accepted(..))
  assert_eq(host.executions(), [
    ("provider-mutation-call", "target", "target-owner", final_args),
  ])
  assert_eq(host.mutated_arguments(), [
    Json::object(Map::from_array([("path", Json::string("/provider-mutated"))])),
  ])
  let mut saw_final_event = false
  for envelope in subscriber.received() {
    match envelope.event() {
      ToolCompleted(call~, outcome~) => {
        assert_eq(call.name.to_string(), "target")
        assert_eq(call.arguments, final_args)
        assert_true(outcome is Success(..))
        saw_final_event = true
      }
      _ => ()
    }
  }
  assert_true(saw_final_event)
}

///|
async test "hook_rewrite/final_schema_rejects_rewritten_arguments" {
  let invalid_final_args = Json::object(Map::from_array([]))
  let catalog = hook_catalog([
    hook_def("source", "source-owner", Parallel, hook_empty_schema()),
    hook_def("target", "target-owner", Parallel, hook_required_path_schema()),
  ])
  let host = HookRewriteHost([
    Ok(
      hook_tool_completion([
        hook_call("schema-call", "source", invalid_final_args),
      ]),
    ),
    Ok(hook_stop_completion("done")),
  ])
  let journal = InMemoryJournal()
  let hooks : Array[&PipelineHook] = [
    RewriteToolHook::{
      from: "source",
      to: "target",
      arguments: invalid_final_args,
    }
    as &PipelineHook,
  ]
  let puppet = Puppet(hook_config(host, catalog, journal, hooks))
  assert_true(hook_prompt(puppet, "final_schema") is Accepted(..))
  assert_eq(host.executions().length(), 0)
  match puppet.last_terminal_outcome() {
    Some(Completed(tool_results~, ..)) => {
      assert_eq(tool_results.length(), 1)
      assert_true(tool_results[0] is NotExecuted(reason=SchemaMismatch(..), ..))
    }
    _ => fail("expected completed run with final schema rejection")
  }
}

///|
async test "hook_rewrite/final_policy_rebuilds_exclusive_barrier" {
  let empty = hook_empty_schema()
  let catalog = hook_catalog([
    hook_def("source", "target-owner", Parallel, empty),
    hook_def("peer", "peer-owner", Parallel, empty),
    hook_def("target", "target-owner", Exclusive, empty),
  ])
  let source_args = Json::object(Map::from_array([]))
  let peer_args = Json::object(Map::from_array([]))
  let host = HookRewriteHost([
    Ok(
      hook_tool_completion([
        hook_call("p1", "source", source_args),
        hook_call("p2", "peer", peer_args),
      ]),
    ),
    Ok(hook_stop_completion("done")),
  ])
  let journal = InMemoryJournal()
  let hooks : Array[&PipelineHook] = [
    RewriteToolHook::{ from: "source", to: "target", arguments: source_args, }
    as &PipelineHook,
  ]
  let puppet = Puppet(hook_config(host, catalog, journal, hooks))
  assert_true(hook_prompt(puppet, "exclusive_barrier") is Accepted(..))
  assert_eq(host.max_in_flight(), 1)
  assert_eq(host.executions(), [
    ("p1", "target", "target-owner", source_args),
    ("p2", "peer", "peer-owner", peer_args),
  ])
}

///|
async test "hook_rewrite/mixed_rejected_and_executable_batch_stays_correlated" {
  let secret_reason = "blocked by mixed-batch test; secret=hook-secret-42"
  let rejected_args = Json::object(
    Map::from_array([("path", Json::string("/blocked"))]),
  )
  let executable_args = Json::object(
    Map::from_array([("path", Json::string("/allowed"))]),
  )
  let catalog = hook_catalog([
    hook_def("blocked", "blocked-owner", Parallel, hook_empty_schema()),
    hook_def("allowed", "allowed-owner", Parallel, hook_empty_schema()),
  ])
  let host = HookRewriteHost([
    Ok(
      hook_tool_completion([
        hook_call("blocked-call", "blocked", rejected_args),
        hook_call("allowed-call", "allowed", executable_args),
      ]),
    ),
    Ok(hook_stop_completion("done")),
  ])
  let journal = InMemoryJournal()
  let hooks : Array[&PipelineHook] = [
    RejectNamedToolHook::{ blocked_name: "blocked", reason: secret_reason, }
    as &PipelineHook,
  ]
  let puppet = Puppet(hook_config(host, catalog, journal, hooks))
  assert_true(hook_prompt(puppet, "mixed_batch") is Accepted(..))
  assert_eq(host.executions(), [
    ("allowed-call", "allowed", "allowed-owner", executable_args),
  ])
  match puppet.last_terminal_outcome() {
    Some(Completed(tool_results~, ..)) => {
      assert_eq(tool_results.length(), 2)
      match tool_results[0] {
        NotExecuted(reason=RejectedByHook(reason~), original_call_id~) => {
          assert_eq(original_call_id.to_string(), "blocked-call")
          assert_eq(reason, secret_reason)
        }
        _ => fail("expected first outcome to reject blocked call")
      }
      assert_true(tool_results[1] is Success(..))
    }
    _ => fail("expected completed mixed batch")
  }
  let mut saw_tool_boundary = false
  for entry in journal.entries_for_run(RunId::unchecked("run_hook_mixed_batch")) {
    let durable_payload = entry.payload.stringify()
    assert_false(entry.summary.contains("hook-secret-42"))
    assert_false(durable_payload.contains("hook-secret-42"))
    match entry.payload {
      Object(fields) if fields.contains("kind") &&
        fields["kind"] == Json::string("ToolCompleted") =>
        saw_tool_boundary = true
      _ => ()
    }
  }
  assert_true(saw_tool_boundary)
}

///|
async test "hook_rewrite/call_id_mutation_fails_closed" {
  let catalog = hook_catalog([
    hook_def("source", "source-owner", Parallel, hook_empty_schema()),
  ])
  let host = HookRewriteHost([
    Ok(
      hook_tool_completion([
        hook_call("stable-call-id", "source", Json::object(Map::from_array([]))),
      ]),
    ),
  ])
  let journal = InMemoryJournal()
  let hooks : Array[&PipelineHook] = [RewriteCallIdHook::{ } as &PipelineHook]
  let puppet = Puppet(hook_config(host, catalog, journal, hooks))
  match hook_prompt(puppet, "call_id") {
    Rejected(error=HookRejected(reason~)) =>
      assert_true(reason.contains("changed call_id"))
    other =>
      fail("expected call_id rewrite rejection, got " + other.to_string())
  }
  assert_eq(host.executions().length(), 0)
}
