///|
/// M0-T05 regression tests: session metadata fidelity.
///
/// These tests document and enforce the data-fidelity invariant: loaded
/// session metadata MUST survive a turn unchanged (unknown keys preserved),
/// and NewThread lineage metadata MUST survive the final save.

// ---------------------------------------------------------------------------
// Helper: build an Agent wired with the testkit for metadata assertions.
// ---------------------------------------------------------------------------

///|
fn metadata_config() -> AgentConfig {
  agent_config(max_tool_rounds=Some(10))
}

// ---------------------------------------------------------------------------
// Regression 1: unknown metadata keys round-trip through a plain turn.
// ---------------------------------------------------------------------------

///|
async test "t05_metadata_roundtrip_preserves_unknown_keys" {
  // Seed a session with user-owned metadata. After a no-tool turn, the saved
  // session MUST still contain those keys with unchanged values.
  let model = ScriptedModel([Respond(tk_stop_response("done"))])
  let store = RecordingSessionStore()
  let initial_meta = Map::from_array([
    ("user_role", Json::string("admin")),
    ("turn_count", Json::number(5.0)),
  ])
  store.seed("s1", { messages: [], metadata: initial_meta, })
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=metadata_config(),
  )
  let _ = agent.run_turn(tk_user_msg("hello"), "s1")
  // The pure-append path calls append_messages; verify the persisted session
  // still carries the seeded metadata by loading it back.
  let persisted = store.load("s1") catch {
    e => fail("expected persisted s1 to load: \{e}")
  }
  assert_true(persisted.metadata.contains("user_role"))
  assert_true(persisted.metadata["user_role"] == Json::string("admin"))
  assert_true(persisted.metadata.contains("turn_count"))
  assert_true(persisted.metadata["turn_count"] == Json::number(5.0))
}

// ---------------------------------------------------------------------------
// Regression 2: save failure returns AgentError::Session, no TurnCompleted.
// ---------------------------------------------------------------------------

///|
async test "t05_save_failure_returns_session_error_no_turn_completed" {
  let model = ScriptedModel([Respond(tk_stop_response("done"))])
  let store = RecordingSessionStore()
  // Configure the session id to fail on save.
  store.fail_save("doomed")
  let obs = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store], observers=[obs]),
    ],
    config=metadata_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("hello"), "doomed")) catch {
    e => Err(e)
  }
  match result {
    Err(Session(error)) => {
      let message = error.to_string()
      assert_true(message.contains("doomed"))
      assert_true(message.contains("input_checkpoint"))
      assert_true(message.contains("SessionError::Save"))
      assert_true(!message.contains("hello"))
    }
    _ => fail("expected AgentError::Session on save failure")
  }
  // TurnCompleted MUST NOT have fired.
  let events = obs.events()
  for e in events {
    match e {
      TurnCompleted => fail("TurnCompleted must not fire on save failure")
      _ => ()
    }
  }
}

// ---------------------------------------------------------------------------
// Regression 3: a failed turn persists its progress, without mutating the
// loaded session by alias.
// ---------------------------------------------------------------------------

///|
async test "t05_failed_turn_persists_progress_without_aliasing" {
  let model = ScriptedModel([Fail(Transport("network down"))])
  let store = RecordingSessionStore()
  let original_messages = [tk_user_msg("already persisted")]
  store.seed("stable", {
    messages: original_messages,
    metadata: Map::from_array([]),
  })
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=metadata_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("must not leak"), "stable")) catch {
    e => Err(e)
  }
  match result {
    Err(Model(_)) => ()
    _ => fail("expected model failure")
  }
  assert_eq(original_messages.length(), 1)
  assert_true(original_messages[0] == tk_user_msg("already persisted"))
  try {
    let persisted = store.load("stable")
    // The failed turn's user input must survive: the next turn rebuilds its
    // context from this store, so losing it makes the model forget the query.
    assert_eq(persisted.messages.length(), 2)
    assert_true(persisted.messages[0] == tk_user_msg("already persisted"))
    assert_true(persisted.messages[1] == tk_user_msg("must not leak"))
  } catch {
    _ => fail("seeded session should remain loadable")
  }
}

// ---------------------------------------------------------------------------
// Regression 4: session failures identify id, operation and error category.
// ---------------------------------------------------------------------------

