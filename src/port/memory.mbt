///|
/// MemoryPort: durable cross-session memory store/search/delete. Distinct
/// from SessionStore (conversation history) — memory holds durable
/// decisions/knowledge (e.g. brain.md integration).
pub(open) trait MemoryPort {
  fn store(Self, entry : @types.MemoryEntry) -> String raise @error.MemoryError
  fn search(Self, query : @types.MemoryQuery) -> Array[@types.MemoryEntry] raise @error.MemoryError
  fn delete(Self, id : String) -> Unit raise @error.MemoryError
}
