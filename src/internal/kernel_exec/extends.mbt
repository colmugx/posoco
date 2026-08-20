// Blessed dot-call promotions (MoonBit v0.10.9 deprecation of implicit
// method promotion): each declaration re-enables `value.to_string()` for one
// `impl Show` owned by this package. Keep this list limited to types that
// are actually dot-called within this module.

///|
pub extend BudgetDimension with Show::{to_string}

///|
pub extend BudgetState with Show::{to_string}

///|
pub extend Effect with Show::{to_string}

///|
pub extend ExecutionWave with Show::{to_string}

///|
pub extend FailureReason with Show::{to_string}

///|
pub extend InvariantCategory with Show::{to_string}

///|
pub extend KernelEvent with Show::{to_string}

///|
pub extend ModelStepId with Show::{to_string}

///|
pub extend Phase with Show::{to_string}

///|
pub extend RunOutcome with Show::{to_string}

///|
pub extend RunState with Show::{to_string}
