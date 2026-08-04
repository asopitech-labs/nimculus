# Codex ブリーフ: コマンドパレット/ピッカーを Zed からクローン

ゴールは **Zed の UI/UX 完全再現**。今回はコマンドパレットと、同じ Picker 基盤を使う
Quick Open（ファイル検索）。Zed の実装は `references/zed/crates/command_palette/` と
`references/zed/crates/picker/`、行の見た目は `crates/ui/src/components/list_item.rs`、
配色は `assets/themes/one/one.json`。**値はそこから読む（推測禁止）**。macOS のみ。
`DEVELOPMENT_GUIDELINES.md` 厳守。`nimble clean` 禁止。コミットしない。

## Zed の構造（読むべき箇所）

- `Picker::uniform_list` による**中央配置モーダル**。ウィンドウ上部中央に浮かぶカード
  （`shape::Centered`）で、幅は既定シェイプ、高さは候補数に応じて上限まで伸びる。
- 行は `ListItem::new(ix).inset(true).spacing(ListItemSpacing::Sparse)`。
- 各行の右端に**キーバインド表示**（`KeyBinding::for_action_in`）。
- ラベルは `HighlightedLabel` で、**入力にマッチした文字がハイライト**される
  （fuzzy マッチ位置の強調）。
- 選択行は `element.selected`、hover は `element.hover`（One テーマの役割色）。
- 背景は `elevated_surface.background`、境界は `border`、影付き。

## 現状 Nimculus との差分

現状は `NimculusCommandPaletteOverlay`（NSComboBox ベース）で、Zed のような
中央モーダルカード・マッチ文字ハイライト・キーバインド右寄せ表示・inset 行が無い。

## 実装

1. **中央モーダルカード**にする: ウィンドウ上部中央、Zed と同じ角丸・影・
   `elevated_surface.background` + `border`。幅/高さ/上マージンは Zed の picker 既定に合わせる。
2. **行の見た目**: inset + Sparse 間隔、選択は `element.selected`、hover は `element.hover`。
3. **マッチ文字ハイライト**: 入力に対する fuzzy マッチ位置を強調表示（Zed の
   `HighlightedLabel` 相当。既存のファジー検索が返すマッチ位置を使う。無ければ
   前方一致/部分一致の位置で可）。
4. **キーバインドを各行の右端**に表示（Nimculus のショートカット定義から解決。
   無いコマンドは非表示）。
5. Quick Open（ファイル検索）にも同じピッカー体裁を適用する。
6. キーボード操作（↑↓/Enter/Esc）、既存コマンド実行経路、AX を維持。

## 検証（必須・ライトとダーク）
```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```
- **必ず `open build/macos/Nimculus.app` で起動確認**し、新しい
  `~/Library/Logs/DiagnosticReports/Nimculus-*.ips` が出ないこと。
- `DESIGN_DECISIONS.md` に採用した Zed の出典を記録。`nimble clean` 禁止。コミットしない。
