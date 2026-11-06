///|
/// Turn terminal protocol: a turn that published `TurnStarted` projects
/// exactly one of `TurnCompleted` / `TurnFailed` / `TurnCancelled`.

///|
/// Turn terminal labels in arrival order.
fn turn_terminals(events : Array[@types.TurnEvent]) -> Array[String] {
  let labels : Array[String] = []
  for event in events {
    match event {
      TurnCompleted => labels.push("TurnCompleted")
      TurnFailed(_) => labels.push("TurnFailed")
      TurnCancelled => labels.push("TurnCancelled")
      _ => ()
    }
  }
  labels
}

///|
fn turn_starts(events : Array[@types.TurnEvent]) -> Int32 {
  let mut starts = 0
  for event in events {
    if event is TurnStarted {
      starts = starts + 1
    }
  }
  starts
}

///|
/// `operation_settled` outcomes in projection order.
fn settled_outcomes(events : Array[@types.TurnEvent]) -> Array[String] {
  let outcomes : Array[String] = []
  for event in events {
    match event {
      Custom(source~, label~, data~) if source == "posoco.operation" &&
        label == "operation_settled" =>
        match data {
          Object(fields) =>
            match fields.get("outcome") {
              Some(String(outcome)) => outcomes.push(outcome)
              _ => ()
            }
          _ => ()
        }
      _ => ()
    }
  }
  outcomes
}

///|
fn log_count(log : Array[String], wanted : String) -> Int32 {
  log.filter(fn(entry) { entry == wanted }).length()
}

///|
/// Park point: waits until the surrounding task is cancelled; callers wrap
/// themselves in a bounded timeout.
async fn cancel_park_point() -> Unit noraise {
  while !@async.is_being_cancelled() {
    @async.pause()
  }
}

///|
/// The first chat parks mid-effect until the operation is cancelled; later
/// turns answer at once, so the same Agent can prove it is reusable.
priv struct ParkedChatModel {
  entered : Ref[Bool]
  mut parks : Int32
}

///|
impl @port.ModelPort for ParkedChatModel with fn chat(
  self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  if self.parks > 0 {
    return @test_support.tk_stop_response("answered after the cancellation")
  }
  self.parks = self.parks + 1
  self.entered.val = true
  cancel_park_point()
  @test_support.tk_stop_response("never observed")
}

///|
impl @port.ModelPort for ParkedChatModel with fn compact(
  _self,
  _scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  {
    compacted_messages: messages.to_owned(),
    mode: @kernel.CompactMode::Replace,
  }
}

///|
impl @port.ModelPort for ParkedChatModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
/// Standalone compact parks mid-effect until cancelled; chat answers at once.
priv struct ParkedCompactModel {
  entered : Ref[Bool]
}

///|
impl @port.ModelPort for ParkedCompactModel with fn chat(
  _self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  @test_support.tk_stop_response("chatted")
}

///|
impl @port.ModelPort for ParkedCompactModel with fn compact(
  self,
  _scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  _tools : Array[@kernel.ToolDef],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  self.entered.val = true
  cancel_park_point()
  {
    compacted_messages: messages.to_owned(),
    mode: @kernel.CompactMode::Replace,
  }
}

///|
impl @port.ModelPort for ParkedCompactModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

///|
/// Session store that parks at a chosen persistence suspension point before
/// delegating to the recording store. `park_on` counts `save` and `checkpoint`
/// calls together: `1` is the input checkpoint, `2` the terminal append.
priv struct ParkingSessionPort {
  inner : @test_support.RecordingSessionPort
  park_on : Int32
  mut persist_calls : Int32
  entered : Ref[Bool]
}

///|
async fn ParkingSessionPort::park(self : ParkingSessionPort) -> Unit noraise {
  self.persist_calls = self.persist_calls + 1
  if self.persist_calls == self.park_on {
    self.entered.val = true
    cancel_park_point()
  }
}

///|
impl @port.SessionPort for ParkingSessionPort with fn load(self, id : String) -> @types.Session raise @error.SessionError {
  self.inner.load(id)
}

///|
impl @port.SessionPort for ParkingSessionPort with fn save(
  self,
  id : String,
  session : @types.Session,
) -> Unit raise @error.SessionError {
  self.park()
  self.inner.save(id, session)
}

///|
impl @port.SessionPort for ParkingSessionPort with fn checkpoint(
  self,
  id : String,
  checkpoint : @port.SessionCheckpoint,
) -> Unit raise @error.SessionError {
  self.park()
  self.inner.checkpoint(id, checkpoint)
}

