///|
/// Steer consumption at the pump's step boundary
/// (docs/message-delivery-boundaries.md §5.2 / §5.6.2).

///|
/// Host that parks its single tool call on a release gate and records every
/// model request. The gate makes "the steer arrives while the tool wave is in
/// flight" deterministic instead of a sleep race.
struct SteerProbeHost {
  model_results : Array[Result[@kernel.Completion, ModelFailure]]
  mut model_index : Int32
  messages_at_model_call : Array[Array[Message]]
  tool_started : @aqueue.Queue[String]
  tool_gate : @aqueue.Queue[Unit]
}

///|
fn SteerProbeHost::SteerProbeHost(
  model_results : Array[Result[@kernel.Completion, ModelFailure]],
) -> SteerProbeHost {
  {
    model_results: model_results.copy(),
    model_index: 0,
    messages_at_model_call: [],
    tool_started: Queue(kind=Unbounded),
    tool_gate: Queue(kind=Unbounded),
  }
}

///|
fn SteerProbeHost::messages_at(
  self : SteerProbeHost,
  index : Int32,
) -> Array[Message] {
  self.messages_at_model_call[index]
}

///|
pub extend SteerProbeHost with @kernel_exec.HostRuntime::{
  execute_tool,
  cancel_effects,
  call_model,
  compact,
}

///|
pub impl @kernel_exec.HostRuntime for SteerProbeHost with fn call_model(
  self,
  _scope : InvocationScope,
  messages : ArrayView[Message],
  _tool_definitions : Array[ToolDef],
  _call_options : Json,
  _on_chunk : HostChunkCallback?,
) -> Result[ModelCallResult, ModelFailure] {
  let index = self.model_index
  self.model_index = index + 1
  self.messages_at_model_call.push(messages.to_owned())
  if index >= self.model_results.length() {
    Err(Runtime(reason="steer probe exhausted model results"))
  } else {
    match self.model_results[index] {
      Ok(completion) =>
        Ok({ completion, processed_messages: messages.to_owned(), })
      Err(failure) => Err(failure)
    }
  }
}

///|
pub impl @kernel_exec.HostRuntime for SteerProbeHost with fn execute_tool(
  self,
  _effect_id : EffectId,
  _owner_id : OwnerId,
  call_id : CallId,
  _tool_name : ToolName,
  _arguments : Json,
  _scope,
) -> @kernel.ToolOutcome {
  let id = call_id.to_string()
  self.tool_started.put(id)
  self.tool_gate.get()
  Success(content=id + "-ok", structured=None)
}

///|
pub impl @kernel_exec.HostRuntime for SteerProbeHost with fn cancel_effects(
  self : SteerProbeHost,
  run_id~,
  effect_ids : Array[EffectId],
  _reason : CancelReason,
) -> Array[(EffectId, CancelDisposition)] {
  let _ = run_id

  ignore(self)
  effect_ids.map(id => (id, NotPropagated))
}

///|
/// Compact stub — SteerProbeHost does not exercise compact.
pub impl @kernel_exec.HostRuntime for SteerProbeHost with fn compact(
  self : SteerProbeHost,
  _scope : InvocationScope,
  _messages : ArrayView[Message],
  _tools : Array[ToolDef],
  _call_options : Json,
  _trigger : @kernel.CompactTrigger,
) -> Result[CompactResult, ModelFailure] {
  ignore(self)
  Err(Parse(reason="SteerProbeHost does not implement compact"))
}

///|
/// User-authored text in one message list, in transcript order. Assistant and
/// tool messages are skipped, so the result answers "what did the user say".
fn user_texts(messages : ArrayView[Message]) -> Array[String] {
  let out : Array[String] = []
  for message in messages {
    guard message is UserMessage(content~) else { continue }
    for block in content {
      guard block is Text(text) else { continue }
      out.push(text)
    }
  }
  out
}

///|
fn SteerProbeHost::user_texts_at(
  self : SteerProbeHost,
  index : Int32,
) -> Array[String] {
  user_texts(self.messages_at(index))
}

///|
fn steer_command(command_id : String, text : String) -> SteerCommand {
  {
    command_id: CommandId::unchecked(command_id),
    target_run_id: RunId::unchecked("run_steer"),
    target_turn_id: TurnId::unchecked("turn_steer"),
    message: UserMessage(content=[Text(text)]),
  }
}

