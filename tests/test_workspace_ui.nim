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

  test "root split duplicates viewport ownership without duplicating tabs":
    var state = initWorkspaceUi(tabCount = 2, activeTab = 0)
    check state.splitFocusedPane(paneVertical)
    check state.center.kind == paneSplit
    check state.center.first.pane.tabIndices == @[0, 1]
    check state.center.second.pane.tabIndices == @[0, 1]
