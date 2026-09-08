///|
/// A conversation session. `messages` is the linear transcript this thread
/// owns; `metadata` is a free-form product-owned bag (used for lineage via
/// `parent_thread_id`, product-specific flags, anything posoco does not
/// interpret).
///
/// R3 M3.7: `messages` carries canonical `@kernel.Message` values directly.
/// There is no longer a legacy `@types.Message` form — the kernel ADT is the
/// single protocol.
pub(all) struct Session {
  messages : Array[@kernel.Message]
  metadata : Map[String, Json]
} derive(Eq, Debug)

///|
/// Metadata key under which a session's parent thread id is stored. Absent
/// for threads created via the `new` command (fresh, no parent). Present
/// when this session was forked from another thread (user-initiated
/// `/fork-here`) or compacted from another thread (modelport-driven compact
/// via `ModelPort::compact` returning `CompactMode::NewThread`).
///
/// Stored in `metadata` rather than a dedicated field so existing Session
/// construction sites continue to compile unchanged. Product code reads it
/// via `Session::parent_thread_id(session)`.
pub const PARENT_THREAD_ID_KEY = "posoco.parent_thread_id"

///|
pub const CONTEXT_STATE_METADATA_KEY = "posoco.context_state"

///|
pub(all) enum ContextReadingSource {
  Measured
  Estimated
  Unknown
} derive(Eq, Debug)

///|
pub impl Show for ContextReadingSource with fn to_string(
  self : ContextReadingSource,
) -> String {
  match self {
    Measured => "measured"
    Estimated => "estimated"
    Unknown => "unknown"
  }
}

///|
pub(all) struct ContextState {
  session_id : String
  model_id : String
  context_version : Int
  last_measured_tokens : Int?
  estimated_added_tokens : Int
  window_tokens : Int?
  compact_threshold : Double
  source : ContextReadingSource
  reading_message_count : Int
} derive(Eq, Debug)

///|
pub impl Show for ContextState with fn to_string(self : ContextState) -> String {
  let measured = match self.last_measured_tokens {
    Some(n) => n.to_string()
    None => "unknown"
  }
  "ContextState(session=\{self.session_id}, model=\{self.model_id}, version=\{self.context_version}, measured=\{measured}, estimated_added=\{self.estimated_added_tokens}, window=\{match self.window_tokens { Some(w) => w.to_string(); None => "unknown" }}, threshold=\{self.compact_threshold}, source=\{self.source.to_string()})"
}

///|
pub fn ContextState::to_metadata_json(self : ContextState) -> Json {
  Json::object(
    Map::from_array([
      ("session_id", Json::string(self.session_id)),
      ("model_id", Json::string(self.model_id)),
      ("context_version", Json::number(self.context_version.to_double())),
      (
        "last_measured_tokens",
        match self.last_measured_tokens {
          Some(n) => Json::number(n.to_double())
          None => Json::null()
        },
      ),
      (
        "estimated_added_tokens",
        Json::number(self.estimated_added_tokens.to_double()),
      ),
      (
        "window_tokens",
        match self.window_tokens {
          Some(n) => Json::number(n.to_double())
          None => Json::null()
        },
      ),
      ("compact_threshold", Json::number(self.compact_threshold)),
      ("source", Json::string(self.source.to_string())),
      (
        "reading_message_count",
        Json::number(self.reading_message_count.to_double()),
      ),
    ]),
  )
}