///|
/// Bind a steer to the mailbox's own view of the active run/turn, mirroring
/// how a host would submit one mid-run.
fn SteerCommand::to_active_run(
  self : SteerCommand,
  mailbox : &Mailbox,
) -> SteerCommand raise {
  let target_run_id = match mailbox.active_run_id() {
    Some(id) => id
    None => fail("mailbox must be bound to the active run")
  }
  let target_turn_id = match mailbox.active_turn_id() {
    Some(id) => id
    None => fail("mailbox must be bound to the active turn")
  }
  { ..self, target_run_id, target_turn_id, }
}

///|
async test "puppet/steer_reaches_second_model_step_only" {
  let host = SteerProbeHost([
    Ok(fixture_tool_calls([fixture_call("echo", "tool_1")])),
    Ok(fixture_stop("done")),
  ])
  let journal = InMemoryJournal()
  let subscriber = RecordingSubscriber("steer-observer")
  let puppet = Puppet(
    canonical_puppet_config(
      host as &@kernel_exec.HostRuntime,
      fixture_tool_catalog("echo"),
      journal,
      [subscriber as &EventSubscriber],
      [],
      None,
    ),
  )
  let mailbox = puppet.mailbox()
  @async.with_task_group(group => {
    let task = group.spawn(async fn() {
      puppet.prompt({
        run_id: RunId::unchecked("run_steer"),
        turn_id: TurnId::unchecked("turn_steer"),
        session_id: SessionId::unchecked("session_steer"),
        initial_messages: [UserMessage(content=[Text("hello")])],
        operation_id: "operation_steer",
        policy: fixture_run_policy("fixture-model", Json::null()),
      })
    })
    group.spawn_bg(async fn() {
      // The tool call is parked until the steer is queued, so delivery is
      // provably mid-wave — no sleep margin needed.
      let started = host.tool_started.get()
      assert_eq(started, "tool_1")
      let accepted = mailbox.enqueue_steer(
        steer_command("steer_1", "keep to analysis only").to_active_run(mailbox),
      )
      assert_true(accepted is Accepted(_))
      host.tool_gate.put(())
    })
    let result = task.wait()
    assert_true(result is Accepted(_))
  })
  assert_eq(host.messages_at_model_call.length(), 2)
  // Step 1 was already dispatched before the steer was accepted.
  assert_eq(host.user_texts_at(0), ["hello"])
  // Step 2 carries the steer, appended after the committed tool result.
  assert_eq(host.user_texts_at(1), ["hello", "keep to analysis only"])
  let second = host.messages_at(1)
  assert_eq(second.length(), 4)
  guard second[2] is ToolMessage(call_id~, ..) else {
    fail("expected the committed tool result before the steer")
  }
  assert_eq(call_id.to_string(), "tool_1")
  assert_true(second[3] is UserMessage(content=[Text("keep to analysis only")]))
  // The message is committed after the tool fact and before the next model
  // intent, so observers see it as an input-acceptance boundary.
  let mut tool_at = -1
  let mut appended_at = -1
  let step_starts : Array[Int32] = []
  for i, envelope in subscriber.received() {
    match envelope.event {
      ToolCompleted(..) => tool_at = i
      UserMessageAppended(..) => appended_at = i
      ModelStepStarted(..) => step_starts.push(i)
      _ => ()
    }
  }
  assert_true(tool_at >= 0 && appended_at > tool_at)
  assert_eq(step_starts.length(), 2)
  assert_true(appended_at < step_starts[1])
}

