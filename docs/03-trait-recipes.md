# 03 — Trait 实现配方集

每种 trait 的完整实现指南：签名、最小模板、经典用法（Recipes）和测试方法。

> 所有代码签名来源于 `src/port.mbt`、`src/types.mbt`、`src/builtin.mbt`。

---

## 1. ModelPort

### 签名

```moonbit
pub(open) trait ModelPort {
  async fn chat(
    Self,
    messages : Array[Message],
    tools : Array[ToolDef],
    options : ChatOptions,
  ) -> ModelResponse raise ModelError

  async fn chat_streaming(
    Self,
    messages : Array[Message],
    tools : Array[ToolDef],
    options : ChatOptions,
    on_chunk : (StreamChunk) -> Unit,
  ) -> ModelResponse raise ModelError  // 默认 fallback 到 chat()
}
```

`chat_streaming` 有默认实现（忽略 `on_chunk`，直接调用 `chat()`）。只需要实现 `chat` 就能得到一个完整的 ModelPort。

### 最小实现模板

```moonbit
pub(all) struct MyModelPort {
  api_key : String
  model : String
}

pub impl @posoco.ModelPort for MyModelPort with fn chat(
  self : MyModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
) -> @posoco.ModelResponse raise @posoco.ModelError {
  // 1. 将 messages 转换为目标 API 格式
  // 2. 发起 HTTP 请求
  // 3. 解析响应为 ModelResponse
  // 失败时 raise ModelError::Transport("...")
  @posoco.ModelResponse::{
    message: { role: Assistant, content: [Text("response")], tool_calls: [],
               tool_call_id: None, name: None },
    tool_calls: [],
    finish_reason: Stop,
    usage: None,
    reasoning_summary: None,
  }
}
// chat_streaming 自动 fallback 到 chat()
```

### Recipe A: Mock Provider（测试用）

返回预设响应，用于测试 Agent 逻辑而不依赖真实 LLM。

```moonbit
pub(all) struct MockModelPort {
  mut response_index : Int
  responses : Array[@posoco.ModelResponse]
}

pub fn MockModelPort::new(
  responses : Array[@posoco.ModelResponse],
) -> MockModelPort {
  { response_index: 0, responses }
}

pub impl @posoco.ModelPort for MockModelPort with fn chat(
  self : MockModelPort,
  _messages : Array[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
) -> @posoco.ModelResponse {
  let idx = self.response_index
  self.response_index = idx + 1
  if idx < self.responses.length() {
    self.responses[idx]
  } else {
    // 默认：纯文本响应
    let msg : @posoco.Message = {
      role: Assistant, content: [Text("mock")],
      tool_calls: [], tool_call_id: None, name: None,
    }
    { message: msg, tool_calls: [], finish_reason: Stop,
      usage: None, reasoning_summary: None }
  }
}
```

**用法**：构造时传入预期的响应序列，Agent 会依次返回。

### Recipe B: 条件路由 Provider

根据输入内容决定返回文本还是工具调用。适合 demo 和快速原型。

```moonbit
pub(all) struct EchoModelPort {}

pub impl @posoco.ModelPort for EchoModelPort with fn chat(
  self : EchoModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  _options : @posoco.ChatOptions,
) -> @posoco.ModelResponse {
  let user_text = match messages {
    [.., msg] if msg.role == User =>
      match msg.content { [Text(t), ..] => t; _ => "" }
    _ => ""
  }

  // 如果像命令，调用第一个工具
  if user_text.has_prefix("$ ") && !tools.is_empty() {
    let tool = tools[0]
    let cmd = user_text["$ ".length():].to_owned()
    let tc : ToolCall = {
      id: "call_1", name: tool.name,
      arguments: Json::object(Map::from_array([("input", Json::string(cmd))])),
    }
    let msg : Message = {
      role: Assistant, content: [], tool_calls: [tc],
      tool_call_id: None, name: None,
    }
    { message: msg, tool_calls: [tc], finish_reason: ToolCalls,
      usage: None, reasoning_summary: None }
  } else {
    let msg : Message = {
      role: Assistant, content: [Text("Echo: " + user_text)],
      tool_calls: [], tool_call_id: None, name: None,
    }
    { message: msg, tool_calls: [], finish_reason: Stop,
      usage: None, reasoning_summary: None }
  }
}
```

### Recipe C: Streaming Provider（OpenAI 模式）

override `chat_streaming`，逐 token 发出 StreamChunk。

