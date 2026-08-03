# Codex ブリーフ: ピクセル平滑スクロール + 横スクロールバー（Zed 準拠）

目的: エディタの縦スクロールを**行単位の量子化からピクセル平滑（サブライン）**へ変え、
横長行に**水平スクロールバー**を出す。Zed のスクロール体感に合わせる。macOS のみ、
`DEVELOPMENT_GUIDELINES.md` 厳守（層分離・UI スレッド非ブロッキング・端末に配慮したログ・
専用 nimcache・format/lint・tooltip/AX 維持・既存テスト/contract 不破壊）。`nimble clean`
禁止。コミットしない。

## 現状（観察・コード確認済み）

- 縦スクロール状態は整数行 `EditorView.scrollLine`（`editor_view.nim:17`）と、C 側
  `g_editor_scroll_line`（NSUInteger）。`scrollLineDelta`（`editor_view.nim:201`）は
  トラックパッドのサブライン量を `remainder` に蓄積するが、**描画位置は常に整数行**なので
  1 行（≈18px）刻みでジャンプし、ピクセル平滑にならない。
- 横スクロールは `scrollX`（ピクセル, `g_editor_scroll_x`）で既にピクセル単位。
- スクロールバーは **縦のみ**（Nim の `paint.drawScrollbar`＋C の paint kind 10）。
  横長行用の**水平スクロールバーが無い**。

## 実装 A: ピクセル平滑な縦スクロール（サブライン描画）

方針: 「最初の可視行 `scrollLine`(int)」に加えて「サブラインのピクセル/端数オフセット
`scrollYFraction`（0 以上、lineHeight 未満、px）」を持ち、エディタ内容全体をこの端数だけ
上へずらして描く。既存の `scrollLineDelta` の `remainder` が実質この端数なので、破棄せず
**描画に反映**する。

1. **スクロール状態**: 連続ピクセル位置を正とする（例 `scrollYPixels: float32`）。
   `scrollLine = floor(scrollYPixels / lineHeight)`、
   `scrollYFraction = scrollYPixels - scrollLine*lineHeight`。上下限でクランプ
   （最終行まで、負でクランプ）。`editor_view.nim` にフィールド追加、`scrollLineDelta` は
   端数を保持したままピクセル位置を更新する形へ調整（回帰しないよう既存 API を壊さない）。
2. **プラットフォーム受け渡し**: `platformSetEditorScrollLine(int)` に加え、
   `platformSetEditorScrollYFraction(double px)` を追加（primary/secondary 両方）。
   C 側に `g_editor_scroll_y_fraction`（と secondary）を追加。
3. **描画のサブラインオフセット（macos_platform.m）**: エディタ本文テキスト・行番号
   オーバレイ・カーソル・選択範囲・Git ガター・診断下線など、**Y 座標を使う全描画を
   `-scrollYFraction` だけシフト**する。上端・下端に 1 行分の余剰を描いてクリップし、
   部分行が自然に見えるようにする（`clipsToBounds`/scissor で editor 矩形にクランプ）。
   `editorTextBaseline` / `editorTextLineBottom` / 行番号 overlay の drawRect /
   `editorTextCursorYForRow` などを端数対応にする。
4. **ヒットテスト/IME の整合**: point→行/桁のヒットテスト（`characterIndexForPoint` 等）、
   カーソル→座標、IME 候補矩形（`firstRectForCharacterRange`）も `scrollYFraction` を
   含めて計算する。行境界のオフバイワンを出さない。
5. **縦スクロールバー**: 連続ピクセル位置で thumb 位置・高さを算出（サブラインでも滑らかに
   動く）。

## 実装 B: 水平スクロールバー

- 可視行の最大ピクセル幅がビューポート幅を超えるとき、エディタ下端に**水平スクロールバー**を
  描く（thumb 幅 = viewport/content 比、位置 = `scrollX`/最大スクロール量）。soft-wrap が
  有効なときは出さない。
- 既存の縦スクロールバー描画（paint kind 10 / `drawScrollbar`）に倣い、水平版を追加
  （Nim 側で矩形生成 → C 側 paint、または C 側で直接描画）。`scrollbarThumb` 役割色を使い、
  ライト/ダーク両対応。ホバーで `scrollbarHover`（あれば）。
- 縦・横が同時に出るとき右下コーナーが重ならないよう調整。

## 契約・非回帰（重要）

- フレーム計数・display-link・ダメージ描画の意味は変えない。スクロール反映は既存の
  `requestRedraw` 経路を使う（新規の同期 drawFrame 乱発をしない）。
- 既存テスト（特に `test_ui_text`, `test_workspace_ui`, `test_editor`,
  `test_platform_contract`, `test_platform_headless`）とカーソル/選択/IME の contract を
  壊さない。`scrollLineDelta` の既存シグネチャ/意味を壊す場合はテストも整合させる。
- soft-wrap・分割ペイン（secondary）でも破綻しないこと。

## 検証（必須・ライトとダーク）

```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```

- 全て通す。変更を `DESIGN_DECISIONS.md` に追記。`nimble clean` 禁止。コミットしない。
- GUI スモークは不要（人間が実機で平滑スクロールと水平スクロールバーを確認する）。

## やらないこと

- frame_count/display-link/ダメージ描画の意味変更、Windows/Linux/headless 改変、
  command/contract/テスト破壊、`nimble clean`。