///|
async test "puppet/steer_drains_fifo_into_one_step" {
  let host = SteerProbeHost([
    Ok(fixture_tool_calls([fixture_call("echo", "tool_1")])),
    Ok(fixture_stop("done")),
  ])
  let journal = InMemoryJournal()
  let puppet = Puppet(
    canonical_puppet_config(
      host as &@kernel_exec.HostRuntime,
      fixture_tool_catalog("echo"),
      journal,
      [],
      [],
      None,
    ),
  )
  let mailbox = puppet.mailbox()
  @async.with_task_group(group => {
    let task = group.spawn(async fn() {
      puppet.prompt({
        run_id: RunId::unchecked("run_steer"),
        turn_id: TurnId::unchecked("turn_steer"),
        session_id: SessionId::unchecked("session_steer"),
        initial_messages: [UserMessage(content=[Text("hello")])],
        operation_id: "operation_steer",
        policy: fixture_run_policy("fixture-model", Json::null()),
      })
    })
    group.spawn_bg(async fn() {
      let started = host.tool_started.get()
      assert_eq(started, "tool_1")
      let first = mailbox.enqueue_steer(
        steer_command("steer_1", "keep to analysis only").to_active_run(mailbox),
      )
      assert_true(first is Accepted(_))
      let second = mailbox.enqueue_steer(
        steer_command("steer_2", "target branch is release").to_active_run(
          mailbox,
        ),
      )
      assert_true(second is Accepted(_))
      assert_eq(mailbox.steer_depth(), 2)
      host.tool_gate.put(())
    })
    let result = task.wait()
    assert_true(result is Accepted(_))
  })
  assert_eq(mailbox.steer_depth(), 0)
  assert_eq(host.messages_at_model_call.length(), 2)
  assert_eq(host.user_texts_at(0), ["hello"])
  assert_eq(host.user_texts_at(1), [
    "hello", "keep to analysis only", "target branch is release",
  ])
}

///|
/// Records what each `before_model` call observes, without rewriting.
struct SteerObservingHook {
  observed : Array[Array[Message]]
}

///|
fn SteerObservingHook::SteerObservingHook() -> SteerObservingHook {
  { observed: [], }
}

///|
impl @port.PipelineHook for SteerObservingHook with fn before_model(
  self,
  messages : Array[Message],
) -> Array[Message] {
  self.observed.push(messages.copy())
  messages
}

///|
async test "puppet/steer_folds_before_the_first_model_hook" {
  // `pump_ready_for_model` is the turn's first-step path. `prompt` never
  // reaches it (the initial boundary already declares the first model
  // intent), so this drives that step directly to prove the ordering the doc
  // requires: fold the steer, then let the hook chain see the transcript.
  let host = SteerProbeHost([Ok(fixture_stop("done"))])
  let journal = InMemoryJournal()
  let hook = SteerObservingHook()
  let puppet = Puppet(
    hook_config(
      host as &@kernel_exec.HostRuntime,
      fixture_empty_catalog(),
      journal,
      [hook as &@port.PipelineHook],
    ),
  )
  let run_id = RunId::unchecked("run_steer_first")
  let turn_id = TurnId::unchecked("turn_steer_first")
  let session_id = SessionId::unchecked("session_steer_first")
  let snap = TurnSnapshot::capture({
    run_id,
    turn_id,
    session_id,
    catalog: fixture_empty_catalog(),
    policy: fixture_run_policy("fixture-model", Json::null()),
    deadline: None,
    hook_provenance: [],
    lifecycle_provenance: [],
    subscriber_provenance: [],
  })
  let initial = RunState::initial(
    run_id~,
    session_id~,
    budget=Budget::default_run(),
  )
  let started = reduce(
    initial,
    fixture_empty_catalog(),
    Start(payload={
      initial_messages: [UserMessage(content=[Text("hello")])],
      catalog_version: snap.catalog_version(),
    }),
  )
  let state = started.next_state()
  assert_true(state.phase() == ReadyForModel)
  puppet.mailbox().bind_run(run_id, turn_id)
  let accepted = puppet
    .mailbox()
    .enqueue_steer({
      command_id: CommandId::unchecked("steer_first"),
      target_run_id: run_id,
      target_turn_id: turn_id,
      message: UserMessage(content=[Text("keep to analysis only")]),
    })
  assert_true(accepted is Accepted(_))
  let stepped = puppet.pump_ready_for_model(
    state,
    EventDispatcher(run_id, turn_id, session_id),
    run_id,
    turn_id,
    session_id,
    snap,
    0,
  )
  let next_state = match stepped {
    StopWith(result) =>
      fail("expected the step to continue: " + result.to_string())
    ContinueWith(next_state) => next_state
  }
  assert_true(next_state.phase() == AwaitingModel)
  let messages = next_state.transcript().messages_snapshot()
  assert_eq(messages.length(), 2)
  assert_true(
    messages[1] is UserMessage(content=[Text("keep to analysis only")]),
  )
  // The hook observed the transcript after the steer was folded in.
  assert_eq(hook.observed.length(), 1)
  assert_eq(hook.observed[0].length(), 2)
  // Fact, message and the next model intent share one boundary.
  let entries = journal.entries_for_run(run_id)
  assert_eq(entries.length(), 1)
  assert_true(entries[0].identity.kind == InputAccepted)
}

