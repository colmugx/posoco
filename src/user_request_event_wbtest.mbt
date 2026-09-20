// UserRequestStarted / UserRequestFinished — the core wrapper around the
// aggregated UiPort broadcasts these around every interactive request that
// resolves the composed port from a CompositionView.

///|
/// Tool provider that asks through the composed UI captured at composition.
priv struct UiAskingTool {
  mut ui : &@port.UiPort?
}

///|
fn UiAskingTool::UiAskingTool() -> UiAskingTool {
  { ui: None, }
}

///|
impl @port.ToolProvider for UiAskingTool with fn list_tools(
  _self : UiAskingTool,
) -> Array[@kernel.ToolDef] {
  [tk_tool_def("ask_ui", "asks the composed ui for a confirm")]
}

///|
impl @port.ToolProvider for UiAskingTool with fn execute(
  self : UiAskingTool,
  _name : String,
  _call : @kernel.ToolCall,
) -> @kernel.ToolOutcome raise @error.RuntimeError {
  let ui = match self.ui {
    Some(ui) => ui
    None =>
      return @kernel.ToolOutcome::ToolReportedError(
        content="no composed ui",
        structured=None,
      )
  }
  let result : Result[@port.UiResponse, @error.UiError] = Ok(
    ui.request(@port.UiRequest::Confirm(prompt="allow?")),
  ) catch {
    e => Err(e)
  }
  match result {
    Ok(response) =>
      @kernel.ToolOutcome::Success(
        content="reply=\{Show::to_string(response)}",
        structured=None,
      )
    Err(Unsupported(detail~)) =>
      @kernel.ToolOutcome::ToolReportedError(
        content="unsupported: \{detail}",
        structured=None,
      )
    Err(_) =>
      @kernel.ToolOutcome::ToolReportedError(
        content="ui request failed",
        structured=None,
      )
  }
}

///|
impl @port.Lifecycle for UiAskingTool with fn on_compose(
  self : UiAskingTool,
  ctx : @port.CompositionView,
) -> Unit raise @error.CompositionError {
  self.ui = ctx.ui()
}

///|
impl @port.Lifecycle for UiAskingTool with fn on_shutdown(_self : UiAskingTool) -> Unit {
  ()
}

///|
fn user_request_event_labels(events : Array[@types.TurnEvent]) -> Array[String] {
  let labels : Array[String] = []
  for event in events {
    match event {
      UserRequestStarted(kind~, prompt~) =>
        labels.push("started(\{kind}, \{prompt})")
      UserRequestFinished(kind~, outcome~) =>
        labels.push("finished(\{kind}, \{outcome})")
      _ => ()
    }
  }
  labels
}

///|
fn build_uireq_agent(
  tool : UiAskingTool,
  observer : RecordingObserver,
  ui? : Array[&@port.UiPort] = [],
  requires? : Array[@port.Capability] = [],
) -> Agent raise @error.CompositionError {
  Agent(
    exts=[
      tk_ext(
        id="model",
        model=Some(
          ScriptedModel([
            Respond(tk_tool_call_response("ask_ui", "call_1", Json::null())),
            Respond(tk_stop_response("done")),
          ]),
        ),
      ),
      tk_ext(
        id="uiask",
        tools=[tool],
        lifecycle=[tool],
        requires~,
        ui~,
        sessions=[RecordingSessionStore()],
        observers=[observer],
      ),
    ],
    config=tk_config(),
  )
}

///|
async test "composed ui request emits started/finished around the answer" {
  let tool = UiAskingTool::UiAskingTool()
  let observer = RecordingObserver()
  let agent = build_uireq_agent(
    tool,
    observer,
    ui=[RecordingUiPort(responses=[@port.UiResponse::Yes])],
    requires=[@port.Capability::Ui],
  )
  let result = agent.run_turn(tk_user_msg("hi"), "session_uireq")
  assert_eq(result.final_session_id, "session_uireq")
  inspect(
    user_request_event_labels(observer.events()).join(" -> "),
    content="started(confirm, allow?) -> finished(confirm, answered)",
  )
}

///|
async test "all-unsupported contributors still close the request as unsupported" {
  let tool = UiAskingTool::UiAskingTool()
  let observer = RecordingObserver()
  let agent = build_uireq_agent(
    tool,
    observer,
    ui=[RecordingUiPort::new_unsupported()],
    requires=[@port.Capability::Ui],
  )
  let _ = agent.run_turn(tk_user_msg("hi"), "session_uireq_unsupported")
  inspect(
    user_request_event_labels(observer.events()).join(" -> "),
    content="started(confirm, allow?) -> finished(confirm, unsupported)",
  )
}

///|
async test "ui-less composition emits no user request events" {
  let tool = UiAskingTool::UiAskingTool()
  let observer = RecordingObserver()
  // No `ui` contributors: the aggregated port is the unwrapped NoopUiPort,
  // so the attempted request produces no events by design (a UI-less agent
  // never waits for a user).
  let agent = build_uireq_agent(tool, observer)
  let _ = agent.run_turn(tk_user_msg("hi"), "session_uireq_noui")
  inspect(user_request_event_labels(observer.events()).join(" -> "), content="")
}
