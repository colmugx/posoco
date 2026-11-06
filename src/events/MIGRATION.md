# 原生强类型事件：资源、接管与迁移

`colmugx/posoco/events` 定义开放的 `Event`、按 owner 绑定的 `Events` 能力、
`EventEnvelope` 与 `Subscription`；根包 `@posoco` 提供宿主用来建立并接管这些
资源的 `EventSystem`。每个 Agent 独占一个事件资源：核心通知与社区协议共用同一
份监听器、队列和关闭状态，但发布权限不同。

可编译的协议与能力形状见 [`README.mbt.md`](README.mbt.md)；可运行的宿主示例见
[`examples/quickstart`](../../examples/quickstart/README.md)。

## 1. 资源与三个状态

`EventSystem` 是公共不透明类型，只有三个可解释状态：

| 状态 | 含义 | 可用操作 |
|---|---|---|
| 未接管 | 宿主刚创建，还没有 Agent | `publisher`、`subscribe`、`close` |
| 已接管 | 由一个活跃 Agent 独占 | `publisher`、`subscribe`、`Agent::subscribe_events`；`close` 被拒绝 |
| 已关闭 | 构造失败、shutdown 完成或宿主显式关闭 | 授权、社区发布、订阅返回 `Closed`；`cancel` 仍幂等 |

没有全局注册表、进程身份查找、第二套分发器或失败后的自动重建。资源不会因为
构造失败而被悄悄替换成新实例。

## 2. 公共 API

```moonbit
pub fn EventSystem::EventSystem() -> EventSystem

pub fn EventSystem::publisher(
  self : EventSystem,
  owner~ : String,
) -> Result[Events, EventError]

pub fn EventSystem::subscribe(
  self : EventSystem,
  handler : (EventEnvelope) -> Unit,
  namespace_~ : EventNamespace? = None,
) -> Result[Subscription, EventError]

pub fn EventSystem::close(self : EventSystem) -> Result[Unit, EventError]

pub fn Agent::Agent(
  exts~ : Array[&@port.Extension],
  config~ : AgentConfig,
  events~ : EventSystem,
  ui_projection~ : Bool = false,
) -> Agent raise @error.CompositionError

pub fn Agent::with_runtime(
  exts~ : Array[&@port.Extension],
  config~ : AgentConfig,
  events~ : EventSystem,
  runtime~ : &@runtime.Runtime,
  ui_projection~ : Bool = false,
) -> Agent raise @error.CompositionError
```

`events~` 是必填参数：没有默认值、可选重载、旧签名代理或自动 fallback。两个
构造入口都独占接管传入的资源。

## 3. 生命周期契约

1. **未接管**：可授予能力、订阅和发布。发布同步送给当时存在的监听器；没有
   历史回放，也不会为将来的 Agent 缓存历史。
2. **独占接管**：Agent 构造先同步接管资源，再执行 aggregation/composition。
   一个资源至多被一个 Agent 接管；第二次接管被拒绝，且不得关闭、替换或改变
   第一个 Agent 的资源。
3. **构造失败即关闭**：接管之后的 aggregation、配置校验、`on_compose` 等任何
   构造失败都会关闭这一资源并撤销已发出的能力。不留下半组合资源，也不自动
   重试或替换新资源。
4. **接管后仍可授权**：接管成功后，可以从原 `EventSystem` 继续授予新 owner 的
   `Events`。`on_compose` 不再是扩展获取能力的唯一时机。
5. **运行期不关闭**：正常 turn 结束、失败或取消都不关闭事件系统。同一 Agent
   可以继续下一轮、重试或压缩。
6. **shutdown 关闭**：Agent 完成 shutdown 清理后关闭同一资源。关闭后获取
   publisher、publish、subscribe 均返回 `Closed`；`Subscription::cancel` 幂等。
7. **能力边界**：发布能力始终拒绝 `Core`；namespace 在授予时绑定，`publish`
   不接收可伪造来源的参数。核心发布与资源管理仍由框架拥有。

## 4. 能力、身份与入口

- `EventSystem::publisher(owner~)` 授予绑定 `Extension(owner)` 的 `Events`。
  owner 由持有资源的宿主显式指定，可以不是 manifest id；空字符串或全空白被
  拒绝，不会自动改写身份。普通 publisher 只拿到 `Events`，不获得资源管理能力：
  它不能关闭系统，也不能转移所有权。
- `CompositionView::events()` 仍是扩展的正常授予入口：manifest 声明
  `requires: [@posoco.Capability::Events]` 并登记 `lifecycle: [self]`，在
  `Lifecycle::on_compose` 取得能力。它与提前授予的能力使用同一 runtime，不是
  兼容分支。