///|
/// Shared log of observer projections and `on_turn_end` dispatches, so the
/// terminal-before-hook order is assertable.
priv struct TerminalLogHook {
  log : Array[String]
}

///|
impl @port.PipelineHook for TerminalLogHook with fn on_turn_end(self) -> Unit {
  self.log.push("hook:on_turn_end")
}

///|
priv struct TerminalLogObserver {
  log : Array[String]
}

///|
impl @port.Observer for TerminalLogObserver with fn on_event(
  self,
  _scope,
  event : @types.TurnEvent,
) -> Unit {
  self.log.push("obs:" + event.to_string())
}

///|
/// Parks inside `on_turn_begin`: the turn exists, but its chunk dispatcher has
/// not been created yet — a raw-cancellation window of its own.
priv struct ParkingTurnBeginHook {
  entered : Ref[Bool]
  log : Array[String]
}

///|
impl @port.PipelineHook for ParkingTurnBeginHook with fn on_turn_begin(self) -> Unit {
  self.log.push("hook:on_turn_begin")
  self.entered.val = true
  cancel_park_point()
}

///|
impl @port.PipelineHook for ParkingTurnBeginHook with fn on_turn_end(self) -> Unit {
  self.log.push("hook:on_turn_end")
}

///|
/// Parks inside `on_turn_end`: the turn already projected `TurnCompleted`,
/// while the operation that owns the hook is still open.
priv struct ParkingTurnEndHook {
  entered : Ref[Bool]
  log : Array[String]
}

///|
impl @port.PipelineHook for ParkingTurnEndHook with fn on_turn_end(self) -> Unit {
  self.log.push("hook:on_turn_end")
  self.entered.val = true
  cancel_park_point()
}

///|
/// Requests an abort from inside a live observer projection: the listener
/// re-enters the Agent while the turn is running, and the turn must still
/// project exactly one terminal.
priv struct AbortOnModelStartObserver {
  control : Ref[AgentControl?]
  mut aborted : Bool
}

///|
impl @port.Observer for AbortOnModelStartObserver with fn on_event(
  self,
  _scope,
  event : @types.TurnEvent,
) -> Unit {
  if event is ModelRequestStarted && !self.aborted {
    self.aborted = true
    match self.control.val {
      Some(control) =>
        ignore(control.abort_active(Some("aborted from the observer")))
      None => ()
    }
  }
}

///|
async test "turn_terminal/success_projects_exactly_one_completed" {
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_stop_response("done"),
            ),
          ]),
        ),
      ),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let result = agent.run_turn(@test_support.tk_user_msg("hello"), "tc-success")
  assert_eq(result.final_session_id, "tc-success")
  let events = observer.events()
  assert_eq(turn_starts(events), 1)
  assert_eq(turn_terminals(events), ["TurnCompleted"])
  assert_eq(settled_outcomes(events), ["completed"])
  agent.shutdown()
}

///|
async test "turn_terminal/real_failure_projects_exactly_one_failed" {
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            @test_support.ScriptedModelStep::Fail(Transport("boom")),
          ]),
        ),
      ),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let outcome = Ok(
    agent.run_turn(@test_support.tk_user_msg("hello"), "tc-failure"),
  ) catch {
    error => Err(error)
  }
  guard outcome is Err(Model(_)) else {
    fail("a model transport failure must stay a typed Model error")
  }
  let events = observer.events()
  assert_eq(turn_starts(events), 1)
  assert_eq(turn_terminals(events), ["TurnFailed"])
  assert_eq(settled_outcomes(events), ["failed"])
  agent.shutdown()
}

///|
async test "turn_terminal/soft_cancel_projects_exactly_one_cancelled" {
  let model = ParkedChatModel::{ entered: Ref(false), parks: 0, }
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let control = agent.control()
  let outcome : Ref[Result[@types.TurnResult, @error.AgentError]?] = Ref(None)
  @async.with_timeout(30_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(async fn() {
        let result : Result[@types.TurnResult, @error.AgentError] = Ok(
          agent.run_turn(@test_support.tk_user_msg("stop me"), "tc-soft"),
        ) catch {
          error => Err(error)
        }
        outcome.val = Some(result)
      })
      while !model.entered.val {
        @async.pause()
      }
      guard control.abort_active(Some("user pressed stop"))
        is @runtime.Accepted(_) else {
        fail("the host abort must be accepted while the turn is live")
      }
      ignore(turn.wait())
    })
  })
  guard outcome.val is Some(Err(@error.AgentError::Cancelled(_))) else {
    fail("a soft-cancelled turn must surface as a typed cancellation")
  }
  let events = observer.events()
  assert_eq(turn_starts(events), 1)
  assert_eq(turn_terminals(events), ["TurnCancelled"])
  assert_eq(settled_outcomes(events), ["cancelled"])
  // The guard is gone: the same Agent admits the next operation.
  ignore(agent.run_turn(@test_support.tk_user_msg("again"), "tc-soft"))
  agent.shutdown()
}

