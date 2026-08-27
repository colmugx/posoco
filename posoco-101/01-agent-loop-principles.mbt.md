---
moonbit:
  backend:
    native
---

# Agent Loop 原理：如何实现一个 Agent Loop

> 课题：用最少代码讲清楚 Agent Loop 如何运行。
>
> 本文是可执行的 MoonBit 文档（`.mbt.md`）。所有代码块按顺序声明、可直接
> `moon test`。本文不依赖 Posoco —— 它定义自己的最小类型来解释原理。

## 1. Agent 不是模型

LLM 一次只能返回一条响应。它可以在响应里表达两种意图：

1. 直接回答用户；
2. 请求程序调用某个工具。

真正让它成为 Agent 的，是模型外面的循环：程序看见工具请求后执行工具，把结果追加到对话，再调用模型。模型负责决定下一步，循环负责让下一步真实发生。

## 2. 最小类型

为了让代码能编译运行，我们先定义最小的消息和工具类型。这些类型故意简化——它们只服务于讲解，不是 Posoco 的真实 API。

```mbt check
///|
/// 一次工具调用的请求。
struct ToolCall {
  id : String
  name : String
}

///|
/// 工具执行的结果。
struct ToolResult {
  call_id : String
  content : String
}

///|
/// 模型的回复。如果没有 tool_calls，表示模型给出了最终答案。
struct Reply {
  message : String
  tool_calls : Array[ToolCall]
}

///|
/// 工具集合：按名字查找并执行。本文用一个简单的函数表。
struct ToolSet {
  executors : Map[String, (ToolCall) -> ToolResult]
}

///|
/// 在对话末尾追加一条消息。返回新对话（不可变风格）。
fn push(messages : Array[String], msg : String) -> Array[String] {
  let out = messages.copy()
  out.push(msg)
  out
}
```

## 3. 最小 Agent Loop

整个原理压缩成一个函数。`model` 是一个接收对话、返回 `Reply` 的函数；`tools` 是工具集合：

```mbt check
///|
/// 运行 Agent Loop，直到模型不再请求工具。
fn run_agent(
  user_message : String,
  model : (Array[String]) -> Reply,
  tools : ToolSet,
) -> String {
  let mut messages = [user_message]
  while true {
    let reply = model(messages)
    messages = push(messages, reply.message)
    if reply.tool_calls.is_empty() {
      return reply.message
    }
    for call in reply.tool_calls {
      let result = execute_tool(tools, call)
      messages = push(
        messages,
        "tool(" + result.call_id + ") -> " + result.content,
      )
    }
  }
  ""
}

///|
/// 按名字查找并执行工具。未知工具返回错误结果。
fn execute_tool(tools : ToolSet, call : ToolCall) -> ToolResult {
  match tools.executors.get(call.name) {
    Some(exec) => exec(call)
    None => { call_id: call.id, content: "unknown tool: " + call.name }
  }
}
```

这就是 Agent Loop 的最小本质：

```text
用户消息
   ↓
调用模型
   ├─ 没有工具请求 ─────────────→ 返回最终回答
   └─ 有工具请求
          ↓
       执行工具
          ↓
   把工具结果追加到 messages
          └──────────────────────→ 再次调用模型
```

## 4. 运行一个例子

我们用一个固定模型和两个工具来验证 loop 能跑通。模型的行为是脚本化的：第一次请求工具，第二次给出最终答案。

```mbt check
///|
/// 脚本化模型：第一次请求 echo 工具，第二次直接回答。
fn scripted_model(messages : Array[String]) -> Reply {
  let turn = messages.length()
  if turn <= 1 {
    // 第一次：请求调用 echo 工具
    { message: "let me check", tool_calls: [{ id: "call_1", name: "echo" }] }
  } else {
    // 第二次：工具结果已在 messages 里，给出最终答案
    { message: "done", tool_calls: [] }
  }
}

///|
/// echo 工具：原样返回 call id。
fn echo_tool(call : ToolCall) -> ToolResult {
  { call_id: call.id, content: "echoed:" + call.id }
}

///|
/// 组装工具集。
fn make_tools() -> ToolSet {
  { executors: Map::from_array([("echo", echo_tool)]) }
}

///|
/// 验证：loop 执行一轮工具调用后返回最终答案。
test "agent_loop_runs_one_tool_round" {
  let tools = make_tools()
  let answer = run_agent("hello", scripted_model, tools)
  assert_eq(answer, "done")
}
```

