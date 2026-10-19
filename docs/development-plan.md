# MuxShots 开发计划

## 1. 问题与目标

macOS 的窗口模型有三层：App → Window → Space。原生全屏会给每个全屏窗口单独开一个 Space，
系统自带的切换手段（`Cmd+Tab` 按 App、`` Cmd+` `` 按 App 内窗口、三指滑动按 Space）
都绑定在这三层之一上，没有任何一层对应"我的一个任务"（例如：项目 A 的 VSCode + 项目 A 的 Chrome 窗口）。

目标：把所有窗口抽成一张统一的、以**单个窗口**为粒度的表，在其上由我们自己定义：

- **Grouping**：哪些窗口属于同一组（规则自动归组 + 手动归组）。
- **Switching**：在组之间、组内窗口之间怎么切（快捷键、切换面板、MRU 顺序）。
- **Hiding**：切走的组如何隐藏、切回时如何恢复（位置、大小、层级）。

非目标（至少前几个里程碑不做）：平铺布局引擎、Chrome 标签页级管理、App Store 上架。

## 2. 关键技术事实与约束

这些事实决定了整体架构，先列出来，后面的设计都基于它们。

| 主题 | 事实 | 对设计的影响 |
|---|---|---|
| 窗口读写 | 公开 API 只有 Accessibility（`AXUIElement`）能读写窗口的位置、大小、最小化、全屏、raise | 核心依赖 AX，需要"辅助功能"权限 |
| 窗口身份 | AX 元素没有稳定 ID；`CGWindowID` 需通过私有 `_AXUIElementGetWindow` 从 AX 元素取得 | 以 `CGWindowID` 作为窗口主键，接受这一个只读私有 API |
| 枚举范围 | `kAXWindowsAttribute` 对很多 App 只返回**当前 Space** 的窗口；`CGWindowListCopyWindowInfo` 能看到 WindowServer 里的窗口但拿不到 AX 句柄 | 两路数据源合并；其他 Space 的窗口需要 alt-tab-macos 式的 remote token 暴力枚举（私有）或在 Space 切换时增量补全 |
| Space | 没有公开 API 切换或移动 Space；SkyLight 的写操作在新系统上需关闭 SIP（yabai 的做法） | **不碰 SIP**。只读 Space 信息，不主动移动 Space |
| 原生全屏 | 激活另一个全屏 Space 里的窗口一定伴随系统 Space 切换动画 | 这是当前痛点的根源，见 §3 的核心决策 |
| 单窗口隐藏 | 没有公开的"隐藏单个窗口"API；`hide` 是整个 App 级，最小化有动画且慢 | 采用 AeroSpace 的做法：把窗口移到屏幕可视区外实现隐藏 |
| 截图/标题 | `CGWindowList` 的窗口标题和 ScreenCaptureKit 缩略图需要"屏幕录制"权限；AX 读标题不需要 | 标题走 AX；缩略图作为可选功能，单独申请权限 |
| 全局快捷键 | Carbon `RegisterEventHotKey` 无需权限；"按住修饰键切换、松开确认"需要 `CGEventTap` | 快捷键注册用 Carbon，切换面板用 event tap |
| AX 调用 | AX 是同步跨进程 IPC，无响应的 App 会卡住调用方 | 每个 App 一个串行队列 + `AXUIElementSetMessagingTimeout`，主线程永不直接调 AX |
| Chromium/Electron | Chrome、VSCode 开启 `AXEnhancedUserInterface` 后设置 frame 会变慢、有动画 | 写 frame 前临时关闭该属性，写完恢复（Rectangle 的做法） |
| 分发 | AX 不能在 App Sandbox 里工作；TCC 权限绑定代码签名，ad-hoc 签名每次重编译都会丢权限 | 非沙盒、Developer ID 签名；开发期用固定的 Apple Development 证书签名 |
| 工具链 | 本机只有 Command Line Tools，没有 Xcode | 用 SwiftPM 构建，脚本打包成 `.app` 并签名；需要 Xcode 时再装 |

## 3. 核心决策：用"虚拟工作区 + 托管最大化"代替原生全屏

原生全屏 = 一个窗口一个 Space，而我们无法无动画地控制 Space。所以继续用原生全屏，
切换体验的上限就是系统动画，我们做的只是"更好的入口"。

推荐方案：

- 所有被管理的窗口留在同一个 Space（每块显示器一个）。
- "全屏"由我们实现为**托管最大化**：窗口铺满显示器可用区域（可选隐藏菜单栏/Dock 的效果另议）。
- "组"即虚拟工作区：切到一个组 = 把该组窗口恢复到记录的 frame 并 raise，把其他组窗口移到屏幕外。
- 切换是几十毫秒级的 frame 写入，没有 Space 动画。

保留一个兼容模式：对仍处于原生全屏的窗口，允许"跳转到它"（激活 + raise，接受系统动画），
并提供"一键退出原生全屏并纳入托管"的操作。

已确认采用本方案（见 §8）。

## 4. 架构

```
┌──────────────────────────── UI ────────────────────────────┐
│ 菜单栏 · 切换面板 (NSPanel) · 设置 (SwiftUI) · 权限引导      │
└─────────────────────────────┬──────────────────────────────┘
┌────────────────────────── Policy ──────────────────────────┐
│ GroupEngine（规则 + 手动） · WorkspaceManager · MruTracker   │
└─────────────────────────────┬──────────────────────────────┘
┌────────────────────────── Model ───────────────────────────┐
│ WindowRegistry：窗口表 + 变更事件流（唯一的事实来源）        │
└─────────────┬───────────────────────────────┬──────────────┘
┌──────── Observation ────────┐   ┌────────── Actions ─────────┐
│ AX 观察者 · NSWorkspace 通知 │   │ focus · hide · show ·       │
│ CGWindowList 周期对账        │   │ set_frame · 带校验与重试     │
└─────────────┬───────────────┘   └─────────────┬──────────────┘
┌───────────────────────── Platform ─────────────────────────┐
│ AXClient · WindowServerClient · HotkeyService · Capture     │
│ （所有系统 API / 私有 API 只出现在这一层，上层只见协议）     │
└────────────────────────────────────────────────────────────┘
          + Control：Unix socket + `muxctl` CLI（调试与脚本化）
