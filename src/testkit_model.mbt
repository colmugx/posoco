// ---------------------------------------------------------------------------
// ScriptedModel — returns responses/errors/stream chunks by call sequence.
// ---------------------------------------------------------------------------

///|
/// A single scripted model interaction. R3 M3.7: each step produces a
/// `ModelCallResult` (the canonical chat return type) instead of the deleted
/// `ModelResponse`. `Stream` carries the chunk sequence plus the final
/// completion; chunks are emitted to the callback during the call.
pub(all) enum ScriptedModelStep {
  Respond(@kernel.ModelCallResult)
  Stream(
    chunks~ : Array[@types.StreamChunk],
    response~ : @kernel.ModelCallResult
  )
  StreamParked(chunks~ : Array[@types.StreamChunk])
  Fail(@error.ModelError)
  Compact(result~ : @kernel.CompactResult)
  CompactFail(error~ : @error.ModelError)
}

///|
fn testkit_snapshot_model_step(step : ScriptedModelStep) -> ScriptedModelStep {
  match step {
    Respond(result) => Respond(testkit_snapshot_model_call_result(result))
    Stream(chunks~, response~) =>
      Stream(
        chunks=chunks.copy(),
        response=testkit_snapshot_model_call_result(response),
      )
    StreamParked(chunks~) => StreamParked(chunks=chunks.copy())
    Fail(error) => Fail(error)
    Compact(result~) =>
      Compact(result={
        compacted_messages: snapshot_messages(result.compacted_messages),
        mode: result.mode,
      })
    CompactFail(error~) => CompactFail(error~)
  }
}

///|
fn testkit_is_chat_step(step : ScriptedModelStep) -> Bool {
  match step {
    Compact(_) | CompactFail(_) => false
    _ => true
  }
}

///|
fn testkit_is_compact_step(step : ScriptedModelStep) -> Bool {
  match step {
    Compact(_) | CompactFail(_) => true
    _ => false
  }
}

///|
/// ModelPort fake that plays a fixed script. Each `chat` call consumes one
/// chat step in order (`Compact`/`CompactFail` steps are skipped and left for
/// `compact` calls, which conversely skip chat steps). When the matching
/// script is exhausted the next call fails with
/// `ModelError::Transport("scripted_model_exhausted at call <N>")` — it never
/// silently repeats the last response.
pub(all) struct ScriptedModel {
  steps : Array[ScriptedModelStep]
  mut index : Int
  mut calls : Int
  received_messages : Array[Array[@kernel.Message]]
  received_tools : Array[Array[@kernel.ToolDef]]
  received_options : Array[@types.ChatOptions]
  received_chunks : Array[@types.StreamChunk]
  mut compact_calls : Int
  received_compacts : Array[(Array[@kernel.Message], @kernel.CompactTrigger)]
  mut parked_calls : Int
}

///|
pub fn ScriptedModel::ScriptedModel(
  steps : Array[ScriptedModelStep],
) -> ScriptedModel {
  {
    steps: steps.map(testkit_snapshot_model_step),
    index: 0,
    calls: 0,
    received_messages: [],
    received_tools: [],
    received_options: [],
    received_chunks: [],
    compact_calls: 0,
    received_compacts: [],
    parked_calls: 0,
  }
}

///|
/// Number of chat calls observed so far.
pub fn ScriptedModel::call_count(self : ScriptedModel) -> Int {
  self.calls
}

///|
pub fn ScriptedModel::compact_call_count(self : ScriptedModel) -> Int {
  self.compact_calls
}

///|
pub fn ScriptedModel::received_compacts(
  self : ScriptedModel,
) -> Array[(Array[@kernel.Message], @kernel.CompactTrigger)] {
  self.received_compacts.map(fn(entry) {
    let (messages, trigger) = entry
    (snapshot_messages(messages), trigger)
  })
}

///|
pub fn ScriptedModel::parked_calls(self : ScriptedModel) -> Int {
  self.parked_calls
}

///|
/// Fabricated `InvocationScope` for tests that drive a `ModelPort` directly
/// (no reducer in play, so `effect_id` is `None`).
pub fn tk_scope(
  session_id? : String = "tk_session",
  run_id? : String = "tk_run",
  pressure? : @kernel.ContextPressure? = None,
) -> @kernel.InvocationScope {
  {
    session_id: @kernel.SessionId::unchecked(session_id),
    run_id: @kernel.RunId::unchecked(run_id),
    effect_id: None,
    pressure,
  }
}