- `Agent::subscribe_events()` 仍是宿主的只读通知入口，不提供发布权。
- `Observer` 是同一系统上只收核心事件的适配器，`Hook` 仍是管线拦截；
  journal/checkpoint 提交协议仍在通知队列之外，必须等待并传播错误。

| 需求 | 入口 |
|---|---|
| 宿主在 Agent 之前接听 | `system.subscribe(handler, namespace_=...)` |
| 普通对象在 Agent 之前发布 | `system.publisher(owner="status_bar")` |
| 扩展获取能力 | `requires` + `Lifecycle::on_compose` → `view.events()` |
| 宿主在组合后接听 | `agent.subscribe_events(handler, namespace_=...)` |
| 释放监听 | `Subscription::cancel()` |
| 清理未接管资源 | `system.close()` |
| 结束 Agent | `agent.shutdown()` |

## 5. 派发、快照与无重放

- 派发同步执行，按注册顺序通知。提前通过 `EventSystem` 注册的监听者排在组合时
  才注册的 Observer 之前；Observer 之间仍按 manifest 顺序。慢监听者会延长发布者的调用时间。
- 回调中再次发布会入队，不递归调用监听者；当前批次完成后派发下一批。
- 每批获取监听快照；批内新增或取消的订阅从下一批生效。
- 不重放历史，不提供 sticky state。业务当前状态由业务扩展自己的投影维护。
- 核心 `TurnEvent` 入队和交付时做必要快照；任意社区 ADT 不承诺通用深拷贝，
  生产者与消费者都不得修改共享的可变数据，优先使用不可变载荷。
- Handler 的签名不允许 raising 或 async。编译器约束不等于吞掉运行期故障。
- 第一版不承诺跨 OS 线程共享安全，遵循现有 Agent 的执行模型。

## 6. 错误表

| 操作 | 条件 | 结果 |
|---|---|---|
| `publisher(owner~)` | owner 为空或全空白 | `Err(InvalidOwner)` |
| `publisher(owner~)` | 资源已关闭 | `Err(Closed)` |
| `publisher(owner~)` | 未接管或已接管 | `Ok(Events)`，绑定 `Extension(owner)` |
| `publish` | 资源已关闭 | `Err(Closed)` |
| `publish` | 发布 `Core` | `Err(ReservedEvent)` |
| `publish` | 没有监听者 | `Ok(())`，不保留消息 |
| `subscribe` | 资源已关闭 | `Err(Closed)` |
| `subscribe` | 未接管或已接管 | `Ok(Subscription)` |
| 第二个 `Agent(events=same)` | 已被活跃 Agent 接管 | raise `CompositionError::EventSystemAlreadyOwned`；第一个 Agent 不受影响 |
| `Agent(events=same)` | 资源已关闭 | raise `CompositionError::EventSystemClosed` |
| Agent 构造 | 接管后 aggregation/配置/`on_compose` 失败 | 资源关闭、已授权能力失效，构造 raise |
| `system.close()` | 未接管 | `Ok(())`，之后授权/发布/订阅均为 `Closed` |
| `system.close()` | 由活跃 Agent 接管 | `Err(Owned)`；资源保持打开，只能经 `Agent::shutdown` 关闭 |
| `system.close()` | 已关闭 | `Ok(())`（幂等） |
| `Subscription::cancel()` | 任意状态 | 幂等，无错误通道 |
| turn 失败/取消 | 已接管 | 资源保持可用 |

`Core` 的保留载荷检查优先于关闭检查：即使资源已关闭，发布 `Core` 仍返回
`ReservedEvent`；其他载荷在关闭后返回 `Closed`。已关闭资源的 `publisher` 授权
优先返回 `Closed`，不再校验 owner。

资源归属失败使用 `EventError` / `CompositionError` 的独立分支，不伪装成
manifest 格式错误；调用方应处理 `Result`，不要忽略授权与发布错误。

## 7. 从 0.24 迁移

旧构造器不再存在：

```moonbit
// 0.24：隐式创建事件资源
let agent = @posoco.Agent(exts=[model_ext, tools_ext], config=config)
```

改为由宿主显式创建并交出资源：

```moonbit
let events = @posoco.EventSystem()
let agent = @posoco.Agent(
  exts=[model_ext, tools_ext],
  config=config,
  events=events,
)
```

迁移步骤：

1. **在宿主边界创建一个 `EventSystem`**，位置早于所有需要它的 port 和 Agent。
   每个 Agent 一个新实例，不做进程级单例。
