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
/// Read the parent thread id from a session's metadata. Returns `None` when
/// the key is absent or not a string.
pub fn Session::parent_thread_id(self : Session) -> String? {
  match self.metadata.get(PARENT_THREAD_ID_KEY) {
    Some(Json::String(s)) => Some(s)
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
  { messages: self.messages, metadata: new_metadata }
}

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
  /// Runtime configuration warning. Emitted when a setting change
  /// (model switch, reasoning_effort change, ...) conflicts with the active
  /// modelport's `ProviderConfig`. Posoco has already auto-corrected the
  /// config (reset the offending field); this event lets the product layer
  /// surface what happened to the user.
  ///
  /// `field` is the config field name (e.g. "reasoning_effort").
  /// `value` is the value the user tried to set.
  /// `reason` is a human-readable explanation including the modelport's
  /// accepted values.
  ConfigWarning(field~ : String, value~ : String, reason~ : String)
  /// A runtime config field changed value. Emitted by `Agent::update_model`
  /// / `Agent::update_reasoning_effort` (and by auto-resets after a
  /// `ConfigWarning`). Subscribers (cetas persistence, UI, ...) use this to
  /// stay in sync without polling.
  ///
  /// `old_value` is empty when the field was previously unset.
  /// `new_value` is empty when the field was reset to `None`.
  ConfigChanged(field~ : String, old_value~ : String, new_value~ : String)
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
    ConfigWarning(field~, value~, reason~) =>
      "ConfigWarning(field=\{field}, value=\{value}, reason=\{reason})"
    ConfigChanged(field~, old_value~, new_value~) =>
      "ConfigChanged(field=\{field}, \{old_value} → \{new_value})"
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
