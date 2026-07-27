///|
/// SessionStore: persist and load conversation sessions by id.
///
/// Methods use the `raise` style (matching ModelPort/CommandPort) instead of
/// returning `Result`. This eliminates the Result-plus-async redundancy and
/// lets js-target adapters (e.g. JsonlSessionStore) implement the trait
/// directly instead of going through `load_async`/`save_async` side-paths.
pub(open) trait SessionStore {
  async fn load(Self, id : String) -> @types.Session raise @error.SessionError
  async fn save(Self, id : String, session : @types.Session) -> Unit raise @error.SessionError
}
