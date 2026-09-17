# Harbor TUI（v1.1.0）完整实施方案

方案 A 落地：同仓库抽 `HarborCore` 本地包，GUI 与 TUI 共享核心层；渲染层自研最小 ANSI 层；TUI 完整支持项目注册管理。探索已确认：核心 15 个文件零 GUI 依赖，`ProcessSupervisor` 已用闭包解耦（`onAutoRestartGiveUp`、`portAllocator`），84 个测试仅 1 处路径需适配即可进 `swift test`。

## 目标态仓库结构

```
harbor/
├── Core/                          # 新增：本地 SwiftPM 包（swift-tools 5.9，language mode 5）
│   ├── Package.swift              # deps: TOMLKit from 0.6.0, swift-argument-parser from 1.7.0
│   ├── Sources/HarborCore/        # ← 迁移 App/Models 5 文件 + App/Services 10 文件
│   ├── Sources/harbor-tui/        # TUI 可执行目标
│   │   ├── main.swift / CLI/      # ArgumentParser 入口（--version 读 HarborCore 版本常量）
│   │   ├── Terminal/              # termios raw mode、alternate screen、按键解析、SIGWINCH、双缓冲 diff 渲染
│   │   ├── Widgets/               # 可滚动表格、日志 tail、状态栏、内联确认条、命令条
│   │   └── Panels/                # Projects / Logs / Ports 三面板 + TuiController 装配 + 键位
│   └── Tests/HarborCoreTests/     # ← 迁移现有 8 个测试文件（84 例）
├── App/                           # GUI 不动结构：Views/ViewModels + NotificationService + LaunchAtLogin
├── project.yml                    # packages 加 HarborCore(path: Core)；Harbor 依赖它；删 HarborTests 目标与 TOMLKit 直依赖
└── .github/workflows/ci.yml
```

## PR 切分（squash merge）

### PR1 — 抽 HarborCore（行为零变化）
1. 方案存档为 `docs/superpowers/specs/2026-09-17-harbor-tui-design.md` 并提交。
2. 新建 `Core/Package.swift`（platforms `.macOS(.v13)`，保持 Swift 5 语言模式避免并发重写）。
3. `git mv`：`App/Models` 全部 5 个 + `App/Services` 中 10 个（HarborError、HealthProbe、ProcessKiller、PortPlanner、LogBuffer、HarborConfigParser、ConfigImporter、PortObserver、ProcessSupervisor、ProjectRegistry）→ `Core/Sources/HarborCore/`。`NotificationService`、`LaunchAtLogin` 留在 App（UserNotifications / ServiceManagement 绑 bundle）。
4. 批量补 `public`（全仓库现为零 public）：跨模块使用的类型与成员，重点是 `ConfigImporter.Draft`、`PortPlanner` 三个嵌套类型 + `commandReferencesPortEnv`、`HarborConfigParser` 静态方法、`ParsedProjectConfig`/`HarborConfigError`、`LogBuffer`、`ProcessKey`（含成员级 init）、`Project`、`ProcessDefinition`、`Listener`、`HarborError`、`ProjectRegistry.AddError`、`ProcessKiller.KillError`。ViewModels/Views 不直接用 TOMLKit，TOMLKit 依赖随之收进包内。
5. 测试迁移：`Tests/` 8 文件 → `Core/Tests/HarborCoreTests/`；仅 `ConfigParserTests.swift:45-48` 的 fixtures 路径需适配 SPM 层级（改回溯层级或把 `fixtures/sample-harbor.toml` 复制为包测试资源）。
6. `project.yml`：`packages:` 增加 `HarborCore: path: Core`；Harbor target 依赖 HarborCore；删除 HarborTests 目标（职责由 `swift test` 接管）；App 侧加 `import HarborCore`。
7. 验证：`xcodegen generate && xcodebuild build` 通过；`cd Core && swift test` 84 例全绿；GUI 冒烟（启动、注册 fixtures/selftest-project、start/stop、日志）。

### PR2 — TUI 渲染底座（自研，约 1200–2000 行）
- `Terminal/`：termios raw mode（Darwin 自带 API，退出/信号时恢复）；alternate screen 进入/退出；`DispatchSource` 读 stdin + escape 序列解析（方向键、PgUp/PgDn、Esc、Ctrl 组合）；SIGWINCH → `ioctl(TIOCGWINSZ)`；双缓冲 cell diff 渲染（SGR 16/256 色，最小化写入）；`wcwidth(3)` 处理项目名可能含中文的列对齐。
- `Widgets/`：可滚动表格（选中行、列对齐）、日志 tail 视图（follow/暂停）、状态栏、内联确认条、命令条。
- 单元测试：按键解析、diff 渲染输出、wcwidth、表格对齐（纯逻辑全可测）。可参考 TSCBasic/TerminalController 的写法（Apache-2.0，只借鉴不引依赖）。