///|
/// Parks the turn's `before_model` chain on a release gate so a steer can be
/// accepted inside the real await window that opens between `bind_run` and the
/// initial model declaration.
struct SteerFirstStepGateHook {
  entered : @aqueue.Queue[Int32]
  release : @aqueue.Queue[Int32]
}

///|
fn SteerFirstStepGateHook::SteerFirstStepGateHook() -> SteerFirstStepGateHook {
  { entered: Queue(kind=Unbounded), release: Queue(kind=Unbounded), }
}

///|
impl @port.PipelineHook for SteerFirstStepGateHook with fn before_model(
  self,
  messages : Array[Message],
) -> Array[Message] {
  self.entered.put(1) catch {
    _ => raise Aborted(reason="steer gate enter failed")
  }
  ignore(
    self.release.get() catch {
      _ => raise Aborted(reason="steer gate release failed")
    },
  )
  messages
}

///|
async test "puppet/steer_reaches_the_first_model_step" {
  // A steer accepted before the first model intent is declared must reach the
  // first request: the initial boundary already declares that intent, so the
  // pump's ReadyForModel fold never runs on a real first step.
  let host = SteerProbeHost([Ok(fixture_stop("done"))])
  let journal = InMemoryJournal()
  let subscriber = RecordingSubscriber("steer-first-step")
  let hook = SteerFirstStepGateHook()
  let puppet = Puppet(
    hook_config_with_subscribers(
      host as &@kernel_exec.HostRuntime,
      fixture_empty_catalog(),
      journal,
      [hook as &@port.PipelineHook],
      [subscriber as &EventSubscriber],
    ),
  )
  let mailbox = puppet.mailbox()
  @async.with_task_group(group => {
    let task = group.spawn(async fn() {
      puppet.prompt({
        run_id: RunId::unchecked("run_steer"),
        turn_id: TurnId::unchecked("turn_steer"),
        session_id: SessionId::unchecked("session_steer"),
        initial_messages: [UserMessage(content=[Text("hello")])],
        operation_id: "operation_steer",
        policy: fixture_run_policy("fixture-model", Json::null()),
      })
    })
    group.spawn_bg(async fn() {
      // The hook chain parks inside the real await window that `bind_run`
      // opens before the initial declaration, so the steer is accepted while
      // the run is bound but no model intent exists yet.
      ignore(hook.entered.get())
      let accepted = mailbox.enqueue_steer(
        steer_command("steer_first_step", "use the v2 endpoint").to_active_run(
          mailbox,
        ),
      )
      assert_true(accepted is Accepted(_))
      assert_eq(mailbox.steer_depth(), 1)
      ignore(hook.release.put(1))
    })
    let result = task.wait()
    assert_true(result is Accepted(_))
  })
  assert_eq(host.messages_at_model_call.length(), 1)
  assert_eq(host.user_texts_at(0), ["hello", "use the v2 endpoint"])
  assert_eq(mailbox.steer_depth(), 0)
  // Fact, steer message and the first model intent commit atomically.
  let entries = journal.entries_for_run(RunId::unchecked("run_steer"))
  assert_true(entries[0].identity.kind == InputAccepted)
  let kinds : Array[String] = []
  for i, envelope in subscriber.received() {
    if i >= 3 {
      break
    }
    kinds.push(
      match envelope.event {
        RunStarted(..) => "RunStarted"
        UserMessageAppended(..) => "UserMessageAppended"
        ModelStepStarted(..) => "ModelStepStarted"
        _ => envelope.event.to_string()
      },
    )
  }
  assert_eq(kinds, ["RunStarted", "UserMessageAppended", "ModelStepStarted"])
}

// ──────────────────────────────────────────────────────────────────────────
// Residual steers: terminal / abort exit (docs/message-delivery-boundaries.md
// §5.3 "terminal 与 abort 的残留", §5.6.3).
// ──────────────────────────────────────────────────────────────────────────

