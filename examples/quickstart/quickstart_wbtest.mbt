///|
/// The fixed model must preserve the input transcript when it does not
/// preprocess messages. This catches regressions where an empty
/// `processed_messages` array drops the user message at the persistence
/// boundary.
async test "quickstart_persists_user_and_assistant_history" {
  let extension = QuickstartExtension()
  let agent = @posoco.Agent(exts=[extension], config={
    max_tool_rounds: Some(0),
    temperature: None,
    max_output_tokens: None,
    model_context_window: None,
    compact_threshold: None,
  })
  let input : @posoco.Message = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("Say hello"),
  ])
  let result = agent.run_turn(input, "quickstart-test-session")
  match result.message {
    @posoco.Message::AssistantMessage(content~, ..) =>
      assert_eq(content, [
        @posoco.Content::Text("Hello from the Posoco quickstart."),
      ])
    _ => fail("expected AssistantMessage")
  }
  let saved = @port.SessionStore::load(
    extension.sessions,
    "quickstart-test-session",
  )
  assert_eq(saved.messages.length(), 2)
  assert_true(saved.messages[0] is @posoco.Message::UserMessage(..))
  assert_true(saved.messages[1] is @posoco.Message::AssistantMessage(..))
  agent.shutdown()
}