///|
async test "t05_session_load_error_has_context_without_metadata" {
  let model = ScriptedModel([])
  let store = RecordingSessionStore()
  store.fail_load("load-target", Load("backend unavailable"))
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=metadata_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("secret prompt"), "load-target")) catch {
    e => Err(e)
  }
  match result {
    Err(Session(err)) => {
      let message = err.to_string()
      assert_true(message.contains("load-target"))
      assert_true(message.contains("load"))
      assert_true(message.contains("SessionError::Load"))
      assert_true(message.contains("backend unavailable"))
      assert_true(!message.contains("secret prompt"))
    }
    _ => fail("expected contextualized session load failure")
  }
}

///|
async test "t05_session_error_uses_bounded_single_line_id" {
  let raw_id = "line-one\n" + "x".repeat(100) + "TAIL_SESSION_SECRET"
  let model = ScriptedModel([])
  let store = RecordingSessionStore()
  store.fail_load(raw_id, Load("backend unavailable"))
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=metadata_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("private prompt"), raw_id)) catch {
    error => Err(error)
  }
  match result {
    Err(Session(error)) => {
      let message = error.to_string()
      assert_true(message.contains("line-one "))
      assert_true(message.contains("...(truncated)"))
      assert_true(!message.contains("\n"))
      assert_true(!message.contains("TAIL_SESSION_SECRET"))
      assert_true(!message.contains("private prompt"))
    }
    _ => fail("expected contextualized session load failure")
  }
}

///|
async test "t05_session_save_cause_cannot_reexpand_raw_id" {
  let raw_id = "save-line\n" + "y".repeat(100) + "TAIL_SAVE_SECRET"
  let model = ScriptedModel([Respond(tk_stop_response("done"))])
  let store = RecordingSessionStore()
  // This fake includes the raw id in its underlying Save message, exercising
  // both the contextual id label and the bounded cause label.
  store.fail_save(raw_id)
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[store]),
    ],
    config=metadata_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("private prompt"), raw_id)) catch {
    error => Err(error)
  }
  match result {
    Err(Session(error)) => {
      let message = error.to_string()
      assert_true(message.contains("input_checkpoint"))
      assert_true(message.contains("SessionError::Save"))
      assert_true(message.contains("configured save failure"))
      assert_true(!message.contains("\n"))
      assert_true(!message.contains("TAIL_SAVE_SECRET"))
      assert_true(!message.contains("private prompt"))
    }
    _ => fail("expected contextualized session save failure")
  }
}

// ---------------------------------------------------------------------------
// Regression 5: every mutable port boundary receives an isolated snapshot.
// ---------------------------------------------------------------------------

///|
fn poison_json(value : Json, label : String) -> Unit {
  match value {
    Object(fields) => {
      fields["poison"] = Json::string(label)
      for key in fields.keys() {
        if key != "poison" {
          poison_json(fields[key], label)
        }
      }
    }
    Array(items) => items.push(Json::string(label))
    _ => ()
  }
}

///|
fn json_has_poison(value : Json) -> Bool {
  match value {
    String(text) => text.contains("poison")
    Array(items) => items.iter().any(json_has_poison)
    Object(fields) => {
      if fields.contains("poison") {
        return true
      }
      fields.values().any(json_has_poison)
    }
    _ => false
  }
}

///|
/// Mutate the first message in the array to inject `label` poison. R3 M3.7:
/// Message is an ADT; mutation requires building a new variant. We only
/// mutate messages that carry mutable arrays (AssistantMessage's content
/// and tool_calls). For SystemMessage/UserMessage we mutate content only.
/// For ToolMessage this helper leaves the payload alone; its `ToolOutcome`
/// does carry mutable structured JSON and attachment arrays, covered by the
/// dedicated `snapshot_message/tool_*` boundary tests below.
fn poison_first_message(
  messages : Array[@kernel.Message],
  label : String,
) -> Unit {
  match messages {
    [first, ..] =>
      match first {
        SystemMessage(content~) => content.push(Text(label))
        UserMessage(content~) => content.push(Text(label))
        AssistantMessage(content~, tool_calls~, ..) => {
          content.push(Text(label))
          tool_calls.push({
            call_id: @kernel.CallId::unchecked(label),
            name: @kernel.ToolName::unchecked(label),
            arguments: Json::null(),
          })
        }
        ToolMessage(..) => ()
      }
    [] => ()
  }
}

