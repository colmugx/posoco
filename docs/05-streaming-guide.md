# 05 — 流式指南

流式（streaming）让你的模型回复边生成边送达：用户看到文字逐字出现，而不是干等
一个完整响应。本文讲清楚 Posoco 里流式是怎么设计的、模型适配器该怎么实现、宿主
和 observer 怎么消费。

## 1. 流式的开关：StreamMode

`ModelPort::chat` 的最后一个参数 `stream` 决定是否启用流式回调：

```moonbit
pub(open) trait ModelPort {
  async fn chat(
    Self,
    scope : InvocationScope,
    messages : Array[Message],
    tools : Array[ToolDef],
    options : ChatOptions,
    stream : StreamMode,
  ) -> ModelCallResult raise ModelError
}

pub(all) enum StreamMode {
  NoStream
  Stream((Json) -> Unit)
}
```

- `NoStream`：适合后台任务、批处理，或不需要增量 UI 的调用。适配器可以完全跳过
  流式解析工作。
- `Stream(callback)`：适配器每解析到一个可消费的 provider chunk，就调用一次
  `callback`。**回调的载荷是 `Json`**——流式的 wire 格式由你的适配器和消费方
  自己约定，Posoco 不规定统一的 chunk schema。

注意：无论是否流式，`chat` 最终都要返回完整的 `ModelCallResult`，其中
`completion` 是**完整、权威**的结果（完整文本、推理、工具调用、结束原因、用量）。
流式只是"边到边通知"，不是"分块返回"。

## 2. 两条数据路径

一次流式 chat 有两条同时存在、职责不同的路径：

```mermaid
sequenceDiagram
  participant Agent as Agent.run_turn
  participant Model as ModelPort.chat
  participant Host as Stream callback
  participant Obs as Observer

  Agent->>Model: chat(scope, messages, tools, options, Stream(cb))
  loop provider 事件
    Model->>Host: cb(Json chunk)
    Host-->>Obs: StreamChunkReceived（可识别时投影）
  end
  Model->>Agent: ModelCallResult(completion, processed_messages)
```

- **回调是实时通道**：给 UI / 遥测用的，JSON 形状是适配器与宿主之间的私有约定。
- **返回值是最终事实**：必须包含完整文本、reasoning、tool calls、finish reason
  和 usage，不能只返回最后发出去的那一块。
- 没有 observer 时，Agent 不建立投影；适配器仍然可以用回调把数据直接交给宿主
  自己的 sink。

Posoco 导出的 `StreamChunk` 是一套**可选的共享词汇表**，方便多个适配器复用同一
套 SSE 解析和 `StreamAccumulator`（官方 OpenAI / DeepSeek / Kimi 适配器都用它）。
它不是强制的 wire schema——你想定义自己的 chunk JSON 完全没问题，只要消费方
知道怎么解码。

## 3. 共享词汇表：StreamChunk

五种变体，覆盖文本、推理、工具调用、用量和结束：

```moonbit
pub(all) enum StreamChunk {
  TextDelta(token~ : String)
  ReasoningDelta(token~ : String)
  ToolCallDelta(
    index~ : Int,
    id~ : String?,
    name~ : String?,
    arguments_delta~ : String?
  )
  Usage(input_tokens~ : Int, output_tokens~ : Int, total_tokens~ : Int)
  Finish(reason~ : String)
}
```

- `ToolCallDelta` 按 `index` 区分不同的工具调用；`id` / `name` 通常只出现在第一
  片，`arguments_delta` 是**增量拼接**的 JSON 字符串，直到 `Finish` 才完整。
- `Finish(reason)` 的值有 `"stop"`、`"length"`、`"tool_calls"` 等，会被映射成
  `FinishReason`。

## 4. StreamAccumulator：把碎片拼回完整结果

`StreamAccumulator` 是可选工具，帮适配器把共享 chunk 组装成最终的
`Completion`：

