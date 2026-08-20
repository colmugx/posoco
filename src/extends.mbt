// Blessed dot-call promotions (MoonBit v0.10.9 deprecation of implicit
// method promotion). Each declaration below re-enables `value.method()`
// syntax for one trait impl owned by this package; without it, callers must
// use the qualified `Trait::method(value)` form. Keep this list limited to
// methods that are actually dot-called within this module.

///|
pub extend MemoryRetrievalHook with @port.Hook::{before_model}

///|
pub extend NoopCommandPort with @port.CommandPort::{commands, invoke}

///|
pub extend RecordingHook with @port.Hook::{before_model, before_tool}

///|
pub extend RecordingObserver with @port.Observer::{on_event}

///|
pub extend RecordingSessionStore with @port.SessionStore::{load, save}

///|
pub extend RecordingToolProvider with @port.ToolProvider::{list_tools}

///|
pub extend SystemPromptHook with @port.Hook::{before_model}

///|
pub extend UiRenderHook with @port.Hook::{on_post_event}