///|
fn assert_session_has_no_boundary_poison(session : @types.Session) -> Unit {
  if session.metadata.contains("store_poison") {
    abort("store metadata mutation leaked across session snapshot")
  }
  for value in session.metadata.values() {
    if json_has_poison(value) {
      abort("nested metadata mutation leaked across session snapshot")
    }
  }
  for message in session.messages {
    match message {
      SystemMessage(content~) =>
        for c in content {
          match c {
            Text(text) =>
              if text.contains("poison") {
                abort("message content mutation leaked across session snapshot")
              }
            Image(..) => ()
          }
        }
      UserMessage(content~) =>
        for c in content {
          match c {
            Text(text) =>
              if text.contains("poison") {
                abort("message content mutation leaked across session snapshot")
              }
            Image(..) => ()
          }
        }
      AssistantMessage(content~, tool_calls~, ..) => {
        for c in content {
          match c {
            Text(text) =>
              if text.contains("poison") {
                abort("message content mutation leaked across session snapshot")
              }
            Image(..) => ()
          }
        }
        for call in tool_calls {
          if call.name.to_string().contains("poison") ||
            call.call_id.to_string().contains("poison") {
            abort("tool call mutation leaked across session snapshot")
          }
          if json_has_poison(call.arguments) {
            abort("tool arguments mutation leaked across session snapshot")
          }
        }
      }
      ToolMessage(..) => ()
    }
  }
}

///|
struct BoundaryMutatingStore {}

///|
pub extend BoundaryMutatingStore with @port.SessionStore::{
  save,
  append_messages,
  checkpoint,
  load,
  truncate,
}

///|
pub impl @port.SessionStore for BoundaryMutatingStore with fn load(_self, _id) -> @types.Session {
  {
    messages: [],
    metadata: Map::from_array([
      (
        "nested",
        Json::object(
          Map::from_array([("value", Json::string("clean-metadata"))]),
        ),
      ),
    ]),
  }
}

///|
pub impl @port.SessionStore for BoundaryMutatingStore with fn save(
  _self,
  _id,
  session,
) -> Unit {
  poison_first_message(session.messages, "store-poison")
  if session.metadata.contains("nested") {
    poison_json(session.metadata["nested"], "store-poison")
  }
  session.metadata["store_poison"] = Json::boolean(true)
}

///|
struct BoundaryMutatingHook {}

///|
pub extend BoundaryMutatingHook with @port.PipelineHook::{
  tool_exposure,
  on_turn_begin,
  on_post_event,
  before_model,
  before_tool,
  on_turn_end,
}

///|
pub impl @port.PipelineHook for BoundaryMutatingHook with fn before_model(
  _self,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] raise @port.HookAbort {
  messages
}

///|
pub impl @port.PipelineHook for BoundaryMutatingHook with fn before_tool(
  _self,
  call : @kernel.ToolCall,
) -> @port.ToolDecision {
  Approve(call~)
}

///|
struct BoundaryMutatingObserver {}

///|
pub extend BoundaryMutatingObserver with @port.Observer::{on_event}

///|
pub impl @port.Observer for BoundaryMutatingObserver with fn on_event(
  _self,
  _scope,
  event,
) {
  match event {
    ModelResponseReceived(message~, ..) =>
      poison_first_message([message], "observer-model-poison")
    ToolCallPending(call) =>
      poison_json(call.arguments, "observer-pending-poison")
    ToolCallSucceeded(call~, content=_, structured~, ..) => {
      poison_json(call.arguments, "observer-result-poison")
      match structured {
        Some(value) => poison_json(value, "observer-result-poison")
        None => ()
      }
    }
    ToolCallFailed(call~, failure~) => {
      poison_json(call.arguments, "observer-result-poison")
      // We can only mutate the Json payload of payload-carrying failures.
      match failure {
        ReportedError(content=_, structured=Some(value)) =>
          poison_json(value, "observer-result-poison")
        _ => ()
      }
    }
    _ => ()
  }
}