```moonbit
pub impl @posoco.ModelPort for OpenAIModelPort with fn chat_streaming(
  self : OpenAIModelPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  on_chunk : (@posoco.StreamChunk) -> Unit,
) -> @posoco.ModelResponse raise @posoco.ModelError {
  // 1. 构建请求
  let body = build_request_body(messages, tools, options, stream=true)
  let client = @http.Client::new(self.config.base_url, headers)

  // 2. 发起 SSE 请求
  client.request("POST", "/responses", body) catch {
    e => raise ModelError::Transport(e.to_string())
  }
  client.write(body) catch { e => { client.close(); raise Transport(e.to_string()) } }
  client.flush() catch { _ => () }
  client.end_request() catch { _ => () }

  // 3. 用 StreamAccumulator 累积
  let acc = @posoco.StreamAccumulator::new()

  // 4. 逐行读取 SSE
  let mut done = false
  while !done {
    let line = client.read_until("\n") catch { _ => None }
    match line {
      Some(data) => {
        if data.has_prefix("data: ") {
          let json_str = data["data: ".length():].to_owned()
          let event = @json.parse(json_str) catch { _ => continue }
          match process_sse_event(event) {
            Some(chunk) => {
              on_chunk(chunk)         // 通知 Observer
              acc.push(chunk)         // 累积
            }
            None => done = true       // [DONE]
          }
        }
      }
      None => done = true
    }
  }
  client.close()

  // 5. 转为最终响应
  acc.to_response()
}
```

> 完整 SSE 解析见 [05-streaming-guide.md](05-streaming-guide.md)。

### 测试方法

```moonbit
async test("mock model returns preset responses") {
  let mock = MockModelPort::new([
    @posoco.ModelResponse::{ message: msg1, tool_calls: [], finish_reason: Stop, usage: None, reasoning_summary: None },
    @posoco.ModelResponse::{ message: msg2, tool_calls: [], finish_reason: Stop, usage: None, reasoning_summary: None },
  ])
  let r1 = mock.chat([], [], { temperature: None, max_output_tokens: None, tool_choice: None, thinking: None })
  let r2 = mock.chat([], [], { temperature: None, max_output_tokens: None, tool_choice: None, thinking: None })
  assert_eq!(r1.message.content, [Text("first")])
  assert_eq!(r2.message.content, [Text("second")])
}
```

---

## 2. ToolProvider

### 签名

```moonbit
pub(open) trait ToolProvider {
  async fn list_tools(Self) -> Array[ToolDef]
}
```

`ToolDef` 结构：

```moonbit
pub(all) struct ToolDef {
  name : String
  description : String
  input_schema : Json        // JSON Schema
  metadata : Json?
}
```

### 最小实现模板

```moonbit
pub(all) struct MyToolProvider {}

pub impl @posoco.ToolProvider for MyToolProvider with fn list_tools(
  _self,
) -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: "my_tool",
      description: "Does something useful",
      input_schema: Json::object(Map::from_array([
        ("type", Json::string("object")),
        ("properties", Json::object(Map::from_array([
          ("input", Json::object(Map::from_array([
            ("type", Json::string("string")),
            ("description", Json::string("The input parameter")),
          ]))),
        ]))),
        ("required", Json::array([Json::string("input")])),
      ])),
      metadata: None,
    },
  ]
}
```

### Recipe A: 静态工具列表

硬编码一组工具，最简单的模式。适合工具集固定的场景。

```moonbit
pub(all) struct CalcToolProvider {}

pub impl @posoco.ToolProvider for CalcToolProvider with fn list_tools(
  _self,
) -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef::{
      name: "add",
      description: "Add two numbers",
      input_schema: Json::object(Map::from_array([
        ("type", Json::string("object")),
        ("properties", Json::object(Map::from_array([
          ("a", Json::object(Map::from_array([("type", Json::string("number"))]))),
          ("b", Json::object(Map::from_array([("type", Json::string("number"))]))),
        ]))),
        ("required", Json::array([Json::string("a"), Json::string("b")])),
      ])),
      metadata: None,
    },
    @posoco.ToolDef::{
      name: "multiply",
      description: "Multiply two numbers",
      input_schema: Json::object(Map::from_array([
        ("type", Json::string("object")),
        ("properties", Json::object(Map::from_array([
          ("a", Json::object(Map::from_array([("type", Json::string("number"))]))),
          ("b", Json::object(Map::from_array([("type", Json::string("number"))]))),
        ]))),
        ("required", Json::array([Json::string("a"), Json::string("b")])),
      ])),
      metadata: None,
    },
  ]
}
```

### Recipe B: 动态注册（ToolRegistry）

运行时增删工具。ToolRegistry 是内置的 ToolProvider 实现。

```moonbit
let registry = @posoco.ToolRegistry::new()

// 注册工具
registry.register(@posoco.ToolDef::{
  name: "search",
  description: "Search the web",
  input_schema: Json::object(Map::from_array([
    ("type", Json::string("object")),
    ("properties", Json::object(Map::from_array([
      ("query", Json::object(Map::from_array([("type", Json::string("string"))]))),
    ]))),
  ])),
  metadata: None,
})

// 注销工具
registry.unregister("search")
```

### Recipe C: 组合多个 Provider

用 `CompositeToolProvider` 合并多个来源的工具。

```moonbit
let provider = @posoco.CompositeToolProvider::{
  providers: [bash_provider, mcp_provider, calc_provider],
}
// list_tools() 会返回所有 provider 的工具之和
```

### 测试方法

```moonbit
async test("list_tools returns expected tools") {
  let provider = CalcToolProvider::{}
  let tools = provider.list_tools()
  assert_eq!(tools.length(), 2)
  assert_eq!(tools[0].name, "add")
  assert_eq!(tools[1].name, "multiply")
}
```

---