2. **把普通对象的 `Events` 提前授权出去**：
   `events.publisher(owner=...)`，owner 由宿主决定并保持稳定。普通对象不需要
   实现 `Lifecycle`，也不需要持有 `Agent`。
3. **需要早期接听就提前订阅**：`events.subscribe(handler, namespace_=...)`。
   组合之后仍可用 `agent.subscribe_events(...)`；两者的通知来自同一资源。
4. **把同一个实例传给构造入口**：`Agent(exts~, config~, events~)` 或
   `Agent::with_runtime(exts~, config~, events~, runtime~)`。不要保留旧签名的
   包装函数，也不要用测试专用的兼容构造器掩盖迁移成本。
5. **扩展的组合入口保留**：manifest 继续声明 `Capability::Events`，在
   `on_compose` 通过 `view.events()` 取得能力；需要更早发布的对象可接收第 2 步
   授予的能力，在构造期间或之后发布，不必实现 `Lifecycle`。
6. **分开处理失败**：构造失败后不要复用同一 `EventSystem`（它已关闭），重新
   创建新实例；turn 失败或取消后资源仍可用，不要重建。
7. **只经 `Agent::shutdown` 结束已接管的资源**。宿主直接 `close()` 只会成功于
   未接管的系统。
8. **测试按契约断言**：接管前授权/订阅/发布、接管后晚授权、第二个 Agent 被拒、
   构造失败撤销能力、turn 失败仍可用、shutdown 后全部 `Closed`、无历史回放。

迁移后的最小可运行示例见
[`examples/quickstart/main.mbt`](../../examples/quickstart/main.mbt)：宿主先建
`EventSystem`，让一个普通对象在 Agent 创建前取得 publisher 并发布，再把同一个
系统交给 `Agent`。

## 8. 扩展与宿主的边界

- 构造器的包限定名：社区协议包用 `extenum @events.Event += { ... }` 定义构造器，
  生产者与消费者导入同一个协议包直接构造或匹配业务 ADT。它不是运行期字符串
  topic，也没有注册 Json schema 的步骤。
- 运行期 namespace：封闭的 `EventNamespace` 区分 `Posoco` 与
  `Extension(owner)`，由系统在授权时绑定；即便某个 owner 含 `posoco`，也不会
  获得 `Posoco` namespace。
- `EventScope`：可选的 session/run/turn 归属，不能借此获得核心身份。多个 session
  共用同一 Agent 时仍共享该订阅；需要 session 隔离的消费者应检查归属。
- 既有 `TurnEvent` 保持不变（包括 `Custom`）。社区 ADT 不会被序列化成
  `TurnEvent::Custom` 发给旧 `Observer`。
- `Events`/`Subscription` 的构造工厂仍是框架接线和测试接缝，不是申请真实 Agent
  核心发布权的入口。

## 9. Cetas / devkit 迁移注意事项

本次只实现 posoco；不直接修改 Cetas 的宿主、statusbar、权限和模型路由协议。
迁移不能只是替换 `BusEvent` 的类型：

1. 将字符串 topic/Json 协议提升为独立社区协议包中的 ADT/exenum。status segment
   所有权、priority、first-seen 排序和色角色属于社区协议，不进入 Posoco 核心。
2. 现有 Cetas 某些扩展在构造器中立即发布。现在宿主可以在构造 ports 之前用
   `EventSystem::publisher(owner=...)` 授权，让这些对象在 Agent 存在前就能发布；
   组合之后的发布仍可继续使用同一能力。仍然不能凭空获得权限，也不能用隐式
   重放或进程全局 bus 掩盖时序问题。
3. `on_start` 在首次 run_turn 内触发。若宿主要求首次 turn 前即显示模型、权限或
   状态栏初值，应使用第 2 步的提前授权，而不是假设移到 `on_start` 没有 UI 影响。
4. 组合层以下的 router/store/provider 应由拥有它们的扩展转交自己的 owner-bound
   `Events`。不要让产品知道 Puppet，也不要用进程默认 registry 让"最后一个
   session"决定所有发布者的去向。
5. 进程级 tracker 若服务多个 Agent，需要明确绑定目标或由业务层聚合；一个
   `EventSystem` 只能由一个 Agent 接管，原来的 last-write-wins 默认 bus 不再是
   可用迁移方案。
6. 将旧的"停止后回调自行 no-op"逐步替换为明确退订；释放状态栏 segment 仍是
   业务动作，不等于取消监听。

当前 Cetas 的依据：`extension/posoco-devkit/src/bus.mbt`、`status_bus.mbt`，以及
`cetas-core/lib/session_assembly.mbt` 中的构造顺序与 bus 注入。
