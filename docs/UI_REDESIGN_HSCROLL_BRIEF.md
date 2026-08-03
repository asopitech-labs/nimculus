# Codex ブリーフ: 水平スクロール + 横スクロールバー + no-wrap 既定（Zed 準拠）

目的: Zed 準拠にする。折り返しを既定 OFF にし、長い行を**水平スクロール**でき、エディタ下端に
**横スクロールバー**を出す。macOS のみ。`DEVELOPMENT_GUIDELINES.md` 厳守（層分離・UI スレッド
非ブロッキング・端末に配慮したログ・専用 nimcache・format/lint・tooltip/AX 維持・既存テスト/
contract 不破壊）。`nimble clean` 禁止。コミットしない。

## 現状（観察・コード確認済み）

- 既定 `softWrap = true`（`editor_view.nim` newEditorView、`session.nim:78` の復元既定も true）。
  折り返しは正しく動作する（ON で長い行が reflow する）。
- 折り返し OFF にすると長い行はクリップされる。**このとき水平スクロールが効かず、横スクロール
  バーも出ない**（実機で確認）。`g_editor_scroll_x` はグリフ描画（macos_platform.m L2405,
  選択 L2082, ヒットテスト等）に適用され、L4111 で `softWrap ? 0 : scroll_x` になっている。
- Nim 側ホイールハンドラは `not softWrap and abs(horizontalDelta) > 0.01` のとき
  `scrollX += horizontalDelta` する。`addEditorScrollbars`（main.nim）は
  `not softWrap and widestLineWidth > viewportWidth` のとき横バーを描く条件だが、実機で
  出ていない（`widestLineWidth` 推定が小さすぎる/描画位置の問題の可能性）。

## 実装（Zed 準拠）

### 1. 既定を no-wrap にする
- `editor_view.nim` newEditorView の `softWrap: true` → `false`。
- `session.nim` の `jsonBool(node, "softWrap", true)` → 既定 `false`（キー未保存の旧セッション
  でも no-wrap になる）。保存済みで明示的に true のセッションは尊重する。

### 2. 水平スクロールを実機で機能させる
- 折り返し OFF のとき、トラックパッド/ホイールの水平デルタ（`delta_x`）と、shift+縦ホイールの
  水平換算で `g_editor_scroll_x`（primary/secondary）を更新し、テキスト本文だけを左右に動かす。
  行番号ガター（`NimculusLineNumberOverlay`）は固定（横に動かさない）。
- `scrollX` を `[0, max(0, widestVisibleLineWidth - textViewportWidth)]` にクランプ。
  行の実ピクセル幅は Core Text 計測（既存の `editorTextOffset`/glyph 幅）で求める。
- カーソル・選択・ヒットテスト・IME 矩形は既に `- g_editor_scroll_x` を使うので整合を確認し、
  ずれがあれば直す。折り返し ON のときは `scrollX = 0` を維持。

### 3. 横スクロールバーを必ず出す（条件成立時）
- 折り返し OFF かつ「可視行の最大ピクセル幅 > テキストビューポート幅」のとき、エディタ下端に
  水平スクロールバーを描く。thumb 幅 = viewport/content 比、thumb 位置 = `scrollX`/maxScrollX。
  `widestLineWidth` は**実際に可視な行の Core Text 実測幅の最大**で求める（過小推定しない）。
- 縦バーと同時表示時は右下コーナーで重ならないよう調整。`scrollbarThumb`/`scrollbarHover`
  役割色でライト/ダーク両対応。ドラッグでスクロールできると尚良い（最低限クリックで移動）。
- 縦スクロールバーの thumb は既存の連続位置ロジックを維持。

### 4. その他
- 分割ペイン（secondary）でも水平スクロール・横バーが独立に動くこと。
- フレーム計数/display-link/ダメージ描画のセマンティクスは不変。再描画は既存 `requestRedraw`
  経路を使う。

## 検証（必須・ライトとダーク）

```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```

- 全て通す。水平スクロール・横バーの回帰テストを追加（scrollX がクランプされ、条件成立時に
  横バー矩形が生成されること）。変更を `DESIGN_DECISIONS.md` に追記。`nimble clean` 禁止。
  コミットしない。

## やらないこと
- frame_count/display-link/ダメージ描画の意味変更、Windows/Linux/headless の機能改変、
  command/contract/テスト破壊、`nimble clean`。
