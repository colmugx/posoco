///|
priv struct EventSystem {
  runtime : @event_runtime.EventRuntime
}

///|
fn EventSystem::EventSystem() -> EventSystem {
  { runtime: @event_runtime.EventRuntime(), }
}

///|
priv struct Agent {
  runtime : AgentRuntime
}

///|
fn agent_config(
  max_tool_rounds~ : Int32? = None,
  max_tool_calls~ : Int32? = None,
  max_tool_depth~ : Int32? = None,
  temperature~ : Double? = None,
  max_output_tokens~ : Int32? = None,
  model_context_window~ : Int32? = None,
  compact_threshold~ : Double? = None,
  system_prompt~ : String? = None,
  memory_inbound_timeout_ms~ : Int32? = None,
) -> RuntimeConfig {
  {
    max_tool_rounds,
    max_tool_calls,
    max_tool_depth,
    temperature,
    max_output_tokens,
    model_context_window,
    compact_threshold,
    system_prompt,
    memory_inbound_timeout_ms,
  }
}

///|
fn Agent::Agent(
  exts~ : Array[&@port.Extension],
  config~ : RuntimeConfig,
  events~ : EventSystem,
  ui_projection~ : Bool = false,
) -> Agent raise @error.CompositionError {
  {
    runtime: AgentRuntime::compose(
      exts~,
      config~,
      events=events.runtime,
      ui_projection~,
    ),
  }
}

///|
async fn[X] Agent::run_scoped(self : Agent, body : async (Agent) -> X) -> X {
  self.runtime.run_scoped_with(async fn() { body(self) })
}

///|
async fn Agent::run_turn(
  self : Agent,
  input : @kernel.Message,
  session_id : String,
) -> @types.TurnResult raise @error.AgentError {
  self.runtime.run_turn(input, session_id)
}

///|
async fn Agent::compact_session(
  self : Agent,
  session_id : String,
) -> @types.CompactOutcome raise @error.AgentError {
  self.runtime.compact_session(session_id)
}

///|
fn Agent::commands(self : Agent) -> Array[&@port.CommandPort] {
  self.runtime.commands()
}

///|
priv struct TaskCapture {
  mut tasks : @port.Tasks?
}

///|
fn TaskCapture::new() -> TaskCapture {
  { tasks: None, }
}

///|
impl @port.Lifecycle for TaskCapture with fn on_compose(
  self : TaskCapture,
  view : @port.CompositionView,
) {
  self.tasks = view.tasks()
}

///|
impl @port.Lifecycle for TaskCapture with fn on_shutdown(_self : TaskCapture) {
  ()
}

///|
fn task_test_spec(session_id : String, label : String) -> @port.TaskSpec {
  {
    session_id,
    mode: Background,
    label,
    timeout_ms: None,
    run: fn() {
      AssistantMessage(
        content=[Text("worker result")],
        tool_calls=[],
        reasoning=None,
        finish_reason=Stop,
      )
    },
  }
}

///|
fn task_test_submit(
  capture : TaskCapture,
  session_id : String,
  label : String,
) -> @port.TaskHandle {
  let tasks = match capture.tasks {
    Some(value) => value
    None => abort("task capability was not composed")
  }
  match tasks.submit(task_test_spec(session_id, label)) {
    Ok(handle) => handle
    Err(_) => abort("task submit failed")
  }
}

///|
fn task_test_has_marker(session : @types.Session, marker : String) -> Bool {
  session.messages
  .iter()
  .any(fn(message) {
    match message {
      UserMessage(content~) =>
        content
        .iter()
        .any(fn(content) { content is Text(text) && text.contains(marker) })
      _ => false
    }
  })
}
