# MuxShots 开发计划

> **现状（2026-10-20）**：本文是最初的开发计划和设计决策记录，M0–M5 已完成，主交互已从"托盘 + 面板"演进为 §3.1 的舞台模式（多个独立的 stage 窗口，各自拥有自己的 group）。计划之外后来加入了：按 app / Chrome tab 的混音台（Core Audio process tap + Chrome 扩展）、侧边栏画中画（WebRTC 推流）、世界时、code agent 限额面板。最低系统版本已提到 macOS 14.2（process tap 需要）。
>
> 现在的实现以英文文档为准：[architecture](architecture.md)、[development](development.md)、[windows](windows.md)、[audio](audio.md)、[chrome-extension](chrome-extension.md)、[agent-usage](agent-usage.md)。

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
| 枚举范围 | 实测（macOS 26）：`kAXWindowsAttribute` 只返回**当前 Space** 的窗口；`CGWindowListCopyWindowInfo` 能看到所有 Space 的窗口，但拿不到 AX 句柄 | 两路合并：其他 Space 的窗口用 remote token 暴力枚举取 AX 元素，元素拿到后跨 Space 一直有效 |
| 窗口是否"存在" | 实测：Electron 等 App 关窗后窗口仍留在 WindowServer 里（不可见）；私有只读 `CGSWindowIsOrderedIn` 可区分 | 只对"ordered in、不在当前 Space、AX 未列出"的窗口做暴力枚举；透明窗口直接过滤 |
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
- "组"即虚拟工作区：切到一个组 = 把该组窗口恢复到记录的 frame 并 raise，把其他组的托管窗口移到屏幕外；未托管的窗口不受影响（见 §5）。
- 切换是几十毫秒级的 frame 写入，没有 Space 动画。

保留一个兼容模式：对仍处于原生全屏的窗口，允许"跳转到它"（激活 + raise，接受系统动画），
并提供"一键退出原生全屏并纳入托管"的操作。

已确认采用本方案（见 §8）。

## 3.1 舞台模式（2026-10-19 用户确认的主交互）

用户要的是"全屏 MuxShots，窗口显示在它里面，在里面操作"。macOS 不允许把别的 app 的窗口嵌进自己的窗口，所以采用**舞台**：

