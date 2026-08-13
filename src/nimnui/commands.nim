import nimnui/ui_tree
import nimnui/context
import std/algorithm
import std/json
import std/strutils
import std/tables

type
  ActionKind* = enum
    actionCommand, actionNoAction, actionUnbind

  Action* = object
    ## A type-erased command value. The name identifies its registered
    ## handler, while the payload carries the invocation-specific data.
    name*: string
    payload*: JsonNode
    kind*: ActionKind
    unbindTarget*: string

  ActionBuilder* = proc(payload: JsonNode): Action {.closure.}
  CommandActionHandler* = proc(action: Action): bool {.closure.}

  Modifier* = enum
    commandModifier, optionModifier, controlModifier, shiftModifier

  Keystroke* = object
    keyCode*: uint32
    modifiers*: set[Modifier]

  PendingInput* = object
    ## Key strokes that are waiting for a longer binding to become complete.
    ## The focus snapshot is owned by the window/app input boundary.
    keystrokes*: seq[Keystroke]
    focus*: NodeId
    needsTimeout*: bool

  Shortcut* = object
    keystrokes*: seq[Keystroke]
    ## Deprecated single-keystroke fields retained for source compatibility.
    keyCode*: uint32
    modifiers*: set[Modifier]

  Command* = object
    name*: string
    shortcut*: Shortcut
    whenClause*: string
    predicate*: KeyBindingContextPredicate
    action*: Action
    ## Source layer: User 0 < Vim 1 < Base 2 < Default 3.
    meta*: uint32

  CommandRegistry* = object
    commands*: seq[Command]

  DispatchResult* = object
    ## Commands are returned for the caller to invoke on its UI thread. A
    ## replay is deliberately data-only: the caller decides how the original
    ## input event should continue through its normal event path.
    bindings*: seq[Command]
    pending*: seq[Keystroke]
    toReplay*: seq[Keystroke]

var keyBindingPredicateParseCount* = 0
var actionRegistry*: Table[string, ActionBuilder] = initTable[string, ActionBuilder]()
var actionHandlers*: Table[string, CommandActionHandler] =
  initTable[string, CommandActionHandler]()

const
  userBindingMeta* = 0'u32
  vimBindingMeta* = 1'u32
  baseBindingMeta* = 2'u32
  defaultBindingMeta* = 3'u32

proc noAction*(): Action =
  Action(name: "NoAction", kind: actionNoAction)

proc unbind*(actionName: string): Action =
  Action(name: "Unbind", kind: actionUnbind, unbindTarget: actionName)

proc isNoAction*(action: Action): bool =
  action.kind == actionNoAction or action.name in ["NoAction", "zed::NoAction"]

proc isUnbind*(action: Action): bool =
  action.kind == actionUnbind or action.name in ["Unbind", "zed::Unbind"]

proc unbindTargetName(action: Action): string =
  if action.unbindTarget.len > 0: return action.unbindTarget
  if action.payload == nil: return ""
  if action.payload.kind == JString: return action.payload.getStr
  if action.payload.kind == JArray and action.payload.len > 1 and
      action.payload[1].kind == JString:
    return action.payload[1].getStr
  ""

proc registerAction*(name: string, builder: ActionBuilder) =
  if name.len == 0:
    raise newException(ValueError, "Cannot register an action without a name")
  if builder == nil:
    raise newException(ValueError, "Cannot register a nil builder for action: " & name)
  actionRegistry[name] = builder

proc buildAction*(name: string, payload: JsonNode): Action =
  if not actionRegistry.hasKey(name):
    raise newException(ValueError, "Unregistered action: " & name)
  result = actionRegistry[name](payload)
  result.name = name

proc registerActionHandler*(name: string, handler: CommandActionHandler) =
  if name.len == 0:
    raise newException(ValueError, "Cannot register a handler without an action name")
  if handler == nil:
    raise newException(ValueError, "Cannot register a nil handler for action: " & name)
  actionHandlers[name] = handler

proc actionAvailable*(action: Action): bool =
  not action.isNoAction and not action.isUnbind and
    actionHandlers.hasKey(action.name) and actionHandlers[action.name] != nil

proc dispatchAction*(action: Action): bool =
  if not action.actionAvailable(): return false
  actionHandlers[action.name](action)

proc effectiveKeystrokes(shortcut: Shortcut): seq[Keystroke] =
  if shortcut.keystrokes.len > 0:
    result = shortcut.keystrokes
  elif shortcut.keyCode != 0 or shortcut.modifiers != {}:
    result = @[Keystroke(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers)]

