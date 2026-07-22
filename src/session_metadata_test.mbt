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
  {
    max_tool_rounds: 10,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: None,
    model_context_window: None,
  }
}

// ---------------------------------------------------------------------------
// Regression 1: unknown metadata keys round-trip through a plain turn.
// ---------------------------------------------------------------------------

///|
async test "t05_metadata_roundtrip_preserves_unknown_keys" {
  // Seed a session with user-owned metadata. After a no-tool turn, the saved
  // session MUST still contain those keys with unchanged values.
  let model = ScriptedModel::new([Respond(tk_stop_response("done"))])
  let store = RecordingSessionStore::new()
  let initial_meta = Map::from_array([
    ("user_role", Json::string("admin")),
    ("turn_count", Json::number(5.0)),
  ])
  store.seed("s1", { messages: [], metadata: initial_meta })
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[],
    sessions=[store],
    lifecycle=None,
    config=metadata_config(),
  )
  let _ = agent.run_turn(tk_user_msg("hello"), "s1")
  // Inspect the final save snapshot for "s1".
  let snaps = store.save_snapshots()
  // Find the last save to "s1".
  let mut found : Map[String, Json]? = None
  for pair in snaps {
    let (id, meta) = pair
    if id == "s1" {
      found = Some(meta)
    }
  }
  match found {
    Some(meta) => {
      assert_true(meta.contains("user_role"))
      assert_true(meta["user_role"] == Json::string("admin"))
      assert_true(meta.contains("turn_count"))
      assert_true(meta["turn_count"] == Json::number(5.0))
    }
    None => fail("expected a save to s1, but none was recorded")
  }
}

// ---------------------------------------------------------------------------
// Regression 2: NewThread lineage parent_session_id survives final save.
// ---------------------------------------------------------------------------

///|
/// A compressor that triggers a NewThread on first call.
struct NewThreadCompressor {
  parent_id : String
}

///|
pub impl @port.Compressor for NewThreadCompressor with fn compress(
  self,
  _messages : Array[@types.Message],
  _ctx : @port.CompressContext,
) -> @port.CompressAction {
  let new_sid = self.parent_id + "_v2"
  NewThread(
    messages=[],
    new_session_id=new_sid,
    messages_before=0,
    messages_after=0,
  )
}

///|
async test "t05_newthread_lineage_survives_final_save" {
  // When compression creates a new thread, the new session's metadata gets
  // parent_session_id. The final save to the NEW session id MUST still carry
  // that lineage key (the bug: final_session used metadata: Map::from_array([])).
  let model = ScriptedModel::new([Respond(tk_stop_response("ok"))])
  let store = RecordingSessionStore::new()
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[NewThreadCompressor::{ parent_id: "orig" }],
    observers=[],
    sessions=[store],
    lifecycle=None,
    config=metadata_config(),
  )
  let result = agent.run_turn(tk_user_msg("compress me"), "orig")
  // The turn should have redirected to a new session.
  assert_true(result.final_session_id != "orig")
  // Look at saves to the new session id.
  let snaps = store.save_snapshots()
  let mut lineage_found = false
  for pair in snaps {
    let (id, meta) = pair
    if id == result.final_session_id && meta.contains("parent_session_id") {
      // The parent must point back to the original session.
      assert_true(meta["parent_session_id"] == Json::string("orig"))
      lineage_found = true
    }
  }
  assert_true(lineage_found)
}

// ---------------------------------------------------------------------------
// Regression 3: save failure returns AgentError::Session, no TurnCompleted.
// ---------------------------------------------------------------------------

///|
async test "t05_save_failure_returns_session_error_no_turn_completed" {
  let model = ScriptedModel::new([Respond(tk_stop_response("done"))])
  let store = RecordingSessionStore::new()
  // Configure the session id to fail on save.
  store.fail_save("doomed")
  let obs = RecordingObserver::new()
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[obs],
    sessions=[store],
    lifecycle=None,
    config=metadata_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("hello"), "doomed")) catch {
    e => Err(e)
  }
  match result {
    Err(@error.AgentError::Session(error)) => {
      let message = error.to_string()
      assert_true(message.contains("doomed"))
      assert_true(message.contains("final_save"))
      assert_true(message.contains("SessionError::Save"))
      assert_true(!message.contains("hello"))
    }
    _ => fail("expected AgentError::Session on save failure")
  }
  // TurnCompleted MUST NOT have fired.
  let events = obs.events()
  for e in events {
    match e {
      @types.TurnEvent::TurnCompleted =>
        fail("TurnCompleted must not fire on save failure")
      _ => ()
    }
  }
}

