# Harbor 代码审查报告

- **日期**：2026-09-21
- **审查对象**：`main` @ `0f7dba1`（feat(ports): prompt at start when a bound \[\[port_claim\]\] is already held），工作树干净
- **范围**：全仓库 —— `Core/Sources/HarborCore`（服务层 + 模型）、`Core/Sources/HarborTUIKit` + `harbor-tui`（终端 UI）、`App/`（SwiftUI 菜单栏应用）、测试与基础设施（CI、project.yml、fixtures、仓库卫生）
- **方法**：三路并行深审（Core 引擎 / TUI / App 与基础设施）+ 对全部 P0/P1 发现逐条人工核对代码证据 + 本机运行测试套件
- **验证状态**：`cd Core && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` → **121 个用例全部通过，0 失败**（2026-09-21 本机实测）

## 总体评价

整体架构是健康的：核心逻辑下沉到无 UI 的 `HarborCore`，`PortPlanner` 刻意纯函数化并有针对性测试，迁移代码防御性好，文件监视采用「watch 目录 + debounce + diff-guard」，App 层 `@MainActor` 纪律一致，仓库卫生经命令验证干净。测试套件全绿。

但本次审查发现了 **2 个 P0、10 个 P1**，集中在三个主题：

1. **TUI 确认交互的两个「一键出大事」缺陷**（P0）：在 kill 确认框上按 Esc 会退出整个 TUI 并停掉所有托管 dev server；一个完整但不支持的转义序列（如 macOS 的 Forward Delete `ESC[3~`）会让键盘永久卡死。
2. **0f7dba1 的 port_claim 启动闸门存在系统性覆盖缺口**：闸门本体和测试是好的，但 6 个启动入口里有 4 个仍然绕过它（popover 不可达、GUI/TUI 的 "start anyway"/"free & start" 分支、TUI restart）——正是要防的那类事故仍能从这些路进来。
3. **进程生命周期的两处竞态**：用户主动 stop 的进程可能被标为 `failed` 并被 auto-restart「复活」；配置迁移对解析失败的配置每次启动无限重复导入。

另有一个贯穿性问题值得点名：**错误呈现链多处断裂**——错误被设置了，但挂在没人渲染的视图上（popover/项目详情页看不到 kill 失败、启动失败等）。

**发现统计**：P0 × 2 · P1 × 10 · P2 × 17 · P3 × 11。

---

## P0 — 立即修复

### P0-1 TUI：在任何非 quit 确认框上按 Esc / Ctrl+C 会退出整个应用并停掉所有托管进程

`Core/Sources/harbor-tui/TuiApp.swift:148-158`（✅ 已核实）

```swift
if choice == nil || choice == "c" || choice == "n" {
    if confirmation.action == .quit, choice == "n" {
        overlay = nil; draw()
    } else if choice == "c" || choice == "n" {
        overlay = nil; draw()
    } else {
        overlay = nil
        quitNow() // Esc / Ctrl+C on a quit prompt quits
    }
    return
}
```

`choice == nil`（Esc / Ctrl+C）且 action 不是 `.quit` 时，前两个分支都不命中，落入 `else` 的 `quitNow()`。场景：用户在 ports 面板按 `x` 弹出 kill 确认，习惯性按 Esc 想取消 → 整个应用退出，`supervisor.emergencyStopAll()` 杀掉所有正在运行的 dev server。0f7dba1 新增的两个 claim 确认框同样只有 s/c 选项，按 Esc 即全灭。

**修复**：`else` 分支加 action 判断——只有 `.quit` 确认框才把 Esc/Ctrl+C 视为退出，其余一律 `overlay = nil; draw()`。

### P0-2 TUI：一个「完整但不支持」的转义序列会永久卡死键盘输入

`Core/Sources/HarborTUIKit/Terminal/Key.swift:75-80`（✅ 已核实；`tildeTable` 仅含 `1~/4~/5~/6~`，见 103-105 行）

```swift
if let tilde = buffer.firstIndex(of: UInt8(ascii: "~")), tilde >= 2, tilde <= 4 {
    let sequence = String(decoding: buffer[0...tilde], as: UTF8.self)
    if let key = Self.tildeTable[sequence] { return (key, tilde + 1) }
}
// Incomplete (or unsupported) sequence: wait for more bytes.
return nil
```

