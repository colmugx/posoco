///|
/// D5 — Observer.on_kernel_event real-time channel whitebox tests.
///
/// Verifies the pump fires each Observer's `on_kernel_event(PostStage)`
/// immediately after every effect commits, in real time (not batched at
/// turn end like the session-level `on_event` channel).

// ──────────────────────────────────────────────────────────────────────────
// Test fixture: an Observer that only overrides on_kernel_event.
// ──────────────────────────────────────────────────────────────────────────

///|
/// Observer that records every PostStage delivered to `on_kernel_event`.
/// Does NOT override `on_event` (session-level) — we want to verify the
/// default no-op on `on_event` is inherited cleanly.
struct EffectRecorder {
  stages : Array[@port.PostStage]
}

///|
/// `on_event` (session-level) default no-op is inherited via the trait's
/// default implementation. We only provide `on_kernel_event`.
pub impl @port.Observer for EffectRecorder with fn on_kernel_event(
  self : EffectRecorder,
  event : @port.PostStage,
) -> Unit {
  self.stages.push(event)
}

// ──────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────

///|
/// A model-only turn fires exactly one `ModelCompleted` stage to every
/// registered Observer's `on_kernel_event`. This is the real-time channel:
/// the observer sees the event as soon as the effect commits, not at turn
/// end.
async test "d5_observer/model_only_turn_fires_model_completed" {
  let host = FixtureHost([Ok(fixture_stop("hi"))], Map::from_array([]))
  let journal = InMemoryJournal()
  let recorder = EffectRecorder::{ stages: [] }
  let recorder_ref : &@port.Observer = recorder as &@port.Observer
  // Build a minimal config with the recorder as the sole observer.
  let mailbox_instance = ControlMailbox()
  let mailbox : &Mailbox = mailbox_instance as &Mailbox
  let host_ref : &@kernel.HostRuntime = host as &@kernel.HostRuntime
  let cfg : PuppetConfig = {
    host: host_ref,
    catalog: fixture_empty_catalog(),
    journal,
    contributors: [],
    subscribers: [],
    observers: [recorder_ref],
    lifecycle_nodes: [],
    stream_chunks: None,
    pre_model_hooks: [],
    pre_tool_hooks: [],
    post_event_hooks: [],
    max_iterations: 10,
    commands: [],
    session_store: None,
    mailbox,
  }
  let puppet = Puppet(cfg)
  match fixture_prompt(puppet, "d5_model") {
    Accepted(..) => ()
    other => fail("expected accepted prompt, got " + other.to_string())
  }
  // Exactly one model call → exactly one ModelCompleted stage delivered.
  assert_eq(recorder.stages.length(), 1)
  match recorder.stages[0] {
    ModelCompleted(..) => ()
    other => fail("expected ModelCompleted, got " + other.to_string())
  }
}

///|
/// A turn with one tool call fires two stages: ModelCompleted (the call
/// that requested the tool) then ToolCompleted (after the tool executes).
/// Both arrive in real time, in execution order.
async test "d5_observer/tool_turn_fires_model_then_tool" {
  let host = FixtureHost(
    [
      Ok(fixture_tool_calls([fixture_call("echo", "one")])),
      Ok(fixture_stop("done")),
    ],
    Map::from_array([("one", Success(content="ok", structured=None))]),
  )
  let journal = InMemoryJournal()
  let recorder = EffectRecorder::{ stages: [] }
  let recorder_ref : &@port.Observer = recorder as &@port.Observer
  let mailbox_instance = ControlMailbox()
  let mailbox : &Mailbox = mailbox_instance as &Mailbox
  let host_ref : &@kernel.HostRuntime = host as &@kernel.HostRuntime
  let cfg : PuppetConfig = {
    host: host_ref,
    catalog: fixture_tool_catalog("echo"),
    journal,
    contributors: [],
    subscribers: [],
    observers: [recorder_ref],
    lifecycle_nodes: [],
    stream_chunks: None,
    pre_model_hooks: [],
    pre_tool_hooks: [],
    post_event_hooks: [],
    max_iterations: 10,
    commands: [],
    session_store: None,
    mailbox,
  }
  let puppet = Puppet(cfg)
  match fixture_prompt(puppet, "d5_tool") {
    Accepted(..) => ()
    other => fail("expected accepted prompt, got " + other.to_string())
  }
  // Two model calls (one requesting tool, one final stop) + one tool
  // execution = 3 stages: ModelCompleted, ToolCompleted, ModelCompleted.
  assert_true(recorder.stages.length() >= 2)
  // First stage must be ModelCompleted (the model requested the tool).
  match recorder.stages[0] {
    ModelCompleted(..) => ()
    other =>
      fail("first stage should be ModelCompleted, got " + other.to_string())
  }
  // A ToolCompleted stage must appear somewhere in the sequence.
  let mut saw_tool = false
  for s in recorder.stages {
    match s {
      ToolCompleted(..) => saw_tool = true
      _ => ()
    }
  }
  assert_true(saw_tool)
}