```moonbit
let acc = @posoco.StreamAccumulator()
acc.push(@posoco.StreamChunk::TextDelta(token="Hello"))
acc.push(@posoco.StreamChunk::TextDelta(token=" world"))
acc.push(
  @posoco.StreamChunk::ToolCallDelta(
    index=0,
    id=Some("call_1"),
    name=Some("echo"),
    arguments_delta=Some("{\"text\":\"hi\"}"),
  ),
)
acc.push(@posoco.StreamChunk::Finish(reason="tool_calls"))
let completion = acc.to_completion()
```

`to_completion()` 返回 `Completion`，并且会 raise `ModelError`。它负责：

- 合并文本和 reasoning 增量；
- 按 `index` 合并工具调用增量；
- 解析 arguments JSON；
- 把 `Finish.reason` 映射为 `FinishReason`；
- 用量齐全时填充 `Usage`。

**容错规则很严格**：工具调用缺 id、缺 name、缺 arguments JSON，或 arguments
JSON 畸形，统统 raise `ModelError::ResponseParse`。绝不把坏 JSON 变成 `{}`、
空字符串或一个看似成功的工具调用——损坏的流不能伪装成有效结果。

## 5. ModelPort 实现模式

推荐把"provider 解析"和"Posoco 回调"分开：解析出的每个 chunk 同时做两件事——
喂给 accumulator（拼最终结果）+ 转发给回调（实时通道）。这叫"双写"：

```moonbit
fn emit_chunk(
  stream : @posoco.StreamMode,
  acc : @posoco.StreamAccumulator,
  chunk : @posoco.StreamChunk,
) -> Unit {
  acc.push(chunk)
  match stream {
    @posoco.StreamMode::NoStream => ()
    @posoco.StreamMode::Stream(callback) => callback(chunk_to_json(chunk))
  }
}

pub impl @posoco.ModelPort for StreamingModel with fn chat(
  self,
  _scope : @posoco.InvocationScope,
  messages : Array[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  match stream {
    @posoco.StreamMode::NoStream => self.chat_without_stream(messages)
    @posoco.StreamMode::Stream(_) => {
      let acc = @posoco.StreamAccumulator()
      // 1. 打开 provider 的流。
      // 2. 把每个 provider 事件解析成一个或多个 StreamChunk。
      // 3. 每个 chunk 都调用 emit_chunk(stream, acc, chunk)。
      // 4. 只在收到 provider 明确的成功终态时停止。
      let completion = acc.to_completion()
      { completion, processed_messages: messages.copy() }
    }
  }
}
```

`chunk_to_json` 是适配器与宿主之间的约定。文本/推理遥测的常见约定是
`{"kind": ..., "token": ...}`：

```moonbit
fn chunk_to_json(chunk : @posoco.StreamChunk) -> Json {
  match chunk {
    @posoco.StreamChunk::TextDelta(token~) => Json::object(Map::from_array([
      ("kind", Json::string("text")),
      ("token", Json::string(token)),
    ]))
    @posoco.StreamChunk::ReasoningDelta(token~) => Json::object(Map::from_array([
      ("kind", Json::string("reasoning")),
      ("token", Json::string(token)),
    ]))
    @posoco.StreamChunk::ToolCallDelta(index~, id~, name~, arguments_delta~) =>
      Json::object(Map::from_array([
        ("kind", Json::string("tool_call_delta")),
        ("index", Json::number(index.to_double())),
        ("id", match id {
          Some(value) => Json::string(value)
          None => Json::null()
        }),
        ("name", match name {
          Some(value) => Json::string(value)
          None => Json::null()
        }),
        ("arguments_delta", match arguments_delta {
          Some(value) => Json::string(value)
          None => Json::null()
        }),
      ]))
    @posoco.StreamChunk::Usage(input_tokens~, output_tokens~, total_tokens~) =>
      Json::object(Map::from_array([
        ("kind", Json::string("usage")),
        ("input_tokens", Json::number(input_tokens.to_double())),
        ("output_tokens", Json::number(output_tokens.to_double())),
        ("total_tokens", Json::number(total_tokens.to_double())),
      ]))
    @posoco.StreamChunk::Finish(reason~) => Json::object(Map::from_array([
      ("kind", Json::string("finish")),
      ("reason", Json::string(reason)),
    ]))
  }
}
```

