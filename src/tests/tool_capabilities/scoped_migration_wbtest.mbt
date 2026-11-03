///|
async test "tool_invoke/migrated_scoped_calls_preserve_permission_and_schema_rejections" {
  let replies : Array[@kernel.InvocationResult] = []
  let child = @test_support.RecordingToolProvider(
    [
      {
        ..@test_support.tk_tool_def("inspect", "Inspect"),
        exposure: Deferred,
        input_schema: {
          "type": "object",
          "properties": { "path": { "type": "string" } },
          "required": ["path"],
        },
      },
    ],
    Map([]),
  )
  let parent = InvocationFixture::{
    id: "parent",
    definitions: [
      { ..@test_support.tk_tool_def("parent", "parent"), policy: Exclusive, },
    ],
    owners: ["child"],
    action: async fn(ctx) {
      replies.push(ctx.invoke("inspect", { "path": "a" }))
      replies.push(ctx.invoke("inspect", { "path": 42 }))
      @test_support.tk_ok_result("done")
    },
  }
  let hook = InvocationHook::{
    decide: call => {
      if call.name.to_string() == "inspect" {
        Reject(reason="permission denied")
      } else {
        Approve(call~)
      }
    },
  }
  let agent = Agent(
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_tool_call_response("parent", "p", Json::null()),
            ),
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_stop_response("done"),
            ),
          ]),
        ),
        hooks=[hook],
      ),
      parent,
      @test_support.tk_ext(id="child", tools=[child]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  ignore(agent.run_turn(@test_support.tk_user_msg("hello"), "scoped-migration"))
  guard replies
    is [
      Completed(NotExecuted(reason=RejectedByHook(..), ..)),
      Completed(NotExecuted(reason=SchemaMismatch(..), ..)),
    ] else {
    fail("scoped permission/schema checks were lost during migration")
  }
  assert_eq(child.exec_records().length(), 0)
  agent.shutdown()
}

///|
async test "tool_invoke/program_names_use_owner_admission_instead_of_a_run_code_special_case" {
  let replies : Array[@kernel.InvocationResult] = []
  let child = @test_support.RecordingToolProvider(
    [
      {
        ..@test_support.tk_tool_def("run_code", "program"),
        exposure: Deferred,
      },
    ],
    Map([
      (
        "run_code",
        @test_support.ScriptedToolOutcome::OutcomeOk(
          @test_support.tk_ok_result("program result"),
        ),
      ),
    ]),
  )
  let parent = InvocationFixture::{
    id: "parent",
    definitions: [
      { ..@test_support.tk_tool_def("parent", "parent"), policy: Exclusive, },
    ],
    owners: [],
    action: async fn(ctx) {
      replies.push(ctx.invoke("run_code", Json::null()))
      @test_support.tk_ok_result("done")
    },
  }
  let agent = Agent(
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_tool_call_response("parent", "p", Json::null()),
            ),
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_stop_response("done"),
            ),
          ]),
        ),
      ),
      parent,
      @test_support.tk_ext(id="child", tools=[child]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  ignore(
    agent.run_turn(@test_support.tk_user_msg("hello"), "program-admission"),
  )
  guard replies is [Completed(NotExecuted(reason=OwnerNotAllowed, ..))] else {
    fail("program invocation must use the same owner admission as every tool")
  }
  assert_eq(child.exec_records().length(), 0)
  agent.shutdown()
}
