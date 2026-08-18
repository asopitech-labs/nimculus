## Application-owned workspace UI state.
##
## This deliberately models interaction and geometry independently of Cocoa and
## Metal.  AppKit remains the platform bridge; the editor owns its docks, panes
## and focus in one place, as Zed's Workspace does.

import nimnui/geometry
import std/json
import std/os
import std/sequtils
import nimculus/editor_app
import nimculus/editor_view
import nimculus/settings

type
  WorkspaceRegion* = enum
    regionNone, regionLeftDock, regionCenter, regionBottomDock, regionRightDock,
    regionStatus

  PanelKind* = enum
    ## Persistence uses PanelPersistentName below; enum order is not persisted.
    panelFiles, panelGit, panelOutline, panelTerminal, panelTasks, panelSearch,
    panelDebugger, panelAgent

  DockSide* = enum
    dockLeft, dockBottom, dockRight

  PanelDescriptor* = object
    settingKey*: string
    persistentKey*: string
    defaultSide*: DockSide
    validSides*: set[DockSide]
    defaultSize*: float32
    minSize*: float32
    iconName*: string
    startsOpen*: bool
    activationPriority*: int

  DockAxis* = enum
    dockHorizontal, dockVertical

  PaneAxis* = enum
    paneHorizontal, paneVertical

  PaneId* = distinct int

  PaneState* = object
    ## A Pane owns its item list. `tabIndices` are stable within the current
    ## workspace tree and are kept as a compact compatibility identity for
    ## native callers; the item payload itself lives here, beside its view
    ## state, activation history, and preview slot.
    id*: PaneId
    tabs*: seq[EditorTab]
    tabIndices*: seq[int]
    activeTabIndex*: int
    pinnedCount*: int
    activationHistory*: seq[tuple[tab: int, stamp: int]]
    previewTab*: int

  PaneTreeKind* = enum
    paneLeaf, paneSplit

  PaneTree* = ref object
    case kind*: PaneTreeKind
    of paneLeaf:
      pane*: PaneState
    of paneSplit:
      axis*: PaneAxis
      children*: seq[PaneTree]
      flexes*: seq[float32]
      ## These fields keep the transitional native editor bridge source
      ## compatible while callers migrate to `children` and `flexes`.
      ratio*: float32
      first*, second*: PaneTree

  DockState* = object
    side*: DockSide
    isOpen*: bool
    zoom*: bool
    activePanel*: PanelKind
    minimumSize*: float32
    entries*: seq[PanelKind]

  DockView* = object
    ## A read-only snapshot of a dock, including the active panel's size.
    ## Width is stored per panel in WorkspaceUiState, not on the dock.
    side*: DockSide
    isOpen*: bool
    zoom*: bool
    activePanel*: PanelKind
    size*: float32
    minimumSize*: float32
    entries*: seq[PanelKind]

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
    panelSizes*: array[PanelKind, float32]
    panelLists*: array[PanelKind, PanelListState]
    center*: PaneTree
    focusedRegion*: WorkspaceRegion
    focusedPane*: PaneId
    resizingDock*: DockSide
    isResizingDock*: bool
    nextPaneId*: int
    agentDisabled: bool

proc `==`*(a, b: PaneId): bool {.borrow.}

const
  PanelInfo*: array[PanelKind, PanelDescriptor] = [
    PanelDescriptor(settingKey: "projectPanel.dock", persistentKey: "projectPanel.dock",
      defaultSide: dockRight, validSides: {dockLeft, dockRight},
      defaultSize: 240'f32, minSize: 160'f32, iconName: "file-tree",
      startsOpen: true, activationPriority: 10),
    PanelDescriptor(settingKey: "gitPanel.dock", persistentKey: "gitPanel.dock",
      defaultSide: dockRight, validSides: {dockLeft, dockRight},
      defaultSize: 240'f32, minSize: 160'f32, iconName: "git-branch",
      startsOpen: false, activationPriority: 0),
    PanelDescriptor(settingKey: "outlinePanel.dock", persistentKey: "outlinePanel.dock",
      defaultSide: dockRight, validSides: {dockLeft, dockRight},
      defaultSize: 240'f32, minSize: 160'f32, iconName: "list-tree",
      startsOpen: false, activationPriority: 0),
    PanelDescriptor(settingKey: "terminal.dock", persistentKey: "terminal.dock",
      defaultSide: dockBottom, validSides: {dockLeft, dockBottom, dockRight},
      defaultSize: 260'f32, minSize: 160'f32, iconName: "terminal",
      startsOpen: false, activationPriority: 10),
    PanelDescriptor(settingKey: "", persistentKey: "tasks.dock",
      defaultSide: dockBottom, validSides: {dockBottom},
      defaultSize: 260'f32, minSize: 160'f32, iconName: "checklist",
      startsOpen: false, activationPriority: 0),
    PanelDescriptor(settingKey: "", persistentKey: "search.dock",
      defaultSide: dockLeft, validSides: {dockLeft},
      defaultSize: 240'f32, minSize: 160'f32, iconName: "magnifying-glass",
      startsOpen: false, activationPriority: 0),
    PanelDescriptor(settingKey: "debugger.dock", persistentKey: "debugger.dock",
      defaultSide: dockBottom, validSides: {dockLeft, dockBottom, dockRight},
      defaultSize: 260'f32, minSize: 160'f32, iconName: "bug",
      startsOpen: false, activationPriority: 0),
    PanelDescriptor(settingKey: "agent.dock", persistentKey: "agent.dock",
      defaultSide: dockLeft, validSides: {dockLeft, dockRight},
      defaultSize: 240'f32, minSize: 160'f32, iconName: "sparkles",
      startsOpen: false, activationPriority: 10)]
  PanelPersistentName*: array[PanelKind, string] = [
    "Project Panel", "Git Panel", "Outline Panel", "TerminalPanel",
    "Tasks Panel", "Search Panel", "Debugger Panel", "Agent Panel"]
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

const
  NimculusPanelKindTerminal* = ord(panelTerminal)
  NimculusPanelKindAgent* = ord(panelAgent)

proc nimculus_panel_kind_terminal*(): cint {.exportc, dynlib, cdecl.} =
  cint(NimculusPanelKindTerminal)

