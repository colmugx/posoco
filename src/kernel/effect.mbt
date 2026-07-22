///|
/// Effect declarations for the M1 functional Kernel (ADR §2.1, §2.5).
///
/// Effects are pure data — the reducer declares them, the stateless executor
/// executes ONE at a time. No effect payload ever carries a trait reference.
///
/// Each `Effect` carries its `effect_id` and the `model_step_id` it belongs
/// to; the executor returns a completion input that must match these.

// ──────────────────────────────────────────────────────────────────────────
// Effect payloads (per kind)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Payload for `Effect::CallModel`. The executor uses `catalog_version` to
/// re-derive the same definitions the model was prompted against; a stale
/// version returned by the executor would be a kernel invariant failure
/// detected at completion correlation.
pub(all) struct CallModelPayload {
  model_step_id : ModelStepId
  /// Read-only snapshot of the messages to send to the model. The executor
  /// must NOT mutate this array.
  messages : Array[CanonicalMessage]
  /// Catalog version this prompt was built against.
  catalog_version : CatalogVersion
  /// Opaque provider-call options (temperature, max_tokens, etc.) — carried
  /// verbatim from the host; the Kernel does not interpret them.
  call_options : Json
} derive(Eq, Debug)

///|
/// Payload for `Effect::ExecuteTool`. The executor looks up
/// `catalog_version`+`owner` in the runtime registry; if either is missing,
/// the executor returns a typed `ToolFailed` input carrying an
/// `InvariantCategory::MissingOwner`/`StaleSnapshot` (ADR §2.5).
pub(all) struct ExecuteToolPayload {
  model_step_id : ModelStepId
  call_id : CallId
  tool_name : ToolName
  /// Parsed arguments — already validated by the reducer as JSON-well-formed.
  /// Schema validation already passed (otherwise the reducer would have
  /// produced a `NotExecuted` outcome instead of declaring this effect).
  arguments : Json
  owner : OwnerId
  catalog_version : CatalogVersion
} derive(Eq, Debug)

///|
/// Payload for `Effect::CancelOutstanding`. Lists the effect ids the reducer
/// wants the executor to stop; the executor records a `CancelDisposition`
/// per id (M1 fakes report `Propagated`; real adapters in M3 may report
/// `NotPropagated`).
pub(all) struct CancelOutstandingPayload {
  /// Effect ids that should be cancelled. May be empty (the executor should
  /// still return `CancelAcked` for idempotency, ADR §2.5 rule 5).
  effect_ids : Array[EffectId]
  /// Why the cancel was issued. Mirrors the terminal CancelReason for
  /// observability — the reducer does not branch on this.
  reason : CancelReason
} derive(Eq, Debug)

// ──────────────────────────────────────────────────────────────────────────
// Effect ADT
// ──────────────────────────────────────────────────────────────────────────

///|
/// A single declared Effect. Each variant carries its own id and the
/// `model_step_id` it belongs to. The executor consumes exactly one Effect at
/// a time and returns exactly one completion Input (ADR §2.5).
///
/// `effect_id` is unique per Run and allocated by the reducer.
pub(all) enum Effect {
  CallModel(effect_id~ : EffectId, payload~ : CallModelPayload)
  ExecuteTool(effect_id~ : EffectId, payload~ : ExecuteToolPayload)
  CancelOutstanding(effect_id~ : EffectId, payload~ : CancelOutstandingPayload)
} derive(Eq, Debug)

///|
pub impl Show for Effect with fn to_string(self : Effect) -> String {
  match self {
    CallModel(effect_id~, payload~) =>
      "Effect::CallModel(\{effect_id.to_string()}, step=\{payload.model_step_id.to_string()}, catalog=\{payload.catalog_version.to_string()})"
    ExecuteTool(effect_id~, payload~) =>
      "Effect::ExecuteTool(\{effect_id.to_string()}, call=\{payload.call_id.to_string()}, tool=\{payload.tool_name.to_string()})"
    CancelOutstanding(effect_id~, payload~) =>
      "Effect::CancelOutstanding(\{effect_id.to_string()}, \{payload.effect_ids.length()} effects)"
  }
}

///|
pub fn Effect::effect_id(self : Effect) -> EffectId {
  match self {
    CallModel(effect_id~, ..) => effect_id
    ExecuteTool(effect_id~, ..) => effect_id
    CancelOutstanding(effect_id~, ..) => effect_id
  }
}

///|
pub fn Effect::model_step_id(self : Effect) -> ModelStepId? {
  match self {
    CallModel(payload~, ..) => Some(payload.model_step_id)
    ExecuteTool(payload~, ..) => Some(payload.model_step_id)
    CancelOutstanding(..) => None
  }
}