///|
/// Host for the residual-steer paths: records every model request, parks a
/// chosen model call (or the tool wave) on a release gate so a steer is
/// accepted inside a deterministic window, and answers `compact` with a fixed
/// replacement transcript so auto-compact is cheap to trigger.
struct SteerDrainProbeHost {
  model_results : Array[Result[@kernel.Completion, ModelFailure]]
  mut model_index : Int32
  messages_at_model_call : Array[Array[Message]]
  /// Per-model-call release gates; an absent index means "do not park".
  model_gates : Map[Int32, @aqueue.Queue[Unit]]
  model_started : @aqueue.Queue[Unit]
  tool_started : @aqueue.Queue[String]
  tool_gate : @aqueue.Queue[Unit]?
  compacted_messages : Array[Message]
  compact_mode : @kernel.CompactMode
  compact_started : @aqueue.Queue[Unit]
  compact_gate : @aqueue.Queue[Unit]?
  mut compact_calls : Int32
}

///|
fn SteerDrainProbeHost::SteerDrainProbeHost(
  model_results : Array[Result[@kernel.Completion, ModelFailure]],
  model_gates~ : Map[Int32, @aqueue.Queue[Unit]] = Map::from_array([]),
  tool_gate? : @aqueue.Queue[Unit],
  compacted_messages~ : Array[Message] = [],
  compact_mode~ : @kernel.CompactMode = Replace,
  compact_gate? : @aqueue.Queue[Unit],
) -> SteerDrainProbeHost {
  {
    model_results: model_results.copy(),
    model_index: 0,
    messages_at_model_call: [],
    model_gates,
    model_started: Queue(kind=Unbounded),
    tool_started: Queue(kind=Unbounded),
    tool_gate,
    compacted_messages,
    compact_mode,
    compact_started: Queue(kind=Unbounded),
    compact_gate,
    compact_calls: 0,
  }
}

///|
fn SteerDrainProbeHost::messages_at(
  self : SteerDrainProbeHost,
  index : Int32,
) -> Array[Message] {
  self.messages_at_model_call[index]
}

///|
fn SteerDrainProbeHost::user_texts_at(
  self : SteerDrainProbeHost,
  index : Int32,
) -> Array[String] {
  user_texts(self.messages_at(index))
}

///|
pub extend SteerDrainProbeHost with @kernel_exec.HostRuntime::{
  execute_tool,
  cancel_effects,
  call_model,
  compact,
}

///|
pub impl @kernel_exec.HostRuntime for SteerDrainProbeHost with fn call_model(
  self,
  _scope : InvocationScope,
  messages : ArrayView[Message],
  _tool_definitions : Array[ToolDef],
  _call_options : Json,
  _on_chunk : HostChunkCallback?,
) -> Result[ModelCallResult, ModelFailure] {
  let index = self.model_index
  self.model_index = index + 1
  self.messages_at_model_call.push(messages.to_owned())
  self.model_started.put(())
  // A parked call is a cancellation point, so a requested abort can never lose
  // the race with it.
  match self.model_gates.get(index) {
    Some(gate) => gate.get()
    None => ()
  }
  if index >= self.model_results.length() {
    Err(Runtime(reason="steer drain probe exhausted model results"))
  } else {
    match self.model_results[index] {
      Ok(completion) =>
        Ok({ completion, processed_messages: messages.to_owned(), })
      Err(failure) => Err(failure)
    }
  }
}

///|
pub impl @kernel_exec.HostRuntime for SteerDrainProbeHost with fn execute_tool(
  self,
  _effect_id : EffectId,
  _owner_id : OwnerId,
  call_id : CallId,
  _tool_name : ToolName,
  _arguments : Json,
  _scope,
) -> @kernel.ToolOutcome {
  let id = call_id.to_string()
  self.tool_started.put(id)
  match self.tool_gate {
    Some(gate) => gate.get()
    None => ()
  }
  Success(content=id + "-ok", structured=None)
}

///|
pub impl @kernel_exec.HostRuntime for SteerDrainProbeHost with fn cancel_effects(
  self : SteerDrainProbeHost,
  run_id~,
  effect_ids : Array[EffectId],
  _reason : CancelReason,
) -> Array[(EffectId, CancelDisposition)] {
  let _ = run_id

  ignore(self)
  effect_ids.map(id => (id, NotPropagated))
}

