import nimnui/ui_tree
import nimnui/context
import std/algorithm
import std/json
import std/strutils
import std/tables
import std/unicode except splitWhitespace

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
var commandPaletteShortcuts = initTable[string, string]()
var commandPaletteShortcutBuffer = ""

const
  userBindingMeta* = 0'u32
  vimBindingMeta* = 1'u32
  baseBindingMeta* = 2'u32
  defaultBindingMeta* = 3'u32

  ## Command names exposed by the editor command palette. The native macOS
  ## picker receives this list from the Nim action registry; it must not own
  ## a second, platform-specific catalogue.
  commandPaletteRequiredActions* = [
    "save as", "replace", "go to line", "quick open", "workspace search",
    "show files", "show outline", "fold recursively", "git stage hunk",
    "git commit", "cancel git", "toggle terminal", "cancel task",
    "duplicate workspace entry", "copy workspace entry", "cut workspace entry",
    "paste workspace entry", "move workspace entry to trash",
    "delete workspace entry permanently", "open selected workspace entry with system",
    "find in selected folder",
    "debug start", "debug attach", "debug stop", "debug continue", "debug pause",
    "debug step over", "debug step into", "debug step out",
    "debug toggle breakpoint", "debug watch", "debug clear watches",
    "debug variables", "debug threads",
    "agent start", "agent start codex", "agent start claude code",
    "agent start opencode", "agent start worktree", "agent stop", "agent send",
    "agent next", "agent previous", "agent review diff",
    "agent approve", "agent reject", "agent apply patch",
    "extensions install", "extensions reload", "extensions list",
    "extensions catalog", "extensions runtime", "extensions run",
    "go to definition", "find references", "code actions", "signature help",
    "inlay hints", "semantic tokens", "format document", "check for updates"
  ]

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

proc rememberCommandPaletteShortcuts(registry: CommandRegistry,
                                     actions: openArray[string],
                                     contexts: openArray[KeyContext])

proc availableActions*(registry: CommandRegistry,
                       contexts: openArray[KeyContext]): seq[string] =
  ## Return the registered command names whose predicates match the current
  ## dispatch path. A command can be registered more than once (for example
  ## when a user binding overrides a default), so names are deduplicated.
  var seen = initTable[string, bool]()
  for command in registry.commands:
    if command.matchingDepth(contexts) >= 0 and not seen.hasKey(command.name):
      seen[command.name] = true
      result.add(command.name)
  result.sort()
  rememberCommandPaletteShortcuts(registry, result, contexts)

proc isActionAvailable*(registry: CommandRegistry, name: string,
                        contexts: openArray[KeyContext]): bool =
  ## Keep the single-name query equivalent to membership in availableActions.
  for command in registry.commands:
    if command.name == name and command.matchingDepth(contexts) >= 0:
      return true
  false

proc highestPrecedenceBindingForAction(registry: CommandRegistry, name: string,
                                       contexts: openArray[KeyContext]): Command =
  ## This is the action-oriented counterpart to bindingsForInput. The picker
  ## must show the same binding that dispatch would use after user bindings
  ## have been appended to the registry.
  var found = false
  var bestDepth = -1
  var bestIndex = -1
  for index, candidate in registry.commands:
    if candidate.name != name or candidate.action.isNoAction or
        candidate.action.isUnbind or candidate.shortcut.effectiveKeystrokes().len == 0:
      continue
    let depth = candidate.matchingDepth(contexts)
    if depth < 0: continue
    if not found or depth > bestDepth or (depth == bestDepth and index > bestIndex):
      result = candidate
      bestDepth = depth
      bestIndex = index
      found = true

proc shortcutDisplay*(shortcut: Shortcut): string

proc normalizedPaletteName(name: string): string =
  ## Main's palette labels turn camelCase action names into human labels for
  ## most commands. Compare both forms without maintaining a second shortcut
  ## catalogue in the platform layer.
  for character in name:
    if character.isAlphaNumeric:
      result.add(character.toLowerAscii)

