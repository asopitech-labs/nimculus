import std/sequtils
import nimnui/geometry
import nimnui/ui_tree

type
  UiEventKind* = enum
    pointerDown, pointerUp, pointerMove, scroll, keyDown, keyUp, command

  EventPhase* = enum
    capture, target, bubble

  UiEvent* = object
    kind*: UiEventKind
    phase*: EventPhase
    target*: NodeId
    position*: Point
    keyCode*: uint32
    command*: string
    handled*: bool

  EventHandler* = proc(event: var UiEvent) {.closure.}

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
