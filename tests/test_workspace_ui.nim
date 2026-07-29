import std/unittest
import nimnui/geometry
import nimculus/workspace_ui

suite "workspace UI state":
  test "initial workspace gives files a persistent left dock":
    let state = initWorkspaceUi(tabCount = 3, activeTab = 1)
    check state.validate()
    check state.leftDock.isOpen
    check state.leftDock.activePanel == panelFiles
    check state.center.firstPane().tabIndices == @[0, 1, 2]
    check state.center.firstPane().activeTabIndex == 1

  test "panel toggles preserve independent dock state":
    var state = initWorkspaceUi()
    state.openPanel(panelTerminal)
    check state.bottomDock.isOpen
    check state.bottomDock.activePanel == panelTerminal
    state.togglePanel(panelTerminal)
    check not state.bottomDock.isOpen
    check state.leftDock.isOpen

  test "layout protects a usable editor center":
    var state = initWorkspaceUi()
    state.resizeDock(dockLeft, 900, 800)
    let layout = state.layout(Size(width: px(800), height: px(600)))
    check float32(layout.center.size.width) >= MinimumCenterWidth
    check layout.regionAt(Point(x: px(10), y: px(10))) == regionLeftDock
    check layout.regionAt(Point(x: px(500), y: px(590))) == regionStatus

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
