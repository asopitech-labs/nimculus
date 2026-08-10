import std/unittest
import std/os
import nimnui/geometry
import nimculus/editor_app
import nimculus/settings
import nimculus/workspace_ui

suite "workspace UI state":
  test "dock side and panel position APIs are exhaustive without moving panels":
    let settings = newSettingsStore("", "", "")
    check dockLeft != dockRight
    check dockBottom != dockRight
    check panelDockSettingKey(panelFiles) == "projectPanel.dock"
    check panelDockSettingKey(panelGit) == "gitPanel.dock"
    check panelDockSettingKey(panelOutline) == "outlinePanel.dock"
    check panelDockSettingKey(panelTerminal) == "terminal.dock"
    check panelDockSettingKey(panelDebugger) == "debugger.dock"
    check panelDockSettingKey(panelAgent) == "agent.dock"
    check panelDockSettingKey(panelTasks) == ""
    check panelDockSettingKey(panelSearch) == ""
    check panelDockSide(panelFiles, settings) == dockRight
    check panelDockSide(panelOutline, settings) == dockRight
    check panelDockSide(panelGit, settings) == dockRight
    check panelDockSide(panelAgent, settings) == dockLeft
    check panelDockSide(panelTerminal, settings) == dockBottom
    check panelDockSide(panelDebugger, settings) == dockBottom
    check panelDockSide(panelTasks, settings) == dockBottom
    check panelDockSide(panelSearch, settings) == dockLeft
    check panelPositionIsValid(panelFiles, dockLeft)
    check panelPositionIsValid(panelFiles, dockRight)
    check not panelPositionIsValid(panelFiles, dockBottom)
    for panel in [panelGit, panelOutline, panelAgent]:
      check panelPositionIsValid(panel, dockLeft)
      check not panelPositionIsValid(panel, dockBottom)
      check panelPositionIsValid(panel, dockRight)
    for panel in [panelTerminal, panelDebugger]:
      check panelPositionIsValid(panel, dockLeft)
      check panelPositionIsValid(panel, dockBottom)
      check panelPositionIsValid(panel, dockRight)
    check panelPositionIsValid(panelTasks, dockBottom)
    check panelPositionIsValid(panelSearch, dockLeft)

    let state = initWorkspaceUi(settings = settings)
    check state.leftDock.side == dockLeft
    check state.bottomDock.side == dockBottom
    check state.rightDock.side == dockRight
    check state.panelBelongsTo(panelFiles, dockRight)
    check state.panelBelongsTo(panelTerminal, dockBottom)
    check state.panelBelongsTo(panelAgent, dockLeft)
    check state.dock(dockRight).side == dockRight

  test "unknown panel dock settings use each panel's default side":
    let root = getTempDir() / "nimculus-unknown-panel-dock-settings"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{"agent":{"dock":"diagonal"}}""")
    let settings = newSettingsStore(path, "", "")
    check panelDockSide(panelAgent, settings) == dockLeft
    check settings.diagnostics().len == 1
    removeFile(path)
    removeDir(root)

  test "startup settings move panel ownership between the three docks":
    let root = getTempDir() / "nimculus-panel-dock-settings"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{"projectPanel":{"dock":"left"},"terminal":{"dock":"right"}}""")
    let settings = newSettingsStore(path, "", "")
    var state = initWorkspaceUi(settings = newSettingsStore("", "", ""))
    state.openPanel(panelFiles)
    state.openPanel(panelTerminal)
    state.applyPanelDockSettings(settings)
    check state.panelDockSide(panelFiles) == dockLeft
    check state.panelDockSide(panelTerminal) == dockRight
    check state.leftDock.isOpen
    check state.leftDock.activePanel == panelFiles
    check state.rightDock.isOpen
    check state.rightDock.activePanel == panelTerminal
    check state.panelDockSide(panelAgent) == dockLeft
    removeFile(path)
    removeDir(root)

  test "dock axes distinguish horizontal edges from the bottom dock":
    check dockLeft.axis == dockHorizontal
    check dockRight.axis == dockHorizontal
    check dockBottom.axis == dockVertical

  test "moving a visible panel left to right preserves width and visibility":
    let root = getTempDir() / "nimculus-live-panel-dock-horizontal"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{"agent":{"dock":"right"}}""")
    let settings = newSettingsStore(path, "", "")
    var state = initWorkspaceUi()
    state.openPanel(panelAgent)
    state.leftDock.size = 312'f32
    state.applyPanelDockSettings(settings)
    check state.panelDockSide(panelAgent) == dockRight
    check state.rightDock.isOpen
    check state.rightDock.activePanel == panelAgent
    check state.rightDock.size == 312'f32
    check state.leftDock.isOpen
    check state.leftDock.activePanel == panelSearch
    removeFile(path)
    removeDir(root)

  test "moving a closed panel does not open its target dock":
    let root = getTempDir() / "nimculus-live-panel-dock-closed"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{"agent":{"dock":"right"}}""")
    let settings = newSettingsStore(path, "", "")
    var state = initWorkspaceUi()
    state.rightDock.isOpen = false
    state.applyPanelDockSettings(settings)
    check state.panelDockSide(panelAgent) == dockRight
    check not state.rightDock.isOpen
    check state.rightDock.activePanel == panelFiles
    check not state.leftDock.isOpen
    check state.leftDock.activePanel == panelSearch
    removeFile(path)
    removeDir(root)

  test "moving a visible panel left to bottom uses the target default size":
    let root = getTempDir() / "nimculus-live-panel-dock-axis"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{"terminal":{"dock":"bottom"}}""")
    let settings = newSettingsStore(path, "", "")
    var state = initWorkspaceUi()
    state.panelDockSides[panelTerminal] = dockLeft
    state.leftDock.isOpen = true
    state.leftDock.activePanel = panelTerminal
    state.leftDock.size = 333'f32
    state.applyPanelDockSettings(settings)
    check state.panelDockSide(panelTerminal) == dockBottom
    check state.bottomDock.isOpen
    check state.bottomDock.activePanel == panelTerminal
    check state.bottomDock.size == DefaultBottomDockHeight
    check state.leftDock.isOpen
    check state.leftDock.activePanel == panelSearch
    removeFile(path)
    removeDir(root)

  test "invalid panel dock settings keep the current ownership":
    let root = getTempDir() / "nimculus-live-panel-dock-invalid"
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, """{"projectPanel":{"dock":"diagonal"}}""")
    let settings = newSettingsStore(path, "", "")
    var state = initWorkspaceUi()
    state.openPanel(panelFiles)
    state.rightDock.size = 321'f32
    state.applyPanelDockSettings(settings)
    check state.panelDockSide(panelFiles) == dockRight
    check state.rightDock.isOpen
    check state.rightDock.activePanel == panelFiles
    check state.rightDock.size == 321'f32
    removeFile(path)
    removeDir(root)

  test "session persistence records all three dock states":
    var state = initWorkspaceUi()
    state.leftDock.isOpen = true
    state.leftDock.size = 271'f32
    state.leftDock.activePanel = panelAgent
    state.bottomDock.isOpen = true
    state.bottomDock.size = 299'f32
    state.bottomDock.activePanel = panelTerminal
    state.rightDock.isOpen = false
    state.rightDock.size = 347'f32
    state.rightDock.activePanel = panelGit
    var session: EditorSession
    state.saveWorkspaceUi(session)
    check session.workspaceLeftDockOpen
    check session.workspaceLeftDockSize == 271'f32
    check session.workspaceLeftPanel == ord(panelAgent)
    check session.workspaceBottomDockOpen
    check session.workspaceBottomDockSize == 299'f32
    check session.workspaceBottomPanel == ord(panelTerminal)
    check not session.workspaceRightDockOpen
    check session.workspaceRightDockSize == 347'f32
    check session.workspaceRightPanel == ord(panelGit)
    let restored = initWorkspaceUi(session)
    check restored.leftDock.isOpen
    check restored.leftDock.size == 271'f32
    check restored.leftDock.activePanel == panelAgent
    check restored.bottomDock.isOpen
    check restored.bottomDock.size == 299'f32
    check restored.bottomDock.activePanel == panelTerminal
    check not restored.rightDock.isOpen
    check restored.rightDock.size == 347'f32
    check restored.rightDock.activePanel == panelGit

  test "session without dock state keeps all docks closed":
    var session: EditorSession
    let restored = initWorkspaceUi(session)
    check not restored.leftDock.isOpen
    check not restored.bottomDock.isOpen
    check not restored.rightDock.isOpen

  test "panel dock side mask keeps left, bottom, and right distinct":
    let state = initWorkspaceUi()
    let mask = state.panelDockSideMask()
    check (mask shr (ord(panelAgent) * 2) and 3'u32) == 1'u32
    check (mask shr (ord(panelTerminal) * 2) and 3'u32) == 2'u32
    check (mask shr (ord(panelFiles) * 2) and 3'u32) == 3'u32

  test "initial workspace starts with all docks closed":
    let state = initWorkspaceUi(tabCount = 3, activeTab = 1)
    check state.validate()
    check not state.leftDock.isOpen
    check not state.bottomDock.isOpen
    check not state.rightDock.isOpen
    check state.rightDock.activePanel == panelFiles
    check state.center.firstPane().tabIndices == @[0, 1, 2]
    check state.center.firstPane().activeTabIndex == 1

  test "panel toggles preserve independent dock state":
    var state = initWorkspaceUi()
    state.openPanel(panelFiles)
    state.openPanel(panelTerminal)
    check state.bottomDock.isOpen
    check state.bottomDock.activePanel == panelTerminal
    state.togglePanel(panelTerminal)
    check not state.bottomDock.isOpen
    check state.rightDock.isOpen

  test "panel focus toggle returns to the editor without hiding the panel":
    var state = initWorkspaceUi()
    state.focusCenter()
    check state.togglePanelFocus(panelGit)
    check state.rightDock.isOpen
    check state.rightDock.activePanel == panelGit
    check state.focusedRegion == regionRightDock
    check not state.togglePanelFocus(panelGit)
    check state.rightDock.isOpen
    check state.rightDock.activePanel == panelGit
    check state.focusedRegion == regionCenter

  test "panel lists preserve selection by stable key across refreshes":
    var state = initWorkspaceUi()
    state.replacePanelItems(panelFiles, ["/workspace/a.nim", "/workspace/b.nim"])
    check state.selectPanelItem(panelFiles, 1)
    state.replacePanelItems(panelFiles, ["/workspace/new.nim", "/workspace/b.nim"])
    check state.panelSelectedIndex(panelFiles) == 1
    check state.panelList(panelFiles).selectedKey == "/workspace/b.nim"
    state.replacePanelItems(panelFiles, ["/workspace/new.nim"])
    check state.panelSelectedIndex(panelFiles) == -1

  test "panel list navigation clamps and keeps panel focus":
    var state = initWorkspaceUi()
    state.replacePanelItems(panelGit, ["commit-a", "commit-b", "commit-c"])
    check state.movePanelSelection(panelGit, 1)
    check state.panelSelectedIndex(panelGit) == 0
    check state.movePanelSelection(panelGit, 99)
    check state.panelSelectedIndex(panelGit) == 2
    check state.movePanelSelection(panelGit, -99)
    check state.panelSelectedIndex(panelGit) == 0
    check state.selectPanelBoundary(panelGit, last = true)
    check state.panelSelectedIndex(panelGit) == 2
    check state.rightDock.activePanel == panelGit
    check state.focusedRegion == regionRightDock

  test "closing a shared tab preserves independent pane selections":
    var state = initWorkspaceUi(tabCount = 3, activeTab = 0)
    discard state.splitFocusedPane(paneVertical)
    discard state.selectPaneTab(state.center.second.pane.id, 2)
    state.removeTab(1)
    check state.center.first.pane.activeTabIndex == 0
    check state.center.second.pane.activeTabIndex == 1
    check state.center.first.pane.tabIndices == @[0, 1]

  test "layout protects a usable editor center":
    var state = initWorkspaceUi()
    state.openPanel(panelFiles)
    state.resizeDock(dockLeft, 900, 800)
    let layout = state.layout(Size(width: px(800), height: px(600)))
    check float32(layout.center.size.width) >= MinimumCenterWidth
    check layout.regionAt(Point(x: px(799), y: px(10))) == regionRightDock
    check layout.regionAt(Point(x: px(500), y: px(599))) == regionStatus

  test "right dock geometry has no activity rail between panel and editor":
    var state = initWorkspaceUi()
    state.openPanel(panelFiles)
    let viewport = Size(width: px(960), height: px(640))
    let layout = state.layout(viewport)
    check float32(layout.rightDock.size.width) == DefaultLeftDockWidth
    check float32(layout.center.origin.x) == 0'f32
    check layout.presentedRegionAt(viewport, Point(x: px(239), y: px(120)),
      presentedDockWidth = DefaultLeftDockWidth) == regionCenter
    check layout.presentedRegionAt(viewport, Point(x: px(240), y: px(120)),
      presentedDockWidth = DefaultLeftDockWidth) == regionCenter
    check layout.presentedRegionAt(viewport, Point(x: px(959), y: px(120)),
      presentedDockWidth = DefaultLeftDockWidth) == regionRightDock
    check state.dockResizeDivider(dockRight, 960) == 720
    state.resizeDock(dockRight, dockResizeRequest(dockRight, 660, 960), 960)
    check state.rightDock.size == 300

  test "left and right dock resize coordinates use their real edges":
    var state = initWorkspaceUi()
    check state.dockResizeDivider(dockRight, 1200) == 960
    check dockResizeRequest(dockRight, 840, 1200) == 360
    state.resizeDock(dockRight, dockResizeRequest(dockRight, 840, 1200), 1200)
    check state.rightDock.size == 360
    check state.dockResizeDivider(dockRight, 1200) == 840
    state.resetDockSize(dockRight)
    check state.rightDock.size == DefaultLeftDockWidth
    state.leftDock.isOpen = true
    check state.dockResizeDivider(dockLeft, 1200) == DefaultLeftDockWidth
    check dockResizeRequest(dockLeft, 300, 1200) == 300

  test "right project dock presentation uses its measured width":
    check projectDockPresentationWidth(DefaultLeftDockWidth, 128'f32,
      ) == DefaultLeftDockWidth

  test "a native dock presentation yields its space when it cannot fit":
    check dockPresentationWidth(160'f32, 178'f32) == 0'f32
    check dockPresentationWidth(178'f32, 178'f32) == 178'f32
    check dockPresentationWidth(240'f32, 178'f32) == 240'f32
    check dockPresentationWidth(-1'f32, 178'f32) == 0'f32

  test "right dock hit testing follows its visible presentation":
    let viewport = Size(width: px(520), height: px(600))
    var state = initWorkspaceUi()
    state.openPanel(panelFiles)
    let narrowed = state.layout(viewport)
    let narrowedDock = dockPresentationWidth(float32(narrowed.rightDock.size.width), 178'f32)
    check narrowedDock == 0'f32
    check narrowed.presentedRegionAt(viewport, Point(x: px(500), y: px(120)),
      presentedDockWidth = narrowedDock) == regionCenter

    let widenedViewport = Size(width: px(640), height: px(600))
    let widened = state.layout(widenedViewport)
    let widenedDock = dockPresentationWidth(float32(widened.rightDock.size.width), 178'f32)
    check widenedDock == 240'f32
    check widened.presentedRegionAt(widenedViewport, Point(x: px(500), y: px(120)),
      presentedDockWidth = widenedDock) == regionRightDock
    check widened.presentedRegionAt(widenedViewport, Point(x: px(100), y: px(120)),
      presentedDockWidth = widenedDock) == regionCenter

  test "bottom dock takes space from the center instead of overlaying it":
    var state = initWorkspaceUi()
    let closed = state.layout(Size(width: px(960), height: px(640)))
    state.openPanel(panelTerminal)
    let opened = state.layout(Size(width: px(960), height: px(640)))
    check float32(opened.bottomDock.size.height) == DefaultBottomDockHeight
    check float32(opened.center.size.height) < float32(closed.center.size.height)
    check float32(opened.center.size.height) + float32(opened.bottomDock.size.height) +
      float32(opened.status.size.height) == 640'f32

  test "root split duplicates viewport ownership without duplicating tabs":
    var state = initWorkspaceUi(tabCount = 2, activeTab = 0)
    check state.splitFocusedPane(paneVertical)
    check state.center.kind == paneSplit
    check state.center.first.pane.tabIndices == @[0, 1]
    check state.center.second.pane.tabIndices == @[0, 1]

  test "tab selection belongs to every mirrored pane":
    var state = initWorkspaceUi(tabCount = 3, activeTab = 0)
    discard state.splitFocusedPane(paneVertical)
    state.selectTab(2)
    check state.center.first.pane.activeTabIndex == 2
    check state.center.second.pane.activeTabIndex == 2

  test "a pane retains its own tab selection when session tabs refresh":
    var state = initWorkspaceUi(tabCount = 3, activeTab = 0)
    discard state.splitFocusedPane(paneVertical)
    let primary = state.center.first.pane.id
    let secondary = state.center.second.pane.id
    check state.selectPaneTab(secondary, 2)
    check state.paneTabIndex(primary) == 0
    check state.paneTabIndex(secondary) == 2
    state.syncRootTabs(tabCount = 3, activeTab = 1)
    check state.paneTabIndex(primary) == 0
    check state.paneTabIndex(secondary) == 2

  test "tab cycling changes only the focused pane selection":
    var state = initWorkspaceUi(tabCount = 3, activeTab = 0)
    discard state.splitFocusedPane(paneVertical)
    let primary = state.center.first.pane.id
    let secondary = state.center.second.pane.id
    check state.cyclePaneTab(secondary, 1) == 1
    check state.paneTabIndex(primary) == 0
    check state.paneTabIndex(secondary) == 1
    check state.cyclePaneTab(secondary, -1) == 0
    check state.paneTabIndex(primary) == 0

  test "split ratio and close remain pane tree operations":
    var state = initWorkspaceUi(tabCount = 1)
    discard state.splitFocusedPane(paneHorizontal, 0.4)
    check state.setRootSplitRatio(0.7)
    check abs(state.center.ratio - 0.7'f32) < 0.001'f32
    check state.closeRootSplit()
    check state.center.kind == paneLeaf

  test "pane tree recursively owns rectangles, dividers, and hit testing":
    var state = initWorkspaceUi(tabCount = 2, activeTab = 0)
    check state.splitFocusedPane(paneVertical, 0.4'f32)
    let bounds = Rect(origin: Point(x: px(10), y: px(20)),
      size: Size(width: px(500), height: px(300)))
    let layout = state.center.paneLayout(bounds)
    check layout.panes.len == 2
    check layout.dividers.len == 1
    check abs(float32(layout.panes[0].bounds.size.width) - 199.2'f32) < 0.001'f32
    check float32(layout.dividers[0].bounds.size.width) == PaneDividerThickness
    check state.paneAt(bounds, Point(x: px(50), y: px(40))) == layout.panes[0].id
    check state.paneAt(bounds, Point(x: px(400), y: px(40))) == layout.panes[1].id
    check state.paneIndexAt(bounds, Point(x: px(400), y: px(40))) == 1
    check state.focusPane(layout.panes[1].id)
    check state.focusedPane == layout.panes[1].id

  test "split panes retain Zed-compatible minimum extents when space permits":
    var sideBySide = initWorkspaceUi(tabCount = 1)
    check sideBySide.splitFocusedPane(paneVertical, 0.1'f32)
    let sideBySideBounds = Rect(origin: Point(x: px(0), y: px(0)),
      size: Size(width: px(300), height: px(240)))
    let wide = sideBySide.center.paneLayout(sideBySideBounds)
    check float32(wide.panes[0].bounds.size.width) == MinimumPaneWidth
    check float32(wide.panes[1].bounds.size.width) ==
      300'f32 - PaneDividerThickness - MinimumPaneWidth
    let expectedMinimumRatio = MinimumPaneWidth / (300'f32 - PaneDividerThickness)
    check abs(sideBySide.clampedRootSplitRatio(sideBySideBounds, 0.1'f32) -
      expectedMinimumRatio) < 0.001'f32

    var stacked = initWorkspaceUi(tabCount = 1)
    check stacked.splitFocusedPane(paneHorizontal, 0.1'f32)
    let tall = stacked.center.paneLayout(Rect(origin: Point(x: px(0), y: px(0)),
      size: Size(width: px(300), height: px(260))))
    check float32(tall.panes[0].bounds.size.height) == MinimumPaneHeight
    check float32(tall.panes[1].bounds.size.height) ==
      260'f32 - PaneDividerThickness - MinimumPaneHeight
