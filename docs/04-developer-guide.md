# 04 — Developer Guide

posoco 开发者的完整参考：Agent 构建、运行模式、错误处理、会话管理和内置组件。

> 本文档假设你已阅读 [01-quickstart.md](01-quickstart.md) 和 [02-architecture.md](02-architecture.md)。

---

## 构建 Agent

### Agent::new — 数组式组合

`Agent::new` 接受每个端口的**数组**，内部自动完成组合（路由、链式、扇出）。开发者不再需要手动创建 `CompositeToolProvider` 或 `HookChain`。

```moonbit
pub fn Agent::new(
  model_port : &ModelPort,             // LLM 模型适配器（单个）
  tools~ : Array[&ToolProvider],        // 工具提供者（按工具名路由）
  hooks~ : Array[&PipelineHook],        // 流程拦截（按序链式调用）
  memory~ : Array[&MemoryPort],         // 长期记忆（扇出）
  compressors~ : Array[&Compressor],    // 上下文压缩（first-wins）
  observers~ : Array[&Observer],        // 事件观察（扇出）
  sessions~ : Array[&SessionStore],     // 会话存储（write-all / read-first）
  lifecycle~ : &Lifecycle?,             // 生命周期管理（可选）
  config~ : AgentConfig,                // 配置
) -> Agent
```

**组合策略：**

| 参数 | 策略 | 说明 |
|------|------|------|
| `tools` | 按名路由 | 同名工具 last-wins，`tool_collisions()` 报告碰撞 |
| `hooks` | 链式 | 按序调用，遇 Err 短路。0→None, 1→直接用, >1→内部 HookChain |
| `observers` | 扇出 | 每个 observer 收到所有事件 |
| `compressors` | first-wins | 按序尝试，第一个返回非 None 的生效 |
| `sessions` | write-all / read-first | 保存写所有，加载读第一个 |
| `memory` | 扇出 | 暂未在 run_turn 中使用 |

### AgentConfig 字段

```moonbit
pub(all) struct AgentConfig {
  max_tool_rounds : Int       // 工具循环最大轮数，默认建议 5-10
  temperature : Double?       // 模型温度，None 使用模型默认
  max_output_tokens : Int?    // 最大输出 token 数
  tool_choice : ToolChoice?   // 工具选择策略
  thinking : Bool?            // 是否启用思维链
  model_context_window : Int? // 上下文窗口大小，Compressor 会用到
}
```

### 典型构建

**最小 Agent：**

```moonbit
let agent = @posoco.Agent::new(
  model_port,
  tools=[my_tools],
  hooks=[],
  memory=[],
  compressors=[@posoco.NoopCompressor::{}],
  observers=[my_observer],
  sessions=[my_session_store],
  lifecycle=None,
  config={ max_tool_rounds: 5, temperature: None, max_output_tokens: None,
    tool_choice: None, thinking: None, model_context_window: None },
)
```

**完整 Agent（多工具 + 多 Hook + 多存储）：**

```moonbit
let agent = @posoco.Agent::new(
  openai_model,
  tools=[shell_tools, mcp_bridge],              // 多个 ToolProvider
  hooks=[audit_hook, approval_hook],             // 链式 Hook
  memory=[vector_store],                         // 记忆
  compressors=[SlidingWindowCompressor::{ max_messages: 20 }],
  observers=[console_observer, metrics_observer],// 多个 observer 扇出
  sessions=[sqlite_store, backup_store],         // write-all / read-first
  lifecycle=Some(managed_resources),
  config={ max_tool_rounds: 10, temperature: Some(0.7),
    max_output_tokens: Some(4096), tool_choice: None,
    thinking: None, model_context_window: Some(128000) },
)

// 检查工具名碰撞
let warnings = agent.tool_collisions()
for w in warnings {
  println("⚠️ " + w)
}
```

---

## 运行模式

### 单轮对话

```moonbit
let msg : @posoco.Message = {
  role: User, content: [Text("What is 2+2?")],
  tool_calls: [], tool_call_id: None, name: None,
}
let result = try? agent.run_turn(msg, "session-1")
match result {
  Ok(r) => println(r.message.content)  // "2+2 equals 4"
  Err(e) => println("Error: " + e.to_string())
}
```

### 多轮对话

用同一个 `session_id` 反复调用 `run_turn`。SessionStore 自动管理历史消息。

```moonbit
let session_id = "user-123"

// 第 1 轮
let r1 = try? agent.run_turn(user_msg("Hello"), session_id)

// 第 2 轮 — Agent 自动加载之前的对话历史
let r2 = try? agent.run_turn(user_msg("What did I just say?"), session_id)
```

### 并行工具执行

当 LLM 返回多个 `tool_calls` 时，Agent 通过 `@async.all` 并行执行。**无需开发者干预**——这是 `run_turn` 的内置行为。

Agent 内部通过 `ToolRouting` 将每个工具调用路由到正确的 ToolProvider：

```moonbit
// 假设 LLM 返回 3 个 tool_calls:
// [bash("ls"), bash("pwd"), search("query")]
//
// Agent 内部:
// bash("ls")   → tool_routing.tool_map["bash"]  → shell_tools.execute(...)
// bash("pwd")  → tool_routing.tool_map["bash"]  → shell_tools.execute(...)
// search("query") → tool_routing.tool_map["search"] → mcp_bridge.execute(...)
//
// 3 个调用并行执行，全部完成后合并结果
```

