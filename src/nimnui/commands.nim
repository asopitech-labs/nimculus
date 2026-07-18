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

proc register*(registry: var CommandRegistry, command: Command) = registry.commands.add(command)

proc resolve*(registry: CommandRegistry, shortcut: Shortcut): Command =
  for command in registry.commands:
    if command.shortcut.keyCode == shortcut.keyCode and command.shortcut.modifiers == shortcut.modifiers:
      return command

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
