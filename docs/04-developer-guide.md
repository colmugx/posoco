# 04 — 开发指南

上一章讲了"怎么实现一个端口"，这一章讲"怎么把它们组合成一个像样的产品"：
组装 Agent、配置、跑多轮对话、处理错误、管理会话与压缩、优雅关闭。

## 1. 组装 Agent

`Agent(exts~, config~)` 是唯一的组合入口。每个扩展通过 manifest 声明自己提供的
端口；**扩展数组的顺序决定 hook 和 observer 的注册顺序**（也就是执行顺序）：

```moonbit
fn build_agent(
  model : &@posoco.Extension,
  tools : &@posoco.Extension,
  store : &@posoco.Extension,
  observer : &@posoco.Extension,
  hook : &@posoco.Extension,
) -> @posoco.Agent raise @posoco.CompositionError {
  @posoco.Agent(
    exts=[model, tools, store, observer, hook],
    config={
      max_tool_rounds: Some(10),
      temperature: Some(0.2),
      max_output_tokens: Some(4096),
      model_context_window: Some(128000),
    },
  )
}
```

规则：

- 恰好一个扩展提供 `ModelPort`，至少一个提供 `SessionStore`；
- 工具、observer、hook 等全部可选，没有也能构造；
- 工具重名、命令重名、manifest 畸形，都在构造阶段以 `CompositionError` 失败。
  不会产生"半成品"Agent，也没有"后声明覆盖前声明"的工具路由。

### 配置字段

```moonbit
pub(all) struct AgentConfig {
  max_tool_rounds : Int?
  temperature : Double?
  max_output_tokens : Int?
  model_context_window : Int?
}
```

- `max_tool_rounds`：一轮对话最多允许几波工具调用。`None` = 不设上限（推荐默认，
  让对话自然结束）；`Some(0)` = 禁止工具；`Some(n)` = 第 n+1 波整体拒绝。
- `temperature`、`max_output_tokens`：所有模型通用的配置。`None` 交给 provider
  默认值。
- `model_context_window`：模型上下文窗口大小。Agent 据此判断何时该自动压缩；
  压缩的具体策略由 `ModelPort::compact` 决定（见第 6 节）。

各家 provider 特有的参数（reasoning effort、tool choice 等）留在对应模型扩展
自己的配置里，不要扩张 `AgentConfig`。

## 2. 运行一轮对话

输入是 `Message` 枚举，不是带 `role` 字段的 record：

```moonbit
fn user_message(text : String) -> @posoco.Message {
  @posoco.Message::UserMessage(content=[
    @posoco.Content::Text(text),
  ])
}

async fn run_once(agent : @posoco.Agent) -> @posoco.TurnResult raise @posoco.AgentError {
  agent.run_turn(user_message("What is 2 + 2?"), "session-1")
}
```

`run_turn` 是 async（MoonBit 没有 `await` 关键字，直接调用即可，但调用方也应是
async）。反复使用相同 `session_id` 会加载之前保存的记录，继续同一段对话：

```moonbit
async fn run_conversation(agent : @posoco.Agent)
  -> Unit raise @posoco.AgentError {
  let first = agent.run_turn(user_message("Hello"), "user-123")
  let second = agent.run_turn(
    user_message("What did I just say?"),
    first.final_session_id,
  )
  match second.message {
    @posoco.Message::AssistantMessage(content~, ..) =>
      println("assistant blocks: \{content.length()}")
    _ => abort("expected AssistantMessage")
  }
}
```

注意第二次调用用的 `session_id` 来自第一次的返回值 `final_session_id`——如果
中间发生了会话重定向（比如压缩开了新线程），继续对话必须用这个字段，不要自己
从 metadata 或 observer 事件里猜。

想把错误保存成值而不是抛出，在 async 上下文中用 `catch`：

```moonbit
let outcome : Result[@posoco.TurnResult, @posoco.AgentError] =
  Ok(agent.run_turn(user_message("hello"), "session-1")) catch {
    error => Err(error)
  }
```

## 3. 工具波次

模型回复里带 `Completion.tool_calls` 时，Agent 按工具名把每个调用送给声明它的
`ToolProvider`，执行完后把 `ToolOutcome` 转成 `ToolMessage` 继续下一次模型调用。
**这套循环 Agent 全包了**——扩展绝不要在 `ToolProvider.execute` 里再调 Agent
或自己实现模型循环。

- 同一波次里多个调用可以**并行执行**；`ToolDef.policy` 表达执行策略，但普通
  扩展只需声明工具，调度交给 Agent。
- 工具执行失败（包括 provider 抛出的 `RuntimeError`）会变成 `RuntimeFailure`
  回到模型上下文，由模型决定重试、换工具还是放弃——单次工具失败不会伪造 turn
  成功，也不会静默丢弃。

## 4. Hooks 与 Observers 的接入

把 hook 放进 manifest 的 `hooks`，observer 放进 `observers`。规则：

- hook 按注册顺序执行；`before_model` 链式改写消息；`before_tool` 首个非
  `Approve` 的决定胜出；`on_post_event` 在效果完成后只读通知。
- observer 只收 `TurnEvent`，不改变主数据流。

只提供一个端口的扩展，manifest 直接写 `{ ..manifest, observers: [self] }`；
同时实现多个端口时，在相应字段里登记同一个 `self`。具体实现见
[03 端口配方](./03-trait-recipes.md) 的第 5、6 节。