///|
pub impl @kernel_exec.HostRuntime for SteerDrainProbeHost with fn compact(
  self : SteerDrainProbeHost,
  _scope : InvocationScope,
  _messages : ArrayView[Message],
  _tools : Array[ToolDef],
  _call_options : Json,
  _trigger : @kernel.CompactTrigger,
) -> Result[CompactResult, ModelFailure] {
  self.compact_calls = self.compact_calls + 1
  self.compact_started.put(())
  match self.compact_gate {
    Some(gate) => gate.get()
    None => ()
  }
  Ok({
    compacted_messages: self.compacted_messages.copy(),
    mode: self.compact_mode,
  })
}

///|
/// Every `SteerUndelivered` in the stream with the `committed_revision` it
/// shares with the terminal boundary, plus the terminal revision itself.
fn undelivered_summary(
  envelopes : Array[EventEnvelope],
) -> (Array[String], Int32, Int32, Int32) {
  let reports : Array[String] = []
  let mut undelivered_rev = -1
  let mut terminal_rev = -1
  let mut appended = 0
  for envelope in envelopes {
    match envelope.event {
      SteerUndelivered(command_id~, reason~) => {
        reports.push("\{command_id}:\{reason}")
        undelivered_rev = envelope.committed_revision
      }
      RunCompleted(..) | RunCancelled(..) | RunFailed(..) =>
        terminal_rev = envelope.committed_revision
      UserMessageAppended(..) => appended = appended + 1
      _ => ()
    }
  }
  (reports, undelivered_rev, terminal_rev, appended)
}

///|
async test "puppet/steer_undelivered_on_abort" {
  // The tool wave commits the only step boundary that could have delivered a
  // steer; the second model call then parks, so the abort lands with the steer
  // still queued.
  let released : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  released.put(())
  let held : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let host = SteerDrainProbeHost(
    [
      Ok(fixture_tool_calls([fixture_call("echo", "tool_1")])),
      Ok(fixture_stop("done")),
    ],
    model_gates=Map::from_array([(0, released), (1, held)]),
  )
  let journal = InMemoryJournal()
  let subscriber = RecordingSubscriber("steer-drain-abort")
  let puppet = Puppet(
    canonical_puppet_config(
      host as &@kernel_exec.HostRuntime,
      fixture_tool_catalog("echo"),
      journal,
      [subscriber as &EventSubscriber],
      [],
      None,
    ),
  )
  let mailbox = puppet.mailbox()
  let run = RunId::unchecked("run_steer")
  @async.with_task_group(group => {
    let task = group.spawn(async fn() {
      puppet.prompt({
        run_id: run,
        turn_id: TurnId::unchecked("turn_steer"),
        session_id: SessionId::unchecked("session_steer"),
        initial_messages: [UserMessage(content=[Text("hello")])],
        operation_id: "operation_steer",
        policy: fixture_run_policy("fixture-model", Json::null()),
      })
    })
    group.spawn_bg(async fn() {
      ignore(host.model_started.get())
      ignore(host.model_started.get())
      // Past the tool boundary, so nothing can deliver it before the abort.
      let accepted = mailbox.enqueue_steer(
        steer_command("steer_abort", "keep to analysis only").to_active_run(
          mailbox,
        ),
      )
      assert_true(accepted is Accepted(_))
      assert_eq(mailbox.steer_depth(), 1)
      let abort = mailbox.enqueue_abort({
        command_id: CommandId::unchecked("abort_steer"),
        target_run_id: run,
        detail: None,
      })
      assert_true(abort is Accepted(_))
    })
    let result = task.wait()
    assert_true(result is Accepted(_))
  })
  // The steer never reached a model request: both calls predate its commit.
  assert_eq(host.messages_at_model_call.length(), 2)
  assert_eq(host.user_texts_at(0), ["hello"])
  assert_eq(host.user_texts_at(1), ["hello"])
  let transcript = match puppet.last_completed_transcript() {
    Some(t) => t
    None => fail("expected the cancelled run to publish its transcript")
  }
  assert_eq(user_texts(transcript.messages_snapshot()), ["hello"])
  // Abort exits through `pump_abort`, which reports the residual steer in the
  // same `RunTerminal` boundary as the cancellation fact.
  let (reports, undelivered_rev, terminal_rev, appended) = undelivered_summary(
    subscriber.received(),
  )
  assert_eq(appended, 0)
  assert_eq(reports, ["steer_abort:run aborted before delivery"])
  assert_eq(undelivered_rev, terminal_rev)
  // Draining the queue is what makes the residual visible: `clear_run` would
  // otherwise drop it silently.
  assert_eq(mailbox.steer_depth(), 0)
}