///|
async test "turn_terminal/hard_cancel_inside_body_projects_exactly_one_cancelled" {
  let model = ParkedChatModel::{ entered: Ref(false), parks: 0, }
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  @async.with_timeout(30_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(allow_failure=true, async fn() {
        ignore(
          Ok(agent.run_turn(@test_support.tk_user_msg("hold"), "tc-hard")) catch {
            error => Err(error)
          },
        )
      })
      while !model.entered.val {
        @async.pause()
      }
      turn.cancel()
      ignore(
        @async.handle_cancellation(async fn() {
          ignore(turn.wait()) catch {
            @error.AgentError::Cancelled(_)
            | @async.WaitedTaskAlreadyCancelled => ()
            error => raise error
          }
        }),
      )
    })
  })
  let events = observer.events()
  assert_eq(turn_starts(events), 1)
  assert_eq(turn_terminals(events), ["TurnCancelled"])
  assert_eq(settled_outcomes(events), ["cancelled"])
  // Reuse after a hard cancel: the same Agent admits the next turn, and the
  // cancelled turn never contaminates its terminal.
  ignore(agent.run_turn(@test_support.tk_user_msg("again"), "tc-hard"))
  assert_eq(turn_terminals(observer.events()), [
    "TurnCancelled", "TurnCompleted",
  ])
  agent.shutdown()
}

///|
async test "turn_terminal/hard_cancel_at_persistence_projects_exactly_one_cancelled" {
  let port = ParkingSessionPort::{
    inner: @test_support.RecordingSessionPort(),
    park_on: 1,
    persist_calls: 0,
    entered: Ref(false),
  }
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_stop_response("saved"),
            ),
          ]),
        ),
      ),
      @test_support.tk_ext(id="io", sessions=[port], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  @async.with_timeout(30_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(allow_failure=true, async fn() {
        ignore(
          Ok(agent.run_turn(@test_support.tk_user_msg("persist"), "tc-persist")) catch {
            error => Err(error)
          },
        )
      })
      while !port.entered.val {
        @async.pause()
      }
      turn.cancel()
      ignore(
        @async.handle_cancellation(async fn() {
          ignore(turn.wait()) catch {
            @error.AgentError::Cancelled(_)
            | @async.WaitedTaskAlreadyCancelled => ()
            error => raise error
          }
        }),
      )
    })
  })
  let events = observer.events()
  assert_eq(turn_starts(events), 1)
  assert_eq(turn_terminals(events), ["TurnCancelled"])
  assert_eq(settled_outcomes(events), ["cancelled"])
  // This raw window sits before the turn's chunk dispatcher is created (the
  // input checkpoint precedes the pump), so there is nothing to unmount.
  assert_true(agent.runtime.chunk_dispatcher.val is None)
  agent.shutdown()
}

///|
async test "turn_terminal/resume_cancel_projects_exactly_one_cancelled" {
  let model = ParkedChatModel::{ entered: Ref(false), parks: 0, }
  let store = @test_support.RecordingSessionPort()
  store.seed("tc-resume", {
    messages: [@test_support.tk_user_msg("interrupted")],
    metadata: Map::from_array([]),
  })
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  @async.with_timeout(30_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(allow_failure=true, async fn() {
        ignore(Ok(agent.resume_turn("tc-resume")) catch { error => Err(error) })
      })
      while !model.entered.val {
        @async.pause()
      }
      turn.cancel()
      ignore(
        @async.handle_cancellation(async fn() {
          ignore(turn.wait()) catch {
            @error.AgentError::Cancelled(_)
            | @async.WaitedTaskAlreadyCancelled => ()
            error => raise error
          }
        }),
      )
    })
  })
  let events = observer.events()
  assert_eq(turn_starts(events), 1)
  assert_eq(turn_terminals(events), ["TurnCancelled"])
  assert_eq(settled_outcomes(events), ["cancelled"])
  agent.shutdown()
}

