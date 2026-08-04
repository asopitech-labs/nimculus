# Codex ブリーフ: タブバーを Zed に厳密整列

Zed と同じライトテーマで並べて比較した結果の差分を、Zed に合わせる。macOS のみ。
`DEVELOPMENT_GUIDELINES.md` 厳守。`nimble clean` 禁止。コミットしない。
主対象: `src/nimnui/platform/macos/macos_platform.m`（タブバー描画・ボタン）。

## Zed 基準の差分（実機・同ライトテーマ）

1. **戻る/進むアイコン**: 現状は山括弧 `chevron.left`/`chevron.right`。Zed は**矢印**。
   `arrow.left` / `arrow.right` に変更。ghost スタイル・サイズ・間隔は維持。
2. **アクティブタブの閉じる/未保存表示**: 現状はアクティブタブに `×` を常時表示。Zed は
   **未保存のとき `●`（ドット）**をファイル名の前後に出し、`×` は **hover 時のみ**。
   Nimculus も「dirty は `•`、`×` は hover 時のみ（アクティブでも非 hover なら × を出さない）」
   に合わせる。クリックの close ターゲット（hover 時）は維持。
3. **アクティブタブ上端の青アクセントバー**: 現状はアクティブタブ上端に 2pt の accent(青)
   バーを描いている。Zed にはこの青バーが無く、**白い浮き上がり背景のみ**で区別している。
   2pt 青バーを**削除**し、アクティブタブは面色（surface/白）と、必要なら極薄い境界のみで示す。
4. **パンくず左端の位置**: Zed のパンくずは戻るボタンのすぐ下・**タブ帯の最左**から始まる
   （タブラベルより左）。現状 Nimculus はタブ文字位置に合わせて右にインデントしている。
   パンくずの左端を Zed 同様、戻る/進むボタン列の左端（タブ帯左）に合わせる。

5. **タブのファイル名に拡張子を表示**: 現状タブは `DEVELOPMENT_GUIDELINES` と拡張子を
   落としている。Zed は `DEVELOPMENT_GUIDELINES.md` と**拡張子込み**で表示（幅超過は末尾
   truncation）。タブラベルを拡張子込みのファイル名にする。
6. **パンくずの内容を Zed 準拠に**: 現状は `プロジェクト名 › ファイル名`。Zed は
   `ファイル名.md › # 見出し › ## 小見出し …` と、カーソル位置の**見出し/シンボル階層**を
   出す。可能なら Nimculus も「ファイル名（拡張子込み）› カーソル行が属する見出し階層」に
   する（Markdown/コードの見出し・シンボルが取れない場合はファイル名のみにフォールバック）。
   最低でも先頭を「プロジェクト名」ではなく「ファイル名」にする。

## その他（アイコンの端・タブ文字位置の総点検）
- タブラベルの左パディング、`×`/`•` の位置、右側の new/split/zoom ボタンの端が Zed と揃うか
  確認し、ずれていれば Zed に合わせる。タブは内容幅を維持。
- 変更はライト/ダーク両テーマで自然なこと。分割ペイン・secondary タブも同様に。

## 検証（必須・ライトとダーク）
```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```
- 全て通す。`DESIGN_DECISIONS.md` に追記。`nimble clean` 禁止。コミットしない。