- **底板**：MuxShots 用一个无边框窗口铺满所在显示器的可用区域（菜单栏和 Dock 之外），层级在桌面图标之上、所有普通窗口之下，点它也不会盖住任何窗口。底板上画左侧组列表、顶部标签栏和内容区。
- **真实窗口在内容区里**：当前组被选中的那个窗口被摆成正好铺满内容区，组内其他窗口和其他组的窗口都藏起来（标签式，一次一个）。用户直接操作原生窗口，输入法、拖放、滚动都不受影响。
- **切换**：点侧栏的组、点标签、快捷键、切换器、Cmd-Tab 跟随焦点，全部落到"把某个窗口摆进内容区，藏起其余"。
- **进出**：进入舞台时记下每个托管窗口原来的位置（`homeFrame`，持久化）；退出、释放窗口、MuxShots 启动恢复时都回到这个位置。
- **拖放**：舞台打开时它就是拖放目标：拖到侧栏的组上就进那个组，拖到内容区就作为当前组的新标签；拖动托管窗口时侧栏出现"Release"。被拖离内容区又没放到目标上的托管窗口，松手后弹回内容区。
- **未托管的窗口**照常浮在底板之上，不受影响。
- **实例（2026-10-19 起）**：舞台不再铺满整块显示器、垫在所有窗口之下，而是一个个像普通窗口一样的 MuxShots 实例：可拖动、四边可调大小、双击顶部铺满显示器，⌘N 新建。每个实例拥有自己的组（`WorkspaceController.mapGroupStageIds`），侧栏只列自己的组；把组或标签拖到另一个实例上就交给它。实例始终紧贴在它的内容窗口下方（内容窗口获得焦点时跟上来；点实例外框时内容窗口一起到最前）。移动或调整实例时内容窗口实时跟随（同一时刻只做一次移动，只保留最新位置）；拖内容窗口的标题栏，整个实例跟着走。关闭实例时，它的窗口回原位、组保留为未分配；下次打开第一个实例时接收所有未分配的组。
- **实现状态（已完成第一版）**：`StageController`（底板窗口、拖放目标）、`StageView`（侧栏、标签栏、内容区）、`WorkspaceController.enterStage/exitStage/performStageSwitch`。入口：菜单栏 Enter Stage、⌃⌥↩、再次打开 app、`muxctl stage on|off`；⌃⌥\` 在舞台里切下一个标签，⌃⌥0 退出舞台。
- **Space 的约束**：舞台只能放在桌面 Space 上（别的 app 的窗口进不了 MuxShots 的全屏 Space），进入舞台时托管窗口会退出原生全屏，回到桌面 Space，摆进舞台。舞台因此是用户那些原生全屏 Space 的替代品。
- **坐标来源**：窗口的当前位置一律用 AX 读取。WindowServer 的位置在 Space 切换动画期间带偏移，曾导致记下错误的原位置。
- **第二轮（2026-10-19）**：组和标签可在原地改名（双击或右键）；标签可拖到侧栏的组上换组、拖到空白处新建组、拖到 Release 释放；侧栏可折叠成图标条；拖动侧栏顶部可把舞台移到另一块显示器（也可用菜单 Move Stage to Next Display）；舞台层级改为普通窗口减一，桌面小组件不再盖住它。
- **排序与命名**：组和标签都可拖动排序；拖进来新建的组会自动显示；切换标签后窗口获得键盘焦点（AX 设焦点窗口与前台 app）。
- **⌘⇥ 接管**：舞台打开且前台是舞台当前窗口所属的 app 或 MuxShots 时，用 event tap 截住 ⌘⇥，弹出跨组的最近使用窗口切换器；其他时候放行给系统。

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

- **单一事实来源**：`WindowRegistry` 由事件流增量更新，再由每 10 秒一次的低频周期对账纠正丢失的事件。AX 通知会丢，这是常态；通常变化仍由 AX 通知即时反映。
- **Platform 层协议化**：上层只依赖协议，测试时用假实现，Model/Policy 可在无权限、无窗口的环境下单元测试。
- **Action 是"期望状态"**：执行后读回实际 frame 校验，不一致则重试一次并记日志；部分 App 会拒绝或修正尺寸。
- **`muxctl` 从第一个里程碑就有**：`muxctl list`、`muxctl focus <id>`、`muxctl group ...`。它既是调试手段，也让代码代理能在不点 UI 的情况下验证行为，也为以后的脚本化留口子。
- **配置**：`~/.config/muxshots/config.toml`（规则、快捷键），运行时状态（手动分组、记录的 frame）单独存 JSON，App 重启后按规则重新匹配窗口（`CGWindowID` 在 App 重启后会变）。

## 5. 接管与分组模型

MuxShots 只管理用户主动交给它的窗口，其余 app 一概不碰。

- **拖入**：面板开着时，面板就是落点：拖动开始时面板排到被拖窗口正下方，光标进入面板后边框发光、顶部提示条说明松手的效果、高亮卡片罩住光标下的组，底部滑出"New Group"区。面板关着时，屏幕顶部浮出托盘，列出各组和"New Group"。两种方式松手后窗口都回到拖动前的位置。
- **拖出**：拖动已托管的窗口时，托盘多出"Release"落点；也可以在面板（菜单栏 → Show Managed Windows…）里把窗口条目拖到面板外，或右键 Release。面板内拖到其他组即移组，双击组名可重命名。
- **跟踪范围**：只为拥有托管窗口的 app 启动 tracker；拖动识别只用 WindowServer 的窗口列表与全局鼠标事件，不需要对其他 app 做 AX 调用。
- **持久化**：`~/Library/Application Support/MuxShots/workspace.json`。启动时逐个校验：窗口仍存在且属于同一 bundle 才恢复（防止重启后窗口 ID 被别的窗口复用）。
- **关闭**：托管窗口关闭后自动移出所在组；组没有成员时自动删除。
- **以后**：规则自动接管（例如按 VSCode 标题里的项目名），以及"接管当前窗口"的快捷键，用于无法拖动的原生全屏窗口。

## 6. 里程碑

每个里程碑都有可验证的退出标准；前两个是**技术探针**，用来尽早暴露 §2 里的风险。

### M0 工程骨架（0.5 周）

- SwiftPM 工程：`MuxShotsPlatform`、`MuxShots`（菜单栏 App）；`MuxShotsCore` 与 `muxctl` 随 M1 加入。
- 打包签名脚本：产出 `.app`；本地自签名证书脚本，使 designated requirement 绑定证书，重编译后权限不丢。
- 权限检测与引导（辅助功能必需，屏幕录制可选）。
- **退出标准**：`make run` 启动菜单栏 App，授权一次后重编译仍保有权限。

### M1 观察：看见所有窗口（已完成）

- 每个 App 一个 run-loop 线程（`ApplicationWindowTracker`），AX 全局消息超时 1 秒；`_AXUIElementGetWindow` 取 `CGWindowID`。
- 订阅窗口创建/销毁/移动/缩放/标题/最小化与 App 聚焦/隐藏；窗口级事件经 250 ms 合并后只重读对应窗口，结构变化和兜底对账才读取该 App 的完整快照；`WindowRegistry` 按 App 做差分。
- 每 10 秒、以及每次 Space 切换时，与 `CGWindowList` 对账；仅对托管窗口查询 WindowServer 顺序状态。其他 Space 的窗口用 remote token 暴力枚举（找齐即停，每个窗口 ID 只探测一次）。
- `muxctl list [--json]` / `muxctl watch`，走 `~/Library/Application Support/MuxShots/control.sock`。
- **实测结果**：5 个原生全屏 VSCode 窗口、2 个全屏 Chrome 窗口、其他 Space 上的 iTerm2 窗口全部列出，ID 稳定；改标题 0.3 秒、关窗 0.3 秒、新建窗口约 0.6 秒内反映；空闲 CPU 约 1%。
- **遗留问题**：单个窗口找不到时，暴力枚举要扫满 50 万个 ID（单核约 13 秒），只在启动或切 Space 后出现新的不可识别窗口时发生；以后可以改成分片、低优先级扫描。

### M2 接管：拖入托盘与拖出（已实现，待手动验证）

- 拖动检测（`WindowDragMonitor`）、托盘（`DropTrayController`）、面板（`WorkspacePanelController`）、`Workspace` 模型与持久化，见 §5。
- tracker 改为只跟踪托管窗口；registry 只在窗口确认关闭时删除。
- `muxctl manage <id>` / `muxctl release <id>` 走与拖放相同的路径。
- **退出标准**：拖一个 Chrome 窗口进新组、再拖一个 VSCode 窗口进同一组，面板正确显示；拖出或面板拖出后释放；MuxShots 重启后分组恢复。

### M2.5 拖放体验打磨（已实现，待手动验证）

用户反馈（2026-10-19）：托盘能用，但太丑；被拖的窗口压在托盘下面；没有任何动画。目标是达到 macOS 原生应用的质感。

- **层级**：托盘不再用 `.popUpMenu` 盖住一切，改为普通层级、排在被拖窗口之下、其他窗口之上（`order(.below, relativeTo:)` 被拖窗口），被拖的窗口始终在最上面。
- **出现方式**：拖动开始时只在顶部显示一个小胶囊；光标进入屏幕顶部 240pt 内时用弹簧动画展开成完整托盘，离开时收起；松手后淡出。macOS 26 上用 Liquid Glass，更早版本用毛玻璃材质。
- **悬停反馈**：落点 tile 悬停时放大、高亮色渐变过渡，轻微触觉反馈（`NSHapticFeedbackManager`）。
- **落入动画**：松手时，一个窗口形状的占位块（带 app 图标）缩小飞进目标组，组 tile 弹一下并显示新成员；真实窗口同时回到原位；开启"减弱动态效果"时跳过飞行动画。窗口截图版本留到申请屏幕录制权限时再做。
- **组 tile 内容**：显示组内窗口的 app 图标叠放，而不是"N windows"文字。
- **面板**：侧栏材质背景、透明标题栏、组行显示图标叠放和成员数、窗口行两行（标题 / app）、空状态提示。为了拖放可靠，列表仍用 `NSOutlineView`，只有空状态用 SwiftUI。

### M3 动作：可靠地控制托管窗口（已完成）

- `muxctl focus|hide|show|maximize <id>`，内部走 `WorkspaceController.perform(_:on:)`。
- **focus**：取消最小化 → `AXMain` + `AXRaise` → `NSRunningApplication.activate()`；后台的 MuxShots 用公开 API 即可把别的 app 切到前台。
- **hide**：移到所在显示器右下角外（右下挨着其他显示器时改用左下），只留 1 个点在屏幕上；移动后读回实际 frame 校验。原 frame 存进 `workspace.json`（`restoreFrame`）。
- **show**：放回 `restoreFrame`。
- **maximize**：原生全屏的窗口先退出全屏（轮询 `AXFullScreen`，最多 3 秒，再等 0.4 秒动画），然后铺满显示器可用区域。
- **崩溃恢复**：启动时把所有 `restoreFrame` 不为空的窗口放回原位；正常退出前也先放回（`applicationShouldTerminate` → `.terminateLater`）。
- **实测**（TextEdit 测试窗口）：30 轮 hide/show 零漂移，单次中位数约 31 ms（含 muxctl 进程启动）；`kill -9` 后重启与正常退出都能恢复窗口；聚焦能从 Chrome 切到 TextEdit。
- **未实测**：从原生全屏最大化（会在你屏幕上切 Space），以及对 Chrome、VSCode 真实窗口的 `AXEnhancedUserInterface` 处理；留到 M4 用真实窗口验证。

### M4 虚拟工作区（已完成单显示器版本）

- **切组**（`WorkspaceController.switchTo`）：记录当前组的前后顺序 → 并行隐藏其他组正在显示的托管窗口、恢复目标组被隐藏的窗口 → 按记录的顺序从后往前 raise，激活最前面窗口的 app。连续切换串行执行。
- 原生全屏与最小化的窗口不参与隐藏；未托管的窗口完全不受影响。
- **Show All**：恢复所有隐藏窗口并退出组模式。启动和正常退出时也会这样做，所以磁盘上的状态永远一致。
- 释放一个被隐藏的窗口时先把它放回原位。
- **入口**：菜单栏组列表（当前组打勾，另有 Show All Windows）、面板右键 "Switch to Group"（当前组名用强调色加圆点）、`muxctl switch <组名或序号> | --all`。
- **实测**（自己新开的 2 个 TextEdit、1 个 Chrome、1 个 VSCode 窗口）：切组 48–208 ms（内部计时）；切回时恢复组内前后顺序；组模式下 `kill -9` 后重启恢复所有窗口。
- **发现**：Electron/Chrome 的新窗口如果开在非当前 Space，AX 列不出来，接管时要靠暴力枚举（VSCode 约 2 秒）。
- **待做**：多显示器各自独立的当前组；用 Cmd-Tab 或 Dock 切到一个被隐藏的窗口时，自动切到它所在的组（放进 M5）。

### M5 切换体验（已完成）

- **跟随焦点**：被隐藏的托管窗口因 Cmd-Tab、Dock 或通知获得焦点时（tracker 的焦点通知，加上 `didActivateApplication` 时读取 app 的焦点窗口），自动切到它所在的组，并让它排在组内最前。切组期间及之后 0.4 秒内忽略焦点事件，避免来回切换。
- **快捷键**（Carbon `RegisterEventHotKey`，无需额外权限）：⌃⌥1–9 切到第 N 组，⌃⌥0 显示全部，⌃⌥\` 在当前组内轮换窗口；菜单栏的组列表显示对应快捷键。窗口轮换没用 ⌥\`，因为它在美式键盘上是重音死键。
- **切换器**：⌥⇥ / ⌥⇧⇥ 打开并移动选择，松开 ⌥ 切换，Esc 取消；按下 140 ms 内松开则直接切到下一组、不显示界面（同 Cmd-Tab）。松开检测同时用全局和本地 `flagsChanged` 监听，再加上每 30 ms 轮询 `CGEventSource.flagsState`，因为松开可能发生在监听装好之前。
- **暴力枚举分片**：每片 1 万个元素 ID，切片之间让出 tracker 线程，窗口动作最多等一片（约 0.25 秒）。此前 Finder 的一次 10 秒扫描曾让切组等了 9.6 秒。
- **实测**：自动切组（`open -a` / AppleScript activate）、⌃⌥1/2/0、⌥⇥ 轻按循环与反向、按住两次 ⇥ 后松开、按住后 Esc 取消，都用合成按键验证过；切换器显示在 popUpMenu 层。有一次失败疑似与真实键鼠输入同时发生，未能复现。
- **待做**：快捷键可配置（M6 设置界面）；多显示器各自的当前组。

### M6 打磨与分发（进行中）

- **多显示器（已完成）**：每块显示器各自一个当前组（`Workspace.setActiveGroupIds`）。一个组占据它的窗口所在的显示器（隐藏的窗口按 `restoreFrame` 算）；切到它只隐藏这些显示器上其他组的窗口，并把共享显示器的旧当前组替换掉。实测：笔记本与外接屏各自切组互不影响，约 80 ms。
- **设置（已完成）**：菜单栏 Settings…（⌘,）。开机自启（`SMAppService`）；拖动时是否提供托盘或面板；落下后是否回到拖动前的位置；快捷键可录制（录制期间暂停全局快捷键），组快捷键在几种修饰键组合中选择，切换器的按住键取自它的修饰键、加 ⇧ 反向。存在 `UserDefaults`，修改立即生效。快捷键名按 ASCII 键盘布局显示，避免中文输入法把 \` 显示成"·"。
- **待做**：签名公证（暂缓）、崩溃日志与诊断导出、首次启动引导。

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
3. **最低系统版本 macOS 14.2**：接管应用音频所用的 Core Audio process tap 自 14.2 起才有。
4. **对外发布**：Developer ID 签名 + 公证、崩溃后恢复屏幕外窗口、权限引导都是发布前的硬性要求。
