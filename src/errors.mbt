///|
pub(all) suberror ModelError {
  RequestBuild(String)
  Transport(String)
  ResponseParse(String)
} derive(Debug)

///|
pub impl Show for ModelError with fn to_string(self) -> String {
  match self {
    RequestBuild(msg) => "ModelError::RequestBuild(\{msg})"
    Transport(msg) => "ModelError::Transport(\{msg})"
    ResponseParse(msg) => "ModelError::ResponseParse(\{msg})"
  }
}

///|
pub(all) suberror SessionError {
  Load(String)
  Save(String)
} derive(Debug)

///|
pub impl Show for SessionError with fn to_string(self) -> String {
  match self {
    Load(msg) => "SessionError::Load(\{msg})"
    Save(msg) => "SessionError::Save(\{msg})"
  }
}

///|
pub(all) suberror RuntimeError {
  UnknownTool(String)
  InvocationFailed(String)
  Transport(String)
} derive(Debug)

///|
pub impl Show for RuntimeError with fn to_string(self) -> String {
  match self {
    UnknownTool(msg) => "RuntimeError::UnknownTool(\{msg})"
    InvocationFailed(msg) => "RuntimeError::InvocationFailed(\{msg})"
    Transport(msg) => "RuntimeError::Transport(\{msg})"
  }
}

///|
pub(all) suberror AgentError {
  Model(String)
  Session(SessionError)
  Runtime(RuntimeError)
  ToolLoopExceeded
  HookAborted(String)
} derive(Debug)

///|
pub impl Show for AgentError with fn to_string(self) -> String {
  match self {
    Model(msg) => "AgentError::Model(\{msg})"
    Session(err) => "AgentError::Session(\{err.to_string()})"
    Runtime(err) => "AgentError::Runtime(\{err.to_string()})"
    ToolLoopExceeded => "AgentError::ToolLoopExceeded"
    HookAborted(msg) => "AgentError::HookAborted(\{msg})"
  }
}

///|
pub(all) suberror MemoryError {
  Store(String)
  Search(String)
  Delete(String)
} derive(Debug)

///|
pub impl Show for MemoryError with fn to_string(self) -> String {
  match self {
    Store(msg) => "MemoryError::Store(\{msg})"
    Search(msg) => "MemoryError::Search(\{msg})"
    Delete(msg) => "MemoryError::Delete(\{msg})"
  }
}

///|
/// Composition errors raised during Agent::new (tool collisions, empty required ports).
pub(all) suberror CompositionError {
  ToolCollision(String, String)
  EmptyPort(String)
} derive(Debug)

///|
pub impl Show for CompositionError with fn to_string(self) -> String {
  match self {
    ToolCollision(name, msg) =>
      "CompositionError::ToolCollision(\{name}: \{msg})"
    EmptyPort(port) => "CompositionError::EmptyPort(\{port})"
  }
}