## 3. ToolProvider（统一：声明 + 执行）

### 签名

```moonbit
pub(open) trait ToolProvider {
  fn list_tools(Self) -> Array[ToolDef]
  async fn execute(Self, name : String, call : ToolCall) -> ToolResult raise RuntimeError
}
```

`ToolCall` 和 `ToolResult`：

```moonbit
pub(all) struct ToolCall {
  id : String
  name : String
  arguments : Json
}

pub(all) struct ToolResult {
  content : String
  structured : Json?
  is_error : Bool
}
```

### 最小实现模板

```moonbit
pub(all) struct MyTools {}

pub impl @posoco.ToolProvider for MyTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  [
    @posoco.ToolDef::{
      name: "my_tool",
      description: "Does something",
      input_schema: Json::object({}),
      metadata: None,
      source: None,
    },
  ]
}

pub impl @posoco.ToolProvider for MyTools with fn execute(
  _self,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  match name {
    "my_tool" => {
      @posoco.ToolResult::{
        content: "result text",
        structured: None,
        is_error: false,
      }
    }
    _ => raise @posoco.RuntimeError::UnknownTool("Unknown tool: " + name)
  }
}
```

### Recipe A: Shell 执行

执行 bash 命令，捕获 stdout。这是 `posoco_ext_bash` 的核心模式。

```moonbit
pub(all) struct ShellTools {}

pub impl @posoco.ToolProvider for ShellTools with fn list_tools(_self) -> Array[
  @posoco.ToolDef,
] {
  [
    @posoco.ToolDef::{
      name: "bash",
      description: "Execute a shell command",
      input_schema: Json::object(Map::from_array([("cmd", Json::string("command"))])),
      metadata: None,
      source: Some("posoco_ext_bash"),
    },
  ]
}

pub impl @posoco.ToolProvider for ShellTools with fn execute(
  _self,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  let cmd = match call.arguments {
    Json::Object(map) =>
      match map.get("cmd") {
        Some(Json::String(s)) => s
        _ => call.arguments.to_string()
      }
    _ => call.arguments.to_string()
  }

  if cmd == "" {
    raise @posoco.RuntimeError::InvocationFailed("empty command")
  }

  let (exit_code, output) = @process.collect_output_merged("sh", [
    "-c", cmd,
  ]) catch {
    e => raise RuntimeError::InvocationFailed(e.to_string())
  }

  let content = output.text() catch { _ => "(decoding error)" }
  @posoco.ToolResult::{ content, structured: None, is_error: exit_code != 0 }
}
```

### Recipe B: 多 Provider 路由（Agent 内部自动处理）

传入多个 ToolProvider 到 `Agent::new(tools=[...])`，Agent 内部按工具名自动路由。

```moonbit
let agent = @posoco.Agent::new(
  model,
  tools=[shell_tools, mcp_bridge],   // Agent 内部用 ToolRouting 按 name 路由
  hooks=[],
  memory=[],
  compressors=[@posoco.NoopCompressor::{}],
  observers=[my_observer],
  sessions=[my_store],
  lifecycle=None,
  config=my_config,
)

// 检查碰撞
let warnings = agent.tool_collisions()
for w in warnings {
  println("⚠️ " + w)
}
```

### Recipe C: 错误处理策略

**关键区分**：何时 raise vs 何时返回 ToolResult(is_error=true)。

```moonbit
pub impl @posoco.ToolProvider for MyTools with fn execute(
  _self, name : String, call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {

  // 1. 工具不存在 → raise（框架级错误）
  if name != "expected_tool" {
    raise RuntimeError::UnknownTool("not found: " + name)
  }

  // 2. 参数无效 → 返回 is_error=true（让 LLM 自行修正）
  let input = parse_input(call.arguments)
  if input == "" {
    return { content: "Error: empty input", structured: None, is_error: true }
  }

  // 3. 执行成功
  let result = do_work(input) catch {
    // 4. 执行失败 → 可以 raise（变成 AgentError::Runtime）
    //    或返回 is_error=true（让 LLM 重试）
    e => return { content: "Execution failed: " + e.to_string(),
                  structured: None, is_error: true }
  }

  { content: result, structured: None, is_error: false }
}
```

**经验法则**：
- `raise`：工具根本不存在、基础设施故障
- `ToolResult(is_error=true)`：参数错误、执行失败（LLM 可修正的情况）

### 测试方法

```moonbit
async test("shell tools execute commands") {
  let tools = ShellTools::{}
  let call : @posoco.ToolCall = {
    id: "test", name: "bash",
    arguments: Json::object(Map::from_array([("cmd", Json::string("echo hello"))])),
  }
  let result = tools.execute("bash", call)
  assert_eq!(result.is_error, false)
  assert_eq!(result.content.trim().to_owned(), "hello")
}
```

---

## 4. SessionStore

### 签名

```moonbit
pub(open) trait SessionStore {
  fn load(Self, id : String) -> Result[Session, SessionError]
  fn save(Self, id : String, session : Session) -> Result[Unit, SessionError]
}
```

`Session` 结构：

```moonbit
pub(all) struct Session {
  messages : Array[Message]
  metadata : Map[String, Json]
}
```

