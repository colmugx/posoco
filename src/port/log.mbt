///|
/// Structured application logging capability for extensions.
///
/// LogPort is intentionally storage-agnostic: Posoco defines the record and
/// durability contract, while adapters decide whether records land in JSONL,
/// SQLite, stderr, OpenTelemetry, or a composite sink.
///
/// Consumers choose the durability level per record. The sink owns timestamps,
/// sequence numbers, rotation, integrity metadata, and physical layout.

///|
pub(all) enum LogLevel {
  Trace
  Debug
  Info
  Warn
  Error
} derive(Eq, Debug)

///|
pub extend LogLevel with Eq::{not_equal, equal}

///|
pub extend LogLevel with Debug::{to_repr}

///|
/// Persistence acknowledgement requested by a log producer.
///
/// - Buffered: the sink accepted the record; it may still live only in memory.
/// - Written: the sink completed its normal write path.
/// - Durable: the sink crossed its durability barrier before returning.
pub(all) enum LogDurability {
  Buffered
  Written
  Durable
} derive(Eq, Debug)

///|
pub extend LogDurability with Eq::{not_equal, equal}

///|
pub extend LogDurability with Debug::{to_repr}

///|
/// Provider-neutral structured log record.
///
/// source, channel, and event are stable machine-readable identifiers.
/// message is optional human-readable context. scope attributes records to a
/// Posoco session/run/turn when one exists. data is producer-owned JSON;
/// sinks must not inspect it to infer secrets or policy.
pub(all) struct LogRecord {
  level : LogLevel
  source : String
  channel : String
  event : String
  message : String?
  scope : @types.EventScope?
  data : Json
} derive(Eq, Debug)

///|
pub extend LogRecord with Eq::{not_equal, equal}

///|
pub extend LogRecord with Debug::{to_repr}

///|
/// Validate the protocol-level fields that every sink may rely on.
pub fn LogRecord::validate(self : LogRecord) -> Unit raise @error.LogError {
  if self.source.trim().length() == 0 {
    raise @error.LogError::InvalidRecord("source must not be empty")
  }
  if self.channel.trim().length() == 0 {
    raise @error.LogError::InvalidRecord("channel must not be empty")
  }
  if self.event.trim().length() == 0 {
    raise @error.LogError::InvalidRecord("event must not be empty")
  }
}

///|
/// Structured logging port.
///
/// Implementations must preserve call order for writes observed through the
/// same LogPort instance and honour the requested durability before returning.
/// flush commits any buffered records according to the sink's normal durable
/// flush semantics. Implementations should validate records with
/// LogRecord::validate before accepting them.
pub(open) trait LogPort {
  async fn write(Self, record : LogRecord, durability : LogDurability) -> Unit raise @error.LogError
  async fn flush(Self) -> Unit raise @error.LogError
}
