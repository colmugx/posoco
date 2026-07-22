///|
/// Whitebox tests for M2-T07 Agent ↔ Harness compatibility facade.
///
/// Coverage:
/// - run_turn_via_harness with a no-tool ScriptedModel returns a TurnResult
/// - session is persisted (RecordingSessionStore captured the save)
/// - run_turn_via_harness reuses Agent's existing tool providers
/// - CatalogComposition surfaces when tools collide

// ──────────────────────────────────────────────────────────────────────────
// Fixtures — reuse testkit mocks
// ──────────────────────────────────────────────────────────────────────────

///|
/// Build a minimal Agent wired with a ScriptedModel + empty tools.
fn compat_agent_no_tools(
  responses : Array[@types.ModelResponse],
) -> Agent raise @error.CompositionError {
  let model = ScriptedModel::new(responses.map(fn(r) { Respond(r) }))
  let tools = MockToolProvider::{ tools: [], results: Map::from_array([]) }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = AgentConfig::{
    max_tool_rounds: 5,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: None,
    model_context_window: None,
  }
  Agent::new(
    model,
    tools=[tools],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
}

///|
fn compat_stop_response(text : String) -> @types.ModelResponse {
  {
    message: {
      role: @types.Assistant,
      content: [@types.Text(text)],
      tool_calls: [],
      tool_call_id: None,
      name: None,
      reasoning_content: None,
    },
    finish_reason: @types.Stop,
    tool_calls: [],
    usage: None,
    reasoning_content: None,
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Happy path
// ──────────────────────────────────────────────────────────────────────────

///|
async test "agent_compat/run_turn_via_harness_no_tools" {
  let agent = compat_agent_no_tools([compat_stop_response("hello back")])
  let result = agent.run_turn_via_harness(
    {
      role: @types.User,
      content: [@types.Text("hi")],
      tool_calls: [],
      tool_call_id: None,
      name: None,
      reasoning_content: None,
    },
    "sess_compat_1",
  )
  // Result is a TurnResult.
  assert_true(result.final_session_id == "sess_compat_1")
}

// ──────────────────────────────────────────────────────────────────────────
// Session persistence
// ──────────────────────────────────────────────────────────────────────────

///|
async test "agent_compat/persists_session" {
  let model = ScriptedModel::new([Respond(compat_stop_response("ok"))])
  let tools = MockToolProvider::{ tools: [], results: Map::from_array([]) }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = AgentConfig::{
    max_tool_rounds: 5,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: None,
    model_context_window: None,
  }
  let agent = Agent::new(
    model,
    tools=[tools],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let _ = agent.run_turn_via_harness(
    {
      role: @types.User,
      content: [@types.Text("hello")],
      tool_calls: [],
      tool_call_id: None,
      name: None,
      reasoning_content: None,
    },
    "sess_persist",
  )
  // The RecordingSessionStore (MockSessionStore) recorded a save for this id.
  let saved = store.store.get("sess_persist")
  assert_true(saved is Some(_))
}

///|
async test "agent_compat/persists_complete_tool_transcript" {
  let model = ScriptedModel::new([
    Respond(tk_tool_call_response("greet", "call_1", Json::null())),
    Respond(compat_stop_response("done")),
  ])
  let tools = MockToolProvider::{
    tools: [tk_tool_def("greet", "say hello")],
    results: Map::from_array([("greet", Ok(tk_ok_result("hi from tool")))]),
  }
  let store = MockSessionStore::{ store: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let agent = Agent::new(
    model,
    tools=[tools],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config=AgentConfig::{
      max_tool_rounds: 5,
      temperature: None,
      max_output_tokens: None,
      tool_choice: None,
      reasoning_effort: None,
      model_context_window: None,
    },
  )
  let result = agent.run_turn_via_harness(
    {
      role: @types.User,
      content: [@types.Text("hello")],
      tool_calls: [],
      tool_call_id: None,
      name: None,
      reasoning_content: None,
    },
    "sess_tool_transcript",
  )
  assert_eq(result.tool_results.length(), 1)
  assert_eq(result.tool_results[0].content, "hi from tool")
  let saved = match store.store.get("sess_tool_transcript") {
    Some(session) => session
    None => fail("complete transcript was not saved")
  }
  assert_eq(saved.messages.length(), 4)
  match saved.messages[1] {
    { role: @types.Assistant, tool_calls, .. } =>
      assert_eq(tool_calls.length(), 1)
    _ => fail("saved transcript lost assistant tool call")
  }
  match saved.messages[2] {
    {
      role: @types.Tool,
      tool_call_id: Some(call_id),
      name: Some(name),
      content,
      ..,
    } => {
      assert_eq(call_id, "call_1")
      assert_eq(name, "greet")
      match content[0] {
        @types.Text(text) => assert_eq(text, "hi from tool")
        _ => fail("saved tool message did not preserve text")
      }
    }
    _ => fail("saved transcript lost correlated tool message")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Session load failure surfaces as SessionLoad
// ──────────────────────────────────────────────────────────────────────────

///|
async test "agent_compat/session_load_failure_surfaces" {
  let model = ScriptedModel::new([Respond(compat_stop_response("ok"))])
  let tools = MockToolProvider::{ tools: [], results: Map::from_array([]) }
  // RecordingSessionStore with a forced load failure.
  let store = RecordingSessionStore::new()
  store.fail_load("sess_bad", @error.SessionError::Load("injected"))
  let observer = RecordingObserver::new()
  let config = AgentConfig::{
    max_tool_rounds: 5,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: None,
    model_context_window: None,
  }
  let agent = Agent::new(
    model,
    tools=[tools],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[store],
    lifecycle=None,
    config~,
  )
  let result : Result[@types.TurnResult, HarnessFacadeError] = Ok(
    agent.run_turn_via_harness(
      {
        role: @types.User,
        content: [@types.Text("hi")],
        tool_calls: [],
        tool_call_id: None,
        name: None,
        reasoning_content: None,
      },
      "sess_bad",
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(SessionLoad(detail~)) => assert_true(detail.contains("load"))
    _ => assert_true(false)
  }
}

// ──────────────────────────────────────────────────────────────────────────
// No session store configured
// ──────────────────────────────────────────────────────────────────────────

///|
async test "agent_compat/no_session_store_rejected" {
  let model = ScriptedModel::new([Respond(compat_stop_response("ok"))])
  let tools = MockToolProvider::{ tools: [], results: Map::from_array([]) }
  let observer = MockObserver::{ events: [] }
  let config = AgentConfig::{
    max_tool_rounds: 5,
    temperature: None,
    max_output_tokens: None,
    tool_choice: None,
    reasoning_effort: None,
    model_context_window: None,
  }
  // Pass an empty sessions array.
  let agent = Agent::new(
    model,
    tools=[tools],
    hooks=[],
    memory=[],
    compressors=[NoopCompressor::{  }],
    observers=[observer],
    sessions=[],
    lifecycle=None,
    config~,
  )
  let result : Result[@types.TurnResult, HarnessFacadeError] = Ok(
    agent.run_turn_via_harness(
      {
        role: @types.User,
        content: [@types.Text("hi")],
        tool_calls: [],
        tool_call_id: None,
        name: None,
        reasoning_content: None,
      },
      "sess_x",
    ),
  ) catch {
    e => Err(e)
  }
  assert_true(result is Err(_))
  match result {
    Err(SessionLoad(detail~)) =>
      assert_true(detail.contains("no session store"))
    _ => assert_true(false)
  }
}
