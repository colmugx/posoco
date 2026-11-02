///|
/// Deep-copy a JSON value so mutable Array/Map backing storage cannot cross a
/// message/metadata snapshot boundary.
pub fn snapshot_json(value : Json) -> Json {
  match value {
    Array(items) => Json::array(items.map(snapshot_json))
    Object(fields) => {
      let snapshot : Map[String, Json] = Map::from_array([])
      for key in fields.keys() {
        snapshot[key] = snapshot_json(fields[key])
      }
      Json::object(snapshot)
    }
    scalar => scalar
  }
}

///|
pub fn snapshot_tool_call(call : @kernel.ToolCall) -> @kernel.ToolCall {
  {
    call_id: call.call_id,
    name: call.name,
    arguments: snapshot_json(call.arguments),
  }
}

///|
pub fn snapshot_content(content : @kernel.Content) -> @kernel.Content {
  match content {
    Text(text) => Text(text)
    Image(media_type~, data~) => Image(media_type~, data~)
  }
}

///|
pub fn snapshot_tool_outcome(
  outcome : @kernel.ToolOutcome,
) -> @kernel.ToolOutcome {
  match outcome {
    Success(content~, structured~) =>
      Success(
        content~,
        structured=match structured {
          Some(j) => Some(snapshot_json(j))
          None => None
        },
      )
    SuccessWithAttachments(content~, structured~, attachments~) =>
      SuccessWithAttachments(
        content~,
        structured=match structured {
          Some(j) => Some(snapshot_json(j))
          None => None
        },
        attachments=attachments.copy(),
      )
    ToolReportedError(content~, structured~) =>
      ToolReportedError(
        content~,
        structured=match structured {
          Some(j) => Some(snapshot_json(j))
          None => None
        },
      )
    RuntimeFailure(error_category~, message~) =>
      RuntimeFailure(error_category~, message~)
    NotExecuted(reason~, original_call_id~) =>
      NotExecuted(reason~, original_call_id~)
  }
}

///|
pub fn snapshot_message(message : @kernel.Message) -> @kernel.Message {
  match message {
    SystemMessage(content~) =>
      SystemMessage(content=content.map(snapshot_content))
    UserMessage(content~) => UserMessage(content=content.map(snapshot_content))
    AssistantMessage(content~, tool_calls~, reasoning~, finish_reason~) =>
      AssistantMessage(
        content=content.map(snapshot_content),
        tool_calls=tool_calls.map(snapshot_tool_call),
        reasoning~,
        finish_reason~,
      )
    ToolMessage(call_id~, tool_name~, outcome~) =>
      ToolMessage(call_id~, tool_name~, outcome=snapshot_tool_outcome(outcome))
  }
}

///|
pub fn snapshot_messages(
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] {
  messages.map(snapshot_message)
}

///|
pub fn snapshot_metadata(metadata : Map[String, Json]) -> Map[String, Json] {
  let snapshot : Map[String, Json] = Map::from_array([])
  for key in metadata.keys() {
    snapshot[key] = snapshot_json(metadata[key])
  }
  snapshot
}