### 最小实现模板

```moonbit
pub(all) struct InMemorySessionStore {
  mut store : Map[String, @posoco.Session]
}

pub fn InMemorySessionStore::new() -> InMemorySessionStore {
  { store: {} }
}

pub impl @posoco.SessionStore for InMemorySessionStore with fn load(
  self, id : String,
) -> Result[@posoco.Session, @posoco.SessionError] {
  match self.store.get(id) {
    Some(s) => Ok(s)
    None => Ok({ messages: [], metadata: {} })  // 未知 ID → 空 session
  }
}

pub impl @posoco.SessionStore for InMemorySessionStore with fn save(
  self, id : String, session : @posoco.Session,
) -> Result[Unit, @posoco.SessionError] {
  self.store[id] = session
  Ok(())
}
```

### Recipe A: 内存 Map

上面的最小模板。适合测试和短命 Agent。**注意**：非线程安全。

### Recipe B: 文件持久化

每次 save 写入 JSON 文件，load 从文件读取。

```moonbit
pub(all) struct FileSessionStore {
  dir : String  // 目录路径，如 "/tmp/sessions"
}

pub impl @posoco.SessionStore for FileSessionStore with fn load(
  self, id : String,
) -> Result[@posoco.Session, @posoco.SessionError] {
  let path = self.dir + "/" + id + ".json"
  let content = @fs.read_file(path) catch {
    _ => return Ok({ messages: [], metadata: {} })  // 文件不存在 → 空 session
  }
  let json = @json.parse(content) catch {
    _ => return Err(@posoco.SessionError::Load("invalid JSON"))
  }
  // 解析 json → Session
  parse_session(json)
}

pub impl @posoco.SessionStore for FileSessionStore with fn save(
  self, id : String, session : @posoco.Session,
) -> Result[Unit, @posoco.SessionError] {
  let path = self.dir + "/" + id + ".json"
  let json = session_to_json(session)
  @fs.write_file(path, json.to_string()) catch {
    e => return Err(@posoco.SessionError::Save(e.to_string()))
  }
  Ok(())
}
```

### Recipe C: 惰性保存 + 批量写入

对于高吞吐场景，可以用内存 buffer + 定期 flush。

```moonbit
pub(all) struct BufferedSessionStore {
  inner : InMemorySessionStore
  mut dirty : Set[String]     // 脏 session ID 集合
  backend : FileSessionStore  // 持久化后端
}

// load 直接从内存读（快）
// save 只标记 dirty（不立即写文件）
// flush() 批量写所有 dirty sessions
```

### 关键模式：未知 ID 处理

**约定**：当 `load` 收到不存在的 session_id 时，应返回空 session 而不是错误。

```moonbit
// ✅ 正确：返回空 session
Ok({ messages: [], metadata: {} })

// ❌ 错误：返回 Err（会导致 Agent 无法开始新对话）
Err(SessionError::Load("not found"))
```

### 测试方法

```moonbit
test("session store round-trip") {
  let store = InMemorySessionStore::new()
  let session : @posoco.Session = {
    messages: [{ role: User, content: [Text("hello")], tool_calls: [],
                tool_call_id: None, name: None }],
    metadata: {},
  }
  let save_result = store.save("test", session)
  assert_eq!(save_result.is_ok(), true)

  let load_result = store.load("test")
  assert_eq!(load_result.is_ok(), true)
  assert_eq!(load_result.unwrap().messages.length(), 1)
}

test("unknown session returns empty") {
  let store = InMemorySessionStore::new()
  let result = store.load("nonexistent")
  assert_eq!(result.is_ok(), true)
  assert_eq!(result.unwrap().messages.length(), 0)
}
```

---

## 5. Observer

### 签名

```moonbit
pub(open) trait Observer {
  fn on_event(Self, event : TurnEvent) -> Unit
}
```

`TurnEvent` 有 10 个变体：

```moonbit
pub(all) enum TurnEvent {
  TurnStarted
  ToolCallPending(ToolCall)
  ToolCallResult(call~ : ToolCall, result~ : ToolResult, is_error~ : Bool)
  ModelResponseReceived(message~ : Message, usage~ : Usage?, reasoning_summary~ : String?)
  SessionRedirect(from~ : String, to~ : String, messages_before~ : Int, messages_after~ : Int)
  TurnCompleted
  TurnFailed(String)
  ToolCallDeferred(call~ : ToolCall, reason~ : String)
  StreamChunkReceived(chunk~ : StreamChunk)
  Custom(source~ : String, label~ : String, data~ : Json)
}
```

### 最小实现模板

```moonbit
pub(all) struct NoopObserver {}

pub impl @posoco.Observer for NoopObserver with fn on_event(_self, _event) {
  ()  // 忽略所有事件
}
```

### Recipe A: 日志 Observer

在终端打印每个事件，用于开发和调试。

