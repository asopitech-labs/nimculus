when defined(windows):
  import std/os
  import nimnui/nimnui
  import nimculus/terminal

  var windowsTerminal*: TerminalPty
  var windowsTerminalVisible* = false

  proc syncWindowsTerminal() =
    if windowsTerminal == nil: return
    let text = windowsTerminal.screen.gridText()
    platformSetTerminalText(text.cstring, uint32(text.len))

  proc startWindowsTerminal*() =
    if windowsTerminal != nil and not windowsTerminal.closed:
      windowsTerminalVisible = true
      platformSetTerminalVisible(true)
      syncWindowsTerminal()
      return
    try:
      windowsTerminal = newTerminalPty("cmd.exe", getCurrentDir(), 100, 24)
      windowsTerminalVisible = true
      platformSetTerminalVisible(true)
      syncWindowsTerminal()
    except CatchableError:
      windowsTerminal = nil
      windowsTerminalVisible = false
      platformSetTerminalVisible(false)

  proc pollWindowsTerminal*() =
    if windowsTerminal == nil or windowsTerminal.closed: return
    discard windowsTerminal.pollOutput()
    if windowsTerminalVisible: syncWindowsTerminal()

  proc closeWindowsTerminal*() =
    if windowsTerminal != nil: windowsTerminal.close()
    windowsTerminal = nil
    windowsTerminalVisible = false
    platformSetTerminalVisible(false)

  proc writeWindowsTerminalText*(text: string): bool =
    if not windowsTerminalVisible or windowsTerminal == nil or windowsTerminal.closed: return false
    discard windowsTerminal.writeInput(text)
    true

  proc handleWindowsTerminalInput*(event: ptr NimculusInputEvent): bool =
    if not windowsTerminalVisible or windowsTerminal == nil or windowsTerminal.closed or
        event == nil or event.kind != 10'u32: return false
    let control = (event.modifiers and (1'u32 shl 18)) != 0
    let input = case event.keyCode
      of 37'u32: "\x1b[D"
      of 38'u32: "\x1b[A"
      of 39'u32: "\x1b[C"
      of 40'u32: "\x1b[B"
      of 67'u32:
        if control: "\x03" else: ""
      else: ""
    if input.len == 0: return false
    discard writeWindowsTerminalText(input)
    true

else:
  proc startWindowsTerminal*() = discard
  proc pollWindowsTerminal*() = discard
  proc closeWindowsTerminal*() = discard
  proc writeWindowsTerminalText*(text: string): bool = false
  proc handleWindowsTerminalInput*(event: pointer): bool = false
