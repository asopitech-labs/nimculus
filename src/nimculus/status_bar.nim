import nimculus/settings

const
  DefaultStatusBarShowActiveFile* = false
  DefaultStatusBarActiveLanguageButton* = true
  DefaultStatusBarCursorPositionButton* = true
  DefaultStatusBarLineEndingsButton* = false
  DefaultStatusBarActiveEncodingButton* = "non_utf8"

proc statusBarEncodingShouldShow*(displayOption: string; isUtf8, hasBom: bool): bool =
  ## Mirrors Zed's EncodingDisplayOptions::should_show.
  case displayOption
  of "enabled": true
  of "disabled": false
  of "non_utf8": not (isUtf8 and not hasBom)
  else: not (isUtf8 and not hasBom)

proc statusBarEncodingText*(encoding: string; hasBom: bool): string =
  result = encoding
  if hasBom: result.add(" (BOM)")

proc statusBarFooter*(settings: SettingsStore; cursor, encoding, lineEnding,
    language, activeFile: string; isUtf8 = true; hasBom = false): seq[string] =
  let showActiveFile = if settings == nil: DefaultStatusBarShowActiveFile
    else: settings.boolSetting("statusBar.showActiveFile", DefaultStatusBarShowActiveFile)
  let showLanguage = if settings == nil: DefaultStatusBarActiveLanguageButton
    else: settings.boolSetting("statusBar.activeLanguageButton",
      DefaultStatusBarActiveLanguageButton)
  let showCursor = if settings == nil: DefaultStatusBarCursorPositionButton
    else: settings.boolSetting("statusBar.cursorPositionButton",
      DefaultStatusBarCursorPositionButton)
  let showLineEndings = if settings == nil: DefaultStatusBarLineEndingsButton
    else: settings.boolSetting("statusBar.lineEndingsButton", DefaultStatusBarLineEndingsButton)
  let encodingOption = if settings == nil: DefaultStatusBarActiveEncodingButton
    else: settings.stringSetting("statusBar.activeEncodingButton",
      DefaultStatusBarActiveEncodingButton)

  if showCursor and cursor.len > 0: result.add(cursor)
  if statusBarEncodingShouldShow(encodingOption, isUtf8, hasBom) and encoding.len > 0:
    result.add(statusBarEncodingText(encoding, hasBom))
  if showLineEndings and lineEnding.len > 0: result.add(lineEnding)
  if showLanguage and language.len > 0: result.add(language)
  if showActiveFile and activeFile.len > 0: result.add(activeFile)