```moonbit
pub(all) struct ConsoleObserver {}

pub impl @posoco.Observer for ConsoleObserver with fn on_event(
  _self, event : @posoco.TurnEvent,
) {
  match event {
    TurnStarted => println("🔄 Turn started")
    ToolCallPending(call) => println("🔧 Calling: " + call.name)
    ToolCallResult(call~, result~, is_error~) =>
      if is_error {
        println("❌ " + call.name + ": " + result.content)
      } else {
        println("✅ " + call.name + " done")
      }
    ToolCallDeferred(call~, reason~) =>
      println("⚠️ DEFERRED: " + call.name + " — " + reason)
    ModelResponseReceived(..) => ()   // 通常不打印完整响应
    StreamChunkReceived(chunk~) =>
      match chunk {
        TextDelta(token~) => @stdio.stdout.write(token)  // 实时打印 token
        _ => ()
      }
    SessionRedirect(from~, to~, ..) =>
      println("📦 Session redirect: " + from + " → " + to)
    TurnCompleted => println("\n✅ Turn completed")
    TurnFailed(msg) => println("💥 " + msg)
    Custom(source~, label~, ..) =>
      println("📢 [" + source + "] " + label)
  }
}
```

### Recipe B: 事件收集器（测试用）

收集所有事件到数组，用于断言。

```moonbit
pub(all) struct CollectorObserver {
  mut events : Array[@posoco.TurnEvent]
}

pub fn CollectorObserver::new() -> CollectorObserver {
  { events: [] }
}

pub impl @posoco.Observer for CollectorObserver with fn on_event(
  self, event : @posoco.TurnEvent,
) {
  self.events.push(event)
}

// 使用：
// let collector = CollectorObserver::new()
// agent.run_turn(msg, sid)
// assert_eq!(collector.events.length(), 5)
// match collector.events[0] { TurnStarted => true; _ => false }
```

### Recipe C: 指标收集

统计 token 用量、工具调用次数、延迟等。

```moonbit
pub(all) struct MetricsObserver {
  mut total_input_tokens : Int
  mut total_output_tokens : Int
  mut tool_calls_count : Int
  mut tool_errors_count : Int
  mut turns_count : Int
}

pub impl @posoco.Observer for MetricsObserver with fn on_event(
  self, event : @posoco.TurnEvent,
) {
  match event {
    ModelResponseReceived(usage~, ..) =>
      match usage {
        Some(u) => {
          match u.input_tokens { Some(v) => self.total_input_tokens = self.total_input_tokens + v; None => () }
          match u.output_tokens { Some(v) => self.total_output_tokens = self.total_output_tokens + v; None => () }
        }
        None => ()
      }
    ToolCallResult(is_error~, ..) => {
      self.tool_calls_count = self.tool_calls_count + 1
      if is_error { self.tool_errors_count = self.tool_errors_count + 1 }
    }
    TurnCompleted => self.turns_count = self.turns_count + 1
    _ => ()
  }
}
```

### 测试方法

Observer 的测试通常通过 CollectorObserver 进行，验证事件序列是否符合预期。

```moonbit
test("observer receives correct event sequence") {
  let collector = CollectorObserver::new()
  collector.on_event(TurnStarted)
  collector.on_event(ToolCallPending({ id: "1", name: "bash", arguments: Json::Null }))
  collector.on_event(TurnCompleted)
  assert_eq!(collector.events.length(), 3)
}
```

---

## 6. Compressor

### 签名

```moonbit
pub(open) trait Compressor {
  fn compress(Self, messages : Array[Message], ctx : CompressContext) -> CompressAction
}
```

`CompressAction` 三种返回值：

```moonbit
pub(all) enum CompressAction {
  None                                              // 不压缩
  Replace(Array[Message])                           // 替换消息数组
  NewThread(messages~ : Array[Message],             // 新建 session
            new_session_id~ : String,
            messages_before~ : Int,
            messages_after~ : Int)
}
```

`CompressContext`：

```moonbit
pub(all) struct CompressContext {
  session_id : String
  model_context_window : Int?
}
```

### 设计规则

Compressor **只做计算**，不做 I/O：
- 不直接修改 session（Agent 负责保存）
- 不触发事件（Agent 负责发 SessionRedirect）
- 返回 `NewThread` 时，Agent 会自动保存新 session 并发出事件

### 最小实现模板

```moonbit
pub(all) struct NoopCompressor {}

pub impl @posoco.Compressor for NoopCompressor with fn compress(
  _self, _messages : Array[@posoco.Message], _ctx : @posoco.CompressContext,
) -> @posoco.CompressAction {
  None  // 永不压缩
}
```

### Recipe A: 滑动窗口

保留最近 N 条消息，丢弃更早的。

```moonbit
pub(all) struct SlidingWindowCompressor {
  max_messages : Int
}

pub impl @posoco.Compressor for SlidingWindowCompressor with fn compress(
  _self, messages : Array[@posoco.Message], _ctx : @posoco.CompressContext,
) -> @posoco.CompressAction {
  if messages.length() <= self.max_messages {
    None
  } else {
    let start = messages.length() - self.max_messages
    let kept = messages[start:].to_array()
    Replace(kept)
  }
}
```

### Recipe B: 阈值压缩

当消息数量接近 context window 的比例时触发。

