///|
async test "tool_catalog/events_distinguish_commits_captures_and_cleanup_without_error_payloads" {
  let publisher = ManualPublisher::new()
  let observer = @test_support.RecordingObserver()
  let provider = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("leaf", "leaf")],
    Map([]),
  )
  let probe = RetireProbe::RetireProbe(
    failures_left=1,
    detail="private-connection-detail",
  )
  let agent = Agent(
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_stop_response("one"),
            ),
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_stop_response("two"),
            ),
          ]),
        ),
        observers=[observer],
      ),
      @test_support.tk_ext(id="owner", lifecycle=[publisher], requires=[
        @port.ToolContribution,
      ]),
    ],
    config=@agent.agent_config(max_tool_rounds=Some(10)),
  )
  ignore(publisher.capability().replace(provider~, retire=probe.callback()))
  ignore(agent.run_turn(@test_support.tk_user_msg("one"), "catalog-events"))
  ignore(agent.run_turn(@test_support.tk_user_msg("two"), "catalog-events"))
  guard publisher.capability().withdraw() is Err(@port.CleanupPending(..)) else {
    fail("expected cleanup failure")
  }
  guard publisher.capability().withdraw() is Ok(_) else {
    fail("cleanup retry failed")
  }
  let facts : Array[@types.ToolCatalogChangedPayload] = []
  for event in observer.events() {
    if event is ToolCatalogChanged(payload~) {
      facts.push(payload)
    }
  }
  assert_eq(facts.map(p => p.change), [
    @types.Published,
    @types.Captured,
    @types.Withdrawn,
    @types.CleanupFailed,
  ])
  assert_eq(facts[0].owner, "owner")
  assert_eq(facts[0].revision, Some(1))
  assert_eq(facts[0].catalog_version, None)
  assert_true(facts[1].catalog_version is Some(_))
  assert_true(facts[1].operation_id is Some(_))
  assert_eq(facts[2].revision, Some(2))
  assert_eq(facts[3].detail, Some("retire failed"))
  agent.shutdown()
}