proc nimculus_panel_kind_agent*(): cint {.exportc, dynlib, cdecl.} =
  cint(NimculusPanelKindAgent)

proc panelPersistentKey*(panel: PanelKind): string =
  ## Stable identifiers are independent of PanelKind declaration order.
  PanelInfo[panel].persistentKey

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
    activeTabIndex: activeTabIndex, pinnedCount: 0, previewTab: -1))

proc splitFlexes(ratio: float32): seq[float32] =
  let normalized = normalizedRatio(ratio)
  let first = 2'f32 * normalized
  @[first, 2'f32 - first]

proc newPaneSplit(axis: PaneAxis, children: seq[PaneTree],
                 flexes: seq[float32]): PaneTree =
  result = PaneTree(kind: paneSplit, axis: axis, children: children,
    flexes: flexes)
  if children.len > 0:
    result.first = children[0]
  if children.len > 1:
    result.second = children[1]
  if flexes.len >= 2:
    result.ratio = flexes[0] / (flexes[0] + flexes[1])

proc paneJsonInt(node: JsonNode, key: string, fallback: int): int =
  if node == nil or node.kind != JObject or not node.hasKey(key): return fallback
  try:
    node[key].getInt(fallback)
  except CatchableError:
    fallback

proc paneAxisName(axis: PaneAxis): string =
  if axis == paneVertical: "vertical" else: "horizontal"

proc paneAxisFromJson(value: string, fallback: PaneAxis): PaneAxis =
  case value
  of "vertical", "paneVertical": paneVertical
  of "horizontal", "paneHorizontal": paneHorizontal
  else: fallback

proc paneJsonKind(node: JsonNode, variant: string): JsonNode =
  if node != nil and node.kind == JObject and node.hasKey(variant):
    node[variant]
  else:
    node

proc toJson*(t: PaneTree): JsonNode =
  ## Persist the same recursive distinction as Zed's SerializedPaneGroup:
  ## groups carry axis/flexes and panes carry their item list and pin prefix.
  if t.isNil: return newJNull()
  if t.kind == paneLeaf:
    var items = newJArray()
    for slot, tabIndex in t.pane.tabIndices:
      items.add(%*{"kind": "tab", "item_id": tabIndex,
        "active": tabIndex == t.pane.activeTabIndex,
        "preview": slot == t.pane.previewTab})
    return %*{"kind": "pane", "active": t.pane.activeTabIndex,
      "children": items, "pinnedCount": max(0, t.pane.pinnedCount),
      "previewTab": t.pane.previewTab}
  var children = newJArray()
  for child in t.children:
    children.add(toJson(child))
  var flexes = newJArray()
  for flex in t.flexes:
    flexes.add(%*flex)
  %*{"kind": "group", "axis": paneAxisName(t.axis),
      "flexes": flexes, "children": children}

proc fromJsonImpl(node: JsonNode, nextPaneId: var int): PaneTree =
  ## Be liberal when reading: the explicit kind form is Nimculus's current
  ## shape, while Group/Pane also accepts the externally-tagged Rust form.
  if node == nil or node.kind != JObject: return nil
  let group = paneJsonKind(node, "Group")
  let pane = paneJsonKind(node, "Pane")
  let kind =
    if node.hasKey("Group"):
      "group"
    elif node.hasKey("Pane"):
      "pane"
    elif node.hasKey("kind") and node["kind"].kind == JString:
      node["kind"].getStr
    else:
      ""
  if kind == "group":
    if group == nil or group.kind != JObject: return nil
    let axisValue = if group.hasKey("axis") and group["axis"].kind == JString:
      group["axis"].getStr else: "horizontal"
    var children: seq[PaneTree]
    if group.hasKey("children") and group["children"].kind == JArray:
      for child in group["children"]:
        let restored = fromJsonImpl(child, nextPaneId)
        if not restored.isNil: children.add(restored)
    if children.len == 0: return nil
    var flexes: seq[float32]
    if group.hasKey("flexes") and group["flexes"].kind == JArray:
      for flex in group["flexes"]:
        try: flexes.add(float32(flex.getFloat))
        except CatchableError: flexes.add(1'f32)
    if flexes.len != children.len:
      flexes = newSeq[float32](children.len)
      for index in 0 ..< flexes.len: flexes[index] = 1'f32
    return newPaneSplit(paneAxisFromJson(axisValue, paneHorizontal), children, flexes)
  if kind != "pane": return nil
  let payload = if node.hasKey("Pane"): pane else: node
  if payload == nil or payload.kind != JObject: return nil
  var indices: seq[int]
  var active = paneJsonInt(payload, "active", -1)
  var preview = paneJsonInt(payload, "previewTab",
    paneJsonInt(payload, "preview_tab", -1))
  if payload.hasKey("children") and payload["children"].kind == JArray:
    for item in payload["children"]:
      if item.kind != JObject: continue
      let itemId = paneJsonInt(item, "item_id", paneJsonInt(item, "itemId", -1))
      if itemId < 0: continue
      indices.add(itemId)
      if item.hasKey("active") and item["active"].kind == JBool and
          item["active"].getBool:
        active = itemId
      if item.hasKey("preview") and item["preview"].kind == JBool and
          item["preview"].getBool:
        preview = indices.high
  let pinned = max(0, paneJsonInt(payload, "pinnedCount",
    paneJsonInt(payload, "pinned_count", 0)))
  result = newPane(nextPaneId, indices, active)
  inc nextPaneId
  for _ in indices:
    result.pane.tabs.add(EditorTab(document: newDocument(), title: "Untitled",
      view: newEditorView(), secondaryView: newEditorView()))
  result.pane.pinnedCount = min(pinned, indices.len)
  result.pane.previewTab = if preview >= 0 and preview < indices.len: preview else: -1

proc fromJson*(node: JsonNode): PaneTree =
  var nextPaneId = 1
  fromJsonImpl(node, nextPaneId)

proc defaultPanelDockSide(panel: PanelKind): DockSide =
  PanelInfo[panel].defaultSide

proc axis*(side: DockSide): DockAxis =
  case side
  of dockLeft, dockRight: dockHorizontal
  of dockBottom: dockVertical

proc defaultPanelForDock*(side: DockSide): PanelKind =
  ## Pick the dock's default active panel from the descriptor table. Higher
  ## activation priority wins; declaration order remains the tie-breaker.
  var bestPriority = low(int)
  for panel in PanelKind:
    let descriptor = PanelInfo[panel]
    if descriptor.defaultSide == side and descriptor.activationPriority > bestPriority:
      result = panel
      bestPriority = descriptor.activationPriority

proc panelMinimumSize(panel: PanelKind): float32 =
  PanelInfo[panel].minSize

proc dockRegion(side: DockSide): WorkspaceRegion =
  case side
  of dockLeft: regionLeftDock
  of dockBottom: regionBottomDock
  of dockRight: regionRightDock

proc panelDockSide*(panel: PanelKind, settings: SettingsStore): DockSide
proc panelPositionIsValid*(panel: PanelKind, side: DockSide): bool
proc panelDockSide*(state: WorkspaceUiState, panel: PanelKind): DockSide
proc dock*(state: WorkspaceUiState, side: DockSide): DockView
proc openPanel*(state: var WorkspaceUiState, panel: PanelKind)
proc panelStartsOpen*(panel: PanelKind, settings: SettingsStore,
                      hasFolderWorktree: bool): bool

proc initWorkspaceUi*(tabCount = 0, activeTab = -1,
                      settings: SettingsStore = nil,
                      hasFolderWorktree = false): WorkspaceUiState =
  result.agentDisabled = settings != nil and settings.agentDisabled()
  var tabs: seq[int]
  for index in 0 ..< tabCount: tabs.add(index)
  for panel in PanelKind:
    if result.agentDisabled and panel == panelAgent: continue
    result.panelDockSides[panel] = if settings == nil:
      defaultPanelDockSide(panel) else: panelDockSide(panel, settings)
    result.panelSizes[panel] = PanelInfo[panel].defaultSize
    case result.panelDockSides[panel]
    of dockLeft: result.leftDock.entries.add(panel)
    of dockBottom: result.bottomDock.entries.add(panel)
    of dockRight: result.rightDock.entries.add(panel)
  result.leftDock = DockState(side: dockLeft, isOpen: false, zoom: false,
    activePanel: if result.agentDisabled: panelSearch else: panelAgent,
    minimumSize: panelMinimumSize(if result.agentDisabled: panelSearch else: panelAgent),
    entries: result.leftDock.entries)
  result.bottomDock = DockState(side: dockBottom, isOpen: false, zoom: false,
    activePanel: panelTerminal, minimumSize: panelMinimumSize(panelTerminal),
    entries: result.bottomDock.entries)
  result.rightDock = DockState(side: dockRight, isOpen: false, zoom: false,
    activePanel: panelFiles,
    minimumSize: panelMinimumSize(panelFiles), entries: result.rightDock.entries)
  result.center = newPane(1, tabs, activeTab)
  ## The count-only constructor is used by UI tests and by the early native
  ## bootstrap, before a session has supplied real documents. Keep a matching
  ## item payload so PaneState is complete even in that compatibility path.
  for index in 0 ..< tabCount:
    let document = newDocument()
    result.center.pane.tabs.add(EditorTab(document: document,
      title: "Untitled", view: newEditorView(), secondaryView: newEditorView()))
  for panel in PanelKind:
    result.panelLists[panel].selectedIndex = -1
  result.focusedRegion = regionCenter
  result.focusedPane = PaneId(1)
  result.nextPaneId = 2
  if panelStartsOpen(panelFiles, settings, hasFolderWorktree):
    result.openPanel(panelFiles)

proc panelFromOrdinal(value: int, fallback: PanelKind): PanelKind =
  if value >= ord(low(PanelKind)) and value <= ord(high(PanelKind)):
    PanelKind(value) else: fallback

proc panelFromPersistentName(value: string, fallback: PanelKind): PanelKind =
  for panel in PanelKind:
    if panelPersistentKey(panel) == value or PanelPersistentName[panel] == value:
      return panel
  fallback

proc panelFromSession(name: string, ordinal: int, fallback: PanelKind): PanelKind =
  if name.len > 0:
    panelFromPersistentName(name, fallback)
  else:
    panelFromOrdinal(ordinal, fallback)

proc restoreDock(state: var WorkspaceUiState, side: DockSide, isOpen: bool,
                 size: float32, panel: PanelKind) =
  let restoredSize = max(panelMinimumSize(panel), size)
  var restoredPanel = panel
  if state.agentDisabled and panel == panelAgent:
    restoredPanel = case side
      of dockLeft: panelSearch
      of dockBottom: panelTerminal
      of dockRight: panelFiles
  case side
  of dockLeft:
    state.leftDock.isOpen = isOpen
    state.leftDock.activePanel = restoredPanel
    state.leftDock.minimumSize = panelMinimumSize(restoredPanel)
    state.panelSizes[restoredPanel] = restoredSize
  of dockBottom:
    state.bottomDock.isOpen = isOpen
    state.bottomDock.activePanel = restoredPanel
    state.bottomDock.minimumSize = panelMinimumSize(restoredPanel)
    state.panelSizes[restoredPanel] = restoredSize
  of dockRight:
    state.rightDock.isOpen = isOpen
    state.rightDock.activePanel = restoredPanel
    state.rightDock.minimumSize = panelMinimumSize(restoredPanel)
    state.panelSizes[restoredPanel] = restoredSize

proc panelStartsOpen*(panel: PanelKind, settings: SettingsStore,
                      hasFolderWorktree: bool): bool =
  PanelInfo[panel].startsOpen and hasFolderWorktree and
    (settings == nil or settings.projectPanelStartsOpen())

proc restoreStartsOpen(state: var WorkspaceUiState, settings: SettingsStore,
                       hasFolderWorktree: bool,
                       restoredDocks: array[DockSide, bool]) =
  if not panelStartsOpen(panelFiles, settings, hasFolderWorktree): return
  let side = state.panelDockSide(panelFiles)
  if not restoredDocks[side]: state.openPanel(panelFiles)

proc paneTreeFromSession*(session: EditorSession): PaneTree =
  ## Build a recursive compatibility tree for callers that save an
  ## EditorSession without a live WorkspaceUiState.
  var indices: seq[int]
  for index in 0 ..< session.tabs.len: indices.add(index)
  let pinned = session.pinnedTabCount()
  proc leaf(id: int, active: int): PaneTree =
    result = newPane(id, indices, active)
    result.pane.tabs = session.tabs
    result.pane.pinnedCount = pinned
  if not session.split:
    return leaf(1, session.activeTab)
  let second = session.effectiveSplitSecondaryTab()
  let axis = if session.splitDirection == splitVertical: paneVertical else: paneHorizontal
  newPaneSplit(axis, @[leaf(1, session.activeTab), leaf(2, second)],
    splitFlexes(session.effectiveSplitRatio))

proc maxPaneId(tree: PaneTree): int =
  if tree.isNil: return 0
  if tree.kind == paneLeaf: return int(tree.pane.id)
  for child in tree.children:
    result = max(result, maxPaneId(child))

proc initWorkspaceUi*(session: EditorSession, settings: SettingsStore = nil,
                      hasFolderWorktree = false): WorkspaceUiState =
  let hasFolder = hasFolderWorktree or session.workspaceRoots.len > 0
  result = initWorkspaceUi(session.tabs.len, session.activeTab, settings, hasFolder)
  result.leftDock.zoom = session.workspaceLeftDockZoom
  result.bottomDock.zoom = session.workspaceBottomDockZoom
  result.rightDock.zoom = session.workspaceRightDockZoom
  if session.workspacePaneTree != nil:
    let restoredTree = fromJson(session.workspacePaneTree)
    if not restoredTree.isNil:
      result.center = restoredTree
      result.nextPaneId = max(2, maxPaneId(restoredTree) + 1)
  var restoredDocks: array[DockSide, bool]
  # Session fields belong to physical docks, so restore each dock from its own
  # open bit, size, and active panel. A zero size means there is no persisted
  # dock state, and therefore leaves the dock closed.
  if session.workspaceLeftDockSize > 0:
    restoredDocks[dockLeft] = true
    result.restoreDock(dockLeft, session.workspaceLeftDockOpen,
      session.workspaceLeftDockSize,
      panelFromSession(session.workspaceLeftPanelName, session.workspaceLeftPanel,
        panelAgent))
  if session.workspaceBottomDockSize > 0:
    restoredDocks[dockBottom] = true
    result.restoreDock(dockBottom, session.workspaceBottomDockOpen,
      session.workspaceBottomDockSize,
      panelFromSession(session.workspaceBottomPanelName, session.workspaceBottomPanel,
        panelTerminal))
  if session.workspaceRightDockSize > 0:
    restoredDocks[dockRight] = true
    result.restoreDock(dockRight, session.workspaceRightDockOpen,
      session.workspaceRightDockSize,
      panelFromSession(session.workspaceRightPanelName, session.workspaceRightPanel,
        panelFiles))
  if session.workspacePaneTree == nil:
    result.center = paneTreeFromSession(session)
    result.nextPaneId = max(2, maxPaneId(result.center) + 1)
  else:
    ## Session JSON currently stores item identities rather than full editor
    ## payloads in the pane tree. Rebind those identities to the session's
    ## restored items without changing each pane's independent selection.
    proc rebind(tree: PaneTree) =
      if tree.isNil: return
      if tree.kind == paneLeaf:
        tree.pane.tabs.setLen(0)
        for tabIndex in tree.pane.tabIndices:
          if tabIndex >= 0 and tabIndex < session.tabs.len:
            tree.pane.tabs.add(session.tabs[tabIndex])
      else:
        for child in tree.children:
          rebind(child)
    rebind(result.center)
  result.restoreStartsOpen(settings, hasFolder, restoredDocks)

proc panelDockSide*(state: WorkspaceUiState, panel: PanelKind): DockSide =
  state.panelDockSides[panel]

proc replacementPanel(state: WorkspaceUiState, side: DockSide,
                      removed: PanelKind): PanelKind =
  let entries = case side
    of dockLeft: state.leftDock.entries
    of dockBottom: state.bottomDock.entries
    of dockRight: state.rightDock.entries
  for panel in entries:
    if panel != removed:
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
  let wasAgentDisabled = state.agentDisabled
  state.agentDisabled = settings != nil and settings.agentDisabled()
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
    if source.axis != target.axis:
      state.panelSizes[panel] = PanelInfo[panel].defaultSize

    case source
    of dockLeft:
      let index = state.leftDock.entries.find(panel)
      if index >= 0: state.leftDock.entries.delete(index)
    of dockBottom:
      let index = state.bottomDock.entries.find(panel)
      if index >= 0: state.bottomDock.entries.delete(index)
    of dockRight:
      let index = state.rightDock.entries.find(panel)
      if index >= 0: state.rightDock.entries.delete(index)
    case target
    of dockLeft: state.leftDock.entries.add(panel)
    of dockBottom: state.bottomDock.entries.add(panel)
    of dockRight: state.rightDock.entries.add(panel)

    if wasVisible:
      case target
      of dockLeft:
        state.leftDock.isOpen = true
        state.leftDock.activePanel = panel
        state.leftDock.minimumSize = panelMinimumSize(panel)
      of dockBottom:
        state.bottomDock.isOpen = true
        state.bottomDock.activePanel = panel
        state.bottomDock.minimumSize = panelMinimumSize(panel)
      of dockRight:
        state.rightDock.isOpen = true
        state.rightDock.activePanel = panel
        state.rightDock.minimumSize = panelMinimumSize(panel)
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

  if state.agentDisabled:
    for side in DockSide:
      let entries = case side
        of dockLeft: state.leftDock.entries
        of dockBottom: state.bottomDock.entries
        of dockRight: state.rightDock.entries
      let index = entries.find(panelAgent)
      if index >= 0:
        case side
        of dockLeft: state.leftDock.entries.delete(index)
        of dockBottom: state.bottomDock.entries.delete(index)
        of dockRight: state.rightDock.entries.delete(index)
      let active = case side
        of dockLeft: state.leftDock.activePanel
        of dockBottom: state.bottomDock.activePanel
        of dockRight: state.rightDock.activePanel
      if active == panelAgent:
        let replacement = state.replacementPanel(side, panelAgent)
        if replacement == panelAgent:
          case side
          of dockLeft: state.leftDock.isOpen = false
          of dockBottom: state.bottomDock.isOpen = false
          of dockRight: state.rightDock.isOpen = false
        else:
          case side
          of dockLeft: state.leftDock.activePanel = replacement
          of dockBottom: state.bottomDock.activePanel = replacement
          of dockRight: state.rightDock.activePanel = replacement
  elif wasAgentDisabled:
    let side = state.panelDockSide(panelAgent)
    let entries = case side
      of dockLeft: state.leftDock.entries
      of dockBottom: state.bottomDock.entries
      of dockRight: state.rightDock.entries
    if panelAgent notin entries:
      case side
      of dockLeft: state.leftDock.entries.add(panelAgent)
      of dockBottom: state.bottomDock.entries.add(panelAgent)
      of dockRight: state.rightDock.entries.add(panelAgent)

proc saveWorkspaceUi*(state: WorkspaceUiState, session: var EditorSession) =
  session.workspaceLeftDockOpen = state.leftDock.isOpen
  session.workspaceBottomDockOpen = state.bottomDock.isOpen
  session.workspaceRightDockOpen = state.rightDock.isOpen
  session.workspaceLeftDockSize = state.panelSizes[state.leftDock.activePanel]
  session.workspaceBottomDockSize = state.panelSizes[state.bottomDock.activePanel]
  session.workspaceRightDockSize = state.panelSizes[state.rightDock.activePanel]
  session.workspaceLeftDockZoom = state.leftDock.zoom
  session.workspaceBottomDockZoom = state.bottomDock.zoom
  session.workspaceRightDockZoom = state.rightDock.zoom
  ## Keep the integer fields usable for older in-process callers, but never
  ## use them as the persisted identity.
  let leftPanel = state.leftDock.activePanel
  let bottomPanel = state.bottomDock.activePanel
  let rightPanel = state.rightDock.activePanel
  session.workspaceLeftPanel = ord(leftPanel)
  session.workspaceBottomPanel = ord(bottomPanel)
  session.workspaceRightPanel = ord(rightPanel)
  session.workspaceLeftPanelName = panelPersistentKey(leftPanel)
  session.workspaceBottomPanelName = panelPersistentKey(bottomPanel)
  session.workspaceRightPanelName = panelPersistentKey(rightPanel)
  session.workspacePaneTree = state.center.toJson()
  session.workspaceActivePane = if state.center != nil and
      state.center.kind == paneSplit and state.center.children.len > 1 and
      state.center.children[1].kind == paneLeaf and
      state.center.children[1].pane.id == state.focusedPane: 1 else: 0

proc dock*(state: WorkspaceUiState, side: DockSide): DockView =
  case side
  of dockLeft:
    DockView(side: state.leftDock.side, isOpen: state.leftDock.isOpen,
      zoom: state.leftDock.zoom,
      activePanel: state.leftDock.activePanel,
      size: state.panelSizes[state.leftDock.activePanel],
      minimumSize: state.leftDock.minimumSize, entries: state.leftDock.entries)
  of dockBottom:
    DockView(side: state.bottomDock.side, isOpen: state.bottomDock.isOpen,
      zoom: state.bottomDock.zoom,
      activePanel: state.bottomDock.activePanel,
      size: state.panelSizes[state.bottomDock.activePanel],
      minimumSize: state.bottomDock.minimumSize, entries: state.bottomDock.entries)
  of dockRight:
    DockView(side: state.rightDock.side, isOpen: state.rightDock.isOpen,
      zoom: state.rightDock.zoom,
      activePanel: state.rightDock.activePanel,
      size: state.panelSizes[state.rightDock.activePanel],
      minimumSize: state.rightDock.minimumSize, entries: state.rightDock.entries)

proc panelIsActive*(state: WorkspaceUiState, panel: PanelKind): bool =
  if panel == panelAgent and state.agentDisabled: return false
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
  PanelInfo[panel].settingKey

proc dockSideFromSetting(value: string, fallback: DockSide): DockSide =
  case value
  of "left": dockLeft
  of "bottom": dockBottom
  of "right": dockRight
  else: fallback

proc panelDockSide*(panel: PanelKind, settings: SettingsStore): DockSide =
  ## Read the panel's configured position without applying it to workspace
  ## ownership yet. Applying this result is the follow-up ownership migration.
  let descriptor = PanelInfo[panel]
  let configured = if settings == nil or descriptor.settingKey.len == 0:
    descriptor.defaultSide
  else:
    dockSideFromSetting(settings.stringSetting(descriptor.settingKey),
      descriptor.defaultSide)
  if panelPositionIsValid(panel, configured): configured else: descriptor.defaultSide

proc panelPositionIsValid*(panel: PanelKind, side: DockSide): bool =
  ## Match Zed's panel-specific position predicates. Tasks and Search have no
  ## corresponding Zed panel and retain their current side until they receive
  ## panel-scoped settings.
  side in PanelInfo[panel].validSides

proc panelDockSideMask*(state: WorkspaceUiState): uint32 =
  ## AppKit receives two bits per panel: 1 = left, 2 = bottom, 3 = right.
  ## AppKit uses the complete mapping to put left panels in its left cluster;
  ## bottom and right panels intentionally share the right cluster.
  for panel in PanelKind:
    let panelSide = state.panelDockSide(panel)
    let sideCode = uint32(ord(panelSide)) + 1'u32
    result = result or (sideCode shl uint32(ord(panel) * 2))

proc openPanel*(state: var WorkspaceUiState, panel: PanelKind) =
  if panel == panelAgent and state.agentDisabled: return
  let side = state.panelDockSide(panel)
  case side
  of dockLeft:
    state.leftDock.activePanel = panel
    state.leftDock.minimumSize = panelMinimumSize(panel)
    state.leftDock.isOpen = true
  of dockBottom:
    state.bottomDock.activePanel = panel
    state.bottomDock.minimumSize = panelMinimumSize(panel)
    state.bottomDock.isOpen = true
  of dockRight:
    state.rightDock.activePanel = panel
    state.rightDock.minimumSize = panelMinimumSize(panel)
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
  of dockLeft:
    state.panelSizes[state.leftDock.activePanel] =
      PanelInfo[state.leftDock.activePanel].defaultSize
  of dockBottom:
    state.panelSizes[state.bottomDock.activePanel] =
      PanelInfo[state.bottomDock.activePanel].defaultSize
  of dockRight:
    state.panelSizes[state.rightDock.activePanel] =
      PanelInfo[state.rightDock.activePanel].defaultSize

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
    of dockLeft: state.panelSizes[state.leftDock.activePanel] = size
    of dockBottom: state.panelSizes[state.bottomDock.activePanel] = size
    of dockRight: state.panelSizes[state.rightDock.activePanel] = size

proc layout*(state: WorkspaceUiState, viewport: Size): WorkspaceLayout =
  let width = max(0'f32, float32(viewport.width))
  let height = max(0'f32, float32(viewport.height))
  let statusHeight = min(DefaultStatusHeight, height)
  let usableHeight = max(0'f32, height - statusHeight)
  let leftWidth = if state.leftDock.isOpen:
      min(max(0'f32, width - MinimumCenterWidth), state.dock(dockLeft).size) else: 0'f32
  let rightWidth = if state.rightDock.isOpen:
      min(max(0'f32, width - leftWidth - MinimumCenterWidth), state.dock(
          dockRight).size) else: 0'f32
  let bottomHeight = if state.bottomDock.isOpen:
      min(max(0'f32, usableHeight - MinimumCenterHeight), state.dock(dockBottom).size) else: 0'f32
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
  if tree.kind == paneLeaf: tree.pane else:
    if tree.children.len == 0: PaneState() else: tree.children[0].firstPane()

proc minimumPaneExtent*(tree: PaneTree, axis: PaneAxis): float32 =
  ## The minimum space this subtree needs along `axis`. A split on that axis
  ## adds its children; an orthogonal split overlays their requirement.
  if tree.isNil: return 0'f32
  if tree.kind == paneLeaf:
    return if axis == paneVertical: MinimumPaneWidth else: MinimumPaneHeight
  if tree.children.len == 0: return 0'f32
  var extents: seq[float32]
  for child in tree.children:
    extents.add(minimumPaneExtent(child, axis))
  if tree.axis == axis:
    result = PaneDividerThickness * float32(tree.children.len - 1)
    for extent in extents:
      result += extent
  else:
    result = extents[0]
    for extent in extents[1..^1]:
      result = max(result, extent)

proc clampedRootSplitRatio*(state: WorkspaceUiState, bounds: Rect,
                            requested: float32): float32 =
  ## Convert a drag ratio into the persistent ratio only after applying the
  ## same Zed-compatible pane floor used by layout. This prevents a divider
  ## from visually stopping at a minimum while session state records a value
  ## that would unexpectedly expand/collapse after the window is resized.
  result = normalizedRatio(requested)
  if state.center.isNil or state.center.kind != paneSplit or
      state.center.children.len != 2: return
  let axis = state.center.axis
  let available = max(0'f32, (if axis == paneVertical:
    float32(bounds.size.width) else: float32(bounds.size.height)) - PaneDividerThickness)
  if available <= 0'f32: return
  let firstMinimum = minimumPaneExtent(state.center.children[0], axis)
  let secondMinimum = minimumPaneExtent(state.center.children[1], axis)
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
    if tree.children.len == 0: return
    let sideBySide = tree.axis == paneVertical
    let dividerCount = tree.children.len - 1
    let totalExtent = if sideBySide: float32(rect.size.width) else: float32(rect.size.height)
    let available = max(0'f32, totalExtent - PaneDividerThickness * float32(dividerCount))
    var weights = tree.flexes
    if weights.len != tree.children.len:
      weights.setLen(tree.children.len)
      for index in 0 ..< weights.len:
        weights[index] = 1'f32
    var totalWeight = 0'f32
    for weight in weights:
      totalWeight += max(0'f32, weight)
    if totalWeight <= 0'f32:
      totalWeight = float32(tree.children.len)
      for index in 0 ..< weights.len:
        weights[index] = 1'f32
    var minimums: seq[float32]
    for child in tree.children:
      minimums.add(minimumPaneExtent(child, tree.axis))
    var lengths = newSeq[float32](tree.children.len)
    var totalMinimum = 0'f32
    for minimum in minimums:
      totalMinimum += minimum
    let enoughRoom = available >= totalMinimum
    var remainingExtent = available
    var remainingWeight = totalWeight
    for index in 0 ..< tree.children.len:
      let preferred = if remainingWeight > 0'f32:
          remainingExtent * max(0'f32, weights[index]) / remainingWeight
        else: 0'f32
      var minimumRemaining = 0'f32
      for remaining in index + 1 ..< minimums.len:
        minimumRemaining += minimums[remaining]
      lengths[index] = if index == tree.children.high:
          remainingExtent
        elif enoughRoom:
          min(remainingExtent - minimumRemaining,
            max(minimums[index], preferred))
        else:
          preferred
      lengths[index] = max(0'f32, lengths[index])
      remainingExtent = max(0'f32, remainingExtent - lengths[index])
      remainingWeight = max(0'f32, remainingWeight - max(0'f32, weights[index]))

    var cursor = if sideBySide: float32(rect.origin.x) else: float32(rect.origin.y)
    for index, child in tree.children:
      let childRect = if sideBySide:
          Rect(origin: Point(x: px(cursor), y: rect.origin.y),
            size: Size(width: px(lengths[index]), height: rect.size.height))
        else:
          Rect(origin: Point(x: rect.origin.x, y: px(cursor)),
            size: Size(width: rect.size.width, height: px(lengths[index])))
      append(child, childRect, layout)
      cursor += lengths[index]
      if index < tree.children.high:
        let divider = if sideBySide:
            Rect(origin: Point(x: px(cursor), y: rect.origin.y),
              size: Size(width: px(PaneDividerThickness), height: rect.size.height))
          else:
            Rect(origin: Point(x: rect.origin.x, y: px(cursor)),
              size: Size(width: rect.size.width, height: px(PaneDividerThickness)))
        layout.dividers.add(PaneDivider(axis: tree.axis, bounds: divider))
        cursor += PaneDividerThickness
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
    for child in tree.children:
      if contains(child): return true
    false
  if not contains(state.center): return false
  state.focusedPane = pane
  state.focusedRegion = regionCenter
  true

proc paneNode(state: WorkspaceUiState, pane: PaneId): PaneTree =
  if state.center.isNil: return nil
  proc find(tree: PaneTree): PaneTree =
    if tree.isNil: return nil
    if tree.kind == paneLeaf:
      return if tree.pane.id == pane: tree else: nil
    for child in tree.children:
      let found = find(child)
      if not found.isNil: return found
    nil
  find(state.center)

proc nextPaneTabId(state: WorkspaceUiState): int =
  var nextId = 0
  proc scan(tree: PaneTree) =
    if tree.isNil: return
    if tree.kind == paneLeaf:
      for tabIndex in tree.pane.tabIndices:
        nextId = max(nextId, tabIndex + 1)
    else:
      for child in tree.children:
        scan(child)
  scan(state.center)
  nextId

proc editorTabTitle(document: FileDocument): string =
  if document.path.len > 0:
    let parts = splitFile(document.path)
    if parts.name.len > 0: return parts.name & parts.ext
  "Untitled"

proc refreshPaneTabIndices*(state: var WorkspaceUiState, tabCount,
                            activeTab: int) =
  ## Update only a pane that has not acquired its own item set yet. This is a
  ## bootstrap helper for the native bridge; unlike the former root sync it
  ## never replaces a live pane's list with another pane's list.
  if state.center.isNil:
    state = initWorkspaceUi(tabCount, activeTab)
    return
  proc refresh(tree: PaneTree) =
    if tree.isNil: return
    if tree.kind == paneLeaf:
      if tree.pane.tabIndices.len == 0 and tabCount > 0:
        for index in 0 ..< tabCount:
          tree.pane.tabIndices.add(index)
          tree.pane.tabs.add(EditorTab(document: newDocument(),
            title: "Untitled", view: newEditorView(), secondaryView: newEditorView()))
        tree.pane.activeTabIndex = activeTab
      tree.pane.pinnedCount = min(tree.pane.pinnedCount,
        tree.pane.tabIndices.len)
    else:
      for child in tree.children:
        refresh(child)
  refresh(state.center)

proc openDocumentInPane*(state: var WorkspaceUiState, pane: PaneId,
                         document: FileDocument, preview = true): int =
  ## Add an item to exactly one Pane. A preview occupies one reusable slot until
  ## explicitly activated, matching Zed's replace-preview behaviour.
  let target = state.paneNode(pane)
  if target.isNil: return -1
  let tab = EditorTab(document: document, title: editorTabTitle(document),
    view: newEditorView(), secondaryView: newEditorView())
  if preview and target.pane.previewTab >= 0 and
      target.pane.previewTab < target.pane.tabIndices.len:
    let slot = target.pane.previewTab
    while target.pane.tabs.len <= slot:
      target.pane.tabs.add(EditorTab(document: newDocument(), title: "Untitled",
        view: newEditorView(), secondaryView: newEditorView()))
    target.pane.tabs[slot] = tab
    target.pane.activeTabIndex = target.pane.tabIndices[slot]
    var nextStamp = 1
    for entry in target.pane.activationHistory:
      nextStamp = max(nextStamp, entry.stamp + 1)
    target.pane.activationHistory.add((target.pane.tabIndices[slot], nextStamp))
    return target.pane.tabIndices[slot]
  let tabId = state.nextPaneTabId()
  target.pane.tabIndices.add(tabId)
  target.pane.tabs.add(tab)
  target.pane.activeTabIndex = tabId
  target.pane.activationHistory.add((tabId, 1))
  target.pane.previewTab = if preview: target.pane.tabIndices.high else: -1
  if not preview:
    target.pane.previewTab = -1
  tabId

proc attachTabToPane*(state: var WorkspaceUiState, pane: PaneId,
                      tabIndex: int, tab: EditorTab): bool =
  ## Attach an already-registered item to one Pane without making the sibling
  ## panes inherit it. Native callers use the registry's identity here, while
  ## `openDocumentInPane` allocates a fresh identity for standalone panes.
  let target = state.paneNode(pane)
  if target.isNil or tabIndex < 0 or tabIndex in target.pane.tabIndices:
    return false
  target.pane.tabIndices.add(tabIndex)
  target.pane.tabs.add(tab)
  target.pane.activeTabIndex = tabIndex
  target.pane.previewTab = -1
  var nextStamp = 1
  for entry in target.pane.activationHistory:
    nextStamp = max(nextStamp, entry.stamp + 1)
  target.pane.activationHistory.add((tabIndex, nextStamp))
  true

proc selectPaneTab*(state: var WorkspaceUiState, pane: PaneId,
                    tabIndex: int): bool

proc activatePaneTab*(state: var WorkspaceUiState, pane: PaneId,
                      tabIndex: int, preview = false): bool =
  result = state.selectPaneTab(pane, tabIndex)
  if result and not preview:
    let target = state.paneNode(pane)
    if not target.isNil: target.pane.previewTab = -1

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
      for child in tree.children:
        select(child)
  select(state.center)

proc paneTabIndex*(state: WorkspaceUiState, pane: PaneId): int =
  proc find(tree: PaneTree): int =
    if tree.isNil: return -1
    if tree.kind == paneLeaf:
      return if tree.pane.id == pane: tree.pane.activeTabIndex else: -1
    for child in tree.children:
      let found = find(child)
      if found >= 0: return found
    -1
  find(state.center)

proc selectPaneTab*(state: var WorkspaceUiState, pane: PaneId, tabIndex: int): bool =
  ## A tab activation is scoped to the pane that received the command. This is
  ## the essential difference between a real PaneGroup and a duplicated view.
  proc select(tree: PaneTree): bool =
    if tree.isNil: return false
    if tree.kind == paneLeaf:
      if tree.pane.id != pane or tabIndex notin tree.pane.tabIndices: return false
      tree.pane.activeTabIndex = tabIndex
      var nextStamp = 1
      for entry in tree.pane.activationHistory:
        nextStamp = max(nextStamp, entry.stamp + 1)
      tree.pane.activationHistory.add((tabIndex, nextStamp))
      return true
    for child in tree.children:
      if select(child): return true
    false
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
    for child in tree.children:
      let found = cycle(child)
      if found >= 0: return found
    -1
  result = cycle(state.center)
  if result >= 0:
    state.focusedPane = pane
    state.focusedRegion = regionCenter

proc removeTab*(state: var WorkspaceUiState, tabIndex: int) =
  ## Remove an item from every Pane that owns it. When the active item closes,
  ## activation history chooses the most recently used surviving item before
  ## the index-successor fallback, which is the behavior Zed users expect.
  proc remove(tree: PaneTree) =
    if tree.isNil: return
    if tree.kind == paneLeaf:
      if tabIndex notin tree.pane.tabIndices: return
      let removedSlot = tree.pane.tabIndices.find(tabIndex)
      var mru = -1
      var newestStamp = -1
      for entry in tree.pane.activationHistory:
        if entry.tab != tabIndex and entry.tab in tree.pane.tabIndices and
            entry.stamp > newestStamp:
          mru = entry.tab
          newestStamp = entry.stamp
      if removedSlot < tree.pane.pinnedCount:
        dec tree.pane.pinnedCount
      tree.pane.tabIndices.delete(removedSlot)
      if removedSlot < tree.pane.tabs.len:
        tree.pane.tabs.delete(removedSlot)
      for index in 0 ..< tree.pane.tabIndices.len:
        if tree.pane.tabIndices[index] > tabIndex: dec tree.pane.tabIndices[index]
      for index in 0 ..< tree.pane.activationHistory.len:
        if tree.pane.activationHistory[index].tab > tabIndex:
          dec tree.pane.activationHistory[index].tab
      tree.pane.activationHistory = tree.pane.activationHistory.filterIt(
        it.tab != tabIndex)
      if tree.pane.previewTab == removedSlot:
        tree.pane.previewTab = -1
      elif tree.pane.previewTab > removedSlot:
        dec tree.pane.previewTab
      if tree.pane.activeTabIndex > tabIndex:
        dec tree.pane.activeTabIndex
      elif tree.pane.activeTabIndex == tabIndex:
        if mru >= 0:
          tree.pane.activeTabIndex = if mru > tabIndex: mru - 1 else: mru
        else:
          tree.pane.activeTabIndex = if tree.pane.tabIndices.len == 0: -1
            else: min(tabIndex, tree.pane.tabIndices.high)
    else:
      for child in tree.children:
        remove(child)
  remove(state.center)

proc splitPane*(state: var WorkspaceUiState, targetPane: PaneId, axis: PaneAxis,
                ratio = 0.5'f32): bool

proc splitFocusedPane*(state: var WorkspaceUiState, axis: PaneAxis,
                       ratio = 0.5'f32): bool =
  splitPane(state, state.focusedPane, axis, ratio)

proc splitPane*(state: var WorkspaceUiState, targetPane: PaneId, axis: PaneAxis,
                ratio = 0.5'f32): bool =
  ## Split a leaf in place. A split on the parent's axis inserts a sibling in
  ## that axis; an orthogonal split replaces the leaf with a nested axis.
  if state.center.isNil: return false
  let newId = state.nextPaneId
  var didSplit = false
  proc splitIn(tree: PaneTree): bool =
    if tree.isNil or tree.kind == paneLeaf: return false
    for index, child in tree.children:
      if child.isNil: continue
      if child.kind == paneLeaf and child.pane.id == targetPane:
        let source = child.pane
        let sibling = newPane(newId, source.tabIndices, source.activeTabIndex)
        sibling.pane.tabs = source.tabs
        sibling.pane.activationHistory = source.activationHistory
        sibling.pane.previewTab = source.previewTab
        sibling.pane.pinnedCount = source.pinnedCount
        if tree.axis == axis:
          tree.children.insert(sibling, index + 1)
          tree.flexes.insert(1'f32, index + 1)
          if tree.flexes.len != tree.children.len:
            tree.flexes = newSeq[float32](tree.children.len)
            for flexIndex in 0 ..< tree.flexes.len:
              tree.flexes[flexIndex] = 1'f32
          tree.ratio = if tree.flexes.len > 0:
              tree.flexes[0] / float32(tree.children.len)
            else: 0.5'f32
          tree.first = tree.children[0]
          tree.second = if tree.children.len > 1: tree.children[1] else: nil
        else:
          tree.children[index] = newPaneSplit(axis, @[child, sibling],
            splitFlexes(ratio))
        return true
      if splitIn(child): return true
    false

  if state.center.kind == paneLeaf:
    if state.center.pane.id != targetPane: return false
    let source = state.center.pane
    let sibling = newPane(newId, source.tabIndices, source.activeTabIndex)
    sibling.pane.tabs = source.tabs
    sibling.pane.activationHistory = source.activationHistory
    sibling.pane.previewTab = source.previewTab
    sibling.pane.pinnedCount = source.pinnedCount
    state.center = newPaneSplit(axis, @[state.center, sibling], splitFlexes(ratio))
    didSplit = true
  else:
    didSplit = splitIn(state.center)
  if not didSplit: return false
  inc state.nextPaneId
  state.focusedRegion = regionCenter
  state.focusedPane = targetPane
  true

proc setRootSplitRatio*(state: var WorkspaceUiState, ratio: float32): bool =
  ## The current editor bridge supports one split pair. Keep its divider
  ## ownership in the PaneTree now, so recursive pane layout can replace the
  ## bridge without another state migration.
  if state.center.isNil or state.center.kind != paneSplit or
      state.center.children.len != 2: return false
  state.center.flexes = splitFlexes(ratio)
  state.center.ratio = normalizedRatio(ratio)
  true

proc closeRootSplit*(state: var WorkspaceUiState): bool =
  if state.center.isNil or state.center.kind != paneSplit or
      state.center.children.len != 2: return false
  state.center = state.center.children[0]
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