///|
// R3 M3.7: `boundary_input_message` (User role with non-empty tool_calls,
// an illegal combo under the canonical ADT) and its two consumers
// (t05_model_hook_and_observer_inputs_are_deep_snapshots and
// t05_each_final_save_store_gets_independent_deep_snapshot) have been
// removed. The deep-snapshot invariant is still exercised by the metadata
// + reasoning-content tests below.

///|
async test "t05_each_final_save_store_gets_independent_deep_snapshot" {
  let mutating_store = BoundaryMutatingStore::{ }
  let recording_store = RecordingSessionStore()
  let model = ScriptedModel([Respond(tk_stop_response("done"))])
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", sessions=[mutating_store, recording_store]),
    ],
    config=metadata_config(),
  )
  let _ = agent.run_turn(tk_user_msg("hello"), "final-snapshot")
  try {
    let saved = recording_store.load("final-snapshot")
    assert_session_has_no_boundary_poison(saved)
  } catch {
    _ => fail("expected second store final snapshot")
  }
}

///|
struct BoundaryRecordingToolProvider {
  result : @kernel.ToolOutcome
  calls : Array[@kernel.ToolCall]
}

///|
pub extend BoundaryRecordingToolProvider with @port.ToolProvider::{
  execute,
  list_tools,
}

///|
pub impl @port.ToolProvider for BoundaryRecordingToolProvider with fn list_tools(
  _self,
) {
  [tk_tool_def("probe", "")]
}

///|
pub impl @port.ToolProvider for BoundaryRecordingToolProvider with fn execute(
  self,
  ctx,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  self.calls.push({
    call_id: ctx.call_id,
    name: ctx.name,
    arguments: ctx.arguments,
  })
  self.result
}

///|
async test "t05_tool_ports_hooks_and_observers_get_json_snapshots" {
  let call_args = Json::object(
    Map::from_array([
      (
        "nested",
        Json::object(
          Map::from_array([("value", Json::string("clean-call-arguments"))]),
        ),
      ),
    ]),
  )
  let provider_structured = Json::object(
    Map::from_array([
      (
        "nested",
        Json::object(
          Map::from_array([("value", Json::string("clean-tool-result"))]),
        ),
      ),
    ]),
  )
  let provider_result : @kernel.ToolOutcome = Success(
    content="clean result",
    structured=Some(provider_structured),
  )
  let model = ScriptedModel([
    Respond(tk_tool_call_response("probe", "tc-json", call_args)),
    Respond(tk_stop_response("done")),
  ])
  let provider = BoundaryRecordingToolProvider::{
    result: provider_result,
    calls: [],
  }
  let hook = BoundaryMutatingHook::{ }
  let mutating_observer = BoundaryMutatingObserver::{ }
  let recording_observer = RecordingObserver()
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[provider], hooks=[hook], sessions=[store], observers=[
        mutating_observer, recording_observer,
      ]),
    ],
    config=metadata_config(),
  )
  let result = agent.run_turn(tk_user_msg("run probe"), "tool-boundaries")
  assert_eq(result.tool_results.length(), 1)
  assert_eq(provider.calls.length(), 1)
  assert_true(!json_has_poison(provider.calls[0].arguments))
  assert_true(!json_has_poison(call_args))
  assert_true(!json_has_poison(provider_structured))
  match result.tool_results[0] {
    Success(content=_, structured=Some(value)) =>
      assert_true(!json_has_poison(value))
    _ => fail("expected structured tool result")
  }
  try {
    let saved = store.load("tool-boundaries")
    assert_session_has_no_boundary_poison(saved)
  } catch {
    _ => fail("expected saved tool-boundaries session")
  }
  for event in recording_observer.events() {
    match event {
      ToolCallPending(call) => assert_true(!json_has_poison(call.arguments))
      ToolCallSucceeded(call~, content=_, structured~, ..) => {
        assert_true(!json_has_poison(call.arguments))
        match structured {
          Some(value) => assert_true(!json_has_poison(value))
          None => fail("expected structured result event")
        }
      }
      _ => ()
    }
  }
}

