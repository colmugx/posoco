// Blessed dot-call promotions (MoonBit v0.10.9 deprecation of implicit
// method promotion): each declaration re-enables `value.to_string()` for one
// `impl Show` owned by this package. Keep this list limited to types that
// are actually dot-called within this module.

///|
pub extend UiBody with Show::{to_string}

///|
pub extend UiSlot with Show::{to_string}