```

要点：

- **单一事实来源**：`WindowRegistry` 由事件流增量更新，再由周期对账（例如每 2 秒对一次 `CGWindowList`）纠正丢失的事件。AX 通知会丢，这是常态。
- **Platform 层协议化**：上层只依赖协议，测试时用假实现，Model/Policy 可在无权限、无窗口的环境下单元测试。
- **Action 是"期望状态"**：执行后读回实际 frame 校验，不一致则重试一次并记日志；部分 App 会拒绝或修正尺寸。
- **`muxctl` 从第一个里程碑就有**：`muxctl list`、`muxctl focus <id>`、`muxctl group ...`。它既是调试手段，也让代码代理能在不点 UI 的情况下验证行为，也为以后的脚本化留口子。
- **配置**：`~/.config/muxshots/config.toml`（规则、快捷键），运行时状态（手动分组、记录的 frame）单独存 JSON，App 重启后按规则重新匹配窗口（`CGWindowID` 在 App 重启后会变）。

## 5. 分组模型

窗口记录的可匹配字段：`bundle_id`、`pid`、`title`、`role/subrole`、所在显示器、是否原生全屏。

- **规则归组**（声明式，按顺序第一条命中）：
  - 按 App：`bundle_id == com.google.Chrome`
  - 按标题正则提取 key：VSCode 默认标题为 `文件 — 项目 — Visual Studio Code`，提取"项目"作为组名，就能自动做到"每个项目一组"。
  - 组合规则：同一个 key 可以把 VSCode 和 Chrome 窗口归到同一组（例如 Chrome 窗口标题含项目名）。
- **手动归组**：快捷键"把当前窗口加入/移出组 X"，优先级高于规则，持久化。
- **组内顺序**：MRU。组间顺序：MRU 或用户固定编号（`Opt+1..9` 直达）。

## 6. 里程碑

每个里程碑都有可验证的退出标准；前两个是**技术探针**，用来尽早暴露 §2 里的风险。

### M0 工程骨架（0.5 周）

- SwiftPM 工程：`MuxShotsCore`（Model/Policy，纯逻辑）、`MuxShotsPlatform`、`MuxShots`（App）、`muxctl`。
- 打包签名脚本：产出 `.app`，固定证书签名，保证重编译后权限不丢。
- 权限检测与引导（辅助功能必需，屏幕录制可选）。
- **退出标准**：`make run` 启动菜单栏 App，授权一次后重编译仍保有权限。

### M1 观察：看见所有窗口（1–1.5 周）

- AXClient：每 App 串行队列、消息超时；`_AXUIElementGetWindow` 取 `CGWindowID`。
- 订阅 App 启动/退出/激活与窗口创建/销毁/移动/缩放/聚焦/标题变化/最小化。
- `CGWindowList` 周期对账；其他 Space 与原生全屏窗口的发现策略（探针：remote token 枚举 vs. 增量补全，选一种）。
- `muxctl list` / `muxctl watch` 输出窗口表与事件。
- **退出标准**：开 3 个 Chrome 窗口 + 3 个 VSCode 窗口（含原生全屏），`muxctl list` 全部列出且 ID 稳定；关、开、改标题后 2 秒内表正确。

### M2 动作：可靠地控制单个窗口（1 周）

- `focus`（含跨 App、跨 Space 兼容模式）、`set_frame`、`hide`（移出屏幕）、`show`（恢复记录的 frame）。
- Chromium/Electron 的 `AXEnhancedUserInterface` 处理；最小尺寸、拒绝移动等异常 App 的降级。
- 原生全屏 → 托管最大化 的转换。
- **退出标准**：`muxctl focus/hide/show` 对 Chrome、VSCode、Finder、Terminal 均可靠，连续 100 次操作无错位；单次切换耗时有测量数据。

### M3 分组与虚拟工作区（1–1.5 周）

- GroupEngine：规则解析与匹配、手动归组、持久化与重启后重新匹配。
- WorkspaceManager：切组时批量 hide/show，记录每个窗口在组内的 frame；新窗口按规则自动入组。
- 多显示器：每个显示器独立的当前组（先做单显示器，接口按多显示器设计）。
- **退出标准**：按 VSCode 项目自动分出组，`muxctl switch <group>` 在组间切换无 Space 动画，App 重启后分组恢复。

### M4 切换体验（1–1.5 周）

- 全局快捷键（Carbon），`Opt+Tab` 式切换面板（event tap 检测松开修饰键），组内窗口循环。
- 面板展示组名、窗口标题、App 图标；缩略图在获得屏幕录制权限时启用。
- 菜单栏：当前组、组列表、暂停管理。
- **退出标准**：日常使用一周，切换路径不再需要 `Cmd+Tab` 或三指滑动。

### M5 打磨与分发（持续）

- 设置界面、配置热加载、开机启动（`SMAppService`）。
- 崩溃/退出时把所有屏幕外窗口恢复回可视区（**必须**，否则用户会"丢窗口"）。
- Developer ID 签名 + 公证；日志与诊断导出。

## 7. 风险清单

| 风险 | 缓解 |
|---|---|
| 其他 Space / 原生全屏窗口枚举不全 | M1 探针优先验证；托管模式下窗口都在当前 Space，问题自然消失 |
| App 自身恢复窗口位置、与我们的屏幕外隐藏冲突 | 监听移动事件，对被管理窗口做位置纠正；必要时该 App 退化为最小化隐藏 |
| 私有 API 随系统升级失效 | 私有 API 只限只读的 `_AXUIElementGetWindow` 等少数几个，集中在 Platform 层，失效时有降级路径 |
| 进程崩溃导致窗口留在屏幕外 | 启动时检测屏幕外窗口并恢复；退出钩子恢复；`muxctl restore-all` 兜底 |
| 权限在开发期反复丢失 | M0 固定签名身份 |

## 8. 已确认的决策

1. **虚拟工作区 + 托管最大化**（§3），原生全屏只做兼容跳转与"退出全屏并纳入托管"。
2. **Swift**，遵循 `humanize/swift-coding-conventions.md`（camelCase，即 Swift API Design Guidelines）。
3. **最低系统版本 macOS 14**。
4. **对外发布**：Developer ID 签名 + 公证、崩溃后恢复屏幕外窗口、权限引导都是发布前的硬性要求。
