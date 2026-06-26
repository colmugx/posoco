///|
/// MemoryPort: durable cross-session memory store/search/delete. Distinct
/// from SessionStore (conversation history) — memory holds durable
/// decisions/knowledge (e.g. brain.md integration).
pub(open) trait MemoryPort {
  fn store(Self, entry : MemoryEntry) -> String raise MemoryError
  fn search(Self, query : MemoryQuery) -> Array[MemoryEntry] raise MemoryError
  fn delete(Self, id : String) -> Unit raise MemoryError
}