### PR3 — TUI 应用层
- **装配**：`TuiController`（@MainActor）复刻 `AppState.swift:65-83` 构造序：`ProjectRegistry()` → `PortObserver()` → `ProcessSupervisor()`；注入 `portAllocator`（`autoPortTakenSet` + `PortPlanner.allocatePort`）与 `onAutoRestartGiveUp`（→ 状态栏消息 + bell）；`observer.start(interval: 2)`。
- **逻辑下沉（避免 TUI 复刻 AppState）**：把 `managedHolder(forPID:)` 祖先链上溯（AppState.swift:110-134）、`autoPortTakenSet`（:148-159）、Ports Overview 行构建（PortsOverviewView.swift:23-62）提取为 `HarborCore.HarborCoordinator` / 纯函数 + 单测，GUI 改为调用它们。
- **三面板**：
  - Projects：项目→进程树、状态文字/ready/restart 次数、端口 chip（`:auto`/mismatch 徽章）、config 错误横幅；s 单进程 start / x stop / r restart / S start all / X stop all。
  - Logs：当前进程日志 tail，f 切换跟随、c 清屏、上滚自动暂停跟随、dropped 行数提示。
  - Ports：Listening 子视图（`/` 过滤、m mine only、x kill）+ Overview 子视图（claims∪listeners、Free/managed/external、holder、static overlap 横幅、免费端口建议）。
- **确认交互**（底部内联确认条，语义与 ProjectConflictDialogs 对齐）：单进程端口冲突（释放并启动/强制启动/取消）、Start All 冲突、kill 非托管进程确认、Remove project 确认。
- **注册管理**：`:add <path>`（有 config → static overlap 审查后注册；无 config → 列出 Procfile/package.json 导入草稿 + `suggestFreePorts`，模板/草稿直接写盘并提示可手编，交互式编辑器延后）、`:remove`、`:refresh`。
- **共享注册表**：TUI 与 GUI 共用 `~/Library/Application Support/Harbor/projects.json`；给 `ProjectRegistry` 写路径加 `projects.json.lock` 的 flock（现无锁，atomic rename 下 inode 锁无效，须用旁锁文件）；TUI 用 DispatchSource 监听该文件（复用既有 watcher 模式）；GUI 聚焦时的 `reloadConfigsIfStale` 扩展为同时 `load()` 注册表。
- **退出语义**：q / Ctrl+C / SIGTERM → 恢复终端 + `emergencyStopAll()`（与 GUI Quit 一致；有运行进程时先确认）。

### PR4 — CI/CD 与发布
- `ci.yml`：PR/main 单 job 双步骤（macOS runner 上拆 paths 过滤收益小，先不引入第三方 action）：`cd Core && swift test` + `xcodegen generate && xcodebuild build`（无测试目标后的编译守门）。
- `release`（tag `v*`）保留现有双守卫（tag 在 main 上、匹配 `MARKETING_VERSION`），新增第三守卫：tag == `Core/Sources/HarborCore/HarborVersion.swift` 版本常量（单一版本来源三向校验）；产物在 zip + DMG 之外增加 `harbor-tui-X.Y.Z.macos-universal.tar.gz`（`swift build -c release --arch arm64 --arch x86_64` 直接产 universal binary）。
- 文档：README 加 TUI 章节（安装、键位、与 GUI 共享注册表的边界）；`docs/ACCEPTANCE.md` 加 TUI 手测清单（映射既有 service 级 AC 项）；harbor-toml skill 不受影响。
- 收尾：`MARKETING_VERSION` → 1.1.0，tag `v1.1.0` 触发首个双产物 release。

## v1.1.0 明确不做（v1.2+）
Open in Browser（打印 URL 代替）、系统通知、Launch at Login、Reveal in Finder、交互式 TOML 导入编辑器、复制类操作（终端无意义，永久砍）、批量多选操作、菜单栏/popover 形态相关一切。

## 风险与对策
- projects.json 并写损坏 → flock 旁锁文件 + TUI 监听 + GUI 聚焦重读（PR3）。
- XcodeGen 与子目录本地包共存 → PR1 最先验证，风险前置。
- Swift 6 并发严格性 → 包保持 Swift 5 语言模式。
- 自研渲染层范围蔓延 → 只做三面板所需原语，超出的需求触发再评估（若日后升 macOS 15+ 可迁移到活跃的新版 SwiftTUI）。
- 测试迁移后失去 xcodebuild test → `swift test` 覆盖全部逻辑测试（更快），xcodebuild build 守 GUI 编译。

## 工作量估计
PR1 约 1 天（机械但量大）、PR2 约 2–3 天、PR3 约 2–3 天、PR4 约 0.5 天；合计约 1–1.5 周。