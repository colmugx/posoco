# colmugx/posoco

**零依赖的 LLM Agent 框架 — 基于 Ports 架构。**

Posoco 定义了 8 个 trait 接口 + 一个 `Agent::run_turn` 循环。所有非核心功能通过扩展包提供，核心零运行时依赖。

---

## 快速一览

```moonbit nocheck
// 1. 实现 trait
let model = MyModelPort::{ .. }
let tools = MyToolProvider::{ .. }
let runtime = MyToolRuntime::{ .. }
let store = MySessionStore::{ .. }
let observer = MyObserver::{ .. }

// 2. 构建 Agent（9 个参数）
let agent = Agent::new(model, tools, runtime, store, observer,
  NoopCompressor::{ }, None, None, AgentConfig::{ max_tool_rounds: 10, .. })

// 3. 运行
let result = agent.run_turn(user_msg("hello"), "session_1")
```

---

## 核心概念

### 8 个 Trait（Port 接口）

| Trait | 职责 | 典型实现 |
|-------|------|----------|
| `ModelPort` | LLM 聊天补全 | `OpenAIModelPort`（HTTP → OpenAI/Anthropic） |
| `ToolProvider` | 列出可用工具 | `MCPToolProvider`（MCP 协议发现） |
| `ToolRuntime` | 执行工具调用 | `WasmToolRuntime`（沙箱执行） |
| `SessionStore` | 持久化会话 | `SQLiteSessionStore` |
| `Observer` | 实时事件订阅 | `EventBusObserver`（事件总线） |
| `Compressor` *可选* | 上下文压缩 | `AdaptiveCompressor`（自适应压缩策略） |
| `PipelineHook` *可选* | 流水线拦截 | `RTKHook`（通过 RTK 重写 shell 命令） |
| `MemoryPort` *可选* | 长期记忆存储 | 向量数据库插件 |

### 架构分层

```
Layer 3 — Agent（程序 / 组合）
  Agent struct 持有 &Trait 引用（无泛型）
  run_turn() 编排整个循环

Layer 2 — Interpreters（运行时 / 注入）
  |  扩展包实现 trait（MCP、RTK……）

Layer 1 — Traits（效应接口 / 纯声明）
  8 个 trait + 共享类型（Message、ToolCall、Session……）
```

### Agent.run_turn 循环

```
run_turn(input, session_id)
  │
  ├─ PipelineHook.on_stage(BeforeTurn)
  ├─ Observer.on_event(TurnStarted)
  ├─ SessionStore.load(session_id)
  ├─ Compressor.compress(messages)      ← 每轮 LLM 前执行
  ├─ PipelineHook.on_stage(BeforeModel)
  ├─ ModelPort.chat(messages, tools)    ← LLM 调用
  ├─ PipelineHook.on_stage(AfterModel)
  │
  ├─ [工具循环] max_tool_rounds 上限
  │   ├─ PipelineHook.on_stage(BeforeTool)  ← ✦ RTKHook 在此拦截
  │   ├─ ToolRuntime.execute(tool_call)
  │   ├─ PipelineHook.on_stage(AfterTool)
  │   └─ Observer.on_event(ToolCallResult)
  │
  ├─ SessionStore.save(session)
  ├─ Observer.on_event(TurnCompleted)
  └─ PipelineHook.on_stage(AfterTurn)
```

---

## 安装

```json
// moon.mod.json
{
  "deps": {
    "colmugx/posoco": { "path": "../posoco" }
  }
}
```

```moonbit nocheck
// moon.pkg
import { "colmugx/posoco" }
```

---

## API 参考

### Agent

```moonbit nocheck
/// Agent 配置
pub(all) struct AgentConfig {
  max_tool_rounds : Int           // 工具循环上限（默认 10）
  temperature : Double?           // LLM 温度
  max_output_tokens : Int?        // 最大输出 Token
  tool_choice : ToolChoice?       // 工具选择策略
  thinking : Bool?                // 是否启用思考
  model_context_window : Int?      // 模型上下文窗口（传给 Compressor）
}

/// Agent — 中央运行时
pub(all) struct Agent {
  model_port : &ModelPort
  tool_provider : &ToolProvider
  tool_runtime : &ToolRuntime
  session_store : &SessionStore
  observer : &Observer
  compressor : &Compressor
  pipeline_hook : &PipelineHook?
  memory_port : &MemoryPort?
  config : AgentConfig
}

/// 构造 Agent（传入 9 个 trait 引用）
pub fn Agent::new(
  model_port : &ModelPort,
  tool_provider : &ToolProvider,
  tool_runtime : &ToolRuntime,
  session_store : &SessionStore,
  observer : &Observer,
  compressor : &Compressor,
  pipeline_hook : &PipelineHook?,
  memory_port : &MemoryPort?,
  config : AgentConfig,
) -> Agent

/// 运行一轮（错误通过 raise 传播）
pub fn Agent::run_turn(self : Agent, input : Message, session_id : String) -> TurnResult raise AgentError
```