// ---------------------------------------------------------------------------
// Regression 4: a failed turn must not mutate the loaded session by alias.
// ---------------------------------------------------------------------------

///|
async test "t05_failed_turn_does_not_mutate_loaded_session_messages" {
  let model = ScriptedModel::new([
    Fail(@error.ModelError::Transport("network down")),
  ])
  let store = RecordingSessionStore::new()
  let original_messages = [tk_user_msg("already persisted")]
  store.seed("stable", {
    messages: original_messages,
    metadata: Map::from_array([]),
  })
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[],
    sessions=[store],
    lifecycle=None,
    config=metadata_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("must not leak"), "stable")) catch {
    e => Err(e)
  }
  match result {
    Err(@error.AgentError::Model(_)) => ()
    _ => fail("expected model failure")
  }
  assert_eq(original_messages.length(), 1)
  assert_true(original_messages[0] == tk_user_msg("already persisted"))
  match store.load("stable") {
    Ok(persisted) => {
      assert_eq(persisted.messages.length(), 1)
      assert_true(persisted.messages[0] == tk_user_msg("already persisted"))
    }
    Err(_) => fail("seeded session should remain loadable")
  }
}

// ---------------------------------------------------------------------------
// Regression 5: session failures identify id, operation and error category.
// ---------------------------------------------------------------------------

