///|
pub(all) enum Phase {
  Initializing
  ReadyForModel
  AwaitingModel
  AwaitingTools
  Suspended
  Terminal
}

///|
pub(all) enum EffectTag {
  CallModel
  ExecuteTool
  CancelOutstanding
}

///|
pub(all) enum EventTag {
  NonTerminalEvent
  RunCompleted
  RunFailed
  RunCancelled
}

///|
pub(all) enum TransitionKind {
  StartRun
  StartModelCall
  CompleteModelFinal
  CompleteModelWithTools(Int32)
  CompleteModelSteer
  CompleteToolPartial
  CompleteToolWaveDone
  SuspendFromModel
  ResumeToReady
  CancelRun
  FailRun
}

///|
pub(all) struct PhaseState {
  phase : Phase
  pending_model : Int32
  pending_tools : Int32
  has_outcome : Bool
  has_suspension : Bool
  model_step_id : Int32
  event_seq : Int32
}

///|
pub(all) struct StepResult {
  state : PhaseState
  emitted_non_terminal : Int32
  emitted_terminal : Int32
  terminal_event : EventTag?
}

///|
pub fn check_phase_inv(
  s : PhaseState,
) -> Bool where {
  proof_ensure: result => result == phase_inv(s),
} {
  s.model_step_id >= 0 &&
  s.event_seq >= 0 &&
  (match s.phase {
    Initializing =>
      s.pending_model == 0 &&
      s.pending_tools == 0 &&
      !s.has_outcome &&
      !s.has_suspension &&
      s.model_step_id == 0
    ReadyForModel =>
      s.pending_model == 0 &&
      s.pending_tools == 0 &&
      !s.has_outcome &&
      !s.has_suspension &&
      s.model_step_id >= 1
    AwaitingModel =>
      s.pending_model == 1 &&
      s.pending_tools == 0 &&
      !s.has_outcome &&
      !s.has_suspension &&
      s.model_step_id >= 1
    AwaitingTools =>
      s.pending_model == 0 &&
      s.pending_tools >= 1 &&
      !s.has_outcome &&
      !s.has_suspension &&
      s.model_step_id >= 1
    Suspended =>
      s.pending_model == 0 &&
      s.pending_tools == 0 &&
      !s.has_outcome &&
      s.has_suspension &&
      s.model_step_id >= 1
    Terminal =>
      s.pending_model == 0 &&
      s.pending_tools == 0 &&
      s.has_outcome &&
      !s.has_suspension
  })
}

///|
pub fn phase_initial() -> PhaseState where {
  proof_ensure: result => {
    phase_inv(result) &&
    is_initializing(result.phase) &&
    result.model_step_id == 0 &&
    result.event_seq == 0
  },
} {
  {
    phase: Initializing,
    pending_model: 0,
    pending_tools: 0,
    has_outcome: false,
    has_suspension: false,
    model_step_id: 0,
    event_seq: 0,
  }
}

///|
fn mk_reject(
  state : PhaseState,
) -> StepResult where {
  proof_require: phase_inv(state) && state.event_seq < 2_147_483_645,
  proof_ensure: result => step_post(state, result),
} {
  {
    state: {
      phase: state.phase,
      pending_model: state.pending_model,
      pending_tools: state.pending_tools,
      has_outcome: state.has_outcome,
      has_suspension: state.has_suspension,
      model_step_id: state.model_step_id,
      event_seq: state.event_seq + 1,
    },
    emitted_non_terminal: 1,
    emitted_terminal: 0,
    terminal_event: None,
  }
}

///|
fn mk_terminal(
  state : PhaseState,
  event : EventTag,
) -> StepResult where {
  proof_require: phase_inv(state) &&
  !is_terminal(state.phase) &&
  state.event_seq < 2_147_483_645 &&
  is_terminal_event(event),
  proof_ensure: result => step_post(state, result),
} {
  {
    state: {
      phase: Terminal,
      pending_model: 0,
      pending_tools: 0,
      has_outcome: true,
      has_suspension: false,
      model_step_id: state.model_step_id,
      event_seq: state.event_seq + 1,
    },
    emitted_non_terminal: 0,
    emitted_terminal: 1,
    terminal_event: Some(event),
  }
}

