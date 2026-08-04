# Codex ブリーフ: Outline パネルと Diagnostics を Zed からクローン

ゴールは **Zed の UI/UX 完全再現**。今回は Outline パネル（シンボル一覧）と
Diagnostics 表示。Zed の実装は `references/zed/crates/outline_panel/`,
`references/zed/crates/outline/`, `references/zed/crates/diagnostics/`。
配色は `assets/themes/one/one.json`。**値はそこから読む（推測禁止）**。macOS のみ。
`DEVELOPMENT_GUIDELINES.md` 厳守。`nimble clean` 禁止。コミットしない。

## Zed の構成

### Outline パネル（`crates/outline_panel/src/outline_panel.rs`）
- 各行は `ListItem` + `HighlightedLabel`、**インデントガイド**（`IndentGuideColors` /
  `IndentGuideLayout`）でシンボル階層を示す。
- パネル上部に **シンボル検索フィールド**（placeholder "Search buffer symbols…"）。
- シンボル種別ごとの **アイコン**（`IconName`）。
- スクロールバー（`Scrollbars` / `WithScrollbar`）。

### Outline ピッカー（`crates/outline/src/outline.rs`, Cmd+Shift+O）
- `ListItem::new(ix).spacing(ListItemSpacing::Sparse)` に `StyledText` で
  シンボル名を階層インデント付きで表示。マッチ文字ハイライトあり。

### Diagnostics（`crates/diagnostics/`）
- 診断は severity ごとの色/アイコン（error/warning/info/hint）。
- エディタ内は波線（squiggly underline）＋行末やホバーでメッセージ。

## 実装

1. **Outline パネル**: 行を Zed 体裁（インデントガイド＋シンボル種別アイコン＋
   選択/hover の役割色）にし、上部にシンボル検索フィールドを置く。
   既存の Outline データ（syntax のシンボル）をそのまま使う。
2. **Outline ピッカー**（あれば）: コマンドパレットと同じ picker chrome に揃え、
   シンボル階層のインデントとマッチ強調を出す。
3. **Diagnostics**: severity ごとの色を Zed のテーマ役割色（error/warning/info/hint）に
   合わせ、エディタ内の下線表現を Zed と同じ見え方（波線）にする。
   診断パネル/リストがあれば、行の体裁も Zed に合わせる。
4. ライト/ダーク両対応。既存のキーボード操作・ジャンプ経路・AX を維持。

## 検証（必須・ライトとダーク）
```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```
- **必ず `open build/macos/Nimculus.app` で起動し、Outline パネルを実際に開いて
  スクロール・選択まで行う**こと。新しい
  `~/Library/Logs/DiagnosticReports/Nimculus-*.ips` が出ないことを確認する。
- `DESIGN_DECISIONS.md` に出典を記録。`nimble clean` 禁止。コミットしない。
