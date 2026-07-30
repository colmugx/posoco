///|
/// M3.5 — Pump fork / compact safe-point integration tests.
///
/// These exercise the actual pump loop with a ControlMailbox carrying
/// fork/compact signals. The signal is enqueued from inside the running
/// turn (via `M35Host.on_first_call`) because `prompt()` calls
/// `bind_run`, which rebuilds the queues — pre-prompt enqueues would be
/// dropped. This mirrors the production flow: the product layer calls
/// `CommandPort.invoke("/compact")` while a turn is in flight.

// ──────────────────────────────────────────────────────────────────────────
// Test fixtures — a model host that returns scripted responses AND a
// session store that records every save.
// ──────────────────────────────────────────────────────────────────────────

///|
/// Scripted host: returns a queue of completions on each model call. The
/// host also implements compact with a fixed strategy chosen at construction
/// time so we can exercise Replace / NewThread / Append branches.
///
/// `on_first_call` is an optional hook fired the first time `call_model`
/// runs. Tests use it to enqueue fork/compact signals into the Puppet's
/// mailbox from inside the running turn — this is the only way to enqueue
/// a signal after `prompt()` has bound the mailbox (bind_run clears the
/// queues, so pre-prompt enqueues are dropped).
pub struct M35Host {
  responses : Array[Completion]
  mut resp_index : Int
  compact_strategy : @kernel.CompactMode
  compacted_body : Array[@kernel.Message]
  mut on_first_call : ((M35Host) -> Unit)?
}

///|
pub fn M35Host::M35Host(
  responses : Array[Completion],
  compact_strategy : @kernel.CompactMode,
  compacted_body : Array[@kernel.Message],
) -> M35Host {
  {
    responses,
    resp_index: 0,
    compact_strategy,
    compacted_body,
    on_first_call: None,
  }
}

///|
pub impl @kernel.HostRuntime for M35Host with fn call_model(
  self : M35Host,
  messages : Array[Message],
  _tool_definitions : Array[ToolDef],
  _call_options : Json,
  _on_chunk : @kernel.HostChunkCallback?,
) -> Result[ModelCallResult, ModelFailure] {
  // Fire the enqueue hook the first time we are called. The mailbox is
  // now bound (prompt() did Step 3 before driving the pump), so the
  // enqueue will succeed and the pump will pick it up at the next safe
  // point.
  match self.on_first_call {
    Some(hook) => {
      hook(self)
      self.on_first_call = None
    }
    None => ()
  }
  let completion = if self.resp_index < self.responses.length() {
    let c = self.responses[self.resp_index]
    self.resp_index = self.resp_index + 1
    c
  } else {
    fixture_stop("(no more responses)")
  }
  Ok({ completion, processed_messages: messages })
}

///|
pub impl @kernel.HostRuntime for M35Host with fn execute_tool(
  self : M35Host,
  _owner_id : OwnerId,
  _call_id : CallId,
  _tool_name : ToolName,
  _arguments : Json,
) -> ToolOutcome {
  ignore(self)
  // M35Host returns Success for any tool so the pump can loop back to
  // the top of drive_run, where the fork/compact safe-points fire. The
  // tests do not care about the tool body; they only need the pump to
  // complete a tool batch and re-enter the loop.
  Success(content="ok", structured=None)
}

///|
pub impl @kernel.HostRuntime for M35Host with fn cancel_effects(
  self : M35Host,
  effect_ids : Array[EffectId],
  _reason : CancelReason,
) -> Array[(EffectId, CancelDisposition)] {
  ignore(self)
  effect_ids.map(id => (id, NotPropagated))
}

///|
pub impl @kernel.HostRuntime for M35Host with fn compact(
  self : M35Host,
  _messages : Array[Message],
  _call_options : Json,
  _trigger : @kernel.CompactTrigger,
) -> Result[CompactResult, ModelFailure] {
  Ok({
    compacted_messages: self.compacted_body.copy(),
    mode: self.compact_strategy,
  })
}

