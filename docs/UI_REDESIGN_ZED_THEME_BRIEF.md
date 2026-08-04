# Codex ブリーフ: Zed の見た目を再現（背景色・行間・フォント）

ゴールは **Zed のライト/ダーク外観の忠実な再現**。Zed と同じ文書を並べて撮った実測差分を
埋める。macOS のみ。`DEVELOPMENT_GUIDELINES.md` 厳守。`nimble clean` 禁止。コミットしない。

参照実装がある: `references/zed`（Zed 本体のソース）。**テーマ定義（One Light / One Dark
など Zed 既定テーマの JSON/Rust 定義）と、エディタのフォント・行高の既定値を直接読み、
その値をコピーすること**。推測で色を決めない。

## 実測差分（ライト、同一文書・同一箇所）

1. **エディタ背景**: Zed はほぼ白（#FAFAFA 系）。Nimculus は灰色寄り（#D4D6D8 系）で
   明らかに暗い。→ Zed 既定ライトテーマの `editor.background` 等をそのまま採用。
2. **行間**: Zed は約 23px/行（ゆったり）。Nimculus は 18px/行（密）。→ Zed の
   `buffer_line_height`（既定 comfortable ≒ 1.618em 相当）とフォントサイズから算出した
   行高に合わせる。**注意**: Nimculus は 18px 行高が多数箇所にハードコードされ、カーソル・
   スクロール（scrollYPixels/scrollLine）・ヒットテスト・IME 矩形・行番号・git gutter・
   診断に波及する。単一の行高ソース（`platformEditorLineHeight` / `editorLineHeight()`）へ
   集約し、ハードコード 18 を排除してから値を変える。回帰させないこと。
3. **Markdown 見出しの強調**: Zed は `#`/`##` マーカーを淡色、見出しテキストを太字で描く。
   Nimculus は全て同一。→ syntax ハイライトの heading に weight/色を与える。
4. **フォント**: Zed の既定 buffer font（Zed Plex Mono / Zed Mono 系）と既定サイズに合わせる。
   同名フォントが無い環境では Zed のフォールバック順（等幅→システム等幅）に従う。和文が
   混在しても字送りが崩れないこと。

## 取得済みの Zed 実値（`references/zed` から抽出。これをコピーする）

既定（`references/zed/assets/settings/default.json`）:
- `buffer_font_family: ".ZedMono"`, `buffer_font_size: 15`,
  `buffer_line_height: "comfortable"`（= **1.618 倍** → 15 × 1.618 ≒ **24.3px**）
- `ui_font_size: 16`

**One Light**（`assets/themes/one/one.json`）:
```
background                    #dcdcdd    editor.background        #fafafa
editor.foreground             #242529    editor.gutter.background #fafafa
editor.active_line.background #ebebec bf elevated_surface         #ebebec
tab_bar.background            #ebebec    tab.active_background    #fafafa
tab.inactive_background       #ebebec    status_bar.background    #dcdcdd
title_bar.background          #dcdcdd    border                   #c9c9ca
text                          #242529    text.muted               #58585a
scrollbar.thumb.background    #383a41 4c (= 30% alpha)
```

**One Dark**:
```
background                    #3b414d    editor.background        #282c33
editor.foreground             #acb2be    editor.gutter.background #282c33
editor.active_line.background #2f343e bf panel/surface/elevated   #2f343e
tab_bar.background            #2f343e    tab.active_background    #282c33
tab.inactive_background       #2f343e    status_bar.background    #3b414d
title_bar.background          #3b414d    border                   #464b57
border.variant                #363c46    text                     #dce0e5
text.muted                    #a9afbc    text.accent              #74ade8
scrollbar.thumb.background    #c8ccd4 4c scrollbar.thumb.hover    #363c46
syntax: keyword #b477cf / string #a1c181 / comment #5d636f / function #73ade9
        type #6eb4bf / number #bf956a / title #d07277 (weight 400)
        emphasis.strong #bf956a (weight 700)
```
ライト側の syntax 色も同じ JSON の Light テーマから取得して使うこと。

## 追加の差分（行番号ガター・アクティブ行）

5. **行番号（ガター）のレイアウト**: Zed は行番号を**右揃え**でガター内に置き、ガターと
   本文の間に一定のパディングを取る（`editor.gutter.background` は本文と同色 = 継ぎ目なし）。
   Nimculus は行番号の位置・余白・整列が Zed と異なる。Zed 実装
   （`references/zed/crates/editor` のガター/行番号レイアウト）を参照し、ガター幅の算出
   （桁数依存）・右揃え・本文との間隔・ガター背景色（本文と同色）を合わせる。
   相対行番号や折り返し行のぶら下げがある場合も Zed の見え方に従う。
6. **アクティブ行ハイライト**: Zed はカーソル行の全幅に `editor.active_line.background`
   （One Light `#ebebec` bf / One Dark `#2f343e` bf ＝ 75% alpha）を敷き、行番号も強調する。
   Nimculus のアクティブ行表示（有無・色・範囲）を Zed に合わせる。カーソル（caret）自体の
   色・太さ・点滅も Zed に揃える。

## 実装方針

- `references/zed` から Zed 既定テーマ（ライト/ダーク）の**役割色を抽出**し、Nimculus の
  テーマ定義（`src/nimculus/settings.nim` の light/dark ThemeColors と、macOS 側の
  `themeRoleColor`/`themeTokenFallback` の既定）へ反映する。最低でも editor background /
  foreground / gutter / active line / panel / titleBar / tabBar / tabActive / statusBar /
  border / accent / scrollbarThumb を Zed 値にする。
- 行高は Zed の line-height 方式（font size × 係数）で計算し、単一ソースにする。
- 変更後、ライト/ダーク双方で「Zed と並べて」違和感がないこと。

## 検証（必須・ライトとダーク）
```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```
- 全て通す。行高変更はカーソル/選択/スクロール/ヒットテスト/IME の回帰テストを追加。
- `DESIGN_DECISIONS.md` に「Zed のどのテーマ/値を採用したか」を出典付きで記録。
- `nimble clean` 禁止。コミットしない。
