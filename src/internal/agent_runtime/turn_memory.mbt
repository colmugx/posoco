///|

///|
fn quota_error_detail(
  message : String,
  reset_at_ms : Int64?,
  provider_code : String?,
) -> String {
  let code_label = match provider_code {
    Some(code) => code
    None => "none"
  }
  let reset_label = match reset_at_ms {
    Some(at) => "\{at}"
    None => "none"
  }
  "code=\{code_label}, reset_at_ms=\{reset_label}, message=\{message}"
}

///|
fn messages_prefix_equal(
  left : Array[@kernel.Message],
  right : Array[@kernel.Message],
  len : Int32,
) -> Bool {
  if left.length() < len || right.length() < len {
    return false
  }
  for i in 0..<len {
    if left[i] != right[i] {
      return false
    }
  }
  true
}

///|
fn session_metadata_equal(
  left : Map[String, Json],
  right : Map[String, Json],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for key in left.keys() {
    match right.get(key) {
      Some(value) if value == left[key] => ()
      _ => return false
    }
  }
  true
}

///|
fn automatic_session_title(input : @kernel.Message) -> String? {
  let raw = match input {
    UserMessage(content~) => {
      let buf = StringBuilder()
      let mut has_text = false
      for item in content {
        match item {
          Text(text) => {
            if has_text {
              buf.write_char(' ')
            }
            buf.write_string(text)
            has_text = true
          }
          Image(..) => ()
        }
      }
      buf.to_string()
    }
    _ => return None
  }
  let out = StringBuilder()
  let mut pending_space = false
  let mut written = 0
  for ch in raw {
    let code = ch.to_int()
    if code == 0x20 || code == 0x09 || code == 0x0a || code == 0x0d {
      pending_space = true
    } else {
      if pending_space && written > 0 && written < 50 {
        out.write_char(' ')
        written = written + 1
      }
      pending_space = false
      if written >= 50 {
        break
      }
      out.write_char(ch)
      written = written + 1
    }
  }
  let title = out.to_string()
  if title.length() == 0 {
    None
  } else {
    Some(title)
  }
}

///|
fn session_metadata_for_admission(
  session : @types.Session,
  input : @kernel.Message,
) -> Map[String, Json] {
  let metadata = @message_snapshot.snapshot_metadata(session.metadata)
  if session.messages.is_empty() &&
    !metadata.contains(@types.SESSION_TITLE_METADATA_KEY) {
    match automatic_session_title(input) {
      Some(title) =>
        metadata[@types.SESSION_TITLE_METADATA_KEY] = Json::string(title)
      None => ()
    }
  }
  metadata
}

///|
async fn AgentRuntime::inject_memory_inbound(
  self : AgentRuntime,
  session : @types.Session,
  session_id : String,
  input : @kernel.Message,
  messages : Array[@kernel.Message],
) -> Unit noraise {
  if session.messages.length() == 0 &&
    !self.memory.is_empty() &&
    !self.memory_inbound_attempted.contains(session_id) {
    self.memory_inbound_attempted[session_id] = true
    let request = match input {
      UserMessage(content~) => {
        let parts : Array[String] = []
        for item in content {
          match item {
            Text(t) => parts.push(t)
            _ => ()
          }
        }
        parts.join("")
      }
      _ => ""
    }
    let bodies = @memory.collect_memory_inbound(
      self.memory,
      session_id,
      request,
      self.config.memory_inbound_timeout_ms,
      fn(reason) {
        emit_secondary_failure(self.events, "memory_inbound", reason)
      },
    )
    if !bodies.is_empty() {
      messages.push(@memory.memory_inbound_message(bodies))
    }
  }
}