## 5. 为什么工具结果要回到 messages

假设用户问："当前目录有哪些 MoonBit 文件？"

第一次模型调用返回：

```text
assistant -> call tool: list_files({ pattern: "*.mbt" })
```

程序执行工具后得到：

```text
tool(call_id) -> ["agent.mbt", "errors.mbt", "types_model.mbt"]
```

这还不是最终答案。程序必须把工具结果加入对话，再调用模型。第二次模型调用才能根据结果回答。因此有一个不能破坏的不变量：

> 每个被执行的 tool call，都必须产生一个带相同 call ID 的 tool result，并在下一次模型调用前进入上下文。

工具只是为模型补充它原本不知道的事实；真正面向用户组织答案的仍然是模型。

## 6. Loop 中只有三种状态变化

从最小实现看，循环只做三件事：

| 当前输入 | 动作 | 下一状态 |
|---|---|---|
| 用户或工具消息 | 调用模型 | 得到 assistant 消息 |
| assistant 含 tool calls | 执行工具并追加结果 | 再次调用模型 |
| assistant 不含 tool calls | 停止 | 返回最终消息 |

所以 Agent Loop 可以理解为一个状态机，而不是一段神秘的 AI 代码：

```text
ReadyForModel → AwaitingModel → AwaitingTools → ReadyForModel → … → Terminal
```

这两个名字不是随便起的：Posoco 内核的真实相位就叫
`ReadyForModel` / `AwaitingModel` / `AwaitingTools`（见
[`src/internal/kernel_exec/state.mbt`](../../src/internal/kernel_exec/state.mbt)）。
业界同类框架也是同样的切法——DeepSeek Harness 把一次模型请求加它的工具调用叫一个
**step**，零或多个 step 组成一个 **turn**。词不一样，循环是同一个。

如果把状态转移写成纯函数，就得到更适合测试的形式：`State + Input → NewState + Effects`。纯函数决定"下一步应该调用模型还是工具"；外层运行时执行这些 Effect，再把结果送回状态机。这也是 Posoco 选择函数式 kernel 的原因。

## 7. 生产版本为什么更长

上面的代码足以解释原理，但还不能直接作为可靠 Harness。生产实现至少要回答：

- 模型一直调用工具时，怎样限制最大轮数？
- 工具参数不是合法 JSON 时，谁负责拒绝？
- 多个工具应该顺序执行还是并行执行？
- 用户按下取消时，模型请求和工具进程怎样一起停止？
- 工具失败后，是反馈模型继续，还是终止整个 run？
- 什么时候保存消息，进程崩溃后从哪里恢复？
- 如何保证 streaming、tool progress 和最终事件顺序一致？

这些不是 Agent Loop 原理本身，而是 Harness 给最小循环增加的工程约束。当前 Posoco 的实际循环可以从 [`src/agent.mbt`](../../src/agent.mbt) 开始阅读。

## 8. 错误处理的边界

为了让模型知道工具失败，Harness 可以把一次明确的工具业务失败转换成 tool result：

```text
tool -> Failed("file not found")
```

模型随后可以改用其他路径或向用户解释问题。但这不等于可以吞掉任意错误：

- 非法工具参数不能偷偷替换成 `{}`；
- 网络响应解析失败不能伪装成正常 EOF；
- session 保存失败不能仍然发布"运行完成"；
- 未知工具不能交给随机 provider 执行。

可恢复的失败应成为显式状态；不可恢复的失败应带原因终止。两者都必须可观察。

## 9. 记住这个最小模型

实现任何 Agent 框架时，可以先检查下面四步是否成立：

1. 把用户消息加入上下文；
2. 调用模型，并保存 assistant 消息；
3. 有 tool calls 就执行工具、追加对应结果，然后回到第 2 步；
4. 没有 tool calls 就结束。

其他能力都是围绕这四步建立的安全性、持久性和产品体验。

---

> **运行本文**：`moon test --target native`（本文是 `.mbt.md` doc-test 文件，
> 代码块会被当作可执行测试）。