proc matchKeystrokes*(binding: Shortcut,
                      typed: openArray[Keystroke]): tuple[matched, pending: bool] =
  let bindingKeystrokes = binding.effectiveKeystrokes()
  if typed.len > bindingKeystrokes.len: return (false, false)
  for index, keystroke in typed:
    if keystroke != bindingKeystrokes[index]: return (false, false)
  if typed.len < bindingKeystrokes.len: (false, true) else: (true, false)

const
  ## NSEventModifierFlags values used by AppKit. Keep this conversion at the
  ## platform boundary; command matching should not depend on Cocoa bitmasks.
  macOSShiftFlag = 1'u32 shl 17
  macOSControlFlag = 1'u32 shl 18
  macOSOptionFlag = 1'u32 shl 19
  macOSCommandFlag = 1'u32 shl 20

proc macOSModifiers*(flags: uint32): set[Modifier] =
  ## Convert NSEvent.modifierFlags into NimNUI's platform-neutral shortcut set.
  ## This follows Zed's gpui_macos event mapping: control, alternate/option,
  ## shift, and command are independent modifier bits.
  if (flags and macOSCommandFlag) != 0: result.incl(commandModifier)
  if (flags and macOSOptionFlag) != 0: result.incl(optionModifier)
  if (flags and macOSControlFlag) != 0: result.incl(controlModifier)
  if (flags and macOSShiftFlag) != 0: result.incl(shiftModifier)

proc parseCommandPredicate(source: string): KeyBindingContextPredicate =
  inc keyBindingPredicateParseCount
  parseKeyBindingContextPredicate(source)

proc setWhenClause*(command: var Command, whenClause: string) =
  command.whenClause = whenClause
  command.predicate = parseCommandPredicate(whenClause)

proc register*(registry: var CommandRegistry, command: Command) =
  var registered = command
  registered.predicate = parseCommandPredicate(registered.whenClause)
  registry.commands.add(registered)

proc matchingDepth(command: Command, contexts: openArray[KeyContext]): int =
  let depth = command.predicate.depthOf(contexts)
  if depth.matched: depth.depth else: -1

proc disabledBindingMatchesContext(disabledBinding, binding: Command): bool =
  if disabledBinding.predicate == nil: return true
  if binding.predicate == nil: return false
  disabledBinding.predicate.isSuperset(binding.predicate)

proc bindingIsUnbound(disabledBinding, binding: Command): bool =
  disabledBinding.shortcut.effectiveKeystrokes() == binding.shortcut.effectiveKeystrokes() and
    disabledBinding.action.isUnbind and
    disabledBinding.action.unbindTargetName() == binding.action.name

type MatchingCommand = tuple[command: Command, depth: int, index: int]

proc sortMatchingCommands(matches: var seq[MatchingCommand]) =
  matches.sort(proc(left, right: MatchingCommand): int =
    if left.depth != right.depth: cmp(right.depth, left.depth)
    else: cmp(right.index, left.index))

proc applyBindingMarkers(matches: seq[MatchingCommand]): seq[Command] =
  ## Match Zed's candidate loop: NoAction blocks candidates from its layer
  ## downward, while Unbind removes only a named action.
  var noActionMeta = high(uint32)
  var hasNoAction = false
  for match in matches:
    if match.command.action.isNoAction:
      hasNoAction = true
      noActionMeta = min(noActionMeta, match.command.meta)

  var unbound: seq[Command]
  for match in matches:
    let candidate = match.command
    if candidate.action.isNoAction: continue
    if hasNoAction and candidate.meta >= noActionMeta: continue
    if candidate.action.isUnbind:
      unbound.add(candidate)
      continue
    var isUnboundMatch = false
    for disabled in unbound:
      if disabledBindingMatchesContext(disabled, candidate) and
          bindingIsUnbound(disabled, candidate):
        isUnboundMatch = true
        break
    if isUnboundMatch:
      continue
    result.add(candidate)

proc bindingsForInput*(registry: CommandRegistry, shortcut: Shortcut,
                       contexts: openArray[KeyContext]): seq[Command] =
  var matches: seq[MatchingCommand]
  for index in countdown(registry.commands.high, 0):
    let candidate = registry.commands[index]
    if candidate.shortcut.matchKeystrokes(shortcut.effectiveKeystrokes()) !=
        (true, false): continue
    let depth = candidate.matchingDepth(contexts)
    if depth >= 0:
      matches.add((candidate, depth, index))
  matches.sortMatchingCommands()
  matches.applyBindingMarkers()

