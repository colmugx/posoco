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
  Fail(@error.ModelError)
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
    Fail(error) => Fail(error)
  }
}

///|
/// ModelPort fake that plays a fixed script. Each `chat` call consumes one
/// step in order. When the script is exhausted the next call fails with
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
  }
}

///|
/// Number of chat calls observed so far.
pub fn ScriptedModel::call_count(self : ScriptedModel) -> Int {
  self.calls
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
fn ScriptedModel::take_step(
  self : ScriptedModel,
  messages : ArrayView[@kernel.Message],
  tools : Array[@kernel.ToolDef],
  options : @types.ChatOptions,
) -> ScriptedModelStep raise @error.ModelError {
  self.calls = self.calls + 1
  self.received_messages.push(snapshot_messages(messages.to_owned()))
  self.received_tools.push(tools.map(testkit_snapshot_tool_def))
  self.received_options.push(options)
  if self.index < self.steps.length() {
    let step = self.steps[self.index]
    self.index = self.index + 1
    step
  } else {
    raise Transport(
      "scripted_model_exhausted at call \{self.calls} (script had \{self.steps.length()} steps)",
    )
  }
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
  match self.take_step(messages, tools, options) {
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
    Fail(e) => raise e
  }
}

///|
pub impl @port.ModelPort for ScriptedModel with fn compact(
  _self,
  _scope : @kernel.InvocationScope,
  _messages : ArrayView[@kernel.Message],
  _options : @types.ChatOptions,
  _trigger : @kernel.CompactTrigger,
) -> @kernel.CompactResult raise @error.ModelError {
  raise ResponseParse("ScriptedModel does not implement compact")
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
