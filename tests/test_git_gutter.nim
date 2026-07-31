import std/unittest
import nimculus/git_gutter

suite "Git gutter input routing":
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
