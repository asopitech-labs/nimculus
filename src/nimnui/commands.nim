import nimnui/ui_tree

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
  for candidate in registry.commands:
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

proc focusNext*(tree: var UiTree): NodeId =
  var focusables: seq[NodeId]
  for node in tree.nodes:
    if node.focusable: focusables.add(node.id)
  if focusables.len == 0: return NodeId(0)
  var current = 0
  for index, id in focusables:
    if id == tree.focused: current = (index + 1) mod focusables.len
  discard tree.focus(focusables[current])
  focusables[current]