///|
async test "t05_session_load_error_has_context_without_metadata" {
  let model = ScriptedModel::new([])
  let store = RecordingSessionStore::new()
  store.fail_load(
    "load-target",
    @error.SessionError::Load("backend unavailable"),
  )
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[],
    sessions=[store],
    lifecycle=None,
    config=metadata_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("secret prompt"), "load-target")) catch {
    e => Err(e)
  }
  match result {
    Err(@error.AgentError::Session(err)) => {
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
  let model = ScriptedModel::new([])
  let store = RecordingSessionStore::new()
  store.fail_load(raw_id, @error.SessionError::Load("backend unavailable"))
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[],
    sessions=[store],
    lifecycle=None,
    config=metadata_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("private prompt"), raw_id)) catch {
    error => Err(error)
  }
  match result {
    Err(@error.AgentError::Session(error)) => {
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
  let model = ScriptedModel::new([Respond(tk_stop_response("done"))])
  let store = RecordingSessionStore::new()
  // This fake includes the raw id in its underlying Save message, exercising
  // both the contextual id label and the bounded cause label.
  store.fail_save(raw_id)
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[],
    sessions=[store],
    lifecycle=None,
    config=metadata_config(),
  )
  let result = Ok(agent.run_turn(tk_user_msg("private prompt"), raw_id)) catch {
    error => Err(error)
  }
  match result {
    Err(@error.AgentError::Session(error)) => {
      let message = error.to_string()
      assert_true(message.contains("final_save"))
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
// Regression 6: every mutable port boundary receives an isolated snapshot.
// ---------------------------------------------------------------------------

///|
fn poison_json(value : Json, label : String) -> Unit {
  match value {
    Json::Object(fields) => {
      fields["poison"] = Json::string(label)
      for key in fields.keys() {
        if key != "poison" {
          poison_json(fields[key], label)
        }
      }
    }
    Json::Array(items) => items.push(Json::string(label))
    _ => ()
  }
}

///|
fn json_has_poison(value : Json) -> Bool {
  match value {
    Json::String(text) => text.contains("poison")
    Json::Array(items) => items.iter().any(json_has_poison)
    Json::Object(fields) => {
      if fields.contains("poison") {
        return true
      }
      fields.values().any(json_has_poison)
    }
    _ => false
  }
}

///|
fn poison_first_message(
  messages : Array[@types.Message],
  label : String,
) -> Unit {
  match messages {
    [first, ..] => {
      for call in first.tool_calls {
        poison_json(call.arguments, label)
      }
      first.content.push(@types.Text(label))
      first.tool_calls.push({ id: label, name: label, arguments: Json::null() })
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
    for content in message.content {
      match content {
        @types.Text(text) =>
          if text.contains("poison") {
            abort("message content mutation leaked across session snapshot")
          }
        @types.Image(_, _) => ()
      }
    }
    for call in message.tool_calls {
      if call.name.contains("poison") || call.id.contains("poison") {
        abort("tool call mutation leaked across session snapshot")
      }
      if json_has_poison(call.arguments) {
        abort("tool arguments mutation leaked across session snapshot")
      }
    }
  }
}

///|
struct BoundaryMutatingStore {}

///|
pub impl @port.SessionStore for BoundaryMutatingStore with fn load(_self, _id) {
  Ok({
    messages: [],
    metadata: Map::from_array([
      (
        "nested",
        Json::object(
          Map::from_array([("value", Json::string("clean-metadata"))]),
        ),
      ),
    ]),
  })
}

///|
pub impl @port.SessionStore for BoundaryMutatingStore with fn save(
  _self,
  _id,
  session,
) {
  poison_first_message(session.messages, "store-poison")
  if session.metadata.contains("nested") {
    poison_json(session.metadata["nested"], "store-poison")
  }
  session.metadata["store_poison"] = Json::boolean(true)
  Ok(())
}

///|
struct BoundaryAliasingStore {
  session : @types.Session
}

///|
pub impl @port.SessionStore for BoundaryAliasingStore with fn load(self, _id) {
  // Deliberately return the retained value directly. Agent must detach from
  // this implementation even when the store itself provides no snapshot.
  Ok(self.session)
}

///|
pub impl @port.SessionStore for BoundaryAliasingStore with fn save(
  _self,
  _id,
  _session,
) {
  Ok(())
}

///|
struct BoundaryMutatingCompressor {}

///|
pub impl @port.Compressor for BoundaryMutatingCompressor with fn compress(
  _self,
  messages,
  _ctx,
) {
  poison_first_message(messages, "compressor-poison")
  None
}

///|
struct BoundaryMutatingHook {}

///|
pub impl @port.PipelineHook for BoundaryMutatingHook with fn on_stage(
  _self,
  stage,
) {
  match stage {
    @port.Stage::BeforeModel(messages) => {
      poison_first_message(messages, "hook-poison")
      // Returning a different stage means this mutation was not accepted as a
      // replacement. It must not leak through the input alias.
      Ok(@port.Stage::BeforeTurn)
    }
    @port.Stage::AfterModel(response) => {
      poison_first_message([response.message], "aftermodel-poison")
      response.tool_calls.push({
        id: "aftermodel-poison",
        name: "aftermodel-poison",
        arguments: Json::object(
          Map::from_array([("poison", Json::boolean(true))]),
        ),
      })
      Err(@port.HookError::Aborted("aftermodel-poison"))
    }
    @port.Stage::BeforeTool(call) => {
      poison_json(call.arguments, "beforetool-poison")
      Ok(@port.Stage::BeforeTurn)
    }
    @port.Stage::AfterTool(call, result) => {
      poison_json(call.arguments, "aftertool-poison")
      match result.structured {
        Some(value) => poison_json(value, "aftertool-poison")
        None => ()
      }
      Err(@port.HookError::Aborted("aftertool-poison"))
    }
    @port.Stage::AfterTurn(result) => {
      poison_first_message([result.message], "afterturn-poison")
      result.tool_results.push({
        content: "afterturn-poison",
        structured: Some(Json::string("afterturn-poison")),
        is_error: true,
      })
      Err(@port.HookError::Aborted("afterturn-poison"))
    }
    other => Ok(other)
  }
}

///|
struct BoundaryMutatingModel {
  response : @types.ModelResponse
}

///|
pub impl @port.ModelPort for BoundaryMutatingModel with fn chat(
  self,
  messages,
  tools,
  _options,
) {
  poison_first_message(messages, "model-poison")
  for tool in tools {
    poison_json(tool.input_schema, "model-tool-poison")
    match tool.metadata {
      Some(value) => poison_json(value, "model-tool-poison")
      None => ()
    }
  }
  self.response
}

///|
struct BoundaryMutatingObserver {}

///|
pub impl @port.Observer for BoundaryMutatingObserver with fn on_event(
  _self,
  event,
) {
  match event {
    @types.TurnEvent::ModelResponseReceived(message~, ..) =>
      poison_first_message([message], "observer-model-poison")
    @types.TurnEvent::ToolCallPending(call) =>
      poison_json(call.arguments, "observer-pending-poison")
    @types.TurnEvent::ToolCallResult(call~, result~, ..) => {
      poison_json(call.arguments, "observer-result-poison")
      match result.structured {
        Some(value) => poison_json(value, "observer-result-poison")
        None => ()
      }
    }
    _ => ()
  }
}

///|
fn boundary_input_message(text : String) -> @types.Message {
  {
    role: @types.User,
    content: [@types.Text(text)],
    tool_calls: [
      {
        id: "input-call",
        name: "input-tool",
        arguments: Json::object(
          Map::from_array([
            (
              "nested",
              Json::object(
                Map::from_array([("value", Json::string("clean-arguments"))]),
              ),
            ),
          ]),
        ),
      },
    ],
    tool_call_id: None,
    name: None,
    reasoning_content: None,
  }
}

///|
struct NewThreadWithMessageCompressor {}

///|
pub impl @port.Compressor for NewThreadWithMessageCompressor with fn compress(
  _self,
  _messages,
  ctx,
) {
  if ctx.session_id == "parent" {
    NewThread(
      messages=[boundary_input_message("compressed message")],
      new_session_id="child",
      messages_before=1,
      messages_after=1,
    )
  } else {
    None
  }
}

///|
async test "t05_compressor_hook_and_model_inputs_are_deep_snapshots" {
  let retained_session : @types.Session = {
    messages: [boundary_input_message("persisted")],
    metadata: Map::from_array([
      (
        "nested",
        Json::object(
          Map::from_array([("value", Json::string("clean-metadata"))]),
        ),
      ),
    ]),
  }
  let aliasing_store = BoundaryAliasingStore::{ session: retained_session }
  let recording_store = RecordingSessionStore::new()
  let compressor = BoundaryMutatingCompressor::{  }
  let hook = BoundaryMutatingHook::{  }
  let model = BoundaryMutatingModel::{ response: tk_stop_response("done") }
  let mutating_observer = BoundaryMutatingObserver::{  }
  let recording_observer = RecordingObserver::new()
  let schema = Json::object(
    Map::from_array([
      (
        "nested",
        Json::object(Map::from_array([("value", Json::string("clean-schema"))])),
      ),
    ]),
  )
  let tool_metadata = Json::object(
    Map::from_array([("value", Json::string("clean-tool-metadata"))]),
  )
  let provider = RecordingToolProvider::new(
    [
      {
        name: "boundary-tool",
        description: "snapshot probe",
        input_schema: schema,
        metadata: Some(tool_metadata),
        source: Some("boundary-test"),
      },
    ],
    Map::from_array([]),
  )
  let agent = Agent::new(
    model,
    tools=[provider],
    hooks=[hook],
    memory=[],
    compressors=[compressor],
    observers=[mutating_observer, recording_observer],
    sessions=[aliasing_store, recording_store],
    lifecycle=None,
    config=metadata_config(),
  )
  let input = boundary_input_message("hello")
  let result = agent.run_turn(input, "boundary-inputs")
  assert_eq(result.tool_results.length(), 0)
  assert_session_has_no_boundary_poison({
    messages: [result.message],
    metadata: Map::from_array([]),
  })
  assert_session_has_no_boundary_poison({
    messages: [model.response.message],
    metadata: Map::from_array([]),
  })
  assert_true(!json_has_poison(schema))
  assert_true(!json_has_poison(tool_metadata))
  assert_session_has_no_boundary_poison(aliasing_store.session)
  assert_session_has_no_boundary_poison({
    messages: [input],
    metadata: Map::from_array([]),
  })
  match recording_store.load("boundary-inputs") {
    Ok(saved) => assert_session_has_no_boundary_poison(saved)
    Err(_) => fail("expected saved boundary-inputs session")
  }
  for event in recording_observer.events() {
    match event {
      @types.TurnEvent::ModelResponseReceived(message~, ..) =>
        assert_session_has_no_boundary_poison({
          messages: [message],
          metadata: Map::from_array([]),
        })
      _ => ()
    }
  }
}

///|
async test "t05_each_final_save_store_gets_independent_deep_snapshot" {
  let mutating_store = BoundaryMutatingStore::{  }
  let recording_store = RecordingSessionStore::new()
  let model = ScriptedModel::new([Respond(tk_stop_response("done"))])
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[],
    sessions=[mutating_store, recording_store],
    lifecycle=None,
    config=metadata_config(),
  )
  let _ = agent.run_turn(boundary_input_message("hello"), "final-snapshot")
  match recording_store.load("final-snapshot") {
    Ok(saved) => assert_session_has_no_boundary_poison(saved)
    Err(_) => fail("expected second store final snapshot")
  }
}

///|
async test "t05_each_newthread_save_store_gets_independent_deep_snapshot" {
  let mutating_store = BoundaryMutatingStore::{  }
  let recording_store = RecordingSessionStore::new()
  let model = ScriptedModel::new([Respond(tk_stop_response("done"))])
  let compressor = NewThreadWithMessageCompressor::{  }
  let agent = Agent::new(
    model,
    tools=[],
    hooks=[],
    memory=[],
    compressors=[compressor],
    observers=[],
    sessions=[mutating_store, recording_store],
    lifecycle=None,
    config=metadata_config(),
  )
  let result = agent.run_turn(boundary_input_message("hello"), "parent")
  assert_eq(result.final_session_id, "child")
  match recording_store.load("child") {
    Ok(saved) => {
      assert_session_has_no_boundary_poison(saved)
      assert_true(saved.metadata.contains("parent_session_id"))
      assert_true(saved.metadata["parent_session_id"] == Json::string("parent"))
    }
    Err(_) => fail("expected second store NewThread snapshot")
  }
}

///|
struct BoundaryRecordingToolProvider {
  result : @types.ToolResult
  calls : Array[@types.ToolCall]
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
  _name,
  call,
) {
  self.calls.push(call)
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
  let provider_result : @types.ToolResult = {
    content: "clean result",
    structured: Some(provider_structured),
    is_error: false,
  }
  let model = ScriptedModel::new([
    Respond(tk_tool_call_response("probe", "tc-json", call_args)),
    Respond(tk_stop_response("done")),
  ])
  let provider = BoundaryRecordingToolProvider::{
    result: provider_result,
    calls: [],
  }
  let hook = BoundaryMutatingHook::{  }
  let mutating_observer = BoundaryMutatingObserver::{  }
  let recording_observer = RecordingObserver::new()
  let store = RecordingSessionStore::new()
  let agent = Agent::new(
    model,
    tools=[provider],
    hooks=[hook],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[mutating_observer, recording_observer],
    sessions=[store],
    lifecycle=None,
    config=metadata_config(),
  )
  let result = agent.run_turn(tk_user_msg("run probe"), "tool-boundaries")
  assert_eq(result.tool_results.length(), 1)
  assert_eq(provider.calls.length(), 1)
  assert_true(!json_has_poison(provider.calls[0].arguments))
  assert_true(!json_has_poison(call_args))
  assert_true(!json_has_poison(provider_structured))
  match result.tool_results[0].structured {
    Some(value) => assert_true(!json_has_poison(value))
    None => fail("expected structured tool result")
  }
  match store.load("tool-boundaries") {
    Ok(saved) => assert_session_has_no_boundary_poison(saved)
    Err(_) => fail("expected saved tool-boundaries session")
  }
  for event in recording_observer.events() {
    match event {
      @types.TurnEvent::ToolCallPending(call) =>
        assert_true(!json_has_poison(call.arguments))
      @types.TurnEvent::ToolCallResult(call~, result~, ..) => {
        assert_true(!json_has_poison(call.arguments))
        match result.structured {
          Some(value) => assert_true(!json_has_poison(value))
          None => fail("expected structured result event")
        }
      }
      _ => ()
    }
  }
}
