///|
async test "tool_recovery/resume_interrupts_the_old_call_and_uses_only_the_new_binding" {
  let store = @testkit.RecordingSessionPort()
  let old = @testkit.tk_tool_call_response("leaf", "old-call", Json::null()).completion.message
  store.seed("resumed", {
    messages: [
      @testkit.tk_user_msg("old request"),
      AssistantMessage(
        content=old.content,
        tool_calls=old.tool_calls,
        reasoning=old.reasoning,
        finish_reason=old.finish_reason,
      ),
    ],
    metadata: Map([]),
  })
  let provider = @testkit.RecordingToolProvider(
    [@testkit.tk_tool_def("leaf", "current binding")],
    Map([
      (
        "leaf",
        @testkit.ScriptedToolOutcome::OutcomeOk(
          @testkit.tk_ok_result("new result"),
        ),
      ),
    ]),
  )
  let publisher = ManualPublisher::new()
  let model = @testkit.ScriptedModel([
    @testkit.ScriptedModelStep::Respond(
      @testkit.tk_tool_call_response("leaf", "new-call", Json::null()),
    ),
    @testkit.ScriptedModelStep::Respond(@testkit.tk_stop_response("done")),
  ])
  let agent = Agent(
    exts=[
      @testkit.tk_ext(id="model", model=Some(model), sessions=[store]),
      @testkit.tk_ext(id="current-owner", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  ignore(publisher.capability().replace(provider~))
  let result = agent.resume_turn("resumed")
  assert_eq(contribution_result_texts(result.tool_results), ["new result"])
  assert_eq(provider.exec_records().length(), 1)
  assert_eq(provider.exec_records()[0].call_id.to_string(), "new-call")
  assert_true(
    model.received_messages[0].any(message => {
      message
      is ToolMessage(
        call_id~,
        outcome=RuntimeFailure(error_category="Interrupted", ..),
        ..
      ) &&
      call_id.to_string() == "old-call"
    }),
  )
  assert_eq(model.received_tools[0][0].owner.to_string(), "current-owner")
  let persisted = store.load("resumed")
  assert_eq(
    persisted.messages.filter(message => message is ToolMessage(..)).length(),
    2,
  )
  agent.shutdown()
}
