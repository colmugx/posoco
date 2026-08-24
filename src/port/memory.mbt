///|
/// MemoryPort: durable cross-session memory store/search/delete. Distinct
/// from SessionStore (conversation history) — memory holds durable
/// decisions/knowledge (e.g. brain.md integration). All slots are `async`
/// so adapter IO propagates through async; synchronous implementations
/// write plain `fn` bodies (a sync body satisfies an `async` slot).
pub(open) trait MemoryPort {
  async fn store(Self, entry : @types.MemoryEntry) -> String raise @error.MemoryError
  async fn search(Self, query : @types.MemoryQuery) -> Array[@types.MemoryEntry] raise @error.MemoryError
  async fn delete(Self, id : String) -> Unit raise @error.MemoryError
}