### 核心类型

```moonbit nocheck
///|
/// 角色
pub(all) enum Role {
  System
  User
  Assistant
  Tool
}

///|
/// 消息内容
pub(all) enum Content {
  Text(String)
  Image(String, String)
}

///|
/// 工具调用
pub(all) struct ToolCall {
  id : String
  name : String
  arguments : Json
}

///|
/// 消息
pub(all) struct Message {
  role : Role
  content : Array[Content]
  tool_calls : Array[ToolCall]
  tool_call_id : String?
  name : String?
}

///|
/// 工具定义
pub(all) struct ToolDef {
  name : String
  description : String
  input_schema : Json
}

///|
/// 工具执行结果
pub(all) struct ToolResult {
  content : String
  structured : Json?
  is_error : Bool
}

///|
/// 模型响应
pub(all) struct ModelResponse {
  message : Message
  tool_calls : Array[ToolCall]
  finish_reason : FinishReason
  usage : Usage?
  reasoning_summary : String?
}

///|
/// 会话
pub(all) struct Session {
  messages : Array[Message]
  metadata : Map[String, Json]
}

///|
/// 一轮结果
pub(all) struct TurnResult {
  message : Message
  tool_results : Array[ToolResult]
  final_session_id : String
}
```

### 8 个 Trait 定义

```moonbit nocheck
///|
/// LLM 模型端口
pub(open) trait ModelPort {
  chat(
    Self,
    messages : Array[Message],
    tools : Array[ToolDef],
    options : ChatOptions,
  ) -> ModelResponse raise ModelError
}

///|
/// 工具发现
pub(open) trait ToolProvider {
  list_tools(Self) -> Array[ToolDef]
}

///|
/// 工具执行
pub(open) trait ToolRuntime {
  execute(Self, name : String, call : ToolCall) -> Result[
    ToolResult,
    RuntimeError,
  ]
}

///|
/// 会话存储
pub(open) trait SessionStore {
  load(Self, id : String) -> Result[Session, SessionError]
  save(Self, id : String, session : Session) -> Result[Unit, SessionError]
}

///|
/// 事件观察者（只读，永不阻塞）
pub(open) trait Observer {
  on_event(Self, event : TurnEvent) -> Unit
}

///|
/// 上下文压缩器（纯函数，返回指令）
pub(open) trait Compressor {
  compress(Self, messages : Array[Message], ctx : CompressContext) -> CompressAction
}

///|
/// 流水线钩子（可变更 Stage，返回 Result，可中止）
pub(open) trait PipelineHook {
  on_stage(Self, stage : Stage) -> Result[Stage, HookError]
}

///|
/// 长期记忆端口（可选）
pub(open) trait MemoryPort {
  store(Self, entry : MemoryEntry) -> String raise MemoryError
  search(Self, query : MemoryQuery) -> Array[MemoryEntry] raise MemoryError
  delete(Self, id : String) -> Unit raise MemoryError
}
```
### PipelineStage（9 个阶段）

```moonbit nocheck
///|
pub(all) enum Stage {
  BeforeTurn // 轮次开始
  BeforeModel(Array[Message]) // LLM 调用前
  AfterModel(ModelResponse) // LLM 响应后
  ModelError(String) // LLM 出错（错误信息）
  BeforeTool(ToolCall) // 工具执行前 ← ✦ RTKHook 目标
  AfterTool(ToolCall, ToolResult) // 工具执行后
  ToolError(ToolCall, RuntimeError) // 工具出错
  AfterTurn(TurnResult) // 轮次结束
  TurnError(AgentError) // 轮次出错
}
```

### TurnEvent（9 个变体）

```moonbit nocheck
pub(all) enum TurnEvent {
  TurnStarted
  ToolCallPending(ToolCall)
  ToolCallResult(call~ , result~ , is_error~ : Bool)
  ModelResponseReceived(message~ , usage~ , reasoning_summary~ )
  SessionRedirect(from~ , to~ , messages_before~ , messages_after~ )
  TurnCompleted
  TurnFailed(String)
  ToolCallDeferred(call~ , reason~ : String) // 工具被延迟执行
  Custom(source~ , label~ , data~ : Json) // 自定义事件
}
```

