# Codex ブリーフ: エディタ周辺レイアウトの整理（Zed 準拠）

実機で複数のレイアウト不具合。Zed のように**余計な線・余白がなく端が揃った**状態にする。
macOS のみ。`DEVELOPMENT_GUIDELINES.md` 厳守。`nimble clean` 禁止。コミットしない。
主対象: `src/nimnui/platform/macos/macos_platform.m`, `src/nimculus/main.nim`。

## 不具合（実機観察）

### A. 青いアクセント縦バー（最優先・目立つ）
タブ帯の下・エディタ本文の上にある**パンくず行の左端**に、明るい青（accent 色、`#4daafc`）の
**縦バー**が出ている。エディタ本文の**左下隅**にも同じ青い縦セグメントが見える。Zed には
こんな縦線は無い。原因の accent 色の矩形（drawRectangle/border/accent 系のどれか。paint の
accent 経路や、エディタ header/breadcrumb 背景の左端に描く要素）を特定し、**除去**する
(またはフォーカス表示なら Zed 同様に極めて控えめな 1px の `border` 色にする。accent 青の
太い縦線にはしない)。エディタ本文の枠 `paint.drawBorder(editor)`（main.nim 付近）も、左辺だけ
目立つならやめる/`border` 色の薄いものにする。

### B. パンくず左端の整列
パンくずラベル（native `context`）は `g_editor_rect[0] + 12.0` に置かれ、エディタ本文の
テキスト開始（`g_editor_rect[0] + 8`）やタブのラベル位置と**ずれている**。左端を本文テキスト
（およびタブラベル）と**同じ x** に揃える。上下の余白も詰める。

### C. エディタ周囲の余白
エディタ本文の周囲（タブ帯・パンくず・スクロールバー・フッターとの間、および Files パネル
との境界）に不自然な空きがある。Zed のように各要素が**隙間なく揃う**よう、`g_editor_rect`・
タブ帯・パンくず行・ガター・本文の x/y/inset を見直す。特に本文左（ガターと本文の間）と、
本文右（スクロールバー帯）の余白を Zed 相当に詰める。

### D. Files パネル下の余白
Files ツリーの最終要素の下に大きな空きがあり、パネル最下部で**背景色/帯のシェードが不一致**
（パネル背景が下端まで一様でない）。Files パネルの背景を下端まで一様にし、ツリー領域と
パネルの境界・下端の余白を Zed の Project パネル同様に自然にする。アクティビティバーと
Files パネルの下端も揃える。

## 進め方
- accent(青)の縦バーを最優先で除去（`g_theme_accent`/`accent` role を使う矩形描画のうち、
  breadcrumb/editor 左端に出るものを grep で特定）。caret（テキストカーソル）とは別物なので
  caret 描画は壊さないこと。
- 各要素の frame/inset 定数を Zed 準拠に調整し、端を揃える。ライト/ダーク両対応。
- 分割ペイン・welcome 画面・secondary エディタでも破綻しないこと。

## 検証（必須・ライトとダーク）
```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```
- 全て通す。`DESIGN_DECISIONS.md` に追記。`nimble clean` 禁止。コミットしない。
- frame 定数の回帰が難しければ、変更点を明記して人間の実機確認に回す。
