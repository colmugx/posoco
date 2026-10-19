///|
/// Agent-level guarantee for formerly-rejected schema keywords: a tool
/// declaring `oneOf` composes through the full Agent path, conforming calls
/// execute, and XOR violations die in the pre-pass as
/// `NotExecuted(SchemaMismatch)` — no execution, turn survives. This is the
/// contract extension-side schema debts (ptc run_code code/source XOR)
/// rely on.

///|
fn oneof_tool_def() -> @kernel.ToolDef {
  ToolDef(
    name=@kernel.ToolName::unchecked("write_thing"),
    description="Provide exactly one of code or source.",
    input_schema={
      "type": "object",
      "properties": {
        "code": { "type": "string" },
        "source": { "type": "string" },
      },
      "oneOf": [{ "required": ["code"] }, { "required": ["source"] }],
      "additionalProperties": false,
    },
    owner=@kernel.OwnerId::unchecked("schema_turn_test"),
    policy=Parallel,
    provenance=Some("schema-turn-test"),
  )
}

///|
fn schema_call(id : String, arguments : Json) -> @kernel.ToolCall {
  {
    call_id: @kernel.CallId::unchecked(id),
    name: @kernel.ToolName::unchecked("write_thing"),
    arguments,
  }
}

///|
async test "oneOf tool composes through Agent and executes conforming call" {
  let tc = schema_call("call_1", { "code": "fn main { }" })
  let model = ScriptedModel([
    Respond(tool_response([tc])),
    Respond(stop_response("done")),
  ])
  let tools = RecordingToolProvider(
    [oneof_tool_def()],
    Map::from_array([
      ("write_thing", OutcomeOk(Success(content="ok", structured=None))),
    ]),
  )
  let store = RecordingSessionStore()
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[tools], sessions=[store], observers=[observer]),
    ],
    config=make_config(),
  )
  let result = agent.run_turn(user_msg("write it"), "session_oneof")
  assert_eq(result.tool_results.length(), 1)
  guard result.tool_results[0] is Success(content~, ..) else {
    fail("conforming oneOf call must execute")
  }
  assert_eq(content, "ok")
}

///|
async test "oneOf XOR violations are pre-pass rejected without execution" {
  let both = schema_call("call_both", { "code": "a", "source": "b" })
  let neither = schema_call("call_neither", { "description": "nope" })
  let model = ScriptedModel([
    Respond(tool_response([both])),
    Respond(tool_response([neither])),
    Respond(stop_response("done")),
  ])
  let tools = RecordingToolProvider([oneof_tool_def()], Map::from_array([]))
  let store = RecordingSessionStore()
  let observer = RecordingObserver()
  let agent = Agent(
    exts=[
      tk_ext(id="model", model=Some(model)),
      tk_ext(id="io", tools=[tools], sessions=[store], observers=[observer]),
    ],
    config=make_config(),
  )
  let result = agent.run_turn(user_msg("write it"), "session_xor")
  assert_eq(result.tool_results.length(), 2)
  guard result.tool_results[0]
    is NotExecuted(reason=SchemaMismatch(json_path~, ..), ..) else {
    fail("both-branch call must be pre-pass rejected")
  }
  assert_eq(json_path, "$")
  guard result.tool_results[1] is NotExecuted(reason=SchemaMismatch(..), ..) else {
    fail("zero-branch call must be pre-pass rejected")
  }
  // The provider never executed anything; the turn still completed.
  assert_eq(tools.exec_records().length(), 0)
  assert_eq(result.final_session_id, "session_xor")
}