///|
async test "turn_terminal/shutdown_cancel_projects_exactly_one_cancelled" {
  let model = ParkedChatModel::{ entered: Ref(false), parks: 0, }
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  @async.with_timeout(30_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(allow_failure=true, async fn() {
        ignore(
          Ok(agent.run_turn(@test_support.tk_user_msg("hold"), "tc-shutdown")) catch {
            error => Err(error)
          },
        )
      })
      while !model.entered.val {
        @async.pause()
      }
      // Shutdown waits its graceful window, then cancels the in-flight
      // operation: the turn still owes observers its one terminal.
      agent.shutdown()
      ignore(
        @async.handle_cancellation(async fn() {
          ignore(turn.wait()) catch {
            @error.AgentError::Cancelled(_)
            | @async.WaitedTaskAlreadyCancelled => ()
            error => raise error
          }
        }),
      )
    })
  })
  let events = observer.events()
  assert_eq(turn_starts(events), 1)
  assert_eq(turn_terminals(events), ["TurnCancelled"])
  assert_eq(settled_outcomes(events), ["cancelled"])
}

///|
async test "turn_terminal/compact_cancel_adds_no_turn_terminal" {
  let model = ParkedCompactModel::{ entered: Ref(false), }
  let store = @test_support.RecordingSessionPort()
  store.seed("tc-compact", {
    messages: [@test_support.tk_user_msg("seeded")],
    metadata: Map::from_array([]),
  })
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(id="io", sessions=[store], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let outcome : Ref[Result[@types.CompactOutcome, @error.AgentError]?] = Ref(
    None,
  )
  @async.with_timeout(30_000, async fn() {
    @async.with_task_group(async fn(group) {
      let compact = group.spawn(allow_failure=true, async fn() {
        let result : Result[@types.CompactOutcome, @error.AgentError] = Ok(
          agent.compact_session("tc-compact"),
        ) catch {
          error => Err(error)
        }
        outcome.val = Some(result)
      })
      while !model.entered.val {
        @async.pause()
      }
      compact.cancel()
      ignore(
        @async.handle_cancellation(async fn() {
          ignore(compact.wait()) catch {
            @error.AgentError::Cancelled(_)
            | @async.WaitedTaskAlreadyCancelled => ()
            error => raise error
          }
        }),
      )
    })
  })
  guard outcome.val is Some(Err(@error.AgentError::Cancelled(_))) else {
    fail("a cancelled compact must surface as a typed cancellation")
  }
  let events = observer.events()
  // A compact is an operation, not a turn: no TurnStarted, no turn terminal.
  assert_eq(turn_starts(events), 0)
  assert_eq(turn_terminals(events), [])
  assert_eq(settled_outcomes(events), ["cancelled"])
  agent.shutdown()
}

///|
async test "turn_terminal/abort_from_observer_projection_projects_one_cancelled" {
  let model = ParkedChatModel::{ entered: Ref(false), parks: 0, }
  let log : Array[String] = []
  let observer = TerminalLogObserver::{ log, }
  let hook = TerminalLogHook::{ log, }
  let control_ref : Ref[AgentControl?] = Ref(None)
  let aborting = AbortOnModelStartObserver::{
    control: control_ref,
    aborted: false,
  }
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer as &@port.Observer, aborting as &@port.Observer],
        hooks=[hook as &@port.PipelineHook],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  control_ref.val = Some(agent.control())
  let outcome = Ok(
    agent.run_turn(@test_support.tk_user_msg("hello"), "tc-reentrant"),
  ) catch {
    error => Err(error)
  }
  guard outcome is Err(@error.AgentError::Cancelled(_)) else {
    fail("a cancellation requested from a live projection must land")
  }
  // Exactly one terminal, projected before the async turn-end hook runs.
  assert_eq(log_count(log, "obs:TurnCancelled"), 1)
  assert_eq(log_count(log, "obs:TurnFailed"), 0)
  assert_eq(log_count(log, "obs:TurnCompleted"), 0)
  assert_eq(log_count(log, "hook:on_turn_end"), 1)
  // The hook must be dispatched right after the terminal entry.
  let terminal_index = log.search_by(fn(entry) { entry == "obs:TurnCancelled" })
  guard terminal_index is Some(index) else {
    fail("the cancelled terminal must be logged")
  }
  assert_eq(log[index + 1], "hook:on_turn_end")
  agent.shutdown()
}

