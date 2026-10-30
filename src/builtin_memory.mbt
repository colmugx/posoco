///|
/// Internal memory implementation is owned by @memory. The root retains the
/// original names for Agent composition and unchanged whitebox tests.
using @memory {type MemoryToolProvider, collect_memory_inbound, memory_inbound_message}

///|
/// Stable memory-inbound lead used by existing consumers.
pub const MEMORY_INBOUND_LEAD : String = @memory.MEMORY_INBOUND_LEAD