生产适配器的标准动作就是这套流程：解析 provider 事件 → 喂一次 accumulator →
转发一次回调 → 校验终态后返回 `ModelCallResult`。如果你的适配器有更复杂的流式
需求（比如 DeepSeek 在流式中动态移除工具结果），完全可以不依赖 accumulator，
自己维护状态。

## 6. 终态与错误

**绝不要把"收到了一些文本"当成成功。** 适配器必须严格区分：

| 情形 | 处理 |
|------|------|
| 明确的成功终态（`[DONE]`、合法的 finish marker、校验过的 completed 事件） | 组装并返回 completion |
| 传输 / 读取失败 | `ModelError::Transport` |
| 事件畸形、工具参数不完整 | `ModelError::ResponseParse` |
| provider 明确失败 / 不完整 / 错误终态 | typed `ModelError`（按适配器约定通常是 Transport 或 ResponseParse） |
| 没等到明确成功终态就 EOF | typed 失败——绝不返回"部分成功" |

错误信息只包含有界的阶段/类别信息：不包含凭据、prompt 文本、工具参数、原始
provider 响应体、无界的 `error.to_string()` 载荷。畸形流 JSON 和畸形工具参数
JSON 同样适用这条规则。

## 7. Observer 侧消费

Agent 能把回调的 JSON 投影成 `TurnEvent::StreamChunkReceived` 事件。内置投影
可靠识别 `{kind: "text" | "reasoning", token: "..."}` 这种形式；其他 kind 属于
宿主私有载荷，不要假设它们能在所有宿主里变成 typed 的 observer 事件。

```moonbit
pub impl @posoco.Observer for TokenPrinter with fn on_event(
  _self,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::StreamChunkReceived(chunk~) =>
      match chunk {
        @posoco.StreamChunk::TextDelta(token~) => println(token)
        @posoco.StreamChunk::ReasoningDelta(_) => ()
        _ => ()
      }
    @posoco.TurnEvent::TurnCompleted => println("")
    _ => ()
  }
}
```

如果你的产品需要**无损**的工具调用增量或用量遥测，就在宿主 sink 里直接消费
适配器的回调 JSON，不要试图从最终 transcript 里重建。最终的
`TurnResult.message` 始终是权威的 assistant 消息。

## 8. 测试清单

一个流式 ModelPort 至少应覆盖：

```moonbit
test "accumulator assembles streamed completion" {
  let acc = @posoco.StreamAccumulator()
  acc.push(@posoco.StreamChunk::TextDelta(token="Hi"))
  acc.push(@posoco.StreamChunk::TextDelta(token=" there"))
  acc.push(@posoco.StreamChunk::Usage(
    input_tokens=10,
    output_tokens=2,
    total_tokens=12,
  ))
  acc.push(@posoco.StreamChunk::Finish(reason="stop"))
  let completion = acc.to_completion()
  assert_eq(completion.message.content, [@posoco.Content::Text("Hi there")])
}
```

还要测：

- `NoStream` 不会调用回调；
- 每个流式 chunk 恰好转发一次；
- 合法的终态事件返回一个完整的 `ModelCallResult`；
- 干净 EOF、provider 失败、畸形 JSON 都抛 typed 错误；
- 缺工具调用字段、arguments 畸形时抛 `ResponseParse`，且不泄漏原始载荷；
- 组合好的 Agent 会发出 `StreamChunkReceived` 事件，且恰好一个 terminal turn
  事件。

写扩展时用 testkit 里的 `ScriptedModelStep::Stream` 做一致性假件很方便，但它是
测试专用 API——生产扩展要直接实现 `ModelPort` 和 `Extension`。