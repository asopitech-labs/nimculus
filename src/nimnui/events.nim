import std/sequtils
import nimnui/commands
import nimnui/geometry
import nimnui/ui_tree

type
  UiEventKind* = enum
    pointerDown, pointerUp, pointerMove, scroll, keyDown, keyUp,
    modifiersChanged, command

  EventPhase* = enum
    capture, target, bubble

  UiEvent* = object
    kind*: UiEventKind
    phase*: EventPhase
    target*: NodeId
    position*: Point
    keyCode*: uint32
    ## 0 = left, 1 = right, 2 = other. Pointer events without a button use 0.
    button*: uint32
    ## Raw platform flags are retained for diagnostics and platform-specific
    ## handling. Command routing should use shortcutModifiers.
    modifiers*: uint32
    shortcutModifiers*: set[Modifier]
    deltaX*, deltaY*: float32
    command*: string
    handled*: bool

  EventHandler* = proc(event: var UiEvent) {.closure.}

proc nativeEventKind*(eventType: uint32): UiEventKind =
  ## NSEventType values used by the AppKit bridge. Keep drag and modifier
  ## events distinct; treating them as commands loses pointer selection and
  ## modifier state transitions before they reach NimNUI.
  case eventType
  of 1'u32, 3'u32, 25'u32: pointerDown
  of 2'u32, 4'u32, 26'u32: pointerUp
  of 5'u32, 6'u32, 7'u32, 27'u32: pointerMove
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
  var current = target
  while current != NodeId(0):
    result.add(current)
    let index = tree.nodes.mapIt(it.id).find(current)
    if index < 0: break
    current = tree.nodes[index].parent

proc dispatch*(tree: var UiTree, event: var UiEvent): seq[EventPhase] =
  let path = ancestorPath(tree, event.target)
  for index in countdown(path.high, 0):
    event.phase = capture
    result.add(capture)
    if event.handled: return
  event.phase = target
  result.add(target)
  if event.handled: return
  for index in 0 .. path.high:
    event.phase = bubble
    result.add(bubble)
    if event.handled: return

proc dispatchWithHandlers*(tree: var UiTree, event: var UiEvent,
                           handlers: seq[tuple[node: NodeId, handler: EventHandler]]): seq[EventPhase] =
  let path = ancestorPath(tree, event.target)
  for index in countdown(path.high, 0):
    event.phase = capture
    result.add(capture)
    for entry in handlers:
      if entry.node == path[index]: entry.handler(event)
    if event.handled: return
  event.phase = target
  result.add(target)
  for entry in handlers:
    if entry.node == event.target: entry.handler(event)
  if event.handled: return
  for index in 0 .. path.high:
    event.phase = bubble
    result.add(bubble)
    for entry in handlers:
      if entry.node == path[index]: entry.handler(event)
    if event.handled: return