## 5. 错误处理

### AgentError 层次

```text
AgentError
  ├── Model(String)
  ├── Session(SessionError)
  ├── Runtime(RuntimeError)
  ├── ToolLoopExceeded(consumed~, limit~)
  └── HookAborted(String)
```

模型调用、会话读写、hook 中止、工具轮次超限都会终止当前 turn。已发布
`TurnStarted` 后，Agent 只发布一次安全的 `TurnFailed`，再把原始 `AgentError`
抛给调用方——不要在 observer 里"重建"主结果，observer 看到的 `TurnFailed`
只带错误类别。

```moonbit
async fn report_turn(agent : @posoco.Agent) -> Unit {
  let result : Result[@posoco.TurnResult, @posoco.AgentError] =
    Ok(agent.run_turn(user_message("hello"), "session-1")) catch {
      error => Err(error)
    }
  match result {
    Ok(turn) =>
      match turn.message {
        @posoco.Message::AssistantMessage(content~, ..) =>
          println("received \{content.length()} content blocks")
        _ => abort("expected AssistantMessage")
      }
    Err(@posoco.AgentError::Model(reason)) => println("model: " + reason)
    Err(@posoco.AgentError::Session(error)) => println("session: " + error.to_string())
    Err(@posoco.AgentError::Runtime(error)) => println("runtime: " + error.to_string())
    Err(@posoco.AgentError::ToolLoopExceeded(consumed~, limit~)) =>
      println("tool rounds exhausted: \{consumed}/\{limit}")
    Err(@posoco.AgentError::HookAborted(reason)) => println("hook aborted: " + reason)
  }
}
```

### 分清业务失败与适配器失败

工具侧的状态全部由 `ToolOutcome` 一个类型表达：

- **模型可见的业务失败** → `Success` / `ToolReportedError`（工具跑了，结果或
  业务错误回填给模型）；
- **适配器失败** → raise typed `RuntimeError`，Agent 会转成
  `ToolOutcome::RuntimeFailure`；
- **组合/校验没放行** → `NotExecuted`（工具不存在、参数 schema 不匹配），
  携带原始 call id。

没有第二套结果结构需要和 `ToolOutcome` 保持同步。

### 次要失败

记忆检索这类**次要组件**失败时，不该让主 turn 结果陪葬。Agent 会发布一个清洗
过的 `TurnEvent::Custom`（`source="posoco.core"`、`label="secondary_failure"`），
不暴露原始 prompt、参数和 provider 载荷；observer 的合同违规仍然保持 loud。

## 6. 会话持久化与压缩

`SessionStore` 是对话连续性的来源。查不到的 id 返回：

```moonbit
{ messages: [], metadata: Map::from_array([]) }
```

多个 store 时：**load 只读第一个，save 写所有**（write-all / read-first）。
这不是事务——后面某个 save 失败时，前面的写入不会回滚。需要原子复制就自己实现
事务型适配器。

`metadata` 对模型适配器是不透明的：**未知 key 必须原样保留**，一轮对话后不能
丢。压缩产生新线程时，父线程 id 也会记进 metadata（lineage），`TurnResult
.final_session_id` 会指向新线程：

```moonbit
async fn follow_redirect(agent : @posoco.Agent, input : @posoco.Message)
  -> Unit raise @posoco.AgentError {
  let mut session_id = "session-1"
  let result = agent.run_turn(input, session_id)
  session_id = result.final_session_id
  println("continue with " + session_id)
}
```

## 7. 压缩（Compaction）

压缩是 `ModelPort` 的能力，不是另一个扩展端口。**Posoco 决定何时压缩**（上下文
压力自动触发，或宿主手动触发）；**模型扩展决定怎么压缩**：

```moonbit
async fn compact_model(
  model : &@posoco.ModelPort,
  scope : @posoco.InvocationScope,
  messages : Array[@posoco.Message],
) -> @posoco.CompactResult raise @posoco.ModelError {
  model.compact(
    scope,
    messages,
    { temperature: None, max_output_tokens: None },
    @posoco.CompactTrigger::Manual,
  )
}
```

`CompactResult.mode` 是三种之一：

- `Replace`：原地替换当前会话的消息体；
- `Append`：把压缩结果追加到当前会话；
- `NewThread`：开一条新会话线程（记录父线程 lineage），`final_session_id`
  随之重定向，原会话保留。

不支持压缩的 provider 就 raise；**不要返回未压缩的 transcript 却声称压缩成功**。

## 8. 关闭 Agent

宿主结束前调用 `shutdown`。每个注册的 `Lifecycle` 会收到 `on_shutdown`；
**清理失败是刻意保持 loud 的**——不要把它转成"成功"：

```moonbit
async fn close_agent(agent : @posoco.Agent) -> Unit {
  agent.shutdown()
}
```

如果清理失败后要重试，lifecycle 实现应尽量让进度可观察、操作幂等。

## 9. 发布前检查清单

- 只实现业务需要的那几个公开端口，不碰内部执行细节。
- `extension_id` 稳定，manifest 里每个贡献恰好登记一次。
- 工具定义使用合法的 JSON Schema（object/boolean），`provenance` 稳定。
- 工具业务失败返回 `ToolReportedError`；基础设施失败保持 typed。
- session store 对未知 id 返回空 session，且保留 metadata。
- hook 不静默吞错误；observer 保持只读。
- 通过一个组合好的 `Agent` 做集成测试，而不是伸手够内部实现。