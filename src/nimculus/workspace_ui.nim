## Application-owned workspace UI state.
##
## This deliberately models interaction and geometry independently of Cocoa and
## Metal.  AppKit remains the platform bridge; the editor owns its docks, panes
## and focus in one place, as Zed's Workspace does.

import nimnui/geometry
import nimculus/editor_app
import nimculus/settings

type
  WorkspaceRegion* = enum
    regionNone, regionLeftDock, regionCenter, regionBottomDock, regionRightDock,
    regionStatus

  PanelKind* = enum
    # Keep new values at the end: panel ordinals are persisted in sessions.
    panelFiles, panelGit, panelOutline, panelTerminal, panelTasks, panelSearch,
    panelDebugger, panelAgent

  DockSide* = enum
    dockLeft, dockBottom, dockRight

  DockAxis* = enum
    dockHorizontal, dockVertical

  PaneAxis* = enum
    paneHorizontal, paneVertical

  PaneId* = distinct int

  PaneState* = object
    ## Tab indices remain owned by EditorSession during the migration. This
    ## makes the layout state useful now without duplicating document ownership.
    id*: PaneId
    tabIndices*: seq[int]
    activeTabIndex*: int

  PaneTreeKind* = enum
    paneLeaf, paneSplit

  PaneTree* = ref object
    case kind*: PaneTreeKind
    of paneLeaf:
      pane*: PaneState
    of paneSplit:
      axis*: PaneAxis
      ratio*: float32
      first*, second*: PaneTree

  DockState* = object
    side*: DockSide
    isOpen*: bool
    activePanel*: PanelKind
    size*: float32
    minimumSize*: float32

  PanelListState* = object
    ## A panel owns its selection independently from the text presenter. Keys
    ## are stable identities (workspace path, commit hash, branch name), not
    ## rendered row text, so a refresh can retain the user's current item.
    itemKeys*: seq[string]
    selectedKey*: string
    selectedIndex*: int
    focused*: bool

  WorkspaceLayout* = object
    leftDock*, center*, bottomDock*, rightDock*, status*: Rect

  PaneLayoutEntry* = object
    id*: PaneId
    bounds*: Rect

  PaneDivider* = object
    axis*: PaneAxis
    bounds*: Rect

  PaneLayout* = object
    panes*: seq[PaneLayoutEntry]
    dividers*: seq[PaneDivider]

  WorkspaceUiState* = object
    leftDock*, bottomDock*, rightDock*: DockState
    panelDockSides*: array[PanelKind, DockSide]
    panelLists*: array[PanelKind, PanelListState]
    center*: PaneTree
    focusedRegion*: WorkspaceRegion
    focusedPane*: PaneId
    resizingDock*: DockSide
    isResizingDock*: bool
    nextPaneId*: int

proc `==`*(a, b: PaneId): bool {.borrow.}

const
  DefaultLeftDockWidth* = 240'f32
  DefaultBottomDockHeight* = 260'f32
  ## Zed's logical separator/status surface is presented by AppKit in the
  ## 16pt band above the native 30pt footer. Leave only its two-point Metal
  ## seam in the shared layout so the editor reaches that presenter.
  DefaultStatusHeight* = 2'f32
  DefaultDockMinimumSize* = 160'f32
  MinimumCenterWidth* = 360'f32
  MinimumCenterHeight* = 180'f32
  ## Match Zed's PaneGroup floor: a side-by-side editor remains wide enough
  ## for a cursor and line content, while a stacked editor keeps one readable
  ## text row plus its chrome. The window can be smaller than the aggregate
  ## floor, but divider dragging must not collapse a pane when room exists.
  MinimumPaneWidth* = 80'f32
  MinimumPaneHeight* = 100'f32
  PaneDividerThickness* = 2'f32

proc normalizedRatio*(ratio: float32): float32 =
  min(0.9'f32, max(0.1'f32, ratio))