---

## 错误处理

### 错误层次

```
AgentError
  ├── Model(String)           ← ModelError 转换
  ├── Session(SessionError)   ← SessionError 包装
  ├── Runtime(RuntimeError)   ← RuntimeError 包装
  ├── ToolLoopExceeded        ← 超过 max_tool_rounds
  └── HookAborted(String)    ← PipelineHook 主动中止
```

### 调用方错误处理

```moonbit
let result = try? agent.run_turn(msg, session_id)
match result {
  Ok(turn_result) => {
    println("Response: " + turn_result.message.content)
    println("Session: " + turn_result.final_session_id)
  }
  Err(e) => {
    match e {
      Model(msg) => println("Model error: " + msg)
      Session(err) => println("Session error: " + err.to_string())
      ToolLoopExceeded => println("Too many tool calls!")
      HookAborted(msg) => println("Hook aborted: " + msg)
      Runtime(err) => println("Runtime error: " + err.to_string())
    }
  }
}
```

### 工具失败韧性

工具执行失败**不会终止 turn**。失败的工具调用会被转为 `ToolResult(is_error=true)` 并发回 LLM，让 LLM 决定下一步。

### Observer 内错误

Observer.on_event 是 fire-and-forget。Agent 内部对每个 observer 的调用异常被静默忽略。这是设计决定：Observer 不应影响主流程。

---

## 会话管理

### Session 结构

```moonbit
pub(all) struct Session {
  messages : Array[Message]       // 完整的消息历史
  metadata : Map[String, Json]    // 元数据（如 parent_session_id）
}
```

### 多 SessionStore

传入多个 SessionStore 时，Agent 的行为是 **write-all / read-first**：

- **保存**：遍历所有 store，每个都 `save()`
- **加载**：只从第一个 store `load()`

典型场景：主存储 + 备份存储。

### Session Redirect

当 Compressor 返回 `NewThread` 时，session 可能被重定向。**重要**：始终使用 `TurnResult.final_session_id` 作为下一次调用的 session_id。

```moonbit
let mut current_session = "session-1"
let r1 = try? agent.run_turn(msg1, current_session)
match r1 {
  Ok(result) => current_session = result.final_session_id  // 可能已重定向
  Err(_) => ()
}
let r2 = try? agent.run_turn(msg2, current_session)
```

---

## 内置组件参考

### NoopCompressor

永远返回 `None`（不压缩）。适用场景：不需要上下文管理的简单 Agent、测试。

### NoopHook

`on_stage()` 直接返回 `Ok(stage)`（透传）。适用场景：测试。

### HookChain

按序调用每个 hook，遇到 Err 短路返回。**内部组件**——Agent 在 `hooks` 数组 >1 时自动创建，开发者无需手动使用。

### CompositeToolProvider

合并多个 ToolProvider 的工具列表。**内部组件**——Agent 通过 `ToolRouting` 自行处理，开发者无需手动使用。

### ToolRegistry

动态运行时注册工具，同时存储定义和执行器。实现 `ToolProvider`，可直接传给 `Agent::new(tools=[...])`。

```moonbit
let registry = @posoco.ToolRegistry::new()
registry.register(tool_def, fn(call) { /* execute */ })

// 可以直接传给 Agent
let agent = @posoco.Agent::new(
  model,
  tools=[registry],
  // ...
)
```

### NoopMemoryPort / NoopLifecycle

全部操作 raise error / 空操作。**推荐**：直接传空数组 `memory=[]` 或 `lifecycle=None`。

---

## 生命周期管理

```moonbit
// 程序退出时调用
agent.shutdown()
```

`shutdown` 调用 `Lifecycle.on_shutdown()`，内部异常被静默捕获。对于持有外部连接的组件（如 MCP 客户端），应实现 Lifecycle。

---

## 常见模式

### 模式 1: 多工具提供者

多个 ToolProvider 直接放入数组，Agent 内部按工具名路由。

```moonbit
let agent = @posoco.Agent::new(
  model,
  tools=[shell_tools, mcp_bridge, custom_tools],
  // ... 工具名碰撞: tool_collisions() 报告
)
```

### 模式 2: 多 Hook 链式调用

按序放入数组，第一个 hook 先执行。

```moonbit
let agent = @posoco.Agent::new(
  model,
  tools=[...],
  hooks=[audit_hook, approval_hook, rewrite_hook],
  // approval_hook 返回 Deferred 时，rewrite_hook 不执行（短路）
)
```

### 模式 3: 保守配置 vs 激进配置

```moonbit
// 保守：低温度，限制工具轮数
let conservative = {
  max_tool_rounds: 3, temperature: Some(0.1),
  max_output_tokens: Some(1024), tool_choice: None,
  thinking: None, model_context_window: Some(4096),
}

// 激进：高温度，允许更多探索
let aggressive = {
  max_tool_rounds: 15, temperature: Some(0.9),
  max_output_tokens: Some(8192), tool_choice: Some(Auto),
  thinking: Some(true), model_context_window: Some(128000),
}
```

## 下一步

- [03-trait-recipes.md](03-trait-recipes.md) — 每个 trait 的详细实现配方
- [05-streaming-guide.md](05-streaming-guide.md) — 流式响应实现
