///|
/// MemoryPort: session memory — the port a memory system plugs into
/// (nowledge-mem today, OpenViking and any other scheme tomorrow). Four
/// slots: `inbound` for session-opening recall, `store`/`search`/`delete`
/// for the durable record. Core never labels or re-renders provider output —
/// providers own their text format (community convention e.g. devkit
/// envelopes); core owns only timing, placement, and stability.
pub(open) trait MemoryPort {
  /// Session-opening memory context tailored to the user's first request.
  /// Core calls it at most once per session lifetime per process, ONLY when
  /// the loaded session transcript is empty (the session's first turn).
  /// `None` or an empty body contributes nothing; a non-empty result
  /// freezes into the transcript as ONE user message placed before the real
  /// first user input — never rewritten, never re-read. The slot is `async`
  /// so adapter IO propagates through async; synchronous implementations
  /// write plain `fn` bodies.
  async fn inbound(Self, session_id~ : String, request~ : String) -> String? raise @error.MemoryError

  /// Persist one entry with provider-convention metadata; returns the
  /// provider's id or a pending ticket for it. Whether the write is durable
  /// on return is the provider's business.
  async fn store(Self, content~ : String, metadata~ : Map[String, Json]) -> String raise @error.MemoryError

  /// Query the store; returns provider-rendered text (`None` = no hits).
  /// Omitting `top_k` leaves the hit count to the provider.
  async fn search(Self, query~ : String, top_k? : Int) -> String? raise @error.MemoryError

  /// Remove the memory stored under `id` — a passive interface for
  /// product-side logic (e.g. an observer detecting stale memory). Whether
  /// an unknown id raises is the provider's call.
  async fn delete(Self, id : String) -> Unit raise @error.MemoryError
}