proc dockPresentationWidth*(logicalWidth, minimumPresenterWidth: float32): float32 =
  ## A platform presenter may need more room than the logical dock has after
  ## the workspace protects its center minimum. In that case the visual dock
  ## must disappear as a whole: leaving its Metal background while hiding the
  ## native controls creates a non-functional empty panel.
  let width = max(0'f32, logicalWidth)
  if minimumPresenterWidth > 0'f32 and width < minimumPresenterWidth:
    0'f32
  else:
    width

proc projectDockPresentationWidth*(logicalWidth, minimumPresenterWidth: float32): float32 =
  ## The Project Panel is now owned by its real dock. Its native presenter
  ## therefore uses the dock width directly on either horizontal edge.
  dockPresentationWidth(logicalWidth, minimumPresenterWidth)

proc newPane(id: int, tabIndices: seq[int] = @[], activeTabIndex = -1): PaneTree =
  PaneTree(kind: paneLeaf, pane: PaneState(id: PaneId(id), tabIndices: tabIndices,
    activeTabIndex: activeTabIndex))

proc defaultPanelDockSide(panel: PanelKind): DockSide =
  case panel
  of panelFiles, panelGit, panelOutline: dockRight
  of panelTerminal, panelDebugger, panelTasks: dockBottom
  of panelAgent, panelSearch: dockLeft

proc axis*(side: DockSide): DockAxis =
  case side
  of dockLeft, dockRight: dockHorizontal
  of dockBottom: dockVertical

proc defaultDockSize(side: DockSide): float32 =
  case side
  of dockLeft, dockRight: DefaultLeftDockWidth
  of dockBottom: DefaultBottomDockHeight

proc dockRegion(side: DockSide): WorkspaceRegion =
  case side
  of dockLeft: regionLeftDock
  of dockBottom: regionBottomDock
  of dockRight: regionRightDock

proc panelDockSide*(panel: PanelKind, settings: SettingsStore): DockSide
proc panelPositionIsValid*(panel: PanelKind, side: DockSide): bool
proc panelDockSide*(state: WorkspaceUiState, panel: PanelKind): DockSide
proc dock*(state: WorkspaceUiState, side: DockSide): DockState
proc openPanel*(state: var WorkspaceUiState, panel: PanelKind)

proc initWorkspaceUi*(tabCount = 0, activeTab = -1,
                      settings: SettingsStore = nil): WorkspaceUiState =
  var tabs: seq[int]
  for index in 0 ..< tabCount: tabs.add(index)
  for panel in PanelKind:
    result.panelDockSides[panel] = if settings == nil:
      defaultPanelDockSide(panel) else: panelDockSide(panel, settings)
  result.leftDock = DockState(side: dockLeft, isOpen: false, activePanel: panelAgent,
    size: DefaultLeftDockWidth, minimumSize: DefaultDockMinimumSize)
  result.bottomDock = DockState(side: dockBottom, isOpen: false,
    activePanel: panelTerminal, size: DefaultBottomDockHeight,
    minimumSize: DefaultDockMinimumSize)
  result.rightDock = DockState(side: dockRight, isOpen: false, activePanel: panelFiles,
    size: DefaultLeftDockWidth, minimumSize: DefaultDockMinimumSize)
  result.center = newPane(1, tabs, activeTab)
  for panel in PanelKind:
    result.panelLists[panel].selectedIndex = -1
  result.focusedRegion = regionCenter
  result.focusedPane = PaneId(1)
  result.nextPaneId = 2

proc panelFromOrdinal(value: int, fallback: PanelKind): PanelKind =
  if value >= ord(low(PanelKind)) and value <= ord(high(PanelKind)):
    PanelKind(value) else: fallback

proc restoreDock(state: var WorkspaceUiState, side: DockSide, isOpen: bool,
                 size: float32, panel: PanelKind) =
  let restoredSize = max(DefaultDockMinimumSize, size)
  case side
  of dockLeft:
    state.leftDock.isOpen = isOpen
    state.leftDock.size = restoredSize
    state.leftDock.activePanel = panel
  of dockBottom:
    state.bottomDock.isOpen = isOpen
    state.bottomDock.size = restoredSize
    state.bottomDock.activePanel = panel
  of dockRight:
    state.rightDock.isOpen = isOpen
    state.rightDock.size = restoredSize
    state.rightDock.activePanel = panel

proc initWorkspaceUi*(session: EditorSession, settings: SettingsStore = nil): WorkspaceUiState =
  result = initWorkspaceUi(session.tabs.len, session.activeTab, settings)
  # Session fields belong to physical docks, so restore each dock from its own
  # open bit, size, and active panel. A zero size means there is no persisted
  # dock state, and therefore leaves the dock closed.
  if session.workspaceLeftDockSize > 0:
    result.restoreDock(dockLeft, session.workspaceLeftDockOpen,
      session.workspaceLeftDockSize,
      panelFromOrdinal(session.workspaceLeftPanel, panelAgent))
  if session.workspaceBottomDockSize > 0:
    result.restoreDock(dockBottom, session.workspaceBottomDockOpen,
      session.workspaceBottomDockSize,
      panelFromOrdinal(session.workspaceBottomPanel, panelTerminal))
  if session.workspaceRightDockSize > 0:
    result.restoreDock(dockRight, session.workspaceRightDockOpen,
      session.workspaceRightDockSize,
      panelFromOrdinal(session.workspaceRightPanel, panelFiles))

proc panelDockSide*(state: WorkspaceUiState, panel: PanelKind): DockSide =
  state.panelDockSides[panel]

proc replacementPanel(state: WorkspaceUiState, side: DockSide,
                      removed: PanelKind): PanelKind =
  for panel in PanelKind:
    if panel != removed and state.panelDockSide(panel) == side:
      return panel
  removed

proc applyPanelDockSettings*(state: var WorkspaceUiState, settings: SettingsStore) =
  ## Reconcile settings-owned panel positions with the current dock ownership.
  ## Keep the visible panel and its dock size across a handoff when the dock
  ## axis is unchanged, matching Zed's DockPosition::axis semantics.
  let oldSides = state.panelDockSides
  let oldLeft = state.leftDock
  let oldBottom = state.bottomDock
  let oldRight = state.rightDock
  for panel in PanelKind:
    state.panelDockSides[panel] = panelDockSide(panel, settings)

  for panel in PanelKind:
    let source = oldSides[panel]
    let target = state.panelDockSide(panel)
    if source == target: continue

    let sourceDock = case source
      of dockLeft: oldLeft
      of dockBottom: oldBottom
      of dockRight: oldRight
    let wasVisible = sourceDock.isOpen and sourceDock.activePanel == panel
    let size = if source.axis == target.axis: sourceDock.size
      else: defaultDockSize(target)

    case target
    of dockLeft: state.leftDock.size = size
    of dockBottom: state.bottomDock.size = size
    of dockRight: state.rightDock.size = size

    if wasVisible:
      case target
      of dockLeft:
        state.leftDock.isOpen = true
        state.leftDock.activePanel = panel
      of dockBottom:
        state.bottomDock.isOpen = true
        state.bottomDock.activePanel = panel
      of dockRight:
        state.rightDock.isOpen = true
        state.rightDock.activePanel = panel
      if state.focusedRegion == dockRegion(source):
        state.focusedRegion = dockRegion(target)

    # Removing the active panel must leave the source dock with another
    # panel, or closed if it has no remaining owner. A closed source still
    # needs its stale activePanel replaced for the next explicit open.
    let sourceActive = case source
      of dockLeft: state.leftDock.activePanel
      of dockBottom: state.bottomDock.activePanel
      of dockRight: state.rightDock.activePanel
    if sourceActive == panel:
      let replacement = state.replacementPanel(source, panel)
      if replacement == panel:
        case source
        of dockLeft: state.leftDock.isOpen = false
        of dockBottom: state.bottomDock.isOpen = false
        of dockRight: state.rightDock.isOpen = false
      else:
        case source
        of dockLeft: state.leftDock.activePanel = replacement
        of dockBottom: state.bottomDock.activePanel = replacement
        of dockRight: state.rightDock.activePanel = replacement

proc saveWorkspaceUi*(state: WorkspaceUiState, session: var EditorSession) =
  session.workspaceLeftDockOpen = state.leftDock.isOpen
  session.workspaceBottomDockOpen = state.bottomDock.isOpen
  session.workspaceRightDockOpen = state.rightDock.isOpen
  session.workspaceLeftDockSize = state.leftDock.size
  session.workspaceBottomDockSize = state.bottomDock.size
  session.workspaceRightDockSize = state.rightDock.size
  session.workspaceLeftPanel = ord(state.leftDock.activePanel)
  session.workspaceBottomPanel = ord(state.bottomDock.activePanel)
  session.workspaceRightPanel = ord(state.rightDock.activePanel)

proc dock*(state: WorkspaceUiState, side: DockSide): DockState =
  case side
  of dockLeft: state.leftDock
  of dockBottom: state.bottomDock
  of dockRight: state.rightDock

proc panelIsActive*(state: WorkspaceUiState, panel: PanelKind): bool =
  let side = state.panelDockSide(panel)
  let current = state.dock(side)
  current.isOpen and current.activePanel == panel

proc toggleDock*(state: var WorkspaceUiState, side: DockSide) =
  let wasOpen = state.dock(side).isOpen
  case side
  of dockLeft: state.leftDock.isOpen = not wasOpen
  of dockBottom: state.bottomDock.isOpen = not wasOpen
  of dockRight: state.rightDock.isOpen = not wasOpen
  state.focusedRegion = if wasOpen: regionCenter else: dockRegion(side)

proc panelBelongsTo*(state: WorkspaceUiState, panel: PanelKind, side: DockSide): bool =
  state.panelDockSide(panel) == side

proc panelDockSettingKey*(panel: PanelKind): string =
  ## Settings names mirror Zed's panel-scoped keys while following Nimculus's
  ## camelCase path convention. Tasks and Search have no corresponding Zed
  ## panel setting yet and retain their legacy dock until a setting is added.
  case panel
  of panelFiles: "projectPanel.dock"
  of panelGit: "gitPanel.dock"
  of panelOutline: "outlinePanel.dock"
  of panelTerminal: "terminal.dock"
  of panelDebugger: "debugger.dock"
  of panelAgent: "agent.dock"
  of panelTasks, panelSearch: ""

proc dockSideFromSetting(value: string, fallback: DockSide): DockSide =
  case value
  of "left": dockLeft
  of "bottom": dockBottom
  of "right": dockRight
  else: fallback

proc panelDockSide*(panel: PanelKind, settings: SettingsStore): DockSide =
  ## Read the panel's configured position without applying it to workspace
  ## ownership yet. Applying this result is the follow-up ownership migration.
  let configured = case panel
    of panelFiles: dockSideFromSetting(settings.projectPanelDock(), dockRight)
    of panelGit: dockSideFromSetting(settings.gitPanelDock(), dockRight)
    of panelOutline: dockSideFromSetting(settings.outlinePanelDock(), dockRight)
    of panelTerminal: dockSideFromSetting(settings.terminalDock(), dockBottom)
    of panelDebugger: dockSideFromSetting(settings.debuggerDock(), dockBottom)
    of panelAgent: dockSideFromSetting(settings.agentDock(), dockLeft)
    of panelTasks: dockBottom
    of panelSearch: dockLeft
  if panelPositionIsValid(panel, configured): configured else: defaultPanelDockSide(panel)

proc panelPositionIsValid*(panel: PanelKind, side: DockSide): bool =
  ## Match Zed's panel-specific position predicates. Tasks and Search have no
  ## corresponding Zed panel and retain their current side until they receive
  ## panel-scoped settings.
  case panel
  of panelFiles: side in {dockLeft, dockRight}
  of panelGit, panelOutline: side in {dockLeft, dockRight}
  of panelAgent: side != dockBottom
  of panelTerminal, panelDebugger: true
  of panelTasks: side == dockBottom
  of panelSearch: side == dockLeft

proc panelDockSideMask*(state: WorkspaceUiState): uint32 =
  ## AppKit receives two bits per panel: 1 = left, 2 = bottom, 3 = right.
  ## AppKit uses the complete mapping to put left panels in its left cluster;
  ## bottom and right panels intentionally share the right cluster.
  for panel in PanelKind:
    let sideCode = uint32(ord(state.panelDockSide(panel))) + 1'u32
    result = result or (sideCode shl uint32(ord(panel) * 2))

proc openPanel*(state: var WorkspaceUiState, panel: PanelKind) =
  let side = state.panelDockSide(panel)
  case side
  of dockLeft:
    state.leftDock.activePanel = panel
    state.leftDock.isOpen = true
  of dockBottom:
    state.bottomDock.activePanel = panel
    state.bottomDock.isOpen = true
  of dockRight:
    state.rightDock.activePanel = panel
    state.rightDock.isOpen = true
  state.focusedRegion = dockRegion(side)

proc togglePanel*(state: var WorkspaceUiState, panel: PanelKind) =
  let side = state.panelDockSide(panel)
  let isOpen = state.dock(side).isOpen
  let activePanel = state.dock(side).activePanel
  if isOpen and activePanel == panel:
    case side
    of dockLeft: state.leftDock.isOpen = false
    of dockBottom: state.bottomDock.isOpen = false
    of dockRight: state.rightDock.isOpen = false
    if state.focusedRegion == dockRegion(side):
      state.focusedRegion = regionCenter
  else:
    state.openPanel(panel)

proc togglePanelFocus*(state: var WorkspaceUiState, panel: PanelKind): bool =
  ## Mirrors Zed's ToggleFocus contract: make a panel visible and focused when
  ## it is not focused; otherwise return keyboard focus to the editor without
  ## hiding the panel. Keeping visibility separate from focus avoids layout
  ## churn on a keyboard-only round trip.
  let side = state.panelDockSide(panel)
  let panelRegion = dockRegion(side)
  let isActive = state.dock(side).isOpen and state.dock(side).activePanel == panel
  if isActive and state.focusedRegion == panelRegion:
    state.focusedRegion = regionCenter
    return false
  state.openPanel(panel)
  true

proc panelList*(state: WorkspaceUiState, panel: PanelKind): PanelListState =
  state.panelLists[panel]

proc panelSelectedIndex*(state: WorkspaceUiState, panel: PanelKind): int =
  state.panelLists[panel].selectedIndex

proc replacePanelItems*(state: var WorkspaceUiState, panel: PanelKind,
                        itemKeys: openArray[string]) =
  ## Preserve a selected entry across refresh by identity rather than row
  ## position. A refresh that removes the selected item leaves no implicit
  ## selection; the next navigation command chooses the first available row.
  var list = addr state.panelLists[panel]
  list[].itemKeys = @itemKeys
  list[].selectedIndex = -1
  if list[].selectedKey.len > 0:
    for index, key in list[].itemKeys:
      if key == list[].selectedKey:
        list[].selectedIndex = index
        break
  if list[].selectedIndex < 0:
    list[].selectedKey = ""

proc selectPanelItem*(state: var WorkspaceUiState, panel: PanelKind,
                      index: int): bool =
  var list = addr state.panelLists[panel]
  if index < 0 or index >= list[].itemKeys.len: return false
  list[].selectedIndex = index
  list[].selectedKey = list[].itemKeys[index]
  list[].focused = true
  let side = state.panelDockSide(panel)
  case side
  of dockLeft:
    state.leftDock.activePanel = panel
    state.leftDock.isOpen = true
    state.focusedRegion = regionLeftDock
  of dockBottom:
    state.bottomDock.activePanel = panel
    state.bottomDock.isOpen = true
    state.focusedRegion = regionBottomDock
  of dockRight:
    state.rightDock.activePanel = panel
    state.rightDock.isOpen = true
    state.focusedRegion = regionRightDock
  true

proc movePanelSelection*(state: var WorkspaceUiState, panel: PanelKind,
                         delta: int): bool =
  let list = state.panelLists[panel]
  if list.itemKeys.len == 0: return false
  let target = if list.selectedIndex < 0:
      if delta < 0: list.itemKeys.high else: 0
    else:
      max(0, min(list.itemKeys.high, list.selectedIndex + delta))
  state.selectPanelItem(panel, target)

proc selectPanelBoundary*(state: var WorkspaceUiState, panel: PanelKind,
                          last: bool): bool =
  let list = state.panelLists[panel]
  if list.itemKeys.len == 0: return false
  state.selectPanelItem(panel, if last: list.itemKeys.high else: 0)

proc focusCenter*(state: var WorkspaceUiState) =
  state.focusedRegion = regionCenter

proc beginDockResize*(state: var WorkspaceUiState, side: DockSide) =
  case side
  of dockLeft, dockBottom, dockRight:
    state.resizingDock = side
    state.isResizingDock = true

proc endDockResize*(state: var WorkspaceUiState) =
  state.isResizingDock = false

proc dockResizeDivider*(state: WorkspaceUiState, side: DockSide,
                        available: float32): float32 =
  ## Return the visible divider coordinate on its resize axis. Left and right
  ## docks use their actual edge, while bottom uses its top edge.
  let size = state.dock(side).size
  case side
  of dockLeft:
    size
  of dockBottom, dockRight:
    max(0'f32, available - size)

proc dockResizeRequest*(side: DockSide, pointer, available: float32,
                        ): float32 =
  ## Convert a visible pointer coordinate to the logical dock size.
  case side
  of dockLeft:
    max(0'f32, pointer)
  of dockBottom, dockRight:
    max(0'f32, available - pointer)

proc resetDockSize*(state: var WorkspaceUiState, side: DockSide) =
  ## Match Zed's resize-handle double-click behavior without exposing a
  ## platform event detail to the shared workspace model.
  case side
  of dockLeft: state.leftDock.size = DefaultLeftDockWidth
  of dockBottom: state.bottomDock.size = DefaultBottomDockHeight
  of dockRight: state.rightDock.size = DefaultLeftDockWidth

proc resizeDock*(state: var WorkspaceUiState, side: DockSide, requested: float32,
                 available: float32) =
  case side
  of dockLeft, dockBottom, dockRight:
    let current = state.dock(side)
    let centerMinimum = if side in {dockLeft, dockRight}:
      MinimumCenterWidth else: MinimumCenterHeight
    let upperBound = max(current.minimumSize, available - centerMinimum)
    let size = min(upperBound, max(current.minimumSize, requested))
    case side
    of dockLeft: state.leftDock.size = size
    of dockBottom: state.bottomDock.size = size
    of dockRight: state.rightDock.size = size

proc layout*(state: WorkspaceUiState, viewport: Size): WorkspaceLayout =
  let width = max(0'f32, float32(viewport.width))
  let height = max(0'f32, float32(viewport.height))
  let statusHeight = min(DefaultStatusHeight, height)
  let usableHeight = max(0'f32, height - statusHeight)
  let leftWidth = if state.leftDock.isOpen:
      min(max(0'f32, width - MinimumCenterWidth), state.leftDock.size) else: 0'f32
  let rightWidth = if state.rightDock.isOpen:
      min(max(0'f32, width - leftWidth - MinimumCenterWidth), state.rightDock.size) else: 0'f32
  let bottomHeight = if state.bottomDock.isOpen:
      min(max(0'f32, usableHeight - MinimumCenterHeight), state.bottomDock.size) else: 0'f32
  result.leftDock = Rect(origin: Point(x: px(0), y: px(0)),
    size: Size(width: px(leftWidth), height: px(max(0'f32, usableHeight - bottomHeight))))
  result.center = Rect(origin: Point(x: px(leftWidth), y: px(0)),
    size: Size(width: px(max(0'f32, width - leftWidth - rightWidth)),
      height: px(max(0'f32, usableHeight - bottomHeight))))
  result.bottomDock = Rect(origin: Point(x: px(leftWidth),
      y: px(max(0'f32, usableHeight - bottomHeight))),
    size: Size(width: px(max(0'f32, width - leftWidth - rightWidth)), height: px(bottomHeight)))
  result.rightDock = Rect(origin: Point(x: px(max(0'f32, width - rightWidth)), y: px(0)),
    size: Size(width: px(rightWidth), height: px(max(0'f32, usableHeight - bottomHeight))))
  result.status = Rect(origin: Point(x: px(0), y: px(usableHeight)),
    size: Size(width: px(width), height: px(statusHeight)))

proc regionAt*(layout: WorkspaceLayout, point: Point): WorkspaceRegion =
  if layout.status.contains(point): regionStatus
  elif float32(layout.leftDock.size.width) > 0 and layout.leftDock.contains(point): regionLeftDock
  elif float32(layout.bottomDock.size.height) > 0 and layout.bottomDock.contains(
      point): regionBottomDock
  elif float32(layout.rightDock.size.width) > 0 and layout.rightDock.contains(
      point): regionRightDock
  elif layout.center.contains(point): regionCenter
  else: regionNone

proc presentedRegionAt*(layout: WorkspaceLayout, viewport: Size, point: Point,
                        presentedDockWidth: float32): WorkspaceRegion =
  ## Hit-testing follows the actual three-dock geometry. The right presenter
  ## may retire below its native minimum, so use its presented width here.
  if layout.status.contains(point): return regionStatus
  let width = max(0'f32, float32(viewport.width))
  let leftWidth = max(0'f32, float32(layout.leftDock.size.width))
  let rightWidth = max(0'f32, min(width - leftWidth, presentedDockWidth))
  let dockHeight = max(0'f32, float32(layout.rightDock.size.height))
  let contentX = leftWidth
  let contentWidth = max(0'f32, width - leftWidth - rightWidth)
  let bottomHeight = max(0'f32, float32(layout.bottomDock.size.height))
  if bottomHeight > 0'f32:
    let bottom = Rect(origin: Point(x: px(contentX), y: layout.bottomDock.origin.y),
      size: Size(width: px(contentWidth), height: layout.bottomDock.size.height))
    if bottom.contains(point): return regionBottomDock
  if leftWidth > 0'f32 and layout.leftDock.contains(point): return regionLeftDock
  if rightWidth > 0'f32:
    let dock = Rect(origin: Point(x: px(width - rightWidth), y: layout.rightDock.origin.y),
      size: Size(width: px(rightWidth), height: px(dockHeight)))
    if dock.contains(point): return regionRightDock
  let center = Rect(origin: Point(x: px(contentX), y: layout.center.origin.y),
    size: Size(width: px(contentWidth), height: layout.center.size.height))
  if center.contains(point): regionCenter else: regionNone

proc firstPane*(tree: PaneTree): PaneState =
  if tree.isNil: return
  if tree.kind == paneLeaf: tree.pane else: tree.first.firstPane()

proc minimumPaneExtent(tree: PaneTree, axis: PaneAxis): float32 =
  ## The minimum space this subtree needs along `axis`. A split on that axis
  ## adds its children; an orthogonal split overlays their requirement.
  if tree.isNil: return 0'f32
  if tree.kind == paneLeaf:
    return if axis == paneVertical: MinimumPaneWidth else: MinimumPaneHeight
  let first = minimumPaneExtent(tree.first, axis)
  let second = minimumPaneExtent(tree.second, axis)
  if tree.axis == axis:
    first + PaneDividerThickness + second
  else:
    max(first, second)

proc clampedRootSplitRatio*(state: WorkspaceUiState, bounds: Rect,
                            requested: float32): float32 =
  ## Convert a drag ratio into the persistent ratio only after applying the
  ## same Zed-compatible pane floor used by layout. This prevents a divider
  ## from visually stopping at a minimum while session state records a value
  ## that would unexpectedly expand/collapse after the window is resized.
  result = normalizedRatio(requested)
  if state.center.isNil or state.center.kind != paneSplit: return
  let axis = state.center.axis
  let available = max(0'f32, (if axis == paneVertical:
    float32(bounds.size.width) else: float32(bounds.size.height)) - PaneDividerThickness)
  if available <= 0'f32: return
  let firstMinimum = minimumPaneExtent(state.center.first, axis)
  let secondMinimum = minimumPaneExtent(state.center.second, axis)
  if available < firstMinimum + secondMinimum: return
  let first = min(available - secondMinimum,
    max(firstMinimum, available * result))
  result = normalizedRatio(first / available)

proc paneLayout*(tree: PaneTree, bounds: Rect): PaneLayout =
  ## Mirrors Zed's PaneGroup traversal: a single tree owns both the leaf
  ## rectangles and the split handles used for painting and hit testing.
  var computed: PaneLayout
  proc append(tree: PaneTree, rect: Rect, layout: var PaneLayout) =
    if tree.isNil: return
    if tree.kind == paneLeaf:
      layout.panes.add(PaneLayoutEntry(id: tree.pane.id, bounds: rect))
      return
    let sideBySide = tree.axis == paneVertical
    let available = max(0'f32, (if sideBySide: float32(rect.size.width)
      else: float32(rect.size.height)) - PaneDividerThickness)
    let preferredFirst = available * normalizedRatio(tree.ratio)
    let firstMinimum = minimumPaneExtent(tree.first, tree.axis)
    let secondMinimum = minimumPaneExtent(tree.second, tree.axis)
    # When the available extent can honor both panes, clamp the divider to
    # Zed's per-pane floor. If the window itself is already smaller than that
    # aggregate floor, preserve the requested ratio rather than producing a
    # negative sibling rectangle.
    let firstLength = if available >= firstMinimum + secondMinimum:
        min(available - secondMinimum, max(firstMinimum, preferredFirst))
      else:
        preferredFirst
    if sideBySide:
      let firstRect = Rect(origin: rect.origin,
        size: Size(width: px(firstLength), height: rect.size.height))
      let divider = Rect(origin: Point(x: px(float32(rect.origin.x) + firstLength),
        y: rect.origin.y), size: Size(width: px(PaneDividerThickness), height: rect.size.height))
      let secondRect = Rect(origin: Point(x: px(float32(divider.origin.x) + PaneDividerThickness),
        y: rect.origin.y), size: Size(width: px(max(0'f32, available - firstLength)),
            height: rect.size.height))
      append(tree.first, firstRect, layout)
      layout.dividers.add(PaneDivider(axis: tree.axis, bounds: divider))
      append(tree.second, secondRect, layout)
    else:
      let firstRect = Rect(origin: rect.origin,
        size: Size(width: rect.size.width, height: px(firstLength)))
      let divider = Rect(origin: Point(x: rect.origin.x,
        y: px(float32(rect.origin.y) + firstLength)),
        size: Size(width: rect.size.width, height: px(PaneDividerThickness)))
      let secondRect = Rect(origin: Point(x: rect.origin.x,
        y: px(float32(divider.origin.y) + PaneDividerThickness)),
        size: Size(width: rect.size.width, height: px(max(0'f32, available - firstLength))))
      append(tree.first, firstRect, layout)
      layout.dividers.add(PaneDivider(axis: tree.axis, bounds: divider))
      append(tree.second, secondRect, layout)
  append(tree, bounds, computed)
  result = computed

proc paneAt*(state: WorkspaceUiState, bounds: Rect, point: Point): PaneId =
  for pane in state.center.paneLayout(bounds).panes:
    if pane.bounds.contains(point): return pane.id

proc paneIndexAt*(state: WorkspaceUiState, bounds: Rect, point: Point): int =
  for index, pane in state.center.paneLayout(bounds).panes:
    if pane.bounds.contains(point): return index
  -1

proc focusPane*(state: var WorkspaceUiState, pane: PaneId): bool =
  proc contains(tree: PaneTree): bool =
    if tree.isNil: return false
    if tree.kind == paneLeaf: return tree.pane.id == pane
    contains(tree.first) or contains(tree.second)
  if not contains(state.center): return false
  state.focusedPane = pane
  state.focusedRegion = regionCenter
  true

proc syncRootTabs*(state: var WorkspaceUiState, tabCount, activeTab: int) =
  ## EditorSession remains the document store during the migration, while each
  ## Pane owns which of those items it presents. Refresh availability without
  ## overwriting a secondary pane's independent tab choice.
  if state.center.isNil: state = initWorkspaceUi(tabCount, activeTab)
  var indices: seq[int]
  for index in 0 ..< tabCount: indices.add(index)
  proc sync(tree: PaneTree) =
    if tree.isNil: return
    if tree.kind == paneLeaf:
      tree.pane.tabIndices = indices
      if tree.pane.activeTabIndex notin indices:
        tree.pane.activeTabIndex = activeTab
    else:
      sync(tree.first)
      sync(tree.second)
  sync(state.center)

proc selectTab*(state: var WorkspaceUiState, tabIndex: int) =
  ## Selection is pane state, even while EditorSession is the transitional
  ## document owner. Applying it to each currently mirrored pane keeps the
  ## split arrangement visually consistent until panes own independent item
  ## sets.
  proc select(tree: PaneTree) =
    if tree.isNil: return
    if tree.kind == paneLeaf:
      tree.pane.activeTabIndex = if tabIndex in tree.pane.tabIndices: tabIndex else: -1
    else:
      select(tree.first)
      select(tree.second)
  select(state.center)

proc paneTabIndex*(state: WorkspaceUiState, pane: PaneId): int =
  proc find(tree: PaneTree): int =
    if tree.isNil: return -1
    if tree.kind == paneLeaf:
      return if tree.pane.id == pane: tree.pane.activeTabIndex else: -1
    let first = find(tree.first)
    if first >= 0: first else: find(tree.second)
  find(state.center)

proc selectPaneTab*(state: var WorkspaceUiState, pane: PaneId, tabIndex: int): bool =
  ## A tab activation is scoped to the pane that received the command. This is
  ## the essential difference between a real PaneGroup and a duplicated view.
  proc select(tree: PaneTree): bool =
    if tree.isNil: return false
    if tree.kind == paneLeaf:
      if tree.pane.id != pane or tabIndex notin tree.pane.tabIndices: return false
      tree.pane.activeTabIndex = tabIndex
      return true
    select(tree.first) or select(tree.second)
  result = select(state.center)
  if result:
    state.focusedPane = pane
    state.focusedRegion = regionCenter

proc cyclePaneTab*(state: var WorkspaceUiState, pane: PaneId, delta: int): int =
  ## Cycle the item selection of one Pane without changing a sibling Pane.
  ## Zed routes tab navigation through the focused Pane; using the global
  ## EditorSession active tab here would make Cmd+Shift+[ in the secondary
  ## editor unexpectedly replace the primary document.
  if delta == 0: return -1
  proc cycle(tree: PaneTree): int =
    if tree.isNil: return -1
    if tree.kind == paneLeaf:
      if tree.pane.id != pane or tree.pane.tabIndices.len == 0: return -1
      let current = tree.pane.tabIndices.find(tree.pane.activeTabIndex)
      let base = if current < 0: 0 else: current
      let count = tree.pane.tabIndices.len
      let step = if delta < 0: -1 else: 1
      let next = (base + step + count) mod count
      tree.pane.activeTabIndex = tree.pane.tabIndices[next]
      return tree.pane.activeTabIndex
    let first = cycle(tree.first)
    if first >= 0: first else: cycle(tree.second)
  result = cycle(state.center)
  if result >= 0:
    state.focusedPane = pane
    state.focusedRegion = regionCenter

proc removeTab*(state: var WorkspaceUiState, tabIndex: int) =
  ## Keep every mirrored Pane's item indices aligned with EditorSession after
  ## one shared document is closed. Each Pane retains its own selection where
  ## possible, choosing the next item only when it owned the closed tab.
  proc remove(tree: PaneTree) =
    if tree.isNil: return
    if tree.kind == paneLeaf:
      if tabIndex notin tree.pane.tabIndices: return
      tree.pane.tabIndices.delete(tree.pane.tabIndices.find(tabIndex))
      for index in 0 ..< tree.pane.tabIndices.len:
        if tree.pane.tabIndices[index] > tabIndex: dec tree.pane.tabIndices[index]
      if tree.pane.activeTabIndex > tabIndex: dec tree.pane.activeTabIndex
      elif tree.pane.activeTabIndex == tabIndex:
        tree.pane.activeTabIndex = if tree.pane.tabIndices.len == 0: -1
          else: min(tabIndex, tree.pane.tabIndices.high)
    else:
      remove(tree.first)
      remove(tree.second)
  remove(state.center)

proc splitFocusedPane*(state: var WorkspaceUiState, axis: PaneAxis,
                       ratio = 0.5'f32): bool =
  ## The first vertical slice splits the root pane.  Recursive pane operations
  ## follow once tab ownership moves from EditorSession to PaneState.
  if state.center.isNil or state.center.kind != paneLeaf: return false
  let source = state.center.pane
  let newId = state.nextPaneId
  inc state.nextPaneId
  state.center = PaneTree(kind: paneSplit, axis: axis, ratio: normalizedRatio(ratio),
    first: PaneTree(kind: paneLeaf, pane: source),
    second: newPane(newId, source.tabIndices, source.activeTabIndex))
  state.focusedRegion = regionCenter
  state.focusedPane = source.id
  true

proc setRootSplitRatio*(state: var WorkspaceUiState, ratio: float32): bool =
  ## The current editor bridge supports one split pair. Keep its divider
  ## ownership in the PaneTree now, so recursive pane layout can replace the
  ## bridge without another state migration.
  if state.center.isNil or state.center.kind != paneSplit: return false
  state.center.ratio = normalizedRatio(ratio)
  true

proc closeRootSplit*(state: var WorkspaceUiState): bool =
  if state.center.isNil or state.center.kind != paneSplit: return false
  state.center = state.center.first
  state.focusedRegion = regionCenter
  state.focusedPane = state.center.pane.id
  true

proc validate*(state: WorkspaceUiState): bool =
  if state.leftDock.minimumSize <= 0 or state.bottomDock.minimumSize <= 0 or
      state.rightDock.minimumSize <= 0: return false
  if not state.panelBelongsTo(state.leftDock.activePanel, dockLeft): return false
  if not state.panelBelongsTo(state.bottomDock.activePanel, dockBottom): return false
  if not state.panelBelongsTo(state.rightDock.activePanel, dockRight): return false
  if state.center.isNil: return false
  true
