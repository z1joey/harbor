# Harbor TUI（v1.1.0）设计

日期：2026-09-17
状态：已批准（方案 A）

## 背景与目标

为 Harbor（macOS 菜单栏进程监管工具）增加 TUI 形态，作为 v1.1.0 的内容。

关键决策（已与维护者确认）：

1. **同仓库**：TUI 与 GUI 共享 `harbor.toml` 语义契约（解析规则、auto 端口池 8100–9999、停止序列），同仓库保证契约在同一 PR 内演进。
2. **Swift 实现**：核心层（`App/Models` + `App/Services`）已无 GUI 依赖，抽包后 TUI 直接复用，84 个测试随包迁移。
3. **自研最小 ANSI 渲染层**：2026-09 调研结论——所有功能对口的 Swift TUI 库均有硬伤（新版 SwiftTUI 要求 macOS 15+；TermKit 无 release、7 个月未更新；旧版 SwiftTUI 停维护两年带未修崩溃）。本项目 UI 面窄（表格 + 面板 + 日志 tail），自研约 1200–2000 行，零第三方依赖，保持 macOS 13 兼容。
4. **完整注册管理**：TUI 内 `:add <path>` / `:remove`，与 GUI 共享 `projects.json`。

## 架构

```
harbor/
├── Core/                          # 本地 SwiftPM 包（swift-tools 5.9，Swift 5 语言模式）
│   ├── Package.swift              # deps: TOMLKit from 0.6.0, swift-argument-parser from 1.7.0
│   ├── Sources/HarborCore/        # ← App/Models 5 文件 + App/Services 10 文件
│   ├── Sources/harbor-tui/        # TUI 可执行目标
│   │   ├── main.swift / CLI/      # ArgumentParser 入口（--version 读 HarborCore 版本常量）
│   │   ├── Terminal/              # termios raw mode、alternate screen、按键解析、SIGWINCH、双缓冲 diff 渲染
│   │   ├── Widgets/               # 可滚动表格、日志 tail、状态栏、内联确认条、命令条
│   │   └── Panels/                # Projects / Logs / Ports 三面板 + TuiController 装配 + 键位
│   └── Tests/HarborCoreTests/     # ← 现有 8 个测试文件（84 例）
├── App/                           # GUI：Views/ViewModels + NotificationService + LaunchAtLogin（留 App）
├── project.yml                    # packages 加 HarborCore(path: Core)；删 HarborTests 目标
└── .github/workflows/ci.yml
```

### 核心层事实（探索结论）

- 15 个核心文件仅依赖 Foundation/TOMLKit/Combine/Darwin，无 Bundle/AppKit 引用。
- `ProcessSupervisor` 经注入闭包解耦（`onAutoRestartGiveUp`、`portAllocator`），不依赖 NotificationService；wiring 在 GUI 的 `AppState`。
- 服务均为 `@MainActor` + GCD/DispatchSource；`LogBuffer` 仅用内置 `objectWillChange` + 拉取式 `snapshot()`。
- 全仓库零 `public`，拆包后需为跨模块符号补访问级别。
- 测试无 host-app 假设；仅 `ConfigParserTests` 的 fixtures 路径需适配 SPM 层级。
- `projects.json` 读写无文件锁（atomic rename，last-writer-wins）——GUI/TUI 并写需加旁锁。

### GUI 与 TUI 的边界

- 共享：`projects.json` 注册表、`harbor.toml` 解析、进程监管、端口规划/观察、日志缓冲。
- 各自独立：各自 spawn 的进程树互不监管（无 daemon，维持 v1 设计）；通知/开机启动等系统集成仅 GUI。
- TUI 退出 = 恢复终端 + `emergencyStopAll()`（与 GUI Quit 语义一致）。

## PR 切分（squash merge）

### PR1 — 抽 HarborCore（行为零变化）

新建包、`git mv` 15 个文件、批量 `public`、迁移测试（fixtures 路径改为自 `#filePath` 向上查找仓库根 `fixtures/sample-harbor.toml`，避免复制漂移）、`project.yml` 改依赖本地包并删 HarborTests（scheme 同步去掉 test 段）、ci.yml test job 改为 `swift test` + `xcodegen generate && xcodebuild build`。验证：`swift test` 全绿 + `xcodebuild build` + GUI 冒烟。

### PR2 — TUI 渲染底座

`Terminal/`：termios raw mode（退出/信号恢复）、alternate screen、DispatchSource 读 stdin + escape 序列解析、SIGWINCH → `TIOCGWINSZ`、双缓冲 cell diff 渲染（SGR 16/256 色）、`wcwidth(3)` 宽字符列对齐。
`Widgets/`：可滚动表格、日志 tail（follow/暂停）、状态栏、内联确认条、命令条。
单测覆盖：按键解析、diff 输出、wcwidth、表格对齐。可借鉴 TSCBasic/TerminalController 写法（Apache-2.0，只借鉴不引依赖）。

### PR3 — TUI 应用层

- `TuiController`（@MainActor）复刻 AppState 装配序，注入 `portAllocator` 与 `onAutoRestartGiveUp`（→ 状态栏 + bell）。
- 逻辑下沉：`managedHolder(forPID:)` 祖先链上溯、`autoPortTakenSet`、Ports Overview 行构建提取为 HarborCore 的 `HarborCoordinator`/纯函数 + 单测，GUI 改为调用。
- 三面板：Projects（进程树/状态/启停/重启/错误横幅/auto 徽章）、Logs（tail、f 跟随、c 清屏）、Ports（Listening：过滤/mine only/kill；Overview：claims∪listeners、Free/managed/external、static overlap 横幅、免费端口建议）。
- 内联确认（语义对齐 ProjectConflictDialogs）：单进程冲突、Start All 冲突、kill 非托管、Remove project。
- 注册管理：`:add <path>`（含 missing-config → 模板/Procfile/package.json 草稿直接写盘 + `suggestFreePorts`；交互式编辑器延后）、`:remove`、`:refresh`。
- 共享注册表：`ProjectRegistry` 写路径加 `projects.json.lock` flock；TUI 监听该文件；GUI 聚焦 reload 扩展为同时 `load()` 注册表。
- 退出语义：q / Ctrl+C / SIGTERM → 恢复终端 + `emergencyStopAll()`（有运行进程先确认）。

### PR4 — CI/CD 与发布

- release（tag `v*`）双守卫之外加第三守卫：tag == `HarborCore` 版本常量（三向校验）。
- 产物增加 `harbor-tui-X.Y.Z.macos-universal.tar.gz`（`swift build -c release --arch arm64 --arch x86_64`）。
- README TUI 章节、ACCEPTANCE TUI 手测清单；`MARKETING_VERSION` → 1.1.0，tag `v1.1.0`。

## v1.1.0 明确不做（v1.2+）

Open in Browser（打印 URL 代替）、系统通知、Launch at Login、Reveal in Finder、交互式 TOML 导入编辑器、复制类操作（永久砍）、批量多选、菜单栏/popover 形态相关一切。

## 风险与对策

| 风险 | 对策 |
|---|---|
| projects.json 并写损坏 | flock 旁锁文件 + TUI 监听 + GUI 聚焦重读（PR3） |
| XcodeGen 与子目录本地包共存 | PR1 最先验证，风险前置 |
| Swift 6 并发严格性 | 包保持 Swift 5 语言模式 |
| 自研渲染层范围蔓延 | 只做三面板所需原语；日后若升 macOS 15+ 可迁移到活跃的新版 SwiftTUI |
| 测试迁移后失去 xcodebuild test | `swift test` 覆盖全部逻辑测试，`xcodebuild build` 守 GUI 编译 |