proc bindingsForPrefix(registry: CommandRegistry,
                       typed: openArray[Keystroke],
                       contexts: openArray[KeyContext]): seq[Command] =
  ## Return bindings for which `typed` is a strict prefix. Keep the same
  ## context and registration precedence as exact key dispatch.
  var matches: seq[MatchingCommand]
  for index in countdown(registry.commands.high, 0):
    let candidate = registry.commands[index]
    if candidate.shortcut.matchKeystrokes(typed) != (false, true): continue
    let depth = candidate.matchingDepth(contexts)
    if depth >= 0:
      matches.add((candidate, depth, index))
  matches.sortMatchingCommands()
  matches.applyBindingMarkers()

proc dispatchKey*(registry: CommandRegistry, pending: var PendingInput,
                  keystroke: Keystroke,
                  contexts: openArray[KeyContext]): DispatchResult =
  ## Resolve one physical key against the current pending sequence.
  ##
  ## An exact binding is delayed when it is also a prefix of a longer binding;
  ## this is the same ambiguity that Zed resolves with its one-second flush.
  ## If the sequence stops matching, the whole sequence is returned in input
  ## order for replay and no delayed exact binding is invoked here.
  var typed = pending.keystrokes
  typed.add(keystroke)
  let exact = registry.bindingsForInput(
    Shortcut(keystrokes: typed), contexts)
  let prefix = registry.bindingsForPrefix(typed, contexts)

  if prefix.len > 0:
    pending.keystrokes = typed
    pending.needsTimeout = exact.len > 0
    result.pending = typed
    return

  if exact.len > 0:
    result.bindings = exact
  elif pending.keystrokes.len > 0:
    result.toReplay = typed
  else:
    result.toReplay = @[keystroke]
  pending = PendingInput()
  result.pending = pending.keystrokes

proc invalidatePendingInput*(pending: var PendingInput,
                             focused: NodeId): bool =
  ## Focus changes invalidate the sequence before the next key is resolved.
  if pending.keystrokes.len == 0 or pending.focus == focused:
    return false
  pending = PendingInput()
  true

proc flushDispatch*(registry: CommandRegistry, pending: var PendingInput,
                    contexts: openArray[KeyContext]): DispatchResult =
  ## Flush a pending sequence whose exact binding was held behind a longer
  ## prefix. The caller invokes the returned commands, then continues with an
  ## empty pending state.
  if pending.keystrokes.len == 0:
    return
  result.bindings = registry.bindingsForInput(
    Shortcut(keystrokes: pending.keystrokes), contexts)
  pending = PendingInput()
  result.pending = pending.keystrokes

proc resolve*(registry: CommandRegistry, shortcut: Shortcut,
              contexts: openArray[KeyContext]): Command =
  let bindings = registry.bindingsForInput(shortcut, contexts)
  if bindings.len > 0: result = bindings[0]

proc resolve*(registry: CommandRegistry, shortcut: Shortcut): Command =
  registry.resolve(shortcut, [])

proc tryResolve*(registry: CommandRegistry, shortcut: Shortcut,
                 contexts: openArray[KeyContext], command: var Command): bool =
  let bindings = registry.bindingsForInput(shortcut, contexts)
  if bindings.len == 0: return false
  command = bindings[0]
  true

proc tryResolve*(registry: CommandRegistry, shortcut: Shortcut,
                 command: var Command): bool =
  registry.tryResolve(shortcut, [], command)

proc dispatchShortcut*(registry: CommandRegistry, shortcut: Shortcut,
                       contexts: openArray[KeyContext]): bool =
  for command in registry.bindingsForInput(shortcut, contexts):
    if command.action.dispatchAction(): return true
  false

proc dispatchShortcut*(registry: CommandRegistry, shortcut: Shortcut): bool =
  registry.dispatchShortcut(shortcut, [])

