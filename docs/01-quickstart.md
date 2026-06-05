# 01 — Quickstart

5 分钟上手 posoco，构建你的第一个 LLM Agent。

## 前置条件

- [MoonBit](https://www.moonbitlang.com/) 工具链 ≥ 0.1.x
- 终端环境（示例使用 `native` target）

## 创建项目

```bash
mkdir my-agent && cd my-agent
moon init
```

编辑 `moon.mod`，添加 posoco 依赖：

```toml
name = "my-agent"
version = "0.1.0"

import {
  "colmugx/posoco@0.3.0"
  "moonbitlang/async@0.19.1"
}

preferred_target = "native"
```

编辑 `src/moon.pkg`，添加 import：

```toml
import {
  "colmugx/posoco"
  "moonbitlang/async"
  "moonbitlang/async/stdio"
}
```

## 最小 Agent 代码

在 `src/main.mbt` 中写入以下代码。这是一个完整的、可运行的 Agent——使用 Mock ModelPort（回显输入）和 NoopCompressor。

```moonbit
///|
/// Quickstart — 最小可运行 posoco Agent
///
/// 运行: moon run
/// 输入文字后回车，Agent 会回显你的输入。
/// 输入 $ <命令> 或 run <命令> 会触发 bash 工具调用。

///|
/// EchoModelPort — Mock 模型，回显用户输入
pub(all) struct EchoModelPort {}

///|
pub impl @posoco.ModelPort for EchoModelPort with fn chat(
  self : EchoModelPort,
  messages : Array[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
) -> @posoco.ModelResponse {
  // 取最后一条用户消息
  let user_text = match messages {
    [.., msg] if msg.role == @posoco.Role::User =>
      match msg.content {
        [@posoco.Content::Text(t), ..] => t
        _ => "Hello!"
      }
    _ => "Hello!"
  }

  // 如果像 shell 命令，返回工具调用
  if user_text.has_prefix("$ ") || user_text.has_prefix("run ") {
    let cmd = if user_text.has_prefix("$ ") {
      user_text["$ ".length():].to_owned()
    } else {
      user_text["run ".length():].to_owned()
    }
    let tool_call : @posoco.ToolCall = {
      id: "call_1",
      name: "bash",
      arguments: Json::object(
        Map::from_array([("cmd", Json::string(cmd))]),
      ),
    }
    let msg : @posoco.Message = {
      role: @posoco.Role::Assistant,
      content: [],
      tool_calls: [tool_call],
      tool_call_id: None,
      name: None,
    }
    @posoco.ModelResponse::{
      message: msg,
      tool_calls: [tool_call],
      finish_reason: @posoco.FinishReason::ToolCalls,
      usage: None,
      reasoning_summary: None,
    }
  } else {
    // 否则纯文本回显
    let msg : @posoco.Message = {
      role: @posoco.Role::Assistant,
      content: [@posoco.Content::Text("You said: " + user_text)],
      tool_calls: [],
      tool_call_id: None,
      name: None,
    }
    @posoco.ModelResponse::{
      message: msg,
      tool_calls: [],
      finish_reason: @posoco.FinishReason::Stop,
      usage: None,
      reasoning_summary: None,
    }
  }
}

///|
/// InMemorySessionStore — 内存中的会话存储
pub(all) struct InMemorySessionStore {
  mut store : Map[String, @posoco.Session]
}

///|
pub fn InMemorySessionStore::new() -> InMemorySessionStore {
  { store: {} }
}

///|
pub impl @posoco.SessionStore for InMemorySessionStore with fn load(
  self,
  id : String,
) -> Result[@posoco.Session, @posoco.SessionError] {
  match self.store.get(id) {
    Some(s) => Ok(s)
    None => Ok({ messages: [], metadata: {} })
  }
}

///|
pub impl @posoco.SessionStore for InMemorySessionStore with fn save(
  self,
  id : String,
  session : @posoco.Session,
) -> Result[Unit, @posoco.SessionError] {
  self.store[id] = session
  Ok(())
}

///|
/// ConsoleObserver — 在终端打印事件日志
pub(all) struct ConsoleObserver {}

///|
pub impl @posoco.Observer for ConsoleObserver with fn on_event(
  _self,
  event : @posoco.TurnEvent,
) {
  match event {
    @posoco.TurnEvent::TurnStarted => println("🔄 Turn started")
    @posoco.TurnEvent::ToolCallPending(call) =>
      println("🔧 Calling: " + call.name)
    @posoco.TurnEvent::ToolCallResult(call~, result~, is_error~) =>
      if is_error {
        println("❌ " + call.name + ": " + result.content)
      } else {
        println("✅ " + call.name + " done")
      }
    @posoco.TurnEvent::TurnCompleted => println("✅ Turn completed")
    @posoco.TurnEvent::TurnFailed(msg) => println("💥 " + msg)
    _ => ()
  }
}

///|
async fn main {
  println("🐙 Posoco Quickstart")
  println("输入文字回车，或输入 $ <命令> 执行 shell。输入 exit 退出。\n")

  // 构建 Agent — 数组式组合，内部自动处理路由和链式调用
  let agent = @posoco.Agent::new(
    EchoModelPort::{},                          // model_port
    tools=[],                                   // ToolProvider（空）
    hooks=[],                                   // PipelineHook（空）
    memory=[],                                  // MemoryPort（空）
    compressors=[@posoco.NoopCompressor::{}],   // Compressor
    observers=[ConsoleObserver::{}],            // Observer
    sessions=[InMemorySessionStore::new()],     // SessionStore
    lifecycle=None,                             // Lifecycle（可选）
    config={ max_tool_rounds: 5, temperature: None, max_output_tokens: None,
      tool_choice: None, thinking: None, model_context_window: None },
  )

  // REPL 循环
  let session_id = "quickstart"
  while true {
    @stdio.stdout.write("> ")
    let input = match @stdio.stdin.read_until("\n") {
      None => break
      Some(line) => line.trim().to_owned()
    }
    if input == "exit" || input == "" { continue }

    let msg : @posoco.Message = {
      role: @posoco.Role::User,
      content: [@posoco.Content::Text(input)],
      tool_calls: [],
      tool_call_id: None,
      name: None,
    }

    match try? agent.run_turn(msg, session_id) {
      Ok(result) =>
        for c in result.message.content {
          match c {
            @posoco.Content::Text(t) => println("🤖 " + t)
            _ => ()
          }
        }
      Err(e) => println("💥 " + e.to_string())
    }
    println("")
  }

  agent.shutdown()
  println("Bye!")
}
```

## 运行

```bash
moon run
```

预期输出：

```
🐙 Posoco Quickstart
输入文字回车，或输入 $ <命令> 执行 shell。输入 exit 退出。

> Hello
🔄 Turn started
✅ Turn completed
🤖 You said: Hello

> exit
Bye!
```

## 发生了什么？

你刚刚创建了一个完整的 Agent，它包含 posoco 框架的核心组件：

| 组件 | 你写的 | 作用 |
|------|--------|------|
| **ModelPort** | `EchoModelPort` | 模型适配器（这里用 mock，生产环境替换为 OpenAI） |
| **ToolProvider** | `tools=[]` 空 | 声明+执行工具（数组，可传入多个） |
| **SessionStore** | `InMemorySessionStore` | 会话持久化 |
| **Observer** | `ConsoleObserver` | 事件旁路（日志、指标） |
| **Compressor** | `NoopCompressor` | 上下文压缩（这里不压缩） |

## 下一步

- [02-architecture.md](02-architecture.md) — 理解 Agent 内部架构和 run_turn 生命周期
- [03-trait-recipes.md](03-trait-recipes.md) — 每种 trait 的详细实现配方
- [04-developer-guide.md](04-developer-guide.md) — 错误处理、内置组件、会话管理等深入主题
- [05-streaming-guide.md](05-streaming-guide.md) — 流式响应专题