///|
async test "turn_terminal/raw_cancel_projects_the_terminal_but_skips_the_hook" {
  // A cancellation outside every `catch` is the boundary `on_turn_end` cannot
  // promise: no dispatch on a raw unwind; the observer still gets the terminal.
  let port = ParkingSessionPort::{
    inner: @test_support.RecordingSessionPort(),
    park_on: 1,
    persist_calls: 0,
    entered: Ref(false),
  }
  let log : Array[String] = []
  let observer = TerminalLogObserver::{ log, }
  let hook = TerminalLogHook::{ log, }
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_stop_response("saved"),
            ),
          ]),
        ),
      ),
      @test_support.tk_ext(
        id="io",
        sessions=[port],
        observers=[observer as &@port.Observer],
        hooks=[hook as &@port.PipelineHook],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  @async.with_timeout(30_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(allow_failure=true, async fn() {
        ignore(
          Ok(agent.run_turn(@test_support.tk_user_msg("persist"), "tc-raw")) catch {
            error => Err(error)
          },
        )
      })
      while !port.entered.val {
        @async.pause()
      }
      turn.cancel()
      ignore(
        @async.handle_cancellation(async fn() {
          ignore(turn.wait()) catch {
            @error.AgentError::Cancelled(_)
            | @async.WaitedTaskAlreadyCancelled => ()
            error => raise error
          }
        }),
      )
    })
  })
  assert_eq(log_count(log, "obs:TurnCancelled"), 1)
  assert_eq(log_count(log, "obs:TurnFailed"), 0)
  assert_eq(log_count(log, "hook:on_turn_end"), 0)
  agent.shutdown()
}

///|
async test "turn_terminal/a_failing_tool_is_not_a_cancellation" {
  // Tool failures are non-fatal: only cancellation produces `TurnCancelled`.
  let observer = @test_support.RecordingObserver()
  let tools = @test_support.RecordingToolProvider(
    [@test_support.tk_tool_def("boom", "failing tool")],
    Map::from_array([
      (
        "boom",
        @test_support.ScriptedToolOutcome::OutcomeErr(UnknownTool("boom")),
      ),
    ]),
  )
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_tool_call_response(
                "boom",
                "call_boom",
                Json::object(Map::from_array([])),
              ),
            ),
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_stop_response("recovered"),
            ),
          ]),
        ),
      ),
      @test_support.tk_ext(id="tools", tools=[tools], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  let result = agent.run_turn(@test_support.tk_user_msg("go"), "tc-tool-fail")
  guard result.message is @kernel.Message::AssistantMessage(..) else {
    fail("the turn must complete after a non-fatal tool failure")
  }
  let events = observer.events()
  assert_eq(turn_starts(events), 1)
  assert_eq(turn_terminals(events), ["TurnCompleted"])
  assert_eq(settled_outcomes(events), ["completed"])
  agent.shutdown()
}

///|
async test "turn_terminal/hard_cancel_flushes_tail_chunks_and_unmounts_the_dispatcher" {
  // A raw cancellation at the terminal persistence point still owes the tail
  // chunks to observers before the turn terminal.
  let chunks : Array[@types.StreamChunk] = []
  for i in 0..<5 {
    chunks.push(@types.TextDelta(token="t\{i}"))
  }
  let port = ParkingSessionPort::{
    inner: @test_support.RecordingSessionPort(),
    park_on: 2,
    persist_calls: 0,
    entered: Ref(false),
  }
  let observer = @test_support.RecordingObserver()
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            @test_support.ScriptedModelStep::Stream(
              chunks~,
              response=@test_support.tk_stop_response("streamed"),
            ),
          ]),
        ),
      ),
      @test_support.tk_ext(id="io", sessions=[port], observers=[observer]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  @async.with_timeout(30_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(allow_failure=true, async fn() {
        ignore(
          Ok(agent.run_turn(@test_support.tk_user_msg("stream"), "tc-tail")) catch {
            error => Err(error)
          },
        )
      })
      while !port.entered.val {
        @async.pause()
      }
      // The turn owns a live dispatcher at this suspension point.
      assert_true(agent.runtime.chunk_dispatcher.val is Some(_))
      turn.cancel()
      ignore(
        @async.handle_cancellation(async fn() {
          ignore(turn.wait()) catch {
            @error.AgentError::Cancelled(_)
            | @async.WaitedTaskAlreadyCancelled => ()
            error => raise error
          }
        }),
      )
    })
  })
  let events = observer.events()
  assert_eq(turn_terminals(events), ["TurnCancelled"])
  let terminal_index = events.search_by(fn(event) { event is TurnCancelled })
  guard terminal_index is Some(index) else { fail("TurnCancelled not found") }
  let chunk_events = events.filter(fn(event) { event is StreamChunkReceived(_) })
  assert_eq(chunk_events.length(), 5)
  for i, event in events {
    if i >= index && event is StreamChunkReceived(_) {
      fail("chunk observed at or after the turn terminal")
    }
  }
  // Only the installing turn unmounts its dispatcher.
  assert_true(agent.runtime.chunk_dispatcher.val is None)
  agent.shutdown()
}

