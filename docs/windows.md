# Windows and the stage

How MuxShots sees windows, takes them over, and lays them out on its stages.

## Seeing windows

- **Identity**: a window is its `CGWindowID` (`WindowId`). Accessibility elements carry no stable id, so the read-only private `_AXUIElementGetWindow` maps an element to its window id (`PrivateAccessibilityApi.swift`).
- **Window server**: `CGWindowListCopyWindowInfo` sees every window on every Space but gives no handle to move it. The private read-only `CGSWindowIsOrderedIn` tells windows really shown from those an app closed but keeps alive (Electron does).
- **Accessibility**: `kAXWindowsAttribute` lists only the current Space's windows. Windows on other Spaces are found by brute force through `_AXUIElementCreateWithRemoteToken`, in slices of ids up to a limit; only elements that are windows count, and an element once found stays valid across Spaces.
- **Tracking** (`WindowTracker`, `ApplicationWindowTracker`): an `AXObserver` per application on a run loop thread of its own, observing managed windows only. Window-level events are coalesced for 250 ms and read only the changed window; app-level structure changes and a 10-second fallback reconciliation read a full snapshot. Accessibility calls are synchronous IPC and can hang on a stuck app, so the main thread never makes them. A managed window that closed before it was ever observed is reported removed.

Nothing writes window-server state through private APIs; Spaces are never moved or switched.

## Taking windows over

- A window is managed only when the user drags it onto a stage (or `muxctl manage`); other apps' windows are never touched.
- A dropped window is adopted only once it outlives the drop by 0.15 s: dragging a tab out of Chrome makes a window that Chrome merges back and closes at once.
- **Hiding** a window parks it off screen in a corner (`ScreenGeometry.offscreenFrame`) rather than minimizing it, which animates and is slow. Its `restoreFrame` and `homeFrame` are kept in `workspace.json`.
- **Parked windows keep drawing.** macOS does not let a window leave the screen entirely, and a window with a sliver on screen counts as visible however little shows, so its application goes on rendering it at full rate (an opaque window over the sliver does not change that). Half a second after layout settles, every application whose windows shown on any Space are all parked is hidden whole (`NSRunningApplication.hide`), which does stop it; it is unhidden before any of its windows is shown again. An application with another window on screen, or the active one, is left as it is. A hidden application's windows still exist in the window server's list, so the tracker does not take them for closed.
- **Crash safety**: on launch and on quit, every hidden or staged window is put back where it was, so no window is ever left off screen.

## Stages

- A stage (`StageController`) is a borderless, non-activating, resizable panel at normal level. It is kept just beneath its front window (`order(.below, relativeTo:)`), so the managed window looks hosted inside it while staying a real window of its app.
- **Several stages**: each owns its own groups. A stage moves with its front window while that is dragged (coalesced relayout), and dragging the stage moves its windows.
- **Displays**: `StagePanel` overrides `constrainFrameRect` so AppKit does not pin it to one display, and settles on the display under the cursor after a move.
- Frames for layout come from Accessibility, not the window server: during Space animations the window server reports skewed frames.
- **Switching**: ⌃⌥1–9 and the group switcher (⌥⇥) switch groups; ⌘⇥ is taken over by an event tap (`KeyInterceptor`) only while a stage is in front, offering windows most recently used first across groups. The switcher wraps its cards into rows that fit the stage it opens over.

## Sidebar

The sidebar is SwiftUI in the stage's hosting view: the Groups/Mixer switch, then the groups or the mixer, then sidebar videos, code agent limits, the world clock, and the toolbar. Colors are tokens in `StageColors` that follow the light and dark themes (dark is near black); theme changes crossfade through a snapshot of each stage.

Every assignment to an `@Observable` property redraws the views reading it, equal value or not, so `StageController.refresh` assigns only what changed, and a layout change tells the views once when it ends rather than once for each window it moves. Window names live in `StageModel.mapWindowNames`, read only by the texts showing them (`WindowNameText`, `GroupSubtitleText`): pages such as Gmail retitle their window every few seconds, and that must not rebuild the stage.

**No SwiftUI animation runs for long on the stage.** While any SwiftUI animation runs, every frame redraws the whole stage on the CPU, its text and icons included: the tab bar's sliding selection cost a third of a second per switch and the refresh symbol a full core while it turned. Motion that lasts is Core Animation on a layer of its own instead, which the render server runs while the stage draws nothing: the selected tab's background (`TabHighlight`), the refresh symbol (`SpinningSymbol`), the clock's colons.

The world clock's digits are drawn as segment displays (`SevenSegmentDisplay`): seven segments for digits, fourteen for letters. A display redraws only when its text changes; colons blink in a Core Animation layer so a blink costs the app nothing. The window server draws only while a layer's opacity changes, so the colons' fades are kept to 80 ms. Cities come from the time zone database and Apple Maps (`WorldClockCitySearch`); zones by offset, abbreviation or name from `TimeZoneSearch`.
