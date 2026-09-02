///|
/// Pure reducer for the functional Kernel (ADR §2.1, §2.2, §2.5).
///
/// This file is the SOLE arbiter of phase transitions. Given a RunState and
/// a RunInput, the reducer returns the next RunState, the effects the
/// executor should run next, and the domain events the interpreter should
/// publish. The reducer MUST NOT:
/// - import async, fs, http, time, or random
/// - import any host or provider trait
/// - import non-canonical product data — it works only on canonical domain
///   types
/// - mutate caller-owned arrays/maps
///
/// Purity is enforced by a boundary lint in T03/T09 acceptance.

///|
/// Result of a single `reduce(state, input)` call.
/// `next_state` is the new RunState, `effects` are effects to execute, `events` are domain events to publish.
/// Terminal events appear at most once per Run. Invariant violations become a typed `Terminal(Failed)` transition.
pub(all) struct ReduceOutput {
  next_state : RunState
  effects : Array[Effect]
  events : Array[KernelEvent]
} derive(Eq, Debug)

///|
/// Construct a ReduceOutput. Internal helper used by the reducer branches.
fn reduce_output(
  next_state : RunState,
  effects : Array[Effect],
  events : Array[KernelEvent],
) -> ReduceOutput {
  { next_state, effects, events, }
}

///|
pub fn ReduceOutput::next_state(self : ReduceOutput) -> RunState {
  self.next_state
}

///|
pub fn ReduceOutput::effects(self : ReduceOutput) -> Array[Effect] {
  self.effects.copy()
}

///|
pub fn ReduceOutput::events(self : ReduceOutput) -> Array[KernelEvent] {
  self.events.copy()
}

///|
pub impl Show for ReduceOutput with fn to_string(self : ReduceOutput) -> String {
  let effect_summaries = self.effects.map(fn(e) { e.to_string() })
  let event_summaries = self.events.map(fn(e) { e.to_string() })
  "ReduceOutput(state=\{self.next_state.to_string()}, effects=[\{effect_summaries.join(", ")}], events=[\{event_summaries.join(", ")}])"
}

///|
/// The reducer. Pure: same (state, input) → same (next_state, effects, events).
/// The catalog is passed separately because the RunState does not own it.
pub fn reduce(
  state : RunState,
  catalog : ToolCatalogSnapshot,
  input : RunInput,
) -> ReduceOutput raise KernelError {
  // Post-terminal rejection: any input after Terminal is a typed rejection.
  // The state is unchanged; no new terminal event is emitted; the
  // transcript is not mutated. (ADR §2.5 rule 1, §2.6 late-completion rule.)
  match state.phase() {
    Terminal => reduce_post_terminal(state, input)
    Initializing => reduce_initializing(state, catalog, input)
    ReadyForModel => reduce_ready_for_model(state, catalog, input)
    AwaitingModel => reduce_awaiting_model(state, catalog, input)
    AwaitingTools => reduce_awaiting_tools(state, catalog, input)
    Suspended => reduce_suspended(state, catalog, input)
  }
}

///|
/// Allocate the next event sequence number.
fn next_seq(state : RunState) -> EventSequence {
  state.next_event_sequence().next()
}

///|
fn advance_seq_by(state : RunState, n : Int) -> EventSequence {
  let mut s = state.next_event_sequence()
  for i = 0; i < n; i = i + 1 {
    s = s.next()
  }
  s
}

///|
fn EffectId::add(self : EffectId, n : Int) -> EffectId {
  let mut id = self
  for i = 0; i < n; i = i + 1 {
    id = id.next()
  }
  id
}