macOS Terminal 的 Forward Delete 发送 `ESC[3~`：tilde 命中但查表失败，`return nil` 把「不支持」当「不完整」处理，这 4 个字节永远留在 buffer 头部，之后**所有按键（包括 q 和 Ctrl+C）都无法解析**。`ESC[2~`（Insert）、`ESC[Z`（Shift+Tab）同理。终端永久损坏级别。

**修复**：CSI final byte（`0x40...0x7E`）已到却查表失败时，丢弃头部 ESC（返回 `(.escape, 1)`）让剩余字节重解析；或对 buffer 长度设上限，超限冲刷。补 `\u{1B}[3~` 回归测试。

---

## P1 — 明确 bug / 高风险

### P1-1 Core：stop 的「安全网」竞态会让用户主动停止的进程变成 `.failed` 并被 auto-restart 复活

`Core/Sources/HarborCore/Services/ProcessSupervisor.swift:192-196, 233-279, 288-294`（✅ 已核实竞态结构，代码注释自己承认顺序不定）

`stop()` 的兜底路径先跑 `finishStop`（置 `.stopped`、清 `userInitiatedStop`，但**不清 `managed.process`**）；随后 `handleTermination` 才落地时，235 行 guard 通过，250 行「用户主动停止」的判定已被提前复位，进程被标 `.failed`（255 行）——若开了 `autoRestart`，`performAutoRestart` 的 guard 恰好全过，**用户明确要求停止的进程在退避后被重新启动**。不开 auto-restart 时终态也错误地停在 `.failed`。

**修复**：`finishStop` 里同时置 `managed.process = nil`（让 235 行 guard 提前返回），并引入只在下次 `start` 才清除的 `stoppedDeliberately` 标志替代被提前复位的判定。

### P1-2 Core：配置迁移对解析失败的配置每次启动重复导入，在 `~/.harbor/projects/` 无限堆积垃圾文件

`Core/Sources/HarborCore/Services/HarborStoreLocation.swift:111-163`（✅ 已核实；144 行注释自认「retried on next startup」）

配置迁移没有完成标记（stores 迁移有 `.legacy-migration-done`，这里没有）；「已覆盖」判定只认**解析成功**的中央配置（133-137 行），而导入出的文件若本身解析失败（遗留 `harbor.toml` 语法错误、相对路径 root、`declaresRoot` 启发式误判），写失败也被 `try?` 吞掉（162 行）——它进不了 covered，**每次启动**再导入一份 `slug-2.toml`、`slug-3.toml`……无限累积，且每个都作为带 `configError` 的坏项目永久出现在注册表 UI。

**修复**：与 stores 迁移对齐写 marker；至少把解析失败但含该 root 的中央文件也算作 covered。

### P1-3 TUI：启动失败路径进程静默挂死，错误信息永远不打印

`Core/Sources/harbor-tui/main.swift:19-32`（✅ 已核实）

`TuiApp.init` 唯一的 throw 点是 stdin 非 TTY 时 raw mode 启用失败。Task 捕获错误写进 `startupFailure`，但 `dispatchMain()` 永不返回且无任何 source 在跑——进程挂死，29-32 行的报错代码带着「Unreachable」注释永远不会执行。`echo | harbor-tui` 会让 shell 永远拿不回提示符。

**修复**：在 Task 的 `catch` 里直接写 stderr + `Foundation.exit(1)`；删除 `startupFailure`。

### P1-4 TUI：确认链中 "free port & start" 分支完全绕过 0f7dba1 的 claim 闸门

`Core/Sources/harbor-tui/TuiApp.swift:169-176`（✅ 已核实；对照 177-184 行 "s" 分支有 `claimBlockers` 检查）

"s"（start anyway）会重查 claim 并链出第二确认；"f"（free port & start）释放 runtime 冲突后**直接 `supervisor.start`，不查 claim 闸门**。`startAllConflicts` 的 "f"（189-197 行）同样，而 "a"（198-209 行）查了。场景：进程端口和绑定的 `[[port_claim]]` 同时被占时，选 "f" 后进程直接启动并因 claim 端口不可用而失败——正是 0f7dba1 要拦的事故形态。

