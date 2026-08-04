import std/math
import nimculus/editor_view

type
  GitGutterActionKind* = enum
    gitGutterNone, gitGutterStage, gitGutterUnstage

  GitGutterAction* = object
    kind*: GitGutterActionKind
    line*: int

const gitGutterUnstageModifier* = 1'u32 shl 19

proc gitGutterContains*(pointerX, gutterOriginX, gutterWidth: float32): bool =
  ## The gutter is an editor child. Its hit region starts at the editor's left
  ## edge and never extends into the sidebar or outside the pane.
  gutterWidth > 0'f32 and pointerX >= gutterOriginX and
    pointerX < gutterOriginX + gutterWidth

proc gitGutterActionAt*(pointerX, pointerY, gutterOriginX, gutterOriginY,
                        gutterWidth: float32, scrollLine: int,
                        modifiers: uint32, scrollYFraction = 0'f32): GitGutterAction =
  ## Convert the native editor event into the same line action used by the
  ## Git service. Zed first hit-tests the gutter, then resolves the display
  ## row against the scroll position before starting an async diff action.
  ## Keep that boundary pure so native input and Git behavior cannot drift.
  if not gitGutterContains(pointerX, gutterOriginX, gutterWidth) or
      pointerY < gutterOriginY:
    return GitGutterAction(kind: gitGutterNone, line: -1)
  let line = max(0, int(floor((pointerY - gutterOriginY - 4'f32 +
    scrollYFraction) / editorLineHeight())) + scrollLine)
  result = GitGutterAction(kind: if (modifiers and gitGutterUnstageModifier) != 0:
      gitGutterUnstage else: gitGutterStage, line: line)