```moonbit
pub(all) struct ThresholdCompressor {
  threshold_ratio : Double  // 0.0 - 1.0，如 0.8 表示 80% 时触发
  keep_ratio : Double       // 压缩后保留的比例
}

pub impl @posoco.Compressor for ThresholdCompressor with fn compress(
  _self, messages : Array[@posoco.Message], ctx : @posoco.CompressContext,
) -> @posoco.CompressAction {
  match ctx.model_context_window {
    None => None
    Some(window) => {
      // 粗略估算：每条消息 ~100 tokens
      let estimated_tokens = messages.length() * 100
      let threshold = (window.to_double() * self.threshold_ratio).ceil().to_int()
      if estimated_tokens < threshold {
        None
      } else {
        let keep_count = (messages.length().to_double() * self.keep_ratio).ceil().to_int()
        let start = messages.length() - keep_count
        Replace(messages[start:].to_array())
      }
    }
  }
}
```

### Recipe C: NewThread 压缩

将当前对话溢出到新 session，保持原 session 不变。

```moonbit
pub(all) struct NewThreadCompressor {
  max_messages : Int
}

pub impl @posoco.Compressor for NewThreadCompressor with fn compress(
  _self, messages : Array[@posoco.Message], ctx : @posoco.CompressContext,
) -> @posoco.CompressAction {
  if messages.length() <= self.max_messages {
    None
  } else {
    let summary_messages = [
      // 只保留摘要信息
      { role: System, content: [Text("Previous conversation summarized. " +
        "Messages: " + messages.length().to_string())],
        tool_calls: [], tool_call_id: None, name: None },
    ]
    NewThread(
      messages=summary_messages,
      new_session_id=ctx.session_id + "_v2",
      messages_before=messages.length(),
      messages_after=summary_messages.length(),
    )
  }
}
```

### 测试方法

```moonbit
test("sliding window compressor trims messages") {
  let comp = SlidingWindowCompressor::{ max_messages: 3 }
  let msgs = [msg1, msg2, msg3, msg4, msg5]  // 5 条消息
  let ctx = { session_id: "test", model_context_window: None }
  let action = comp.compress(msgs, ctx)
  match action {
    Replace(kept) => {
      assert_eq!(kept.length(), 3)
      assert_eq!(kept[0], msg3)  // 保留最后 3 条
    }
    _ => assert_eq!(true, false)  // 不应该走到这里
  }
}
```

---

## 7. PipelineHook

### 签名

```moonbit
pub(open) trait PipelineHook {
  async fn on_stage(Self, stage : Stage) -> Result[Stage, HookError]
}
```

`Stage` 有 9 个变体：

```moonbit
pub(all) enum Stage {
  BeforeTurn
  BeforeModel(Array[Message])
  AfterModel(ModelResponse)
  ModelError(String)
  BeforeTool(ToolCall)
  AfterTool(ToolCall, ToolResult)
  ToolError(ToolCall, RuntimeError)
  AfterTurn(TurnResult)
  TurnError(AgentError)
}
```

`HookError`：

```moonbit
pub(all) enum HookError {
  Aborted(String)                 // 终止 turn
  Deferred(reason~ : String)      // 仅 BeforeTool: 延迟/拒绝工具调用
}
```

### 最小实现模板

```moonbit
pub(all) struct NoopHook {}

pub impl @posoco.PipelineHook for NoopHook with fn on_stage(
  _self, stage : @posoco.Stage,
) -> Result[@posoco.Stage, @posoco.HookError] {
  Ok(stage)  // 透传，不做任何修改
}
```

### Recipe A: 日志审计 Hook

记录所有 Stage，用于审计和调试。

```moonbit
pub(all) struct AuditHook {
  mut log : Array[String]
}

pub impl @posoco.PipelineHook for AuditHook with fn on_stage(
  self, stage : @posoco.Stage,
) -> Result[@posoco.Stage, @posoco.HookError] {
  let entry = match stage {
    BeforeTurn => "BeforeTurn"
    BeforeModel(msgs) => "BeforeModel(" + msgs.length().to_string() + " msgs)"
    AfterModel(resp) => "AfterModel(tools=" + resp.tool_calls.length().to_string() + ")"
    ModelError(msg) => "ModelError: " + msg
    BeforeTool(call) => "BeforeTool: " + call.name
    AfterTool(call, result) => "AfterTool: " + call.name + " → " + result.content
    ToolError(call, err) => "ToolError: " + call.name + " → " + err.to_string()
    AfterTurn(result) => "AfterTurn(session=" + result.final_session_id + ")"
    TurnError(err) => "TurnError: " + err.to_string()
  }
  self.log.push(entry)
  Ok(stage)
}
```

### Recipe B: 消息改写（BeforeModel 注入 system prompt）

在每次调用模型前注入或修改 system prompt。

```moonbit
pub(all) struct SystemPromptHook {
  system_prompt : String
}

pub impl @posoco.PipelineHook for SystemPromptHook with fn on_stage(
  self, stage : @posoco.Stage,
) -> Result[@posoco.Stage, @posoco.HookError] {
  match stage {
    BeforeModel(msgs) => {
      // 在消息数组开头插入 system prompt
      let system_msg : @posoco.Message = {
        role: System, content: [Text(self.system_prompt)],
        tool_calls: [], tool_call_id: None, name: None,
      }
      let mut new_msgs = [system_msg]
      for m in msgs { new_msgs.push(m) }
      Ok(BeforeModel(new_msgs))
    }
    _ => Ok(stage)  // 其他 stage 透传
  }
}
```

