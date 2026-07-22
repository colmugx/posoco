///|
/// RunContext, Budget, Deadline and Cancel contracts for the M1 functional
/// Kernel (ADR §2.5, §2.6, §2.9).
///
/// Key invariants:
/// - The reducer NEVER reads a clock. Deadlines are delivered as
///   `DeadlineReached` inputs; the reducer only compares its own budget
///   counters.
/// - Budget dimensions are `Int?` because the host may not configure every
///   dimension. Unknown usage is NEVER reported as 0 (ADR §2.9).
/// - Cancel is idempotent: the second `CancelRequested` after
///   `Terminal(Cancelled)` is a typed rejection, not a new terminal event.

// ──────────────────────────────────────────────────────────────────────────
// IDs — typed wrappers (open question Q6.1, recommended option applied)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Stable identifier for a single Run. The Kernel never constructs this; it is
/// supplied by the host in the `Start` input and carried through every state.
pub(all) struct RunId {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn RunId::new(value : String) -> Result[RunId, String] {
  if value == "" {
    Err("RunId must be non-empty")
  } else {
    Ok(RunId::{ value, })
  }
}

///|
pub fn RunId::unchecked(value : String) -> RunId {
  RunId::{ value, }
}

///|
pub fn RunId::to_string(self : RunId) -> String {
  self.value
}

///|
pub impl Show for RunId with fn to_string(self : RunId) -> String {
  "RunId(\{self.value})"
}

///|
/// Stable identifier for a session. Maps directly to the legacy
/// `SessionStore::load/save` id; the Kernel never opens the session itself,
/// it only carries the id for the executor/facade to use.
pub(all) struct SessionId {
  value : String
} derive(Eq, Hash, Debug)

///|
pub fn SessionId::new(value : String) -> Result[SessionId, String] {
  if value == "" {
    Err("SessionId must be non-empty")
  } else {
    Ok(SessionId::{ value, })
  }
}

///|
pub fn SessionId::unchecked(value : String) -> SessionId {
  SessionId::{ value, }
}

///|
pub fn SessionId::to_string(self : SessionId) -> String {
  self.value
}

///|
/// Identifier for a single model step within a Run. Monotonic per Run; the
/// reducer allocates these (the reducer is allowed to do arithmetic, just not
/// IO/time). Each `CallModel` effect carries the model-step id it belongs to.
pub(all) struct ModelStepId {
  value : Int
} derive(Eq, Debug)

///|
pub fn ModelStepId::first() -> ModelStepId {
  { value: 1 }
}

///|
pub fn ModelStepId::next(self : ModelStepId) -> ModelStepId {
  { value: self.value + 1 }
}

///|
pub fn ModelStepId::to_int(self : ModelStepId) -> Int {
  self.value
}

///|
pub impl Show for ModelStepId with fn to_string(self : ModelStepId) -> String {
  "ModelStepId(\{self.value})"
}

///|
/// Identifier for a single declared Effect. Monotonic per Run. Each completion
/// input must correlate to a pending effect with this id; a mismatch is
/// `InvariantViolation::StaleCorrelation`.
pub(all) struct EffectId {
  value : Int
} derive(Eq, Hash, Debug)

///|
pub fn EffectId::first() -> EffectId {
  { value: 1 }
}

///|
pub fn EffectId::next(self : EffectId) -> EffectId {
  { value: self.value + 1 }
}

///|
pub fn EffectId::to_int(self : EffectId) -> Int {
  self.value
}

///|
pub impl Show for EffectId with fn to_string(self : EffectId) -> String {
  "EffectId(\{self.value})"
}

// ──────────────────────────────────────────────────────────────────────────
// Event sequence
// ──────────────────────────────────────────────────────────────────────────

///|
/// Monotonic sequence counter for KernelEvents. The reducer allocates these.
/// EventEnvelopes (built by the Harness/Interpreter outside the reducer) carry
/// the sequence plus a wall-clock timestamp from an injected clock.
pub(all) struct EventSequence {
  value : Int
} derive(Eq, Debug)

///|
pub fn EventSequence::initial() -> EventSequence {
  { value: 0 }
}

///|
pub fn EventSequence::next(self : EventSequence) -> EventSequence {
  { value: self.value + 1 }
}

///|
pub fn EventSequence::to_int(self : EventSequence) -> Int {
  self.value
}

// ──────────────────────────────────────────────────────────────────────────
// Budget
// ──────────────────────────────────────────────────────────────────────────

///|
/// Budget dimensions tracked per Run (ADR §2.9). Each dimension is `Int?`:
/// `None` means "unbounded" (the host did not configure that limit). The
/// reducer increments the consumed counters as it declares effects.
///
/// Token accounting is a special case: `total_tokens_observed` only increases
/// when the model reports usage via `CanonicalUsage`. Unknown usage is never
/// reported as 0; the reducer refuses to terminate on a token budget whose
/// consumed amount is unknown.
pub(all) struct Budget {
  /// Configured limit. `None` = unbounded.
  max_model_steps : Int?
  /// Configured limit. `None` = unbounded.
  max_tool_rounds : Int?
  /// Configured limit. `None` = unbounded.
  max_tool_calls : Int?
  /// Configured limit. `None` = unbounded.
  max_total_tokens : Int?
} derive(Eq, Debug)

///|
/// Default budget: only `max_tool_rounds` is bounded (to a conservative 32 by
/// default — the legacy `AgentConfig.max_tool_rounds` was caller-supplied but
/// every existing caller set it). All other dimensions unbounded. Override
/// via `Budget::bounded`.
pub fn Budget::default_run() -> Budget {
  {
    max_model_steps: None,
    max_tool_rounds: Some(32),
    max_tool_calls: None,
    max_total_tokens: None,
  }
}

///|
/// Build a fully-bounded budget.
pub fn Budget::bounded(
  max_model_steps~ : Int,
  max_tool_rounds~ : Int,
  max_tool_calls~ : Int,
  max_total_tokens~ : Int,
) -> Budget {
  {
    max_model_steps: Some(max_model_steps),
    max_tool_rounds: Some(max_tool_rounds),
    max_tool_calls: Some(max_tool_calls),
    max_total_tokens: Some(max_total_tokens),
  }
}

///|
/// Build a budget that mirrors the legacy `AgentConfig`. The legacy config had
/// no token / step / call limits, so those dimensions stay unbounded.
pub fn Budget::from_legacy_rounds(max_tool_rounds : Int) -> Budget {
  {
    max_model_steps: None,
    max_tool_rounds: Some(max_tool_rounds),
    max_tool_calls: None,
    max_total_tokens: None,
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Budget consumption (incremental counters kept by RunState)
// ──────────────────────────────────────────────────────────────────────────

///|
/// Per-Run consumed counters. The reducer increments these as it declares
/// effects. Each counter is `Int` (never optional) because "nothing consumed
/// yet" is just `0`.
pub(all) struct BudgetConsumed {
  /// Number of `CallModel` effects declared so far.
  model_steps : Int
  /// Number of tool batches (a model completion with N tool calls = 1 round).
  tool_rounds : Int
  /// Number of `ExecuteTool` effects declared so far.
  tool_calls : Int
  /// Sum of observed `CanonicalUsage.total_tokens`, where the model reported
  /// it. Stays at 0 while usage is unknown — and the reducer must NOT
  /// terminate a `max_total_tokens` budget when the consumption is unverified.
  observed_total_tokens : Int
  /// Whether any model step in this Run reported verified token usage. Used to
  /// guard against terminating on a token budget the reducer cannot measure.
  any_usage_verified : Bool
} derive(Eq, Debug)

///|
pub fn BudgetConsumed::zero() -> BudgetConsumed {
  {
    model_steps: 0,
    tool_rounds: 0,
    tool_calls: 0,
    observed_total_tokens: 0,
    any_usage_verified: false,
  }
}

///|
/// Returns the dimension that is now exceeded (if any) after this consumption.
/// Returns `None` if every dimension still has headroom. If a token budget
/// exists but no usage has ever been verified, the token dimension is reported
/// as `BudgetState::UnknownUsage` and the reducer must NOT terminate on it.
pub fn BudgetConsumed::exceeded(
  self : BudgetConsumed,
  limit : Budget,
) -> BudgetState {
  let check = fn(consumed : Int, max_opt : Int?) -> Bool {
    match max_opt {
      Some(max) => consumed >= max
      None => false
    }
  }
  if check(self.model_steps, limit.max_model_steps) {
    return Exceeded(BudgetDimension::ModelSteps)
  }
  if check(self.tool_rounds, limit.max_tool_rounds) {
    return Exceeded(BudgetDimension::ToolRounds)
  }
  if check(self.tool_calls, limit.max_tool_calls) {
    return Exceeded(BudgetDimension::ToolCalls)
  }
  match limit.max_total_tokens {
    Some(_) if !self.any_usage_verified =>
      UnknownUsage(BudgetDimension::TotalTokens)
    Some(max) if self.observed_total_tokens >= max =>
      Exceeded(BudgetDimension::TotalTokens)
    _ => WithinBudget
  }
}

///|
pub enum BudgetState {
  WithinBudget
  Exceeded(BudgetDimension)
  /// A budget dimension exists but the reducer has no verified observation to
  /// compare against. The reducer MUST NOT terminate the Run on this; it can
  /// only continue and hope usage arrives, or let a different dimension
  /// exhaust.
  UnknownUsage(BudgetDimension)
} derive(Eq, Debug)

///|
pub impl Show for BudgetState with fn to_string(self : BudgetState) -> String {
  match self {
    WithinBudget => "WithinBudget"
    Exceeded(d) => "Exceeded(\{d.to_string()})"
    UnknownUsage(d) => "UnknownUsage(\{d.to_string()})"
  }
}

///|
pub(all) enum BudgetDimension {
  ModelSteps
  ToolRounds
  ToolCalls
  TotalTokens
} derive(Eq, Debug)

///|
pub impl Show for BudgetDimension with fn to_string(self : BudgetDimension) -> String {
  match self {
    ModelSteps => "max_model_steps"
    ToolRounds => "max_tool_rounds"
    ToolCalls => "max_tool_calls"
    TotalTokens => "max_total_tokens"
  }
}

// ──────────────────────────────────────────────────────────────────────────
// RunContext — the immutable host-supplied input bundle
// ──────────────────────────────────────────────────────────────────────────

///|
/// Immutable runtime context for a single Run (ADR §2.9). Carried by RunState
/// but never mutated. The reducer reads from this for budget/limit checks; it
/// does NOT read a clock.
///
/// Product layers (TUI, session backend, MCP, extension host) MUST NOT appear
/// here — Kernel boundary.
pub(all) struct RunContext {
  run_id : RunId
  session_id : SessionId
  budget : Budget
} derive(Eq, Debug)

///|
pub fn RunContext::new(
  run_id~ : RunId,
  session_id~ : SessionId,
  budget~ : Budget,
) -> RunContext {
  { run_id, session_id, budget }
}

// ──────────────────────────────────────────────────────────────────────────
// Cancel reasons
// ──────────────────────────────────────────────────────────────────────────

///|
/// Why a Run was cancelled. Carried by the terminal `Cancelled` outcome.
pub(all) enum CancelReason {
  /// Host explicitly cancelled via `CancelRequested`.
  HostRequested(detail~ : String?)
  /// Adapter/host observed the deadline and the reducer delivered the cancel.
  DeadlineReached
} derive(Eq, Debug)

///|
pub impl Show for CancelReason with fn to_string(self : CancelReason) -> String {
  match self {
    HostRequested(detail~) => "HostRequested(\{detail_or_empty(detail)})"
    DeadlineReached => "DeadlineReached"
  }
}

///|
fn detail_or_empty(detail : String?) -> String {
  match detail {
    Some(s) => s
    None => ""
  }
}

// ──────────────────────────────────────────────────────────────────────────
// Cancel disposition — recorded by the scripted executor for M1 conformance
// ──────────────────────────────────────────────────────────────────────────

///|
/// What the scripted executor recorded about a `CancelOutstanding` effect.
/// Real adapter propagation is M3; in M1 the executor always reports
/// `Propagated` against the in-memory scripted fakes and `NotPropagated` only
/// when the bound adapter declares it cannot cancel (used by adapter-hardening
/// tests). The reducer never blocks on this — termination is decided by
/// inputs.
pub(all) enum CancelDisposition {
  /// The underlying operation was observable cancelled (fake: immediately).
  Propagated
  /// The adapter cannot cancel the underlying HTTP/process; the cancel only
  /// stops the reducer waiting for completion.
  NotPropagated
  /// The adapter has not declared its capability yet. Real adapters in M3
  /// must not emit this for production code paths.
  Unknown
} derive(Eq, Debug)

///|
pub impl Show for CancelDisposition with fn to_string(self : CancelDisposition) -> String {
  match self {
    Propagated => "Propagated"
    NotPropagated => "NotPropagated"
    Unknown => "Unknown"
  }
}