///|
async test "turn_terminal/raw_cancel_inside_turn_begin_still_projects_the_terminal" {
  // Cancellation while the async `on_turn_begin` hook is running: no
  // dispatcher exists yet, so the fallback projects the terminal.
  let model = ParkedChatModel::{ entered: Ref(false), parks: 0, }
  let log : Array[String] = []
  let observer = TerminalLogObserver::{ log, }
  let recorder = @test_support.RecordingObserver()
  let hook = ParkingTurnBeginHook::{ entered: Ref(false), log, }
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer as &@port.Observer, recorder],
        hooks=[hook as &@port.PipelineHook],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  @async.with_timeout(30_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(allow_failure=true, async fn() {
        ignore(
          Ok(agent.run_turn(@test_support.tk_user_msg("hold"), "tc-begin")) catch {
            error => Err(error)
          },
        )
      })
      while !hook.entered.val {
        @async.pause()
      }
      turn.cancel()
      ignore(
        @async.handle_cancellation(async fn() {
          ignore(turn.wait()) catch {
            @error.AgentError::Cancelled(_)
            | @async.WaitedTaskAlreadyCancelled => ()
            error => raise error
          }
        }),
      )
    })
  })
  assert_eq(log_count(log, "hook:on_turn_begin"), 1)
  assert_eq(log_count(log, "obs:TurnCancelled"), 1)
  assert_eq(log_count(log, "obs:TurnFailed"), 0)
  // Raw unwind: the async turn-end hook is not dispatched.
  assert_eq(log_count(log, "hook:on_turn_end"), 0)
  assert_true(agent.runtime.chunk_dispatcher.val is None)
  assert_eq(settled_outcomes(recorder.events()), ["cancelled"])
  agent.shutdown()
}

///|
async test "turn_terminal/hard_cancel_after_turn_completed_keeps_one_terminal" {
  // The turn keeps its single `TurnCompleted`; the operation settles
  // cancelled.
  let log : Array[String] = []
  let observer = TerminalLogObserver::{ log, }
  let recorder = @test_support.RecordingObserver()
  let hook = ParkingTurnEndHook::{ entered: Ref(false), log, }
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(
        id="model",
        model=Some(
          @test_support.ScriptedModel([
            @test_support.ScriptedModelStep::Respond(
              @test_support.tk_stop_response("done"),
            ),
          ]),
        ),
      ),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer as &@port.Observer, recorder],
        hooks=[hook as &@port.PipelineHook],
      ),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  @async.with_timeout(30_000, async fn() {
    @async.with_task_group(async fn(group) {
      let turn = group.spawn(allow_failure=true, async fn() {
        ignore(
          Ok(agent.run_turn(@test_support.tk_user_msg("hello"), "tc-end")) catch {
            error => Err(error)
          },
        )
      })
      while !hook.entered.val {
        @async.pause()
      }
      turn.cancel()
      ignore(
        @async.handle_cancellation(async fn() {
          ignore(turn.wait()) catch {
            @error.AgentError::Cancelled(_)
            | @async.WaitedTaskAlreadyCancelled => ()
            error => raise error
          }
        }),
      )
    })
  })
  assert_eq(log_count(log, "obs:TurnCompleted"), 1)
  assert_eq(log_count(log, "obs:TurnCancelled"), 0)
  assert_eq(log_count(log, "obs:TurnFailed"), 0)
  let terminal_index = log.search_by(fn(entry) { entry == "obs:TurnCompleted" })
  guard terminal_index is Some(index) else { fail("turn terminal not found") }
  assert_eq(log[index + 1], "hook:on_turn_end")
  // The operation is the outer boundary: it settles cancelled without
  // rewriting the turn's result.
  assert_eq(settled_outcomes(recorder.events()), ["cancelled"])
  agent.shutdown()
}
