///|
/// PipelineHook.on_post_event real-time channel whitebox tests (BR-6/BR-7: the
/// former `Observer::on_kernel_event` effect-level channel was folded into
/// `PipelineHook::on_post_event`).
///
/// Verifies the pump fires each hook's `on_post_event(HookStage)`
/// immediately after every effect commits, in real time (not batched at
/// turn end like the session-level `Observer::on_event` channel).

// ──────────────────────────────────────────────────────────────────────────
// Test fixture: a PipelineHook that only overrides on_post_event.
// ──────────────────────────────────────────────────────────────────────────

///|
/// PipelineHook that records every HookStage delivered to `on_post_event`. Does NOT
/// override `before_model` / `before_tool` — the trait's default
/// implementations (pass-through / Approve) must be inherited cleanly, so
/// the turn proceeds exactly as if no hook were registered at those points.
struct EffectRecorder {
  stages : Array[@port.HookStage]
}

///|
pub impl @port.PipelineHook for EffectRecorder with fn on_post_event(
  self : EffectRecorder,
  stage : @port.HookStage,
) -> Unit {
  self.stages.push(stage)
}

// ──────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────

///|
/// A model-only turn fires exactly one `ModelCompleted` stage to every
/// registered hook's `on_post_event`. This is the real-time channel: the
/// hook sees the event as soon as the effect commits, not at turn end.
async test "hook_post_event/model_only_turn_fires_model_completed" {
  let host = FixtureHost([Ok(fixture_stop("hi"))], Map::from_array([]))
  let journal = InMemoryJournal()
  let recorder = EffectRecorder::{ stages: [] }
  let recorder_ref : &@port.PipelineHook = recorder as &@port.PipelineHook
  // Build a minimal config with the recorder as the sole hook.
  let mailbox_instance = ControlMailbox()
  let mailbox : &Mailbox = mailbox_instance as &Mailbox
  let host_ref : &@kernel_exec.HostRuntime = host as &@kernel_exec.HostRuntime
  let cfg : PuppetConfig = {
    host: host_ref,
    catalog: fixture_empty_catalog(),
    journal,
    contributors: [],
    subscribers: [],
    stream_chunks: None,
    hooks: [recorder_ref],
    max_iterations: Some(10),
    commands: [],
    session_store: None,
    mailbox,
  }
  let puppet = Puppet(cfg)
  match fixture_prompt(puppet, "hook_post_model") {
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
/// Both arrive in real time, in execution order. The inherited default
/// `before_tool` must approve the call unchanged, or the tool never runs.
async test "hook_post_event/tool_turn_fires_model_then_tool" {
  let host = FixtureHost(
    [
      Ok(fixture_tool_calls([fixture_call("echo", "one")])),
      Ok(fixture_stop("done")),
    ],
    Map::from_array([("one", Success(content="ok", structured=None))]),
  )
  let journal = InMemoryJournal()
  let recorder = EffectRecorder::{ stages: [] }
  let recorder_ref : &@port.PipelineHook = recorder as &@port.PipelineHook
  let mailbox_instance = ControlMailbox()
  let mailbox : &Mailbox = mailbox_instance as &Mailbox
  let host_ref : &@kernel_exec.HostRuntime = host as &@kernel_exec.HostRuntime
  let cfg : PuppetConfig = {
    host: host_ref,
    catalog: fixture_tool_catalog("echo"),
    journal,
    contributors: [],
    subscribers: [],
    stream_chunks: None,
    hooks: [recorder_ref],
    max_iterations: Some(10),
    commands: [],
    session_store: None,
    mailbox,
  }
  let puppet = Puppet(cfg)
  match fixture_prompt(puppet, "hook_post_tool") {
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
  // A ToolCompleted stage must appear somewhere in the sequence — proof
  // the default before_tool approved the call.
  let mut saw_tool = false
  for s in recorder.stages {
    match s {
      ToolCompleted(..) => saw_tool = true
      _ => ()
    }
  }
  assert_true(saw_tool)
}