### 内置实现

```moonbit nocheck
/// 无操作压缩器 — 始终返回 None
pub(all) struct NoopCompressor {}

/// 无操作钩子 — 全部放行
pub(all) struct NoopHook {}

/// 钩子链 — 按顺序执行多个 PipelineHook
pub(all) struct HookChain { hooks : Array[&PipelineHook] }

/// 组合多个 ToolProvider
pub(all) struct CompositeToolProvider { providers : Array[&ToolProvider] }

/// 动态注册工具
pub(all) struct ToolRegistry { mut tools : Map[String, ToolDef] }

/// 无操作记忆端口
pub(all) struct NoopMemoryPort {}

/// 构建工具结果消息
pub fn build_tool_result_message(call : ToolCall, result : ToolResult) -> Message

/// 构建工具错误消息
pub fn build_error_message(call : ToolCall, error : RuntimeError) -> Message
```

---

## 错误模型

工具失败是**非致命的** — 错误变成消息传给 LLM。只有模型错误会终止本轮。

```moonbit nocheck
///
/// Agent 顶层错误（使用 suberror 而非 enum）
pub(all) suberror AgentError {
  Model(String) // LLM 错误 → 终止本轮
  Session(SessionError) // 会话错误 → 终止本轮
  Runtime(RuntimeError) // 运行时错误 → 非致命，转为消息
  ToolLoopExceeded // 工具循环超限 → 终止本轮
  HookAborted(String) // Hook 中止 → 终止本轮
}

/// Hook 错误（可中止或延迟）
pub(all) enum HookError {
  Aborted(String) // 终止轮次
  Deferred(String) // 延迟执行，通知 LLM
}

/// ModelError、SessionError、RuntimeError、MemoryError 都使用 suberror
pub(all) suberror ModelError {
  RequestBuild(String)
  Transport(String)
  ResponseParse(String)
}
```

错误通过 `raise` 传播，而非 `Result` 返回：

```moonbit nocheck
// ModelPort::chat 返回 ModelResponse raise ModelError
// Agent::run_turn 返回 TurnResult raise AgentError
pub fn Agent::run_turn(self : Agent, input : Message, session_id : String) -> TurnResult raise AgentError
```

---

## 扩展机制

Posoco 所有非核心功能通过扩展包提供。核心零运行时依赖扩展。

| 扩展类型 | Trait | 示例包 |
|----------|-------|--------|
| Provider | `ModelPort` | `posoco-ext-openai` |
| Tool Discovery | `ToolProvider` | `posoco-ext-mcp` |
| Tool Execution | `ToolRuntime` | `posoco-ext-wasm` |
| Session | `SessionStore` | `posoco-ext-sqlite` |
| Observer | `Observer` | `posoco-ext-vein` |
|| Compressor | `Compressor` | `posoco-ext-adaptive` |
| Hook | `PipelineHook` | `posoco-ext-rtk` |
| Memory | `MemoryPort` | `posoco-ext-vector` |

> 完整扩展指南 → [`docs/EXTENSIONS.md`](./docs/EXTENSIONS.md)

---

## 更多文档

| 文档 | 说明 |
|------|------|
| [`docs/architecture.md`](./docs/architecture.md) | 完整架构设计：三层架构、类型定义、run_turn 循环伪代码 |
| [`docs/DEVELOPING.md`](./docs/DEVELOPING.md) | MoonBit 语法陷阱与编码约定（必读） |
| [`docs/EXTENSIONS.md`](./docs/EXTENSIONS.md) | 扩展模型 & 创建指南 |
| [`docs/TESTING.md`](./docs/TESTING.md) | Mock 模式、测试覆盖图、常见陷阱 |
| [`docs/MIGRATION.md`](./docs/MIGRATION.md) | v1 到 v2 迁移指南 |

---

## 构建 & 测试

```bash
moon check                           # 类型检查
moon test                            # 全部测试（黑盒+白盒）
moon test posoco_wbtest              # 仅白盒
moon test --update                   # 刷新快照
moon fmt                             # 格式化
moon info                            # 更新 .mbti 接口文件
```

**提交流程**（推送前运行全部 4 步）：

```bash
moon check && moon test && moon fmt && moon info
```

---

## 许可证

Apache-2.0