///|
fn step_initializing(
  state : PhaseState,
  input : TransitionKind,
) -> StepResult where {
  proof_require: phase_inv(state) &&
  is_initializing(state.phase) &&
  state.model_step_id == 0 &&
  state.event_seq < 2_147_483_645,
  proof_ensure: result => step_post(state, result),
} {
  match input {
    StartRun =>
      {
        state: {
          phase: ReadyForModel,
          pending_model: 0,
          pending_tools: 0,
          has_outcome: false,
          has_suspension: false,
          model_step_id: 1,
          event_seq: state.event_seq + 1,
        },
        emitted_non_terminal: 1,
        emitted_terminal: 0,
        terminal_event: None,
      }
    FailRun => mk_terminal(state, RunFailed)
    CancelRun => mk_terminal(state, RunCancelled)
    _ => mk_reject(state)
  }
}

///|
fn step_ready(
  state : PhaseState,
  input : TransitionKind,
) -> StepResult where {
  proof_require: phase_inv(state) &&
  is_ready(state.phase) &&
  state.event_seq < 2_147_483_645,
  proof_ensure: result => step_post(state, result),
} {
  match input {
    StartModelCall =>
      {
        state: {
          phase: AwaitingModel,
          pending_model: 1,
          pending_tools: 0,
          has_outcome: false,
          has_suspension: false,
          model_step_id: state.model_step_id,
          event_seq: state.event_seq + 1,
        },
        emitted_non_terminal: 1,
        emitted_terminal: 0,
        terminal_event: None,
      }
    FailRun => mk_terminal(state, RunFailed)
    CancelRun => mk_terminal(state, RunCancelled)
    _ => mk_reject(state)
  }
}

///|
fn step_awaiting_model(
  state : PhaseState,
  input : TransitionKind,
) -> StepResult where {
  proof_require: phase_inv(state) &&
  is_awaiting_model(state.phase) &&
  state.model_step_id < 2_147_483_647 &&
  state.event_seq < 2_147_483_645,
  proof_ensure: result => step_post(state, result),
} {
  match input {
    CompleteModelFinal =>
      {
        state: {
          phase: Terminal,
          pending_model: 0,
          pending_tools: 0,
          has_outcome: true,
          has_suspension: false,
          model_step_id: state.model_step_id,
          event_seq: state.event_seq + 2,
        },
        emitted_non_terminal: 1,
        emitted_terminal: 1,
        terminal_event: Some(RunCompleted),
      }
    CompleteModelSteer =>
      {
        state: {
          phase: ReadyForModel,
          pending_model: 0,
          pending_tools: 0,
          has_outcome: false,
          has_suspension: false,
          model_step_id: state.model_step_id + 1,
          event_seq: state.event_seq + 1,
        },
        emitted_non_terminal: 1,
        emitted_terminal: 0,
        terminal_event: None,
      }
    CompleteModelWithTools(n_tools) =>
      if n_tools >= 1 {
        {
          state: {
            phase: AwaitingTools,
            pending_model: 0,
            pending_tools: n_tools,
            has_outcome: false,
            has_suspension: false,
            model_step_id: state.model_step_id,
            event_seq: state.event_seq + 2,
          },
          emitted_non_terminal: 2,
          emitted_terminal: 0,
          terminal_event: None,
        }
      } else {
        {
          state: {
            phase: ReadyForModel,
            pending_model: 0,
            pending_tools: 0,
            has_outcome: false,
            has_suspension: false,
            model_step_id: state.model_step_id + 1,
            event_seq: state.event_seq + 2,
          },
          emitted_non_terminal: 2,
          emitted_terminal: 0,
          terminal_event: None,
        }
      }
    SuspendFromModel =>
      {
        state: {
          phase: Suspended,
          pending_model: 0,
          pending_tools: 0,
          has_outcome: false,
          has_suspension: true,
          model_step_id: state.model_step_id,
          event_seq: state.event_seq + 1,
        },
        emitted_non_terminal: 1,
        emitted_terminal: 0,
        terminal_event: None,
      }
    FailRun => mk_terminal(state, RunFailed)
    CancelRun => mk_terminal(state, RunCancelled)
    _ => mk_reject(state)
  }
}

