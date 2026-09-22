// ---------------------------------------------------------------------------
// RecordingLogPort — structured log fake for extension/composition tests.
// ---------------------------------------------------------------------------

///|
pub(all) struct RecordedLogWrite {
  record : @port.LogRecord
  durability : @port.LogDurability
} derive(Eq, Debug)

///|
pub extend RecordedLogWrite with Eq::{not_equal, equal}

///|
pub extend RecordedLogWrite with Debug::{to_repr}

///|
pub(all) struct RecordingLogPort {
  writes_ : Array[RecordedLogWrite]
  mut flush_count_ : Int
}

///|
pub fn RecordingLogPort::RecordingLogPort() -> RecordingLogPort {
  { writes_: [], flush_count_: 0, }
}

///|
fn snapshot_log_record(record : @port.LogRecord) -> @port.LogRecord {
  {
    level: record.level,
    source: record.source,
    channel: record.channel,
    event: record.event,
    message: record.message,
    scope: record.scope,
    data: snapshot_json(record.data),
  }
}

///|
pub fn RecordingLogPort::writes(
  self : RecordingLogPort,
) -> Array[RecordedLogWrite] {
  self.writes_.map(fn(write) {
    { record: snapshot_log_record(write.record), durability: write.durability, }
  })
}

///|
pub fn RecordingLogPort::flush_count(self : RecordingLogPort) -> Int {
  self.flush_count_
}

///|
pub async fn RecordingLogPort::write_direct(
  self : RecordingLogPort,
  record : @port.LogRecord,
  durability : @port.LogDurability,
) -> Unit raise @error.LogError {
  (self as &@port.LogPort).write(record, durability)
}

///|
pub extend RecordingLogPort with @port.LogPort::{write, flush}

///|
pub impl @port.LogPort for RecordingLogPort with fn write(
  self,
  record,
  durability,
) -> Unit raise @error.LogError {
  record.validate()
  self.writes_.push({ record: snapshot_log_record(record), durability, })
}

///|
pub impl @port.LogPort for RecordingLogPort with fn flush(self) -> Unit raise @error.LogError {
  self.flush_count_ = self.flush_count_ + 1
}
