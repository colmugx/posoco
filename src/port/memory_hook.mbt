///|
/// MemoryRetrievalHook: PreModelHook that retrieves durable memory and
/// injects as a SystemMessage (after the system-prompt). Best-effort,
/// non-fatal — failures are swallowed and messages pass through unchanged.
pub(all) struct MemoryRetrievalHook {
  memories : Array[&MemoryPort]
  /// Max entries per search. Low default keeps context short.
  top_k : Int
}

///|
pub fn MemoryRetrievalHook::MemoryRetrievalHook(
  memories~ : Array[&MemoryPort],
  top_k? : Int = 5,
) -> MemoryRetrievalHook {
  { memories, top_k }
}

///|
/// Marker prefix for idempotent detection of existing memory messages.
let memory_marker : String = "[MEMORY]"

///|
/// Build a SystemMessage from retrieved entries. Returns `None` if empty.
fn MemoryRetrievalHook::build_memory_message(
  self : MemoryRetrievalHook,
  entries : Array[@types.MemoryEntry],
) -> @kernel.Message? {
  if entries.is_empty() {
    return None
  }
  let lines : Array[String] = [memory_marker]
  for entry in entries {
    lines.push("- " + entry.content)
  }
  Some(@kernel.SystemMessage(content=[@kernel.Text(lines.join("\n"))]))
}

///|
/// Extract query from the last UserMessage. Returns `None` if absent.
fn MemoryRetrievalHook::extract_query(
  self : MemoryRetrievalHook,
  messages : Array[@kernel.Message],
) -> String? {
  let mut i = messages.length() - 1
  while i >= 0 {
    match messages[i] {
      UserMessage(content~) => {
        for c in content {
          match c {
            Text(s) => return Some(s)
            _ => continue
          }
        }
        return None
      }
      _ => ()
    }
    i = i - 1
  }
  None
}

///|
/// Search every MemoryPort and merge results. Failures are swallowed.
fn MemoryRetrievalHook::search_all(
  self : MemoryRetrievalHook,
  query : String,
) -> Array[@types.MemoryEntry] {
  let out : Array[@types.MemoryEntry] = []
  for mem in self.memories {
    let q : @types.MemoryQuery = {
      query,
      top_k: self.top_k,
      threshold: None,
      filter: Map::from_array([]),
    }
    let entries : Array[@types.MemoryEntry] = mem.search(q) catch { _ => [] }
    for e in entries {
      out.push(e)
    }
  }
  out
}

///|
/// Idempotent injection: replace existing memory SystemMessage or insert
/// after the system-prompt message.
fn MemoryRetrievalHook::inject(
  self : MemoryRetrievalHook,
  messages : Array[@kernel.Message],
  memory_msg : @kernel.Message,
) -> Array[@kernel.Message] {
  let out : Array[@kernel.Message] = []
  let mut injected = false
  for m in messages {
    let is_memory_msg = match m {
      SystemMessage(content~) =>
        match content {
          [Text(s), ..] => s.has_prefix(memory_marker)
          _ => false
        }
      _ => false
    }
    if is_memory_msg {
      out.push(memory_msg)
      injected = true
    } else {
      out.push(m)
    }
  }
  if not(injected) {
    let final_out : Array[@kernel.Message] = []
    if out.length() > 0 {
      match out[0] {
        SystemMessage(..) => {
          final_out.push(out[0])
          final_out.push(memory_msg)
          for i in 1..<out.length() {
            final_out.push(out[i])
          }
        }
        _ => {
          final_out.push(memory_msg)
          for m in out {
            final_out.push(m)
          }
        }
      }
      return final_out
    }
    out.push(memory_msg)
  }
  out
}

///|
pub impl PreModelHook for MemoryRetrievalHook with fn before_model(
  self : MemoryRetrievalHook,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] raise HookAbort {
  match self.extract_query(messages) {
    None => return messages
    Some(query) => {
      let entries = self.search_all(query)
      match self.build_memory_message(entries) {
        None => return messages
        Some(memory_msg) => return self.inject(messages, memory_msg)
      }
    }
  }
}