### Recipe C: 工具审批（BeforeTool Deferred）

对敏感工具要求人工审批。

```moonbit
pub(all) struct ApprovalHook {
  restricted_tools : Set[String]  // 需要审批的工具名集合
}

pub impl @posoco.PipelineHook for ApprovalHook with fn on_stage(
  self, stage : @posoco.Stage,
) -> Result[@posoco.Stage, @posoco.HookError] {
  match stage {
    BeforeTool(call) =>
      if self.restricted_tools.contains(call.name) {
        Err(@posoco.HookError::Deferred(
          reason="Tool '" + call.name + "' requires manual approval",
        ))
      } else {
        Ok(BeforeTool(call))
      }
    _ => Ok(stage)
  }
}
```

### Recipe D: 工具参数改写（RTK 模式）

在执行前修改工具参数。比如优化 token 消耗。

```moonbit
pub(all) struct ToolRewriteHook {}

pub impl @posoco.PipelineHook for ToolRewriteHook with fn on_stage(
  _self, stage : @posoco.Stage,
) -> Result[@posoco.Stage, @posoco.HookError] {
  match stage {
    BeforeTool(call) => {
      // 示例：给 arguments 添加 metadata
      let new_args = match call.arguments {
        Json::Object(map) => {
          map.set("rewritten", Json::boolean(true))
          Json::object(map)
        }
        other => other
      }
      let rewritten : @posoco.ToolCall = {
        id: call.id, name: call.name, arguments: new_args,
      }
      Ok(BeforeTool(rewritten))
    }
    _ => Ok(stage)
  }
}
```

### HookChain 组合

将多个 Hook 串联执行，遇到 Err 短路。

```moonbit
let chain = @posoco.HookChain::{
  hooks: [
    audit_hook,          // 先记录日志
    approval_hook,       // 再检查审批
    rewrite_hook,        // 最后改写参数
  ],
}
```

执行顺序：`audit → approval → rewrite`。如果 approval 返回 `Err(Deferred)`，rewrite 不会执行。

### 测试方法

```moonbit
async test("approval hook defers restricted tools") {
  let hook = ApprovalHook::{ restricted_tools: Set::from_array(["rm"]) }
  let call : @posoco.ToolCall = { id: "1", name: "rm", arguments: Json::Null }
  let result = hook.on_stage(BeforeTool(call))
  match result {
    Err(Deferred(reason~)) => assert_eq!(reason.contains("rm"), true)
    _ => assert_eq!(true, false)
  }
}

async test("noop hook passes through") {
  let hook = NoopHook::{}
  let result = hook.on_stage(BeforeTurn)
  assert_eq!(result.is_ok(), true)
}
```

---

## 8. MemoryPort

### 签名

```moonbit
pub(open) trait MemoryPort {
  fn store(Self, entry : MemoryEntry) -> String raise MemoryError
  fn search(Self, query : MemoryQuery) -> Array[MemoryEntry] raise MemoryError
  fn delete(Self, id : String) -> Unit raise MemoryError
}
```

`MemoryEntry` 和 `MemoryQuery`：

```moonbit
pub(all) struct MemoryEntry {
  id : String
  content : String
  metadata : Map[String, Json]
  score : Double?
}

pub(all) struct MemoryQuery {
  query : String
  top_k : Int
  threshold : Double?
  filter : Map[String, Json]
}
```

### 最小实现模板

如果不需要记忆功能，用 `NoopMemoryPort`（所有操作 raise）。或者传递 `None` 给 Agent（推荐）。

### Recipe A: 内存向量存储

简单的内存实现，适合原型开发。

```moonbit
pub(all) struct InMemoryVectorStore {
  mut entries : Map[String, @posoco.MemoryEntry]
}

pub fn InMemoryVectorStore::new() -> InMemoryVectorStore {
  { entries: {} }
}

pub impl @posoco.MemoryPort for InMemoryVectorStore with fn store(
  self, entry : @posoco.MemoryEntry,
) -> String raise @posoco.MemoryError {
  self.entries[entry.id] = entry
  entry.id
}

pub impl @posoco.MemoryPort for InMemoryVectorStore with fn search(
  self, query : @posoco.MemoryQuery,
) -> Array[@posoco.MemoryEntry] raise @posoco.MemoryError {
  // 简化：按关键词匹配（生产环境应用向量相似度）
  let mut results : Array[@posoco.MemoryEntry] = []
  for entry in self.entries.values() {
    if entry.content.contains(query.query) {
      results.push(entry)
    }
    if results.length() >= query.top_k { break }
  }
  results
}

pub impl @posoco.MemoryPort for InMemoryVectorStore with fn delete(
  self, id : String,
) -> Unit raise @posoco.MemoryError {
  self.entries.remove(id)
  ()
}
```

### Recipe B: 外部 API（Qdrant / Pinecone）

