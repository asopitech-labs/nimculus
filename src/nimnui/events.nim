import nimnui/commands
import nimnui/geometry
import nimnui/ui_tree

type
  UiEventKind* = enum
    pointerDown, pointerUp, pointerMove, pointerEnter, pointerExit, scroll, keyDown, keyUp,
    modifiersChanged, command

  EventPhase* = enum
    capture, target, bubble

  UiEvent* = object
    phase*: EventPhase
    target*: NodeId
    handled*: bool
    case kind*: UiEventKind
    of pointerDown, pointerUp:
      position*: Point
      ## 0 = left, 1 = right, 2 = other. Pointer events without a button use 0.
      button*: uint32
      pointerShortcutModifiers*: set[Modifier]
    of pointerMove, pointerEnter, pointerExit:
      movePosition*: Point
      moveShortcutModifiers*: set[Modifier]
    of scroll:
      scrollPosition*: Point
      scrollShortcutModifiers*: set[Modifier]
      deltaX*, deltaY*: float32
    of keyDown, keyUp:
      keyCode*: uint32
      shortcutModifiers*: set[Modifier]
    of modifiersChanged:
      ## The raw flags are useful for diagnostics on this platform-state event.
      changedModifiers*: uint32
      changedShortcutModifiers*: set[Modifier]
    of command:
      command*: string

  EventHandler* = proc(event: var UiEvent) {.closure.}

proc nativeEventKind*(eventType: uint32): UiEventKind =
  ## NSEventType values used by the AppKit bridge. Keep drag and modifier
  ## events distinct; treating them as commands loses pointer selection and
  ## modifier state transitions before they reach NimNUI.
  case eventType
  of 1'u32, 3'u32, 25'u32: pointerDown
  of 2'u32, 4'u32, 26'u32: pointerUp
  of 5'u32, 6'u32, 7'u32, 27'u32: pointerMove
  of 8'u32: pointerEnter
  of 9'u32: pointerExit
  of 10'u32: keyDown
  of 11'u32: keyUp
  of 12'u32: modifiersChanged
  of 22'u32: scroll
  else: command

proc nativeEventButton*(eventType: uint32): uint32 =
  case eventType
  of 3'u32, 4'u32, 7'u32: 1'u32
  of 25'u32, 26'u32, 27'u32: 2'u32
  else: 0'u32

proc ancestorPath(tree: UiTree, target: NodeId): seq[NodeId] =
  tree.dispatchPath(target)

proc invokeNodeListeners(tree: var UiTree, id: NodeId, event: var UiEvent) =
  let index = tree.nodeIndex(id)
  if index < 0: return
  case event.kind
  of keyDown, keyUp:
    for handler in tree.nodes[index].keyListeners:
      handler(addr event)
  of modifiersChanged:
    for handler in tree.nodes[index].modifiersChangedListeners:
      handler(addr event)
  of command:
    for listener in tree.nodes[index].actionListeners:
      if listener.action == event.command:
        listener.handler(event.command)
  else: discard

proc onKeyEvent*(tree: var UiTree, id: NodeId, handler: EventHandler) =
  let index = tree.nodeIndex(id)
  if index < 0 or handler == nil: return
  tree.nodes[index].keyListeners.add(proc(eventPtr: pointer) =
    var event = cast[ptr UiEvent](eventPtr)
    handler(event[]))

proc onModifiersChanged*(tree: var UiTree, id: NodeId, handler: EventHandler) =
  let index = tree.nodeIndex(id)
  if index < 0 or handler == nil: return
  tree.nodes[index].modifiersChangedListeners.add(proc(eventPtr: pointer) =
    var event = cast[ptr UiEvent](eventPtr)
    handler(event[]))

proc onAction*(tree: var UiTree, id: NodeId, action: string,
               handler: ActionHandler) =
  let index = tree.nodeIndex(id)
  if index < 0 or handler == nil: return
  tree.nodes[index].actionListeners.add((action, handler))

proc onAction*(tree: var UiTree, id: NodeId, handler: ActionHandler,
               action: string) =
  tree.onAction(id, action, handler)

proc dispatchWithHandlers*(tree: var UiTree,
                           event: var UiEvent): seq[EventPhase]

proc dispatch*(tree: var UiTree, event: var UiEvent): seq[EventPhase] =
  tree.dispatchWithHandlers(event)

proc dispatchWithHandlers*(tree: var UiTree, event: var UiEvent): seq[EventPhase] =
  let path = ancestorPath(tree, event.target)
  for index in 0 .. path.high:
    event.phase = capture
    result.add(capture)
    tree.invokeNodeListeners(path[index], event)
    if event.handled: return
  event.phase = target
  result.add(target)
  if event.handled: return
  for index in countdown(path.high, 0):
    event.phase = bubble
    result.add(bubble)
    tree.invokeNodeListeners(path[index], event)
    if event.handled: return
