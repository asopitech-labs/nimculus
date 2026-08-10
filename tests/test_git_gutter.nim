import std/unittest
import nimculus/git_gutter

suite "Git gutter input routing":
  test "change-bar width follows the editor line height":
    check gitGutterStripWidth(24'f32) == 6'f32
    check gitGutterStripWidth(30'f32) == 8'f32
    check gitGutterStripWidth(0'f32) == 0'f32

  test "normal click maps the visible row to a stage action":
    let action = gitGutterActionAt(34'f32, 49'f32, 32'f32, 20'f32, 8'f32,
      12, 0)
    check action.kind == gitGutterStage
    check action.line == 13

  test "Option-click maps the same row to an unstage action":
    let action = gitGutterActionAt(34'f32, 49'f32, 32'f32, 20'f32, 8'f32,
      12, gitGutterUnstageModifier)
    check action.kind == gitGutterUnstage
    check action.line == 13

  test "clicks outside the gutter do not start a Git action":
    check gitGutterActionAt(41'f32, 49'f32, 32'f32, 20'f32, 8'f32, 0, 0).kind == gitGutterNone
    check gitGutterActionAt(34'f32, 19'f32, 32'f32, 20'f32, 8'f32, 0, 0).kind == gitGutterNone

  test "the in-editor gutter begins at the editor edge":
    check gitGutterContains(48'f32, 48'f32, 40'f32)
    check gitGutterContains(87.99'f32, 48'f32, 40'f32)
    check not gitGutterContains(47.99'f32, 48'f32, 40'f32)
    check not gitGutterContains(88'f32, 48'f32, 40'f32)
    let action = gitGutterActionAt(48'f32, 44'f32, 48'f32, 40'f32, 40'f32, 0, 0)
    check action.kind == gitGutterStage
    check action.line == 0