```moonbit
pub(all) struct QdrantMemoryPort {
  client : QdrantClient
  collection : String
}

pub impl @posoco.MemoryPort for QdrantMemoryPort with fn store(
  self, entry : @posoco.MemoryEntry,
) -> String raise @posoco.MemoryError {
  // 1. 生成 embedding
  let vector = self.client.embed(entry.content) catch {
    e => raise MemoryError::Store(e.to_string())
  }
  // 2. upsert 到 Qdrant
  self.client.upsert(self.collection, entry.id, vector, entry.metadata) catch {
    e => raise MemoryError::Store(e.to_string())
  }
  entry.id
}
// search / delete 类似
```

### 测试方法

```moonbit
test("in-memory store round-trip") {
  let store = InMemoryVectorStore::new()
  let id = store.store({ id: "mem1", content: "hello world", metadata: {}, score: None })
  assert_eq!(id, "mem1")

  let results = store.search({ query: "hello", top_k: 5, threshold: None, filter: {} })
  assert_eq!(results.length(), 1)
  assert_eq!(results[0].content, "hello world")

  store.delete("mem1")
  let results2 = store.search({ query: "hello", top_k: 5, threshold: None, filter: {} })
  assert_eq!(results2.length(), 0)
}
```

---

## 9. Lifecycle

### 签名

```moonbit
pub(open) trait Lifecycle {
  async fn on_shutdown(Self) -> Unit
}
```

### 最小实现模板

```moonbit
pub(all) struct NoopLifecycle {}

pub impl @posoco.Lifecycle for NoopLifecycle with fn on_shutdown(_self) {
  ()  // 无资源需要清理
}
```

### Recipe A: 资源清理

关闭连接、flush 缓冲、释放文件句柄。

```moonbit
pub(all) struct ManagedResources {
  mcp_client : MCPClient
  http_pool : HTTPConnectionPool
  file_handle : File
}

pub impl @posoco.Lifecycle for ManagedResources with fn on_shutdown(self) {
  // 按逆序清理（最后获取的资源最先释放）
  self.file_handle.close() catch { _ => () }
  self.http_pool.drain() catch { _ => () }
  self.mcp_client.close() catch { _ => () }
}
```

### Recipe B: 优雅停机

给正在执行的操作一个完成窗口。

```moonbit
pub(all) struct GracefulLifecycle {
  active_tasks : Array[Task]
  timeout_ms : Int
}

pub impl @posoco.Lifecycle for GracefulLifecycle with fn on_shutdown(self) {
  // 等待所有活跃任务完成（带超时）
  let deadline = current_time() + self.timeout_ms
  for task in self.active_tasks {
    if current_time() < deadline {
      task.wait() catch { _ => () }
    } else {
      task.cancel()
    }
  }
}
```

### 使用方式

Lifecycle 通过 Agent 构造函数的 `lifecycle` 参数传入。调用 `agent.shutdown()` 时触发。

```moonbit
let agent = @posoco.Agent::new(
  model, provider, runtime, store, observer, compressor,
  None,                     // pipeline_hook
  None,                     // memory_port
  Some(managed_resources),  // lifecycle ← 这里
  config,
)

// 程序退出时
agent.shutdown()  // → managed_resources.on_shutdown()
```

> **注意**：Agent 自身的 shutdown 不 raise 错误。`on_shutdown` 内部的异常会被静默捕获。

### 测试方法

```moonbit
async test("lifecycle cleanup is called on shutdown") {
  let lc = TestLifecycle::new()
  let agent = @posoco.Agent::new(
    mock_model, mock_provider, mock_runtime,
    mock_store, mock_observer, NoopCompressor::{},
    None, None, Some(lc), default_config,
  )
  agent.shutdown()
  assert_eq!(lc.shutdown_called, true)
}
```

---

## 速查表

| Trait | 方法数 | async? | raise? | 典型实现 |
|-------|--------|--------|--------|----------|
| ModelPort | 1-2 | ✅ chat, chat_streaming | ✅ ModelError | OpenAI, Mock |
| ToolProvider | 1 | ✅ list_tools | ❌ | Static, MCP, Registry |
| ToolProvider | 2 | ✅ list_tools, ✅ execute | ✅ RuntimeError | Shell, MCP, Registry |
| SessionStore | 2 | ❌ | 返回 Result | InMemory, File, SQLite |
| Observer | 1 | ❌ | ❌ | Console, Collector |
| Compressor | 1 | ❌ | ❌ | Noop, SlidingWindow |
| PipelineHook | 1 | ✅ on_stage | 返回 Result | Audit, Approval, Rewrite |
| MemoryPort | 3 | ❌ | ✅ MemoryError | InMemory, Qdrant |
| Lifecycle | 1 | ✅ on_shutdown | ❌ | ResourceCleanup |

## 下一步

- [02-architecture.md](02-architecture.md) — 理解这些 trait 如何在 Agent 中协同工作
- [04-developer-guide.md](04-developer-guide.md) — 错误处理、内置组件详解
- [05-streaming-guide.md](05-streaming-guide.md) — StreamChunk 和 chat_streaming 深入