**修复**：两个 "f" 分支在 `freeConflict` 完成后复用 "s"/"a" 的 `claimBlockers` 检查。建议把整条确认链抽成纯函数（见 P2-15）。

### P1-5 TUI：killListener 确认框上按任何未列出的字符键都会立刻杀进程

`Core/Sources/harbor-tui/TuiApp.swift:161-166`（✅ 已核实）

其它 action 都对 `choice` 做 switch，唯独 `.killListener` 不看 `choice`：界面上写着 `[y] kill [n] cancel`，但按 `x`（肌肉记忆的 stop 键）或 `q`（想退出）都会直接对外国进程树执行 SIGTERM→SIGKILL。

**修复**：`case .killListener(let listener): guard choice == "y" else { draw(); return }`；更通用的做法是在 `handleConfirm` 开头校验 `choice` 是否在 `confirmation.options` 里。

### P1-6 TUI：只捕获了 SIGTERM，关闭终端窗口（SIGHUP）会丢下整棵托管进程树

`Core/Sources/HarborTUIKit/Terminal/TerminalController.swift:75-95`（✅ 已核实，仅注册 SIGWINCH/SIGTERM）

用户直接关掉 Terminal 窗口时，内核向前台进程组发 SIGHUP，harbor-tui 立即死亡——没有 `shutdown()`、没有 `emergencyStopAll()`。而托管子进程都在独立进程组（`setpgid`），收不到这次 SIGHUP，dev server 全部变孤儿继续占端口。README 明确承诺「Quitting the TUI stops its managed trees」，这条路径违背承诺。

**修复**：为 SIGHUP 注册与 SIGTERM 相同的 DispatchSourceSignal，统一路由到 `onTerminate`。

### P1-7 App：popover 启动遇 claim 冲突时完全无反馈（0f7dba1 新功能在主入口不可达）

`App/Views/MenuBarPopoverView.swift:52-63`、`App/Views/Projects/ProjectDetailView.swift:28`（✅ 已核实：`.projectConflictDialogs` 全仓库只挂载在 ProjectDetailView；popover 的 `InlineConfirmation` 枚举只有 startAll/conflict/kill 三个分支，`ProjectConflictDialogs.swift` 顶部「Shared by the popover」的注释与事实不符）

本项目是 menubar-first（`LSUIElement`），主窗口经常关闭。popover 点 Start 命中 claim 冲突 → `pendingClaimConflict` 被设置但不被任何可见 UI 渲染 → 进程静默不启动，无对话框、无 inline 提示、无通知。**整个 claim 确认流程对最常用的入口失效。**

**修复**：给 `InlineConfirmation` 增加 `.claim` 分支并纳入 `inlineConfirmation` 优先级链；或把 `ProjectConflictDialogs` 同时挂到 popover。

### P1-8 App：restart 后几乎必然弹出针对「已死进程」的 stale 冲突对话框

`App/ViewModels/AppState.swift:346-354`（restart）、`163-187`（start gate）

`restart` 是 stop → 直接 `start(force: false)`。`supervisor.stop` 返回时进程树已死，但 start gate 用的是 `portObserver.listeners`（2 秒一刷的快照），旧 PID 的 listener 仍在；`PortPlanner.conflicts` 只比对端口不校验 PID 存活，死 PID 查不到 `managedHolder` → 被当成外部占用者。弹窗内容是「Port X is in use by python3 (PID 旧自己)」；用户选 "Kill PID X & start" 会因对已死 PID 的 SIGTERM 失败而把 restart 整个打断，且该错误在详情页不可见（见 P2-1）。`stopProject` 后立即 Start all 同理。

**修复**：`restart` 的 stop 之后、gate 检查之前 `await portObserver.refresh()`；或在 gate 里过滤进程表已不存在的 listener。

### P1-9 App：「Start all anyway」实际不会启动冲突进程，与文案和单进程版语义相反

