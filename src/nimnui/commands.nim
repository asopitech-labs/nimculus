import nimnui/ui_tree
import std/strutils

type
  Modifier* = enum
    commandModifier, optionModifier, controlModifier, shiftModifier

  Shortcut* = object
    keyCode*: uint32
    modifiers*: set[Modifier]

  Command* = object
    name*: string
    shortcut*: Shortcut
    action*: proc() {.closure.}

  CommandRegistry* = object
    commands*: seq[Command]

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

proc register*(registry: var CommandRegistry, command: Command) = registry.commands.add(command)

proc resolve*(registry: CommandRegistry, shortcut: Shortcut): Command =
  for command in registry.commands:
    if command.shortcut.keyCode == shortcut.keyCode and command.shortcut.modifiers == shortcut.modifiers:
      return command

proc tryResolve*(registry: CommandRegistry, shortcut: Shortcut,
                 command: var Command): bool =
  ## Resolve a shortcut without using an all-zero Command as a sentinel.
  ## Keymap files are ordered; later bindings take precedence, matching Zed's
  ## keymap loader and making layered settings deterministic.
  for index in countdown(registry.commands.high, 0):
    let candidate = registry.commands[index]
    if candidate.shortcut.keyCode == shortcut.keyCode and
        candidate.shortcut.modifiers == shortcut.modifiers:
      command = candidate
      return true
  false

proc dispatchShortcut*(registry: CommandRegistry, shortcut: Shortcut): bool =
  ## Invoke exactly one registered command and report whether it was handled.
  var command: Command
  if not registry.tryResolve(shortcut, command): return false
  if command.action != nil: command.action()
  true

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
  ## `cmd+shift+p` or `ctrl+alt+f`. The platform boundary still owns the
  ## NSEvent bitmask conversion; this function only creates a Shortcut value.
  var key = ""
  for part in binding.split('+'):
    let value = part.strip.toLowerAscii
    case value
    of "cmd", "command": result.modifiers.incl(commandModifier)
    of "ctrl", "control": result.modifiers.incl(controlModifier)
    of "alt", "option": result.modifiers.incl(optionModifier)
    of "shift": result.modifiers.incl(shiftModifier)
    else: key = value
  result.keyCode = macOSKeyCode(key)

proc focusNext*(tree: var UiTree): NodeId =
  var focusables: seq[NodeId]
  for node in tree.nodes:
    if node.focusable and not tree.isDisabledPath(node.id): focusables.add(node.id)
  if focusables.len == 0: return NodeId(0)
  var current = 0
  for index, id in focusables:
    if id == tree.focused: current = (index + 1) mod focusables.len
  discard tree.focus(focusables[current])
  focusables[current]