///|
async test "puppet/steer_undelivered_on_new_thread_compact" {
  // A manual compact consumed at the loop-top safe point stops the turn with
  // `CompactCompleted` and no `RunTerminal` boundary. The steer is enqueued
  // while the compact itself is parked — after the last delivery point — so
  // only the NewThread exit can report it.
  let released : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  released.put(())
  let compact_hold : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let host = SteerDrainProbeHost(
    [
      Ok(fixture_tool_calls([fixture_call("echo", "tool_1")])),
      Ok(fixture_stop("done")),
    ],
    model_gates=Map::from_array([(0, released)]),
    compact_mode=NewThread,
    compact_gate=compact_hold,
  )
  let journal = InMemoryJournal()
  let subscriber = RecordingSubscriber("steer-drain-new-thread")
  let puppet = Puppet(
    canonical_puppet_config(
      host as &@kernel_exec.HostRuntime,
      fixture_tool_catalog("echo"),
      journal,
      [subscriber as &EventSubscriber],
      [],
      None,
    ),
  )
  let mailbox = puppet.mailbox()
  let run = RunId::unchecked("run_steer")
  let turn = TurnId::unchecked("turn_steer")
  @async.with_task_group(group => {
    let task = group.spawn(async fn() {
      puppet.prompt({
        run_id: run,
        turn_id: turn,
        session_id: SessionId::unchecked("session_steer"),
        initial_messages: [UserMessage(content=[Text("hello")])],
        operation_id: "operation_steer",
        policy: fixture_run_policy("fixture-model", Json::null()),
      })
    })
    group.spawn_bg(async fn() {
      ignore(host.model_started.get())
      let compact = mailbox.enqueue_compact({
        command_id: CommandId::unchecked("compact_nt"),
        target_run_id: run,
        target_turn_id: turn,
        trigger: Manual,
      })
      assert_true(compact is Accepted(_))
      // Past the tool-wave fold, so nothing but the NewThread exit can
      // deliver or report the steer from here on.
      ignore(host.compact_started.get())
      let accepted = mailbox.enqueue_steer(
        steer_command("steer_nt", "keep to analysis only").to_active_run(
          mailbox,
        ),
      )
      assert_true(accepted is Accepted(_))
      assert_eq(mailbox.steer_depth(), 1)
      compact_hold.put(())
    })
    let result = task.wait()
    assert_true(result is CompactCompleted(mode=NewThread, ..))
  })
  // The turn stopped after one model call; the steer reached no request.
  assert_eq(host.messages_at_model_call.length(), 1)
  assert_eq(host.user_texts_at(0), ["hello"])
  assert_eq(host.compact_calls, 1)
  let (reports, undelivered_rev, terminal_rev, appended) = undelivered_summary(
    subscriber.received(),
  )
  assert_eq(appended, 0)
  assert_eq(reports, ["steer_nt:turn stopped by compact before delivery"])
  // No RunTerminal fact exists for this exit, but the report is still
  // committed in its own boundary rather than dropped by `clear_run`.
  assert_true(undelivered_rev >= 0)
  assert_eq(terminal_rev, -1)
  assert_eq(mailbox.steer_depth(), 0)
}

