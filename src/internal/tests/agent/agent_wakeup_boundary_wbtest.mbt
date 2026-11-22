///|
priv struct WakeupBoundaryHook {
  note : String
  payload : String
  reject : Bool
  inputs : Array[Array[@kernel.Message]]
}

///|
impl @port.PipelineHook for WakeupBoundaryHook with fn before_model(
  self,
  messages,
) {
  self.inputs.push(messages.copy())
  if !acceptance_user_message_contains(messages, self.note) {
    return messages
  }
  if self.reject {
    raise Aborted(reason="wakeup context rejected")
  }
  messages.map(fn(message) {
    let text = acceptance_message_text(message)
    match message {
      UserMessage(..) if text.contains(self.note) =>
        @test_support.tk_user_msg("[wakeup note redacted]")
      UserMessage(..) if text.contains(self.payload) =>
        @test_support.tk_user_msg("[task outcome redacted]")
      _ => message
    }
  })
}

///|
fn wakeup_boundary_events(observer : SignalObserver) -> Array[@types.TurnEvent] {
  observer.events.filter(event => event is Custom(source="posoco.wakeup", ..))
}

///|
async fn check_wakeup_before_model(reject~ : Bool) -> Unit {
  let session = "wakeup-hook"
  let note = "private wakeup note"
  let payload = "private worker payload"
  let hook = WakeupBoundaryHook::{ note, payload, reject, inputs: [], }
  let capture = WakeupCapture::WakeupCapture()
  let observer = SignalObserver::SignalObserver()
  let gate = WakeupStepGate::WakeupStepGate()
  let script = @test_support.ScriptedModel([
    Respond(@test_support.tk_stop_response("first stop")),
    Respond(@test_support.tk_stop_response("after wakeup")),
  ])
  let model = WakeupStepModel::{ script, gate, }
  let agent = Agent(
    events=EventSystem(),
    exts=[
      @test_support.tk_ext(id="model", model=Some(model)),
      @test_support.tk_ext(
        id="io",
        sessions=[@test_support.RecordingSessionPort()],
        observers=[observer],
        hooks=[hook],
      ),
      @test_support.tk_ext(id="waker", lifecycle=[capture], requires=[
        Tasks,
        Wakeup,
      ]),
    ],
    config=agent_config(max_tool_rounds=Some(10)),
  )
  // Retire the rejected ticket before the operation releases the idle pump.
  let subscription = agent
    .subscribe_events(fn(envelope) {
      if reject && envelope.event is @events.Core(TurnFailed(_)) {
        agent.set_active_session(None)
      }
    })
    .unwrap()
  defer subscription.cancel()
  let port = wakeup_capture_port(capture)
  let observed : Ref[
    (@port.WakeupTicket, String, Result[@types.TurnResult, @error.AgentError])?,
  ] = Ref(None)
  @async.with_timeout(30_000, async fn() {
    agent.run_scoped(async fn(agent) {
      agent.set_active_session(Some(session))
      @async.with_task_group(async fn(group) {
        let turn = group.spawn(async fn() {
          Ok(agent.run_turn(@test_support.tk_user_msg("start work"), session)) catch {
            error => Err(error)
          }
        })
        gate.entered.get()
        let worker = capture.tasks
          .unwrap()
          .submit({
            session_id: session,
            mode: Background,
            label: "worker",
            timeout_ms: None,
            run: fn() { @test_support.tk_user_msg(payload) },
          })
          .unwrap()
        let outcome = worker.wait()
        assert_true(outcome.status is Completed(_))
        let ticket = port.request(session~, tag="worker", note~).unwrap()
        gate.release.put(())
        observed.val = Some((ticket, outcome.receipt.id, turn.wait()))
      })
    })
  })

  let (ticket, task_id, result) = observed.val.unwrap()
  let marker = "[posoco-task-outcome id=\{task_id}]"
  guard hook.inputs is [initial, follow_on] else {
    fail("expected before_model on the initial request and the wakeup step")
  }
  for text in [note, marker, payload] {
    assert_eq(acceptance_text_count(initial, text), 0)
    assert_true(acceptance_user_message_contains(follow_on, text))
  }
  assert_eq(turn_starts(observer.events), 1)
  let wakeups = wakeup_boundary_events(observer)
  guard wakeups is [Custom(label="wakeup_requested", ..) as requested, delivery] else {
    fail("expected one wakeup request and one disposition")
  }
  fail_unless_custom(requested, "ticket_id", ticket.id)
  fail_unless_custom(delivery, "ticket_id", ticket.id)
  let requests = observer.events.filter(event => event is ModelRequestStarted)
  if reject {
    guard result is Err(PipelineAborted(reason)) else {
      fail(
        "expected before_model to abort the wakeup step, got \{repr(result)}",
      )
    }
    assert_true(reason.contains("wakeup context rejected"))
    assert_eq(script.call_count(), 1)
    assert_eq(requests.length(), 1)
    assert_true(delivery is Custom(label="wakeup_dropped", ..))
    assert_eq(turn_terminals(observer.events), ["TurnFailed"])
  } else {
    let result = result.unwrap()
    assert_true(
      result.message is AssistantMessage(content=[Text("after wakeup")], ..),
    )
    assert_eq(script.call_count(), 2)
    assert_eq(requests.length(), 2)
    let sent = script.received_messages[1]
    for
      text in [
        "start work", "[wakeup note redacted]", "[task outcome redacted]",
      ] {
      assert_true(acceptance_user_message_contains(sent, text))
    }
    for text in [note, marker, payload] {
      assert_eq(acceptance_text_count(sent, text), 0)
    }
    assert_true(delivery is Custom(label="wakeup_satisfied", ..))
    fail_unless_custom(delivery, "delivery", "step")
    assert_eq(turn_terminals(observer.events), ["TurnCompleted"])
  }
}