proc macOSKeyCode(key: string): uint32 =
  const letters = [
    ('a', 0'u32), ('b', 11'u32), ('c', 8'u32), ('d', 2'u32), ('e', 14'u32),
    ('f', 3'u32), ('g', 5'u32), ('h', 4'u32), ('i', 34'u32), ('j', 38'u32),
    ('k', 40'u32), ('l', 37'u32), ('m', 46'u32), ('n', 45'u32), ('o', 31'u32),
    ('p', 35'u32), ('q', 12'u32), ('r', 15'u32), ('s', 1'u32), ('t', 17'u32),
    ('u', 32'u32), ('v', 9'u32), ('w', 13'u32), ('x', 7'u32), ('y', 16'u32),
    ('z', 6'u32)]
  let normalized = key.toLowerAscii
  if normalized.len == 1:
    for item in letters:
      if normalized[0] == item[0]: return item[1]
  case normalized
  of "return", "enter": 36
  of "tab": 48
  of "escape", "esc": 53
  of "space": 49
  of "backspace": 51
  of "delete", "forwarddelete": 117
  of "left": 123
  of "right": 124
  of "down": 125
  of "up": 126
  of "home": 115
  of "end": 119
  of "pageup": 116
  of "pagedown": 121
  of "comma": 43
  of "period": 47
  of "slash": 44
  of "semicolon": 41
  of "quote": 39
  of "leftbracket": 33
  of "rightbracket": 30
  of "backslash": 42
  of "pipe", "bar", "|": 42
  of "minus": 27
  of "equal", "equals": 24
  of "grave", "backtick": 50
  of "f1": 122
  of "f2": 120
  of "f3": 99
  of "f4": 118
  of "f5": 96
  of "f6": 97
  of "f7": 98
  of "f8": 100
  of "f9": 101
  of "f10": 109
  of "f11": 103
  of "f12": 111
  else: 0

proc shortcutFromKeyBinding*(binding: string): Shortcut =
  ## Parse the macOS keymap spelling used by settings.json, e.g.
  ## `cmd+shift+p` or `ctrl-alt-f`. Whitespace separates keystrokes, while
  ## either `-` or `+` separates modifiers within each keystroke.
  for keystrokeBinding in binding.splitWhitespace:
    var keystroke = Keystroke()
    for part in keystrokeBinding.split({'-', '+'}):
      let value = part.strip.toLowerAscii
      case value
      of "cmd", "command": keystroke.modifiers.incl(commandModifier)
      of "ctrl", "control": keystroke.modifiers.incl(controlModifier)
      of "alt", "option": keystroke.modifiers.incl(optionModifier)
      of "shift": keystroke.modifiers.incl(shiftModifier)
      else: keystroke.keyCode = macOSKeyCode(value)
    result.keystrokes.add(keystroke)
  if result.keystrokes.len == 1:
    result.keyCode = result.keystrokes[0].keyCode
    result.modifiers = result.keystrokes[0].modifiers

type
  TabStopEntry = object
    id: NodeId
    path: seq[int]
    insertionIndex: int
    tabStop: bool

proc tabPath(tree: UiTree, id: NodeId): seq[int] =
  ## The dispatch path is NimNUI's equivalent of Zed's current_path.
  for nodeId in tree.dispatchPath(id):
    result.add(tree.handle(nodeId).tabIndex)

proc compareTabPaths(left, right: seq[int]): int =
  let commonLength = min(left.len, right.len)
  for index in 0 ..< commonLength:
    result = cmp(left[index], right[index])
    if result != 0: return
  result = cmp(left.len, right.len)

proc tabStopOrder(tree: UiTree): seq[TabStopEntry] =
  ## Sort by the (group, tab index) path, then by declaration order for
  ## equal paths, matching TabStopNode's path/insertion ordering in Zed.
  for index, node in tree.nodes:
    let handle = tree.handle(node.id)
    if node.focusable and not tree.isDisabledPath(node.id):
      result.add(TabStopEntry(id: node.id, path: tree.tabPath(node.id),
                              insertionIndex: index, tabStop: handle.tabStop))
  result.sort(proc(left, right: TabStopEntry): int =
    let pathOrder = compareTabPaths(left.path, right.path)
    if pathOrder != 0: pathOrder else: cmp(left.insertionIndex, right.insertionIndex))

proc focusByTabOrder(tree: var UiTree, forward: bool): NodeId =
  let entries = tree.tabStopOrder()
  if entries.len == 0: return NodeId(0)

  var current = -1
  for index, entry in entries:
    if entry.id == tree.focused:
      current = index
      break

  let start = if current < 0:
    if forward: 0 else: entries.high
  elif forward:
    (current + 1) mod entries.len
  else:
    (current + entries.len - 1) mod entries.len

  var index = start
  for _ in 0 ..< entries.len:
    if entries[index].tabStop:
      discard tree.focus(entries[index].id)
      return entries[index].id
    if forward:
      index = (index + 1) mod entries.len
    else:
      index = (index + entries.len - 1) mod entries.len
  NodeId(0)

proc focusNext*(tree: var UiTree): NodeId = tree.focusByTabOrder(true)

proc focusPrev*(tree: var UiTree): NodeId = tree.focusByTabOrder(false)