///|
pub fn ContextState::from_metadata(
  metadata : Map[String, Json],
) -> ContextState? {
  match metadata.get(CONTEXT_STATE_METADATA_KEY) {
    Some(Object(fields)) => {
      let session_id = match fields.get("session_id") {
        Some(String(s)) => s
        _ => return None
      }
      let model_id = match fields.get("model_id") {
        Some(String(s)) => s
        _ => return None
      }
      let context_version = match fields.get("context_version") {
        Some(Number(n, ..)) => n.to_int()
        _ => return None
      }
      let last_measured : Int? = match fields.get("last_measured_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      let estimated_added = match fields.get("estimated_added_tokens") {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
      let window : Int? = match fields.get("window_tokens") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      }
      let threshold = match fields.get("compact_threshold") {
        Some(Number(n, ..)) => n
        _ => return None
      }
      let source : ContextReadingSource = match fields.get("source") {
        Some(String(s)) =>
          match s {
            "measured" => Measured
            "estimated" => Estimated
            _ => Unknown
          }
        _ => Unknown
      }
      let reading_count = match fields.get("reading_message_count") {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
      Some({
        session_id,
        model_id,
        context_version,
        last_measured_tokens: last_measured,
        estimated_added_tokens: estimated_added,
        window_tokens: window,
        compact_threshold: threshold,
        source,
        reading_message_count: reading_count,
      })
    }
    _ => None
  }
}

///|
pub(all) struct CompactOutcome {
  final_session_id : String
  mode : @kernel.CompactMode
  messages_after : Int
} derive(Eq)

///|
/// Read the parent thread id from a session's metadata. Returns `None` when
/// the key is absent or not a string.
pub fn Session::parent_thread_id(self : Session) -> String? {
  match self.metadata.get(PARENT_THREAD_ID_KEY) {
    Some(String(s)) => Some(s)
    _ => None
  }
}

///|
/// Construct a Session with the given parent thread id recorded in its
/// metadata. Used by fork/compact handlers.
pub fn Session::with_parent_thread_id(
  self : Session,
  parent_thread_id : String,
) -> Session {
  let new_metadata : Map[String, Json] = self.metadata.copy()
  new_metadata[PARENT_THREAD_ID_KEY] = Json::string(parent_thread_id)
  { messages: self.messages, metadata: new_metadata, }
}

///|
/// Attribution identity of one emitted `TurnEvent` / `HookStage`: which
/// session and run the event belongs to. Projected from the committed event
/// envelope at the Agent boundary — never reconstructed by scanning a
/// transcript. Scope answers "which run does this belong to"; it does not
/// carry effect identity (`ToolCall.call_id` already correlates tool
/// events).
pub(all) struct EventScope {
  session_id : @kernel.SessionId
  run_id : @kernel.RunId
  turn_id : @kernel.TurnId
} derive(Eq, Debug)

///|
/// Turn lifecycle events observed via `Observer::on_event`. R3 M3.7: payload
/// types are now canonical kernel types (`ToolCall`, `ToolOutcome`,
/// `Message`, `Usage`). `is_error` on `ToolCallResult` is preserved for
/// legacy observer compatibility — it is derived from the `ToolOutcome`
/// variant (`is_failure`).
pub(all) enum TurnEvent {
  TurnStarted
  ToolCallPending(@kernel.ToolCall)
  ToolCallResult(
    call~ : @kernel.ToolCall,
    result~ : @kernel.ToolOutcome,
    is_error~ : Bool
  )
  ModelResponseReceived(message~ : @kernel.Message, usage~ : @kernel.Usage?)
  SessionRedirect(
    from~ : String,
    to~ : String,
    messages_before~ : Int,
    messages_after~ : Int
  )
  TurnCompleted
  TurnFailed(String)
  ToolCallDeferred(call~ : @kernel.ToolCall, reason~ : String)
  StreamChunkReceived(chunk~ : StreamChunk)
  /// Emitted when the buffered chunk queue overflowed and oldest chunks were
  /// dropped. `count` is the number of dropped `StreamChunkReceived` events.
  /// This event is synthesized by the chunk dispatcher and inserted before
  /// the next delivered chunk or terminal event so observers can detect loss.
  StreamChunksDropped(count~ : Int)
  /// Configuration warning emitted by an extension or product configuration
  /// flow when a requested setting cannot be applied. This event lets
  /// subscribers surface the warning without coupling to the configuration
  /// source.
  ///
  /// `field` identifies the configuration field, `value` is the requested
  /// value, and `reason` explains why it could not be applied.
  ConfigWarning(field~ : String, value~ : String, reason~ : String)
  /// Configuration change notification emitted by an extension or product
  /// configuration flow. Persistence, UI, and other subscribers use it to
  /// stay in sync without polling or coupling to the configuration source.
  ///
  /// `old_value` is empty when the field was previously unset.
  /// `new_value` is empty when the field was reset to `None`.
  ConfigChanged(field~ : String, old_value~ : String, new_value~ : String)
  ContextStateUpdated(state~ : ContextState)
  CompactStarted(trigger~ : String)
  CompactFinished(
    trigger~ : String,
    mode~ : String,
    final_session_id~ : String,
    messages_after~ : Int
  )
  OperationFinalized(operation~ : String, outcome~ : String, detail~ : String)
  Custom(source~ : String, label~ : String, data~ : Json)
} derive(Eq, Debug)

///|
pub impl Show for TurnEvent with fn to_string(self : TurnEvent) -> String {
  match self {
    TurnStarted => "TurnStarted"
    ToolCallPending(call) => "ToolCallPending(\{call.call_id.to_string()})"
    ToolCallResult(call~, is_error~, ..) =>
      "ToolCallResult(\{call.call_id.to_string()}, is_error=\{is_error})"
    ModelResponseReceived(..) => "ModelResponseReceived"
    SessionRedirect(from~, to~, ..) => "SessionRedirect(from:\{from}, to:\{to})"
    TurnCompleted => "TurnCompleted"
    TurnFailed(msg) => "TurnFailed(\{msg})"
    ToolCallDeferred(call~, reason~) =>
      "ToolCallDeferred(\{call.call_id.to_string()}, \{reason})"
    StreamChunkReceived(..) => "StreamChunkReceived"
    StreamChunksDropped(count~) => "StreamChunksDropped(count=\{count})"
    ConfigWarning(field~, value~, reason~) =>
      "ConfigWarning(field=\{field}, value=\{value}, reason=\{reason})"
    ConfigChanged(field~, old_value~, new_value~) =>
      "ConfigChanged(field=\{field}, \{old_value} → \{new_value})"
    ContextStateUpdated(state~) => "ContextStateUpdated(\{state.to_string()})"
    CompactStarted(trigger~) => "CompactStarted(trigger=\{trigger})"
    CompactFinished(trigger~, mode~, final_session_id~, messages_after~) =>
      "CompactFinished(trigger=\{trigger}, mode=\{mode}, session=\{final_session_id}, msgs=\{messages_after})"
    OperationFinalized(operation~, outcome~, detail~) =>
      "OperationFinalized(op=\{operation}, outcome=\{outcome}, detail=\{detail})"
    Custom(source~, label~, ..) => "Custom(source:\{source}, label:\{label})"
  }
}

///|
/// Return value of `Agent::run_turn`. R3 M3.7: payload types are canonical.
pub(all) struct TurnResult {
  message : @kernel.Message
  tool_results : Array[@kernel.ToolOutcome]
  final_session_id : String
} derive(Eq, Debug)