`App/ViewModels/AppState.swift:256-261`（✅ 已核实；对照 270-280 行 claim 版用 `force: true`）

```swift
func confirmPendingStartAllConflicts() {
    ...
    startProject(project)   // force 默认 false！
}
```

用户明确点了 "Start all anyway"（接受冲突），`startProject` 却因 `force: false` 把冲突进程 skip 掉，只在该进程的日志面板留一行记录——无通知、无 banner。两个 "anyway" 按钮（runtime 版 skip、claim 版 force）行为互相矛盾，用户无法建立正确心智模型。

**修复**：改为 `startProject(project, force: true)`（与注释「the user explicitly accepted every blocker」一致），或把 skip 决策以通知呈现。

### P1-10 App：LogPaneView 切换进程后显示上一个进程的日志

`App/Views/Projects/ProjectDetailView.swift:276-283`（✅ 已核实，无 `.id()`）

切换 `selectedProcessName` 时 `LogPaneView` 处于同一结构位置、view identity 不变，内部 `@State lines` 保留旧 buffer 的快照，直到新 buffer 下一次发事件才刷新。从一个高输出进程切到一个安静的进程，面板标题是 B、内容一直是 A 的日志——直接展示错误数据，误导排查。

**修复**：给 `LogPaneView` 加 `.id(selectedProcessName)`，或在 view 内对 buffer 变化立即 `refreshLines`。

---

## 专题：port_claim 启动闸门覆盖矩阵

0f7dba1 的闸门本体（`PortPlanner.claimConflicts`）逻辑正确、测试充分，但把它接到各启动入口时留了缺口。**「防住的事故」仍能从下表打 ❌ 的入口进来**：

| 启动入口 | process.port 闸门 | port_claim 闸门 | 问题 |
|---|---|---|---|
| GUI 详情页 Start | ✅ | ✅ | 对话框只挂在这里 |
| GUI popover Start / Start all | ✅（inline） | ❌ | pending 设置但无 UI 呈现（P1-7） |
| GUI runtime 冲突框 "start anyway" | 用户已接受 | ❌ | `force: true` 同时跳过 claim 闸门 |
| GUI "free ports & start" | — | ❌ | 同上 |
| GUI restart | 走 gate | 走 gate | stale listener 高概率误弹框（P1-8） |
| TUI start（s / start anyway） | ✅ | ✅ | 链式第二确认，正确 |
| TUI "f"（free port & start） | 用户已接受 | ❌ | 直接 start 不查 claim（P1-4） |
| TUI start all（a） | ✅ | ✅ | 正确 |
| TUI start all（f） | 用户已接受 | ❌ | 同 P1-4 |
| TUI restart（r） | ❌ | ❌ | 完全无闸门（P2-2） |
| auto-restart | 无闸（设计使然） | 无闸 | 有 give-up 兜底，合理 |

建议把「任意启动入口必须经过同一对闸门」收敛为一个必经函数，而不是每个入口各写一遍——目前闸门编排散落在 GUI `AppState` 和 TUI `handleConfirm` 的 8 处分支里，矩阵里每个 ❌ 都是这种结构的产物。

---

## P2 — 应当改进

**Core / 引擎**

| # | 位置 | 问题 |
|---|---|---|
| 1 | `TuiApp.swift:528-534` | TUI restart 完全绕过两类启动闸门（GUI restart 反而走全部门禁），见上方矩阵 |
| 2 | `ProcessSupervisor.swift:105-120, 312-324, 379-411` | `LineForker.pending` 无锁；`readabilityHandler`（管道队列）与 `drainPipes`（global 队列 `readToEnd` 后再 feed）在进程退出瞬间可并发 feed，未定义行为 |
| 3 | `ProcessKiller.swift:69-95` | 快照后击杀无进程身份校验：target 在 2 秒 grace 内退出且 PID 被复用时，SIGKILL 可误杀同用户无关进程。建议记录 `kp_proc.p_starttime`，SIGKILL 前重验 |
| 4 | `ProjectRegistry.swift:48-62, 115-142` | 已删除项目的 file watcher 永不取消（`restartWatchers` 只重建现存项目），反复注册/注销泄漏 fd |
| 5 | `HarborConfigParser.swift:117-123` | 同一项目两个 `[[process]]` 声明相同端口不被拒绝，规划层 `byPort` 字典静默折叠后者；建议解析期拒绝 |