///|
async test "puppet/steer_before_normal_stop_continues_same_turn" {
  let held : @aqueue.Queue[Unit] = Queue(kind=Unbounded)
  let host = SteerDrainProbeHost(
    [Ok(fixture_stop("first answer")), Ok(fixture_stop("revised answer"))],
    model_gates=Map::from_array([(0, held)]),
  )
  let journal = InMemoryJournal()
  let subscriber = RecordingSubscriber("steer-drain-turn-end")
  let puppet = Puppet(
    canonical_puppet_config(
      host as &@kernel_exec.HostRuntime,
      fixture_empty_catalog(),
      journal,
      [subscriber as &EventSubscriber],
      [],
      None,
    ),
  )
  let mailbox = puppet.mailbox()
  @async.with_task_group(group => {
    let task = group.spawn(async fn() {
      puppet.prompt({
        run_id: RunId::unchecked("run_steer"),
        turn_id: TurnId::unchecked("turn_steer"),
        session_id: SessionId::unchecked("session_steer"),
        initial_messages: [UserMessage(content=[Text("hello")])],
        operation_id: "operation_steer",
        policy: fixture_run_policy("fixture-model", Json::null()),
      })
    })
    group.spawn_bg(async fn() {
      ignore(host.model_started.get())
      let accepted = mailbox.enqueue_steer(
        steer_command("steer_turn_end", "keep to analysis only").to_active_run(
          mailbox,
        ),
      )
      assert_true(accepted is Accepted(_))
      ignore(held.put(()))
    })
    let result = task.wait()
    assert_true(result is Accepted(_))
  })
  assert_eq(host.messages_at_model_call.length(), 2)
  assert_eq(host.user_texts_at(0), ["hello"])
  assert_eq(host.user_texts_at(1), ["hello", "keep to analysis only"])
  let transcript = match puppet.last_completed_transcript() {
    Some(t) => t
    None => fail("expected the terminal transcript")
  }
  assert_eq(user_texts(transcript.messages_snapshot()), [
    "hello", "keep to analysis only",
  ])
  let (reports, undelivered_rev, terminal_rev, appended) = undelivered_summary(
    subscriber.received(),
  )
  assert_eq(appended, 1)
  assert_eq(reports, [])
  assert_eq(undelivered_rev, -1)
  assert_true(terminal_rev >= 0)
  let entries = journal.entries_for_run(RunId::unchecked("run_steer"))
  let correlated = entries.filter(fn(entry) {
    entry.payload.stringify().contains("steer_turn_end")
  })
  assert_eq(correlated.length(), 1)
  assert_true(correlated[0].payload.stringify().contains("message_deliveries"))
  assert_false(
    correlated[0].payload.stringify().contains("keep to analysis only"),
  )
  let mut run_starts = 0
  for envelope in subscriber.received() {
    match envelope.event {
      RunStarted(..) => run_starts = run_starts + 1
      _ => ()
    }
  }
  assert_eq(run_starts, 1)
  assert_eq(mailbox.follow_up_depth(), 0)
  assert_eq(mailbox.steer_depth(), 0)
}

///|
async test "puppet/steer_lands_after_auto_compact" {
  // Usage 95 crosses 90% of a 100-token window, so the step boundary fires a
  // Replace compact; a steer queued during the tool wave must be appended to
  // the post-compact transcript instead of being rewritten away.
  let host = SteerDrainProbeHost(
    [
      Ok(fixture_tool_calls_with_usage([fixture_call("echo", "tool_1")], 95)),
      Ok(fixture_stop("done")),
    ],
    tool_gate=Queue(kind=Unbounded),
    compacted_messages=[UserMessage(content=[Text("compacted summary")])],
  )
  let journal = InMemoryJournal()
  let puppet = Puppet(
    canonical_puppet_config(
      host as &@kernel_exec.HostRuntime,
      fixture_tool_catalog("echo"),
      journal,
      [],
      [],
      None,
    ),
  )
  let mailbox = puppet.mailbox()
  @async.with_task_group(group => {
    let task = group.spawn(async fn() {
      puppet.prompt({
        run_id: RunId::unchecked("run_steer"),
        turn_id: TurnId::unchecked("turn_steer"),
        session_id: SessionId::unchecked("session_steer"),
        initial_messages: [UserMessage(content=[Text("hello")])],
        operation_id: "operation_steer",
        policy: {
          model_id: "fixture-model",
          call_options: Json::null(),
          budget: Budget::default_run(),
          context_window: Some(100),
          compact_threshold: 0.9,
        },
      })
    })
    group.spawn_bg(async fn() {
      assert_eq(host.tool_started.get(), "tool_1")
      let accepted = mailbox.enqueue_steer(
        steer_command("steer_compact", "keep to analysis only").to_active_run(
          mailbox,
        ),
      )
      assert_true(accepted is Accepted(_))
      match host.tool_gate {
        Some(gate) => ignore(gate.put(()))
        None => fail("the compact probe must gate the tool wave")
      }
    })
    let result = task.wait()
    assert_true(result is Accepted(_))
  })
  // The compact really fired on the step boundary, and the steer survives it.
  assert_eq(host.compact_calls, 1)
  assert_eq(host.messages_at_model_call.length(), 2)
  assert_eq(host.user_texts_at(1), [
    "compacted summary", "keep to analysis only",
  ])
}