///|
async test "wakeup/before_model redacts follow-on wakeup and task context" {
  check_wakeup_before_model(reject=false)
}

///|
async test "wakeup/before_model aborts follow-on step without requesting or satisfying it" {
  check_wakeup_before_model(reject=true)
}

///|
priv struct WakeupBoundaryCompactModel {
  step_model : WakeupStepModel
  compact_gate : WakeupStepGate
}

///|
impl @port.ModelPort for WakeupBoundaryCompactModel with fn chat(
  self,
  scope,
  messages,
  tools,
  options,
  stream,
) {
  (self.step_model as &@port.ModelPort).chat(
    scope, messages, tools, options, stream,
  )
}

///|
impl @port.ModelPort for WakeupBoundaryCompactModel with fn compact(
  self,
  scope,
  messages,
  tools,
  options,
  trigger,
) {
  let result = self.step_model.script.compact(
    scope, messages, tools, options, trigger,
  )
  self.compact_gate.hold() catch {
    error => raise ResponseParse(error.to_string())
  }
  result
}

///|
impl @port.ModelPort for WakeupBoundaryCompactModel with fn provider_config(
  _self,
) {
  policy_reported(context_window=Some(100), compact_threshold=Some(0.9))
}

///|
async test "wakeup/rebind during auto Replace compact settles on the original Stop" {
  let session = "wakeup-compact"
  let capture = WakeupCapture::WakeupCapture()
  let observer = SignalObserver::SignalObserver()
  let gate = WakeupStepGate::WakeupStepGate()
  let compact_gate = WakeupStepGate::WakeupStepGate()
  let script = @test_support.ScriptedModel([
    Respond(wave3_stop_with_usage("original stop", 95)),
    Compact(result={
      compacted_messages: [@test_support.tk_user_msg("compacted summary")],
      mode: Replace,
    }),
    Respond(@test_support.tk_stop_response("unexpected continuation")),
  ])
  let model = WakeupBoundaryCompactModel::{
    step_model: WakeupStepModel::{ script, gate, },
    compact_gate,
  }
  let agent = wakeup_capture_agent(
    capture,
    model,
    @test_support.RecordingSessionPort(),
    observer,
  )
  let port = wakeup_capture_port(capture)
  @async.with_timeout(30_000, async fn() {
    agent.run_scoped(async fn(agent) {
      agent.set_active_session(Some(session))
      @async.with_task_group(async fn(group) {
        let turn = group.spawn(async fn() {
          agent.run_turn(@test_support.tk_user_msg("start"), session)
        })
        gate.entered.get()
        let ticket = port
          .request(session~, tag="refresh", note="stale context")
          .unwrap()
        gate.release.put(())
        compact_gate.entered.get()
        guard script.received_compacts() is [(messages, Auto)] else {
          fail("expected Auto compact after the first Stop")
        }
        assert_true(
          messages.last()
          is Some(
            AssistantMessage(
              content=[Text("original stop")],
              finish_reason=Stop,
              ..
            ),
          ),
        )
        assert_eq(script.call_count(), 1)
        assert_eq(turn_terminals(observer.events), [])
        agent.set_active_session(Some("other-session"))
        guard wakeup_boundary_events(observer)
          is [
            Custom(label="wakeup_requested", ..),
            Custom(label="wakeup_dropped", ..) as dropped,
          ] else {
          fail("rebind must drop the pending wakeup while compact is suspended")
        }
        fail_unless_custom(dropped, "ticket_id", ticket.id)
        compact_gate.release.put(())
        let result = turn.wait()
        assert_eq(result.final_session_id, session)
        assert_eq(result.message, messages.last().unwrap())
      })
    })
  })
  assert_eq(script.call_count(), 1)
  assert_eq(script.compact_call_count(), 1)
  assert_eq(
    observer.events.filter(event => event is ModelRequestStarted).length(),
    1,
  )
  assert_eq(turn_starts(observer.events), 1)
  assert_eq(turn_terminals(observer.events), ["TurnCompleted"])
  assert_eq(wakeup_boundary_events(observer).length(), 2)
}