proc rememberCommandPaletteShortcuts(registry: CommandRegistry,
                                     actions: openArray[string],
                                     contexts: openArray[KeyContext]) =
  commandPaletteShortcuts.clear()
  for action in actions:
    let binding = registry.highestPrecedenceBindingForAction(action, contexts)
    if binding.shortcut.effectiveKeystrokes().len > 0:
      commandPaletteShortcuts[action] = binding.shortcut.shortcutDisplay()

proc shortcutDisplay*(shortcut: Shortcut): string =
  ## Render a macOS keybinding using the same compact glyphs as Zed's Key.
  ## Chords are separated by a space so their boundaries remain visible.
  let strokes = shortcut.effectiveKeystrokes()
  for strokeIndex, stroke in strokes:
    if strokeIndex > 0: result.add(" ")
    if commandModifier in stroke.modifiers: result.add("⌘")
    if optionModifier in stroke.modifiers: result.add("⌥")
    if controlModifier in stroke.modifiers: result.add("⌃")
    if shiftModifier in stroke.modifiers: result.add("⇧")
    case stroke.keyCode
    of 0: discard
    of 36: result.add("↩")
    of 48: result.add("⇥")
    of 49: result.add("Space")
    of 50: result.add("`")
    of 51: result.add("⌫")
    of 53: result.add("⎋")
    of 115: result.add("↖")
    of 116: result.add("⇞")
    of 117: result.add("⌦")
    of 119: result.add("↘")
    of 120: result.add("F2")
    of 121: result.add("⇟")
    of 122: result.add("F1")
    of 123: result.add("←")
    of 124: result.add("→")
    of 125: result.add("↓")
    of 126: result.add("↑")
    of 27: result.add("-")
    of 30: result.add("]")
    of 33: result.add("[")
    of 41: result.add(";")
    of 42: result.add("\\")
    of 43: result.add(",")
    of 44: result.add("/")
    of 47: result.add(".")
    else:
      for letter in [('a', 0'u32), ('b', 11'u32), ('c', 8'u32),
          ('d', 2'u32), ('e', 14'u32), ('f', 3'u32), ('g', 5'u32),
          ('h', 4'u32), ('i', 34'u32), ('j', 38'u32), ('k', 40'u32),
          ('l', 37'u32), ('m', 46'u32), ('n', 45'u32), ('o', 31'u32),
          ('p', 35'u32), ('q', 12'u32), ('r', 15'u32), ('s', 1'u32),
          ('t', 17'u32), ('u', 32'u32), ('v', 9'u32), ('w', 13'u32),
          ('x', 7'u32), ('y', 16'u32), ('z', 6'u32)]:
        if stroke.keyCode == letter[1]:
          result.add(letter[0].toUpperAscii)
          break

proc shortcutDisplayAdvance*(display: string): int =
  ## A single printable key occupies a fixed square, matching Zed's Key
  ## element. Modifier glyphs keep their natural advance; only the final
  ## single-character key is normalized for column alignment.
  if display.len == 0: return 0
  let key = display[^1]
  if key in {'A'..'Z', 'a'..'z', '0'..'9'}:
    return display[0 ..< display.len - 1].toRunes.len + 1
  display.toRunes.len

proc commandPaletteShortcutForAction*(registry: CommandRegistry, name: string,
                                      contexts: openArray[KeyContext]): string =
  let binding = registry.highestPrecedenceBindingForAction(name, contexts)
  binding.shortcut.shortcutDisplay()

proc commandPaletteShortcut*(name: string): string =
  if commandPaletteShortcuts.hasKey(name):
    return commandPaletteShortcuts[name]
  let normalized = normalizedPaletteName(name)
  for action, shortcut in commandPaletteShortcuts.pairs:
    if shortcut.len > 0 and normalizedPaletteName(action) == normalized:
      return shortcut

proc nimculus_command_palette_shortcut(name: cstring): cstring
    {.cdecl, exportc.} =
  ## Called synchronously by the native picker while it rebuilds its rows.
  ## The buffer remains valid until the next query; NSString copies it.
  commandPaletteShortcutBuffer = commandPaletteShortcut($name)
  commandPaletteShortcutBuffer.cstring

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