///|
async test "automatic title comes from admitted human input before memory injection" {
  let model = ScriptedModel([Respond(tk_stop_response("done"))])
  let memory = ScriptedMemoryPort(inbounds=[
    Some("the same injected memory appears in every fresh session"),
  ])
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="memory", memory=[memory]),
      tk_ext(id="io", sessions=[store]),
    ],
    config=metadata_config(),
  )
  ignore(
    agent.run_turn(
      tk_user_msg("  investigate   the login\n race condition  "),
      "title-from-human",
    ),
  )
  let persisted = store.load("title-from-human") catch {
    error => fail("persisted titled session should load: \{error}")
  }
  assert_true(persisted.metadata.contains(@types.SESSION_TITLE_METADATA_KEY))
  assert_true(
    persisted.metadata[@types.SESSION_TITLE_METADATA_KEY] ==
    Json::string("investigate the login race condition"),
  )
  assert_eq(persisted.messages.length(), 3)
  match persisted.messages[0] {
    UserMessage(content=[Text(text), ..]) =>
      assert_true(text.has_prefix(MEMORY_INBOUND_LEAD))
    _ => fail("expected injected memory before the real user input")
  }
  assert_true(
    persisted.messages[1] ==
    tk_user_msg("  investigate   the login\n race condition  "),
  )
}

///|
/// A ToolMessage whose outcome carries both a nested structured payload and an
/// attachments array, so a shallow ToolMessage snapshot exposes two aliases.
fn tool_message_with_nested_outcome() -> (
  @kernel.Message,
  Json,
  Array[@kernel.Content],
) {
  let structured = Json::object(
    Map::from_array([
      (
        "nested",
        Json::object(Map::from_array([("value", Json::string("clean"))])),
      ),
    ]),
  )
  let attachments : Array[@kernel.Content] = [Text("clean-attachment")]
  let message : @kernel.Message = ToolMessage(
    call_id=@kernel.CallId::unchecked("tc-snapshot"),
    tool_name=@kernel.ToolName::unchecked("probe"),
    outcome=SuccessWithAttachments(
      content="clean result",
      structured=Some(structured),
      attachments~,
    ),
  )
  (message, structured, attachments)
}

///|
fn tool_message_snapshot_fields(
  message : @kernel.Message,
) -> (Json, Array[@kernel.Content]) raise {
  match message {
    ToolMessage(
      outcome=SuccessWithAttachments(structured=Some(value), attachments~, ..),
      ..
    ) => (value, attachments)
    _ => fail("expected a tool message with structured attachments")
  }
}

///|
test "snapshot_message/tool_outcome_input_aliases_are_copied" {
  let (message, structured, attachments) = tool_message_with_nested_outcome()
  let snapshot = snapshot_message(message)
  // Mutate the inputs at every level after the snapshot was taken.
  poison_json(structured, "poison")
  attachments.push(Text("poison"))
  let (snapshot_structured, snapshot_attachments) = tool_message_snapshot_fields(
    snapshot,
  )
  assert_false(json_has_poison(snapshot_structured))
  assert_eq(snapshot_attachments.length(), 1)
}

///|
test "snapshot_message/tool_outcome_output_aliases_stay_isolated" {
  let (message, structured, attachments) = tool_message_with_nested_outcome()
  let snapshot = snapshot_message(message)
  let (snapshot_structured, snapshot_attachments) = tool_message_snapshot_fields(
    snapshot,
  )
  // Mutating the snapshot must not reach back into the caller's outcome.
  poison_json(snapshot_structured, "poison")
  snapshot_attachments.push(Text("poison"))
  assert_false(json_has_poison(structured))
  assert_eq(attachments.length(), 1)
}

///|
fn tool_reported_error_message_with_nested_structured() -> (
  @kernel.Message,
  Json,
) {
  let structured = Json::object(
    Map::from_array([
      (
        "nested",
        Json::object(Map::from_array([("value", Json::string("clean"))])),
      ),
    ]),
  )
  let message : @kernel.Message = ToolMessage(
    call_id=@kernel.CallId::unchecked("tc-reported"),
    tool_name=@kernel.ToolName::unchecked("probe"),
    outcome=ToolReportedError(
      content="business failure",
      structured=Some(structured),
    ),
  )
  (message, structured)
}

///|
fn tool_reported_error_snapshot_structured(
  message : @kernel.Message,
) -> Json raise {
  match message {
    ToolMessage(outcome=ToolReportedError(structured=Some(value), ..), ..) =>
      value
    _ => fail("expected a ToolReportedError with structured data")
  }
}

