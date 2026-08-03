# Codex ブリーフ: 横スクロールバー実描画 + 残留scrollXクランプ

実機で 2 つの不具合。macOS のみ。`DEVELOPMENT_GUIDELINES.md` 厳守。`nimble clean` 禁止。
コミットしない。

## 不具合 1: 全行の先頭 1 文字が一律クリップ（残留 scrollX 未クランプ）

no-wrap 既定で開くと、**内容がビューポートに収まる場合でも**全行の先頭 1 文字（≈8px 分）が
欠ける。原因は、以前の水平スクロールで付いた小さな `scrollX`（≈1 文字）が、可視内容が
ビューポート内に収まっても 0 へ再クランプされていないこと。

修正: レンダリング/同期の毎フレーム経路で、`g_editor_scroll_x`（primary/secondary）を
`clampEditorScrollX(scrollX, widestVisibleLineWidth, textViewportWidth)` で必ずクランプする
（＝最長可視行がビューポート以下なら scrollX=0）。macOS 側 `editorClampedScrollX` /
`editorMaxScrollX` は既にあるので、描画時に実際に適用されているか確認し、Nim の
`editorViewState.scrollX` にも反映（`platformEditorScrollX` 経由）してずれを無くす。
soft-wrap 時は既存どおり scrollX=0。

受け入れ: 短い行だけのビューで先頭文字が欠けない。長い行を左端まで戻すと先頭が完全に見える。

## 不具合 2: 横スクロールバーが実画面に描画されない

soft-wrap OFF かつ最長可視行 > ビューポートでも、下端に横スクロールバーが**描画されない**
（`horizontalEditorScrollbar` の thumb は単体テストで非空になるのに、実 Metal 描画で出ない）。
縦スクロールバー（同じ paint kind 10）は描画される。

診断してほしい点（どれかが原因のはず）:
1. 実行時に `editorWidestVisibleLineWidth()`（`g_editor_soft_wrap` の時 0）が実際に
   ビューポート超の値を返しているか。soft-wrap が意図せず true になっていないか。
2. 生成した水平スクロールバーの paint コマンド（kind 10、エディタ下端 y≈editorBottom-14、
   高さ 8）が、**エディタの scissor/クリップ矩形で切り落とされていないか**（縦バーは右端で
   scissor 内、横バーは下端で scissor 外、という非対称がありがち）。エディタ本文描画の
   scissor がスクロールバー帯（下端 14px）を含むよう調整するか、スクロールバー paint を
   本文 scissor の外で（フル editor rect の scissor で）描く。
3. `drawCurrentEditorScrollbars` が実レンダリングのたびに呼ばれ、paint list に確実に
   追加されているか。

一時的に `NIMCULUS_SCROLL_DEBUG`（getenv、1 回だけ）で
`widest/viewport/scrollX/hbar.track/hbar.thumb` を NSLog し、実行時の値を確認できるように
してよい（既定オフ・ホットパス毎回ログにしない）。原因を特定したら、**横スクロールバーが
実画面に確実に描画される**よう修正する（縦バーと同じ経路・scissor で描く）。

## 検証（必須）

```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```

- 全て通す。可能なら「本文 scissor が下端スクロールバー帯を含む」ことの回帰テストを追加。
  `DESIGN_DECISIONS.md` に追記。`nimble clean` 禁止。コミットしない。