**TUI**

| # | 位置 | 问题 |
|---|---|---|
| 6 | `TuiApp.swift:115-135, 227-248` | 命令栏/过滤栏回显延迟一帧（最多 200ms）：`handleInput` 改局部拷贝并 draw 旧值，write-back 在返回后且不再 draw |
| 7 | `TuiApp.swift:668-671` + `ProjectsPanel.swift:49` | `conflictsByProcess` 只按进程名做 key，跨项目同名进程显示别人的冲突 |
| 8 | `TerminalController.swift:100-110` | `read()` 返回 -1（EINTR）与 0（EOF）同路 → 误触发 `quitNow()` 杀掉全部进程；应区分 `count == 0` / `EINTR` |
| 9 | `TuiApp.swift:644-684` | 每 0.2s tick 全量重建模型（`processTableParents` 全系统 sysctl walk + 每 listener 祖先链）；`supervisor.start` 返回的 `Result` 全部被丢弃，启动失败在 UI 上几乎不可见 |

**App / 基础设施**

| # | 位置 | 问题 |
|---|---|---|
| 10 | `AppState.swift:222-233` | `lastKillError` alert 只挂两个 Ports 视图；详情页/popover 的 kill 流程失败静默（与 P1-8 叠加后果严重） |
| 11 | `AppState.swift:189-218` | 成功通知先于/无视 `supervisor.start` 的 Result 发出，通知文案可能与实际相反 |
| 12 | `MainWindowView.swift:37-39` + `AppState.swift:420-422` | 每个 `didBecomeKey`（含 popover 窗口、弹对话框）触发全量 TOML 重解析 + watcher 全部重建；`reloadConfigsIfStale` 名不副实 |
| 13 | `AppState.swift:19-27` | 四个 pending 全是单 slot，多窗口并发时 last-write-wins 静默覆盖；`ProjectConflictDialogs` 三个 dialog 链在同一视图，两个标志同真时行为未指定，可能滞留 stale 状态（其 "Kill PID" 基于 prompt 时刻的 PID，复用后有误杀窗口） |
| 14 | `LogPaneView.swift:38-70` | `\.offset` 做行身份 + 每行日志全量 snapshot + ForEach diff，高频输出掉帧；ring 淘汰后身份错位。建议 debounce 100ms + 稳定序号 |
| 15 | `MenuBarPopoverView.swift:156-176` | popover 每次渲染对每个项目重复全量进程表 walk 与冲突计算（O(N × 全表 walk × 2)），应一次算好传入 |
| 16 | `.github/workflows/ci.yml:88-92` | 版本校验接受未展开的字面量 `$(MARKETING_VERSION)`——占位符没展开恰是该校验要抓的情况，应 hard fail |
| 17 | `ci.yml:23-24` + 提交的 `Harbor.xcodeproj` | 生成物已提交但 CI 直接重新生成覆盖使用、从不 diff——漂移测不出。加 `git diff --exit-code Harbor.xcodeproj` 或取消跟踪（当前实测无漂移） |

## P3 — 小问题

- `ProcessKiller.swift:75-93`：root 恰在 stop 前自行退出时，`.notRunning` 被当失败写错误日志；应视为成功。
- `PortObserver.swift:180-182`：先读完 stdout 再读 stderr，理论死锁（当前只跑 lsof/ps，纯理论）；并发读或重定向 stderr 即可。
- `TuiApp.swift:651-654`：过小终端下白屏无提示；画一行 "terminal too small"。
- `TuiApp.swift:271`：logs 面板首次按 `f` 「看起来没反应」（`scrollUp(0)`）；且 `LogView.scrollUp` 文档说「返回 follow 是否变化」实现恒返回 true。
- `NotificationService.swift:8,11`：`authorizationRequested` 赋值后从未读取（死代码）。
- `.gitignore:8,14`：`docs/`、`build/` 无前导斜杠，会吞任意层级同名目录；改 `/docs/`、`/build/`。
- `PortsTableView.swift:243-249` / `PortsOverviewView.swift:405-411`：连续复制时旧的 flash 清除 Task 会提前清掉新反馈；保存句柄并 cancel。
- `ci.yml`：无 Xcode 版本 pin（`macos-latest` 随镜像浮动）、无 SPM 缓存。
- `LaunchAtLogin.swift:9`：`SMAppService.register` 成功但待用户在系统设置批准时 Toggle 弹回 off 且无解释（`.requiresApproval` 未处理）。
- `project.yml:47`：`LSApplicationCategoryType` 三重重复（KEY_ / Info.plist / properties）。