///|
/// Recording session store — keeps every save by id so tests can assert
/// on what got persisted. Used to verify fork lineage and NewThread
/// compact lineage.
pub struct RecordingSessionStore {
  saved : Map[String, @types.Session]
}

///|
pub fn RecordingSessionStore::RecordingSessionStore() -> RecordingSessionStore {
  { saved: Map::from_array([]) }
}

///|
pub fn RecordingSessionStore::get(
  self : RecordingSessionStore,
  id : String,
) -> @types.Session? {
  match self.saved.get(id) {
    Some(s) => Some(s)
    None => None
  }
}

///|
pub impl @port.SessionStore for RecordingSessionStore with fn load(
  self : RecordingSessionStore,
  id : String,
) -> @types.Session raise @error.SessionError {
  match self.saved.get(id) {
    Some(s) => {
      let snapshot : @types.Session = {
        messages: s.messages.copy(),
        metadata: s.metadata.copy(),
      }
      snapshot
    }
    None =>
      raise @error.SessionError::Load(
        "RecordingSessionStore: id '" + id + "' not found",
      )
  }
}

///|
pub impl @port.SessionStore for RecordingSessionStore with fn save(
  self : RecordingSessionStore,
  id : String,
  session : @types.Session,
) -> Unit raise @error.SessionError {
  self.saved[id] = {
    messages: session.messages.copy(),
    metadata: session.metadata.copy(),
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Config builder that wires M35Host + RecordingSessionStore
// ──────────────────────────────────────────────────────────────────────────

///|
fn m35_config(
  host : M35Host,
  catalog : ToolCatalogSnapshot,
  store : &@port.SessionStore?,
  context_window : Int?,
  compact_threshold : Double,
) -> PuppetConfig {
  let host_ref : &@kernel.HostRuntime = host as &@kernel.HostRuntime
  // D1: fresh mailbox per config. Tests inject signals via
  // `puppet.mailbox().enqueue_fork/compact(...)` after construction —
  // that accessor returns the same &Mailbox the pump reads at its safe
  // points, so the signal reaches the pump.
  let mailbox_instance = ControlMailbox()
  let mailbox : &Mailbox = mailbox_instance as &Mailbox
  {
    host: host_ref,
    model_id: "m35-host",
    catalog,
    journal: InMemoryJournal(),
    contributors: [],
    subscribers: [],
    observers: [],
    lifecycle_nodes: [],
    stream_chunks: None,
    call_options: Json::null(),
    pre_model_hooks: [],
    pre_tool_hooks: [],
    post_event_hooks: [],
    default_budget: Budget::default_run(),
    max_iterations: 10,
    commands: [],
    session_store: store,
    context_window,
    compact_threshold,
    mailbox,
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Tests — each one wires `host.on_first_call` to enqueue a signal after
// `prompt()` has bound the mailbox.
// ──────────────────────────────────────────────────────────────────────────

///|
/// Helper: a one-tool-call completion that lets the pump loop back to
/// the top of drive_run (so the fork/compact safe-point fires on the
/// next iteration). The tool name must match a tool registered in the
/// catalog so the reducer declares an ExecuteTool effect.
fn m35_tool_call_response() -> Completion {
  Completion(
    content=[Text("calling-tool")],
    tool_calls=[
      {
        call_id: CallId::unchecked("m35_call"),
        name: ToolName::unchecked("m35_tool"),
        arguments: Json::object(Map::from_array([])),
      },
    ],
    reasoning=None,
    finish_reason=ToolCalls,
    usage=None,
  )
}

///|
/// Helper: one-tool catalog for m35 tests so the reducer accepts the
/// tool call.
fn m35_catalog() -> ToolCatalogSnapshot raise CatalogCompositionError {
  let schema = Json::object(
    Map::from_array([
      ("type", Json::string("object")),
      ("properties", Json::object(Map::from_array([]))),
    ]),
  )
  let builder = ToolCatalogBuilder()
  ignore(
    builder.add(
      ToolDef(
        name=ToolName::unchecked("m35_tool"),
        description="m35 test tool",
        input_schema=schema,
        owner=OwnerId::unchecked("m35"),
        policy=Parallel,
        provenance=Some("m35"),
      ),
    ),
  )
  builder.finish(version=CatalogVersion(1))
}

// ──────────────────────────────────────────────────────────────────────────
// Tests — each one wires `host.on_first_call` to enqueue a signal after
// `prompt()` has bound the mailbox.
// ──────────────────────────────────────────────────────────────────────────

///|
/// Fork signal enqueued from inside the first model call: the pump
/// consumes it on the next iteration's safe point (after the tool batch
/// commits) and returns ForkCompleted with the snapshot's first N
/// messages. The session_store sees one new save carrying the parent's
/// session id as lineage.
async test "m35_pump/fork_at_index_creates_new_session_with_lineage" {
  let host = M35Host(
    [m35_tool_call_response(), fixture_stop("after-fork")],
    Replace,
    [],
  )
  let store = RecordingSessionStore()
  let store_ref : &@port.SessionStore? = Some(store)
  let cfg = m35_config(host, m35_catalog(), store_ref, None, 0.9)
  let puppet = Puppet(cfg)
  // Wire the host to enqueue a fork at index 1 on its first call. The
  // mailbox is bound by prompt() before the first model call fires.
  host.on_first_call = Some(_ => {
    let _ = puppet
      .mailbox()
      .enqueue_fork({
        command_id: CommandId::unchecked("fk_test_1"),
        target_run_id: RunId::unchecked("run_fork_1"),
        target_turn_id: TurnId::unchecked("turn_fork_1"),
        fork_index: 1,
      })
  })
  let result = puppet.prompt(
    RunId::unchecked("run_fork_1"),
    TurnId::unchecked("turn_fork_1"),
    SessionId::unchecked("session_origin"),
    [
      SystemMessage(content=[Text("system")]),
      UserMessage(content=[Text("hello")]),
    ],
    "op_fork_1",
  )
  match result {
    ForkCompleted(parent_session_id~, new_session_id~, forked_messages~, ..) => {
      assert_eq(parent_session_id, "session_origin")
      assert_true(new_session_id.contains("fork_"))
      // fork_index=1 on a transcript of [SystemMessage, UserMessage,
      // AssistantMessage(tool_call), ToolMessage] keeps the first 1
      // message (the SystemMessage).
      assert_true(forked_messages.length() >= 1)
      // Verify the session_store saw the new session with lineage.
      match store.get(new_session_id) {
        Some(saved) =>
          match saved.parent_thread_id() {
            Some(parent) => assert_eq(parent, "session_origin")
            None => fail("expected parent_thread_id lineage")
          }
        None => fail("expected new session in store")
      }
    }
    other => fail("expected ForkCompleted, got " + other.to_string())
  }
}

///|
/// Fork with no session_store configured: pump still returns
/// ForkCompleted; nothing is persisted (no panic).
async test "m35_pump/fork_without_session_store_returns_completed" {
  let host = M35Host(
    [m35_tool_call_response(), fixture_stop("after-fork")],
    Replace,
    [],
  )
  let cfg = m35_config(host, m35_catalog(), None, None, 0.9)
  let puppet = Puppet(cfg)
  host.on_first_call = Some(_ => {
    let _ = puppet
      .mailbox()
      .enqueue_fork({
        command_id: CommandId::unchecked("fk_no_store"),
        target_run_id: RunId::unchecked("run_fork_ns"),
        target_turn_id: TurnId::unchecked("turn_fork_ns"),
        fork_index: 0,
      })
  })
  let result = puppet.prompt(
    RunId::unchecked("run_fork_ns"),
    TurnId::unchecked("turn_fork_ns"),
    SessionId::unchecked("session_ns"),
    [UserMessage(content=[Text("hi")])],
    "op_fork_ns",
  )
  assert_true(result is ForkCompleted(..))
}

///|
/// Fork index out of range clamps to [0, length]: index=99 forks the
/// entire transcript.
async test "m35_pump/fork_index_clamps_to_length" {
  let host = M35Host(
    [m35_tool_call_response(), fixture_stop("after-fork")],
    Replace,
    [],
  )
  let cfg = m35_config(host, m35_catalog(), None, None, 0.9)
  let puppet = Puppet(cfg)
  host.on_first_call = Some(_ => {
    let _ = puppet
      .mailbox()
      .enqueue_fork({
        command_id: CommandId::unchecked("fk_clamp"),
        target_run_id: RunId::unchecked("run_clamp"),
        target_turn_id: TurnId::unchecked("turn_clamp"),
        fork_index: 99,
      })
  })
  let result = puppet.prompt(
    RunId::unchecked("run_clamp"),
    TurnId::unchecked("turn_clamp"),
    SessionId::unchecked("session_clamp"),
    [
      SystemMessage(content=[Text("sys")]),
      UserMessage(content=[Text("u1")]),
      UserMessage(content=[Text("u2")]),
    ],
    "op_clamp",
  )
  match result {
    ForkCompleted(forked_messages~, ..) =>
      // Index 99 clamps to the transcript length: includes the initial
      // 3 messages + the assistant tool-call + the tool result.
      assert_true(forked_messages.length() >= 3)
    other => fail("expected ForkCompleted, got " + other.to_string())
  }
}

///|
/// Manual compact (Replace mode) replaces the transcript body in place
/// and the run continues. The pump's last_completed_transcript carries
/// the compacted body.
async test "m35_pump/manual_compact_replace_updates_transcript" {
  let compacted : Array[@kernel.Message] = [
    SystemMessage(content=[Text("sys")]),
    UserMessage(content=[Text("compacted-summary")]),
  ]
  let host = M35Host(
    [m35_tool_call_response(), fixture_stop("after-compact")],
    Replace,
    compacted,
  )
  let cfg = m35_config(host, m35_catalog(), None, None, 0.9)
  let puppet = Puppet(cfg)
  host.on_first_call = Some(_ => {
    let _ = puppet
      .mailbox()
      .enqueue_compact({
        command_id: CommandId::unchecked("cm_replace"),
        target_run_id: RunId::unchecked("run_cm_r"),
        target_turn_id: TurnId::unchecked("turn_cm_r"),
        trigger: @kernel.Manual,
      })
  })
  let result = puppet.prompt(
    RunId::unchecked("run_cm_r"),
    TurnId::unchecked("turn_cm_r"),
    SessionId::unchecked("session_cm_r"),
    [UserMessage(content=[Text("original")])],
    "op_cm_r",
  )
  // Replace mode → run continues to terminal Accepted. The final
  // transcript carries the compacted body plus the post-compact
  // assistant response.
  assert_true(result is Accepted(..))
  match puppet.last_completed_transcript() {
    Some(t) => {
      let msgs = t.messages_snapshot()
      let has_summary = msgs
        .iter()
        .any(m => {
          match m {
            UserMessage(content~) =>
              content
              .iter()
              .any(c => {
                match c {
                  Text(t) => t == "compacted-summary"
                  _ => false
                }
              })
            _ => false
          }
        })
      assert_true(has_summary)
    }
    None => fail("expected a terminal transcript")
  }
}

///|
/// Manual compact (NewThread mode) writes a new session to the store
/// and returns CompactCompleted with new_session_id = Some(...).
async test "m35_pump/manual_compact_new_thread_creates_session" {
  let compacted : Array[@kernel.Message] = [
    SystemMessage(content=[Text("sys")]),
    UserMessage(content=[Text("summary")]),
  ]
  let host = M35Host(
    [m35_tool_call_response(), fixture_stop("ignored")],
    NewThread,
    compacted,
  )
  let store = RecordingSessionStore()
  let store_ref : &@port.SessionStore? = Some(store)
  let cfg = m35_config(host, m35_catalog(), store_ref, None, 0.9)
  let puppet = Puppet(cfg)
  host.on_first_call = Some(_ => {
    let _ = puppet
      .mailbox()
      .enqueue_compact({
        command_id: CommandId::unchecked("cm_nt"),
        target_run_id: RunId::unchecked("run_cm_nt"),
        target_turn_id: TurnId::unchecked("turn_cm_nt"),
        trigger: @kernel.Manual,
      })
  })
  let result = puppet.prompt(
    RunId::unchecked("run_cm_nt"),
    TurnId::unchecked("turn_cm_nt"),
    SessionId::unchecked("session_origin_nt"),
    [UserMessage(content=[Text("original")])],
    "op_cm_nt",
  )
  match result {
    CompactCompleted(mode~, new_session_id~, ..) => {
      assert_true(mode == @kernel.NewThread)
      match new_session_id {
        Some(new_sid) =>
          match store.get(new_sid) {
            Some(saved) =>
              match saved.parent_thread_id() {
                Some(p) => assert_eq(p, "session_origin_nt")
                None => fail("expected parent_thread_id lineage")
              }
            None => fail("expected new session in store")
          }
        None => fail("expected Some(new_session_id) for NewThread mode")
      }
    }
    other => fail("expected CompactCompleted, got " + other.to_string())
  }
}

///|
/// Auto-compact fires when observed_total_tokens crosses the threshold.
/// The first model response reports usage with total_tokens=110 AND
/// asks for a tool call so the pump loops back to ReadyForModel. With
/// context_window=100 and threshold=0.9, the trigger point is 90; the
/// first response reports 110 → auto compact fires in the next
/// ReadyForModel branch. With Replace strategy, the transcript is
/// rebuilt from the compacted body.
async test "m35_pump/auto_compact_fires_on_threshold_cross" {
  let response_with_usage : Completion = Completion(
    content=[Text("response")],
    tool_calls=[
      {
        call_id: CallId::unchecked("auto_call"),
        name: ToolName::unchecked("m35_tool"),
        arguments: Json::object(Map::from_array([])),
      },
    ],
    reasoning=None,
    finish_reason=ToolCalls,
    usage=Some({
      input_tokens: Some(50),
      output_tokens: Some(60),
      total_tokens: Some(110),
    }),
  )
  let compacted : Array[@kernel.Message] = [
    SystemMessage(content=[Text("sys")]),
    UserMessage(content=[Text("auto-summary")]),
  ]
  let host = M35Host(
    [response_with_usage, fixture_stop("done")],
    Replace,
    compacted,
  )
  let cfg = m35_config(host, m35_catalog(), None, Some(100), 0.9)
  let puppet = Puppet(cfg)
  // No on_first_call hook — auto compact does not need an explicit
  // signal. The pump observes the high token usage on the first
  // response and triggers compact itself.
  let result = puppet.prompt(
    RunId::unchecked("run_auto"),
    TurnId::unchecked("turn_auto"),
    SessionId::unchecked("session_auto"),
    [UserMessage(content=[Text("hi")])],
    "op_auto",
  )
  assert_true(result is Accepted(..))
  // After auto compact (Replace) + second model call, the transcript
  // contains the compacted body and the second assistant stop.
  match puppet.last_completed_transcript() {
    Some(t) => {
      let msgs = t.messages_snapshot()
      let has_auto_summary = msgs
        .iter()
        .any(m => {
          match m {
            UserMessage(content~) =>
              content
              .iter()
              .any(c => {
                match c {
                  Text(t) => t == "auto-summary"
                  _ => false
                }
              })
            _ => false
          }
        })
      assert_true(has_auto_summary)
    }
    None => fail("expected a terminal transcript")
  }
}
