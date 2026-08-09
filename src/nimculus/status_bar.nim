import nimculus/settings
import nimculus/time_format
import std/unicode

type
  StatusBarFooterItem* = object
    kind*: string
    text*: string

const
  DefaultStatusBarShowActiveFile* = false
  DefaultStatusBarActiveLanguageButton* = true
  DefaultStatusBarCursorPositionButton* = true
  DefaultStatusBarLineEndingsButton* = false
  DefaultStatusBarActiveEncodingButton* = "non_utf8"
  GitBlameMaxAuthorCharsDisplayed* = 20

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
    language, activeFile: string; isUtf8 = true; hasBom = false;
    gitBlameHash = ""; gitBlameText = ""): seq[StatusBarFooterItem] =
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

  if showCursor and cursor.len > 0:
    result.add(StatusBarFooterItem(kind: "cursor", text: cursor))
  if statusBarEncodingShouldShow(encodingOption, isUtf8, hasBom) and encoding.len > 0:
    result.add(StatusBarFooterItem(kind: "encoding", text: statusBarEncodingText(encoding, hasBom)))
  if showLineEndings and lineEnding.len > 0:
    result.add(StatusBarFooterItem(kind: "line-ending", text: lineEnding))
  if showLanguage and language.len > 0:
    result.add(StatusBarFooterItem(kind: "language", text: language))
  if showActiveFile and activeFile.len > 0:
    result.add(StatusBarFooterItem(kind: "active-file", text: activeFile))
  let showGitBlame = settings != nil and settings.gitInlineBlameEnabled() and
    settings.gitInlineBlameLocation() == "status_bar"
  if showGitBlame and gitBlameHash.len > 0 and gitBlameText.len > 0:
    result.add(StatusBarFooterItem(kind: "git-blame:" & gitBlameHash, text: gitBlameText))

proc serializeStatusBarFooter*(items: openArray[StatusBarFooterItem]): string =
  ## The native footer receives each item's kind with its text.  The first
  ## equals sign is the ABI boundary; values may contain additional equals.
  for index, item in items:
    if index > 0: result.add('\t')
    result.add(item.kind)
    result.add('=')
    result.add(item.text)

proc truncateGitBlameAuthor*(author: string): string =
  var count = 0
  for rune in author.runes:
    if count == GitBlameMaxAuthorCharsDisplayed: break
    result.add(rune.toUTF8)
    inc count

proc gitBlameStatusText*(author: string; authorTime: int64; summary: string;
                         showSummary: bool; now: int64; timestampValid = true): string =
  let relative = if timestampValid: formatRelativeTime(authorTime, now)
    else: "Error parsing date"
  result = truncateGitBlameAuthor(author) & ", " & relative
  if showSummary and summary.len > 0:
    result.add(" - " & summary)