---

## 测试覆盖缺口

`swift test` 121 个用例全绿，但以下关键路径无测试（P0/P1 里有 6 条正落在这些空白上）：

1. **KeyParser 完整但不支持的序列**（`\u{1B}[3~` 等）——P0-2 的直接回归测试，当前一条都没有。
2. **TUI 确认链零测试**：`handleConfirm` 私有且 `TuiApp.init` 硬依赖 TTY 无法实例化。把决策抽成 `(Action, Character?) -> ConfirmOutcome` 纯函数后，Esc-on-confirm（P0-1）、"f" 绕闸（P1-4）、任意键杀进程（P1-5）都能表驱动锁住。**这是当前性价比最高的一步重构。**
3. **stop 兜底先于 terminationHandler 的竞态**（P1-1）与 `restart(key:projectRoot:)`、`onAutoRestartGiveUp` 无测试。
4. **迁移失败重导入**（P1-2）：`HarborStoreLocationTests` 8 个用例全用合法 TOML；「导入出的中央配置解析失败 → 不再重复导入」的回归用例可直接抓住 P1-2。
5. `HarborCoordinator.managedHolder(forPID:parents:)` 祖先链上溯零测试——它是 managed-vs-managed 判定和 claim 闸门「同项目跳过」的共同地基。
6. GUI 冲突 gate 状态机（P1-7/8/9 全是「编译通过但流程断裂」型）：把 start/confirm/cancel 对 pending 标志的决策抽成可注入 listeners 快照的纯函数即可单测，无需 app host。
7. 其他：`HealthProbe` 完全无测试；`PortPoolStore` watcher 热更新无测试；`LineForker` 仅被间接覆盖；GUI 无任何行为测试（建议补一个用 `fixtures/selftest-project` 的 XCUITest 冒烟：注册 → start → 断言 8123 监听 → 退出 → 断言无残留进程）。

## 做得好的地方

1. **核心逻辑纯函数化**：`PortPlanner` 全部纯函数、入参显式，claim 闸门本体（含 unbound claim 不拦、同项目 holder 跳过）闭合干净并有 19 个针对性测试。
2. **迁移与文件监视防御性好**：目标文件优先、遗留目录只读不删、marker 短路 TCC 探测、双前端竞态 move 有 guard；watcher 统一「目录 + debounce + diff-guard」并配真实文件系统测试。
3. **工程纪律**：App 层 `@MainActor` 贯穿到底、退出清理无 fire-and-forget；仓库卫生经 `git status --ignored` 验证干净；TUI 的 Screen 差分编码器设计干净、quit 顺序正确；121 个测试全绿。

## 建议修复顺序

1. **今天**：两个 TUI P0（各约 5 行改动 + 回归测试）。
2. **本周期**：闸门矩阵补全（P1-7 popover 可达性、P1-4 "f" 分支、GUI start-anyway 链式化、TUI restart 接入闸门）——这是 0f7dba1 的完整性收尾；随 P1-1（stop 竞态）、P1-2（迁移循环）。
3. **其次**：错误呈现链统一（P2-10/11 + P1-3），把「错误设置了没人渲染」的一次性解决；确认链抽纯函数 + 补表驱动测试。
4. **按需**：其余 P2（性能类 12/14/15 可等有体感再做）、P3 顺手清理。

---
*报告由三路并行代码审查 + 人工逐条核实 P0/P1 证据生成；P2/P3 证据来自审查代理引用的代码片段，未逐条复验。*