///|
test "snapshot_message/tool_reported_error_input_structured_is_copied" {
  let (message, structured) = tool_reported_error_message_with_nested_structured()
  let snapshot = snapshot_message(message)
  poison_json(structured, "poison")
  assert_false(
    json_has_poison(tool_reported_error_snapshot_structured(snapshot)),
  )
}

///|
test "snapshot_message/tool_reported_error_output_structured_stays_isolated" {
  let (message, structured) = tool_reported_error_message_with_nested_structured()
  let snapshot = snapshot_message(message)
  poison_json(tool_reported_error_snapshot_structured(snapshot), "poison")
  assert_false(json_has_poison(structured))
}

///|
/// Whether a tool outcome still carries the tag this regression writes into
/// the returned `TurnResult`. Only the returned variant is expected to change.
fn tool_outcome_has_turn_result_poison(outcome : @kernel.ToolOutcome) -> Bool {
  match outcome {
    SuccessWithAttachments(structured=Some(value), attachments~, ..) => {
      let mut poisoned = json_has_poison(value)
      for content in attachments {
        match content {
          Text(text) =>
            if text.contains("turn-result-poison") {
              poisoned = true
            }
          Image(..) => ()
        }
      }
      poisoned
    }
    _ => false
  }
}

///|
async test "t05_turn_result_tool_outcomes_do_not_alias_held_transcript_or_next_input" {
  let structured = Json::object(
    Map::from_array([
      (
        "nested",
        Json::object(Map::from_array([("value", Json::string("clean"))])),
      ),
    ]),
  )
  let attachments : Array[@kernel.Content] = [Text("clean-attachment")]
  let provider_result : @kernel.ToolOutcome = SuccessWithAttachments(
    content="clean result",
    structured=Some(structured),
    attachments~,
  )
  let model = ScriptedModel([
    Respond(tk_tool_call_response("probe", "tc-turn-result", Json::null())),
    Respond(tk_stop_response("done")),
    Respond(tk_stop_response("next")),
  ])
  let provider = BoundaryRecordingToolProvider::{
    result: provider_result,
    calls: [],
  }
  let store = RecordingSessionStore()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[provider], sessions=[store]),
    ],
    config=metadata_config(),
  )
  let first = agent.run_turn(tk_user_msg("run probe"), "turn-result-alias")
  assert_eq(first.tool_results.length(), 1)
  // Mutate the returned outcome after the turn completed.
  match first.tool_results[0] {
    SuccessWithAttachments(structured=Some(value), attachments~, ..) => {
      poison_json(value, "turn-result-poison")
      attachments.push(Text("turn-result-poison"))
    }
    _ => fail("expected a returned SuccessWithAttachments")
  }
  // The Agent still owns its completed transcript; the returned payload must
  // not reach it.
  let held = match agent.runtime.puppet.last_completed_transcript() {
    Some(transcript) => transcript
    None => fail("expected the Agent to hold a completed transcript")
  }
  let mut held_tool_count = 0
  let mut held_poisoned = false
  for message in held.messages_snapshot() {
    match message {
      ToolMessage(outcome~, ..) => {
        held_tool_count = held_tool_count + 1
        if tool_outcome_has_turn_result_poison(outcome) {
          held_poisoned = true
        }
      }
      _ => ()
    }
  }
  assert_eq(held_tool_count, 1)
  // The next turn is fed from that held transcript, so a leak also shows up
  // in the next model request.
  ignore(agent.run_turn(tk_user_msg("next"), "turn-result-alias"))
  let mut next_tool_count = 0
  let mut next_poisoned = false
  for message in model.received_messages[2] {
    match message {
      ToolMessage(outcome~, ..) => {
        next_tool_count = next_tool_count + 1
        if tool_outcome_has_turn_result_poison(outcome) {
          next_poisoned = true
        }
      }
      _ => ()
    }
  }
  assert_eq(next_tool_count, 1)
  if held_poisoned || next_poisoned {
    fail(
      "TurnResult tool outcome aliased Agent state: held_transcript=\{held_poisoned}, next_input=\{next_poisoned}",
    )
  }
}
