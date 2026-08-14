import std/unittest
import nimnui/commands

suite "UI keybinding display":
  test "palette display follows the highest-precedence registry binding":
    var registry: CommandRegistry
    registry.register(Command(name: "quick open",
      shortcut: shortcutFromKeyBinding("cmd+p"), meta: defaultBindingMeta))
    registry.register(Command(name: "quick open",
      shortcut: shortcutFromKeyBinding("cmd+o"), meta: userBindingMeta))

    let actions = registry.availableActions([])
    check "quick open" in actions
    check registry.commandPaletteShortcutForAction("quick open", []) == "⌘O"
    check commandPaletteShortcut("quick open") == "⌘O"
    check registry.bindingsForInput(shortcutFromKeyBinding("cmd+o"), []).len == 1
    check registry.bindingsForInput(shortcutFromKeyBinding("cmd+p"), []).len == 1

  test "single-character key advances use one fixed square":
    let commandP = shortcutDisplay(shortcutFromKeyBinding("cmd+p"))
    let commandD = shortcutDisplay(shortcutFromKeyBinding("cmd+d"))
    check commandP == "⌘P"
    check commandD == "⌘D"
    check shortcutDisplayAdvance(commandP) == shortcutDisplayAdvance(commandD)