///|
/// Direct (non-trait) chat entry point for testkit self-tests.
/// Trait methods on concrete types must be dispatched through a `&ModelPort`
/// reference; this wrapper lets tests call chat without an Agent.
pub async fn ScriptedModel::chat_direct(
  self : ScriptedModel,
  messages : Array[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : @types.ChatOptions,
) -> @kernel.ModelCallResult raise @error.ModelError {
  (self as &@port.ModelPort).chat(
    tk_scope(),
    messages[:],
    tools,
    options,
    NoStream,
  )
}

///|
/// Snapshot of all chat options received, in call order.
pub fn ScriptedModel::options_received(
  self : ScriptedModel,
) -> Array[@types.ChatOptions] {
  self.received_options.copy()
}

///|
fn ScriptedModel::take_matching_step(
  self : ScriptedModel,
  pred : (ScriptedModelStep) -> Bool,
  kind : String,
) -> ScriptedModelStep raise @error.ModelError {
  while self.index < self.steps.length() {
    let step = self.steps[self.index]
    self.index = self.index + 1
    if pred(step) {
      return step
    }
  }
  raise Transport(
    "scripted_model_exhausted (\{kind}) at call \{self.calls + self.compact_calls} (script had \{self.steps.length()} steps)",
  )
}

///|
fn ScriptedModel::record_chat_call(
  self : ScriptedModel,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : @types.ChatOptions,
) -> Unit {
  self.calls = self.calls + 1
  self.received_messages.push(snapshot_messages(messages.to_owned()))
  self.received_tools.push(tools.map(testkit_snapshot_tool_def))
  self.received_options.push(options)
}

///|
pub impl @port.ModelPort for ScriptedModel with fn chat(
  self,
  _scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : @types.ChatOptions,
  stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  self.record_chat_call(messages, tools, options)
  match self.take_matching_step(testkit_is_chat_step, "chat") {
    Respond(result) => testkit_snapshot_model_call_result(result)
    Stream(chunks~, response~) => {
      match stream {
        Stream(cb) =>
          for chunk in chunks {
            self.received_chunks.push(chunk)
            cb(chunk)
          }
        NoStream => ()
      }
      testkit_snapshot_model_call_result(response)
    }
    StreamParked(chunks~) => {
      match stream {
        Stream(cb) =>
          for chunk in chunks {
            self.received_chunks.push(chunk)
            cb(chunk)
          }
        NoStream => ()
      }
      self.parked_calls = self.parked_calls + 1
      let mut parked = true
      while parked {
        let outcome : Result[Unit, Error] = Ok(@async.pause()) catch {
          e => Err(e)
        }
        let cancelled = match outcome {
          Err(_) => true
          Ok(_) => @async.is_being_cancelled()
        }
        if cancelled {
          parked = false
          raise Transport(
            "scripted parked stream aborted: cancelled mid-stream",
          )
        }
      }
      raise Transport("scripted parked stream resumed without cancellation")
    }
    Fail(e) => raise e
    Compact(result~) =>
      // Unreachable: take_matching_step filtered on testkit_is_chat_step.
      raise Transport(
        "scripted_model internal error: compact step reached chat (mode=\{result.mode.to_string()})",
      )
    CompactFail(error~) =>
      // Unreachable: take_matching_step filtered on testkit_is_chat_step.
      raise error
  }
}

///|
pub impl @port.ModelPort for ScriptedModel with fn compact(
  self,
  _scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  _options : @types.ChatOptions,
  trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  self.compact_calls = self.compact_calls + 1
  self.received_compacts.push((snapshot_messages(messages.to_owned()), trigger))
  match self.take_matching_step(testkit_is_compact_step, "compact") {
    Compact(result~) =>
      {
        compacted_messages: snapshot_messages(result.compacted_messages),
        mode: result.mode,
      }
    CompactFail(error~) => raise error
    // Unreachable: take_matching_step filtered on testkit_is_compact_step.
    _ =>
      raise Transport(
        "scripted_model internal error: chat step reached compact",
      )
  }
}

///|
/// ScriptedModel declares no supported reasoning_effort values. Tests that
/// need to exercise the ConfigWarning path on validation can construct a
/// custom model impl that returns a non-empty `ProviderConfig`.
pub impl @port.ModelPort for ScriptedModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}

// ---------------------------------------------------------------------------
// ScopeRecordingModel — records the InvocationScope of every model-side call.
// ---------------------------------------------------------------------------

///|
/// ModelPort fake that records the `InvocationScope` received by every
/// `chat`/`compact` call. Chat behaviour is scripted like `ScriptedModel`;
/// `compact` returns `compact_result` when set, otherwise raises
/// `ResponseParse` (same contract as `ScriptedModel`). Use it to pin the
/// scope-flow contract end to end.
pub struct ScopeRecordingModel {
  scripted : ScriptedModel
  compact_result : @kernel.CompactResult?
  chat_scopes : Array[@kernel.InvocationScope]
  compact_scopes : Array[@kernel.InvocationScope]
}

///|
pub fn ScopeRecordingModel::ScopeRecordingModel(
  steps : Array[ScriptedModelStep],
  compact_result? : @kernel.CompactResult,
) -> ScopeRecordingModel {
  {
    scripted: ScriptedModel(steps),
    compact_result,
    chat_scopes: [],
    compact_scopes: [],
  }
}

///|
/// Scopes observed by `chat`, in call order.
pub fn ScopeRecordingModel::chat_scopes(
  self : ScopeRecordingModel,
) -> Array[@kernel.InvocationScope] {
  self.chat_scopes.copy()
}

///|
/// Scopes observed by `compact`, in call order.
pub fn ScopeRecordingModel::compact_scopes(
  self : ScopeRecordingModel,
) -> Array[@kernel.InvocationScope] {
  self.compact_scopes.copy()
}

///|
pub impl @port.ModelPort for ScopeRecordingModel with fn chat(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : @types.ChatOptions,
  stream : @types.StreamMode,
) -> @kernel.ModelCallResult raise @error.ModelError {
  self.chat_scopes.push(scope)
  (self.scripted as &@port.ModelPort).chat(
    scope, messages, tools, options, stream,
  )
}

///|
pub impl @port.ModelPort for ScopeRecordingModel with fn compact(
  self,
  scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  self.compact_scopes.push(scope)
  match self.compact_result {
    Some(result) => result
    None => raise ResponseParse("ScopeRecordingModel has no compact_result")
  }
}

///|
pub impl @port.ModelPort for ScopeRecordingModel with fn provider_config(_self) -> @port.ProviderConfig {
  @port.ProviderConfig::empty()
}