///|
fn step_awaiting_tools(
  state : PhaseState,
  input : TransitionKind,
) -> StepResult where {
  proof_require: phase_inv(state) &&
  is_awaiting_tools(state.phase) &&
  state.model_step_id < 2_147_483_647 &&
  state.event_seq < 2_147_483_645,
  proof_ensure: result => step_post(state, result),
} {
  match input {
    CompleteToolPartial =>
      if state.pending_tools > 1 {
        {
          state: {
            phase: AwaitingTools,
            pending_model: 0,
            pending_tools: state.pending_tools - 1,
            has_outcome: false,
            has_suspension: false,
            model_step_id: state.model_step_id,
            event_seq: state.event_seq + 1,
          },
          emitted_non_terminal: 1,
          emitted_terminal: 0,
          terminal_event: None,
        }
      } else {
        {
          state: {
            phase: ReadyForModel,
            pending_model: 0,
            pending_tools: 0,
            has_outcome: false,
            has_suspension: false,
            model_step_id: state.model_step_id + 1,
            event_seq: state.event_seq + 1,
          },
          emitted_non_terminal: 1,
          emitted_terminal: 0,
          terminal_event: None,
        }
      }
    CompleteToolWaveDone =>
      {
        state: {
          phase: ReadyForModel,
          pending_model: 0,
          pending_tools: 0,
          has_outcome: false,
          has_suspension: false,
          model_step_id: state.model_step_id + 1,
          event_seq: state.event_seq + 1,
        },
        emitted_non_terminal: 1,
        emitted_terminal: 0,
        terminal_event: None,
      }
    FailRun => mk_terminal(state, RunFailed)
    CancelRun => mk_terminal(state, RunCancelled)
    _ => mk_reject(state)
  }
}

///|
fn step_suspended(
  state : PhaseState,
  input : TransitionKind,
) -> StepResult where {
  proof_require: phase_inv(state) &&
  is_suspended(state.phase) &&
  state.model_step_id < 2_147_483_647 &&
  state.event_seq < 2_147_483_645,
  proof_ensure: result => step_post(state, result),
} {
  match input {
    ResumeToReady =>
      {
        state: {
          phase: ReadyForModel,
          pending_model: 0,
          pending_tools: 0,
          has_outcome: false,
          has_suspension: false,
          model_step_id: state.model_step_id + 1,
          event_seq: state.event_seq + 1,
        },
        emitted_non_terminal: 1,
        emitted_terminal: 0,
        terminal_event: None,
      }
    FailRun => mk_terminal(state, RunFailed)
    CancelRun => mk_terminal(state, RunCancelled)
    _ => mk_reject(state)
  }
}

///|
pub fn step_phase(
  state : PhaseState,
  input : TransitionKind,
) -> StepResult where {
  proof_require: phase_inv(state) &&
  state.model_step_id < 2_147_483_647 &&
  state.event_seq < 2_147_483_645,
  proof_ensure: result => step_post(state, result),
} {
  match state.phase {
    Terminal => mk_reject(state)
    Initializing => step_initializing(state, input)
    ReadyForModel => step_ready(state, input)
    AwaitingModel => step_awaiting_model(state, input)
    AwaitingTools => step_awaiting_tools(state, input)
    Suspended => step_suspended(state, input)
  }
}
