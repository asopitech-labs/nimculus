# Codex ブリーフ: プロジェクトパネル（Files）を Zed からクローン

ゴールは **Zed の UI/UX を完全再現**。今回はプロジェクトパネル（Nimculus の Files）。
Zed の実装は `references/zed/crates/project_panel/` と
`references/zed/assets/settings/default.json`、配色は `assets/themes/one/one.json`。
**値は必ずそこから読む（推測禁止）**。macOS のみ。`DEVELOPMENT_GUIDELINES.md` 厳守。
`nimble clean` 禁止。コミットしない。

## Zed の実値（取得済み）

`default.json` の `project_panel`:
```
default_width: 240   indent_size: 20   entry_spacing: "comfortable"
file_icons: true     folder_icons: true    git_status: true
hide_gitignore: false   auto_fold_dirs: true
```
One Light の関連色（ダークは同 JSON の Dark から同キーを取る）:
```
text #242529   text.muted #58585a   text.disabled #7e8086
element.selected #cacaca   element.hover #dfdfe0
ghost_element.selected #cacaca   ghost_element.hover #dfdfe0
panel.background #ebebec   border.variant #dfdfe0
ignored #7e8086
version_control.added #27a657  .modified #d3b020  .deleted #e06c76
```

## 現状 Nimculus の差分（実機比較）

1. **アイコンが無い**: Zed はフォルダにフォルダアイコン、ファイルに種別アイコン
   (`file_icons`/`folder_icons` = true)。Nimculus は `▸` と `≡`/`•` の記号だけ。
   → SF Symbols でフォルダ（開/閉）とファイル種別（既定 + 主要拡張子）のアイコンを出す。
   Zed の icon theme (`assets/icons/` と icon theme JSON) のマッピングを参照し、
   少なくとも「フォルダ / 既定ファイル / md / nim,rs,ts,py などコード / json / 画像」を出し分ける。
2. **gitignore 対象が減色されていない**: Zed は `.nimcache` や `build` を `ignored`
   (#7e8086) で淡く描く。→ ignore 判定（既存の workspace の gitignore 情報）を使い減色。
3. **git status 色が無い**: Zed は変更/追加/削除されたファイル名を version_control 色で描く。
   → 既存の Git サービスの status を使い、added/modified/deleted に色を付ける。
4. **インデント**: Zed は `indent_size: 20` で、インデントガイド線を引く。
   → 20pt インデント＋ガイド線（`border.variant`）にする。
5. **行間**: `entry_spacing: "comfortable"` に合わせて行の高さ/パディングを Zed と揃える。
6. **選択・ホバー**: 現状は濃い青紫の塗り。Zed は `element.selected` (#cacaca) /
   `element.hover` (#dfdfe0) の控えめなグレー。→ 役割色に置き換える。
7. **パネルヘッダー**: Zed はヘッダーに「📁 プロジェクト名」だけを出し、アクションは
   hover 時にだけ現れる。Nimculus は「Files」ラベル＋常時 4 アイコン。
   → ヘッダーをプロジェクト名（フォルダアイコン付き）にし、アクション群は hover 表示にする。
8. **パネル幅**: 既定 240pt（Zed の `default_width`）に合わせる。

## 検証（必須・ライトとダーク）
```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```
- 全て通す。**必ず `open build/macos/Nimculus.app` で実際に起動して確認**し、
  新しい `~/Library/Logs/DiagnosticReports/Nimculus-*.ips` が出ないこと（前回は起動
  クラッシュを見逃した）。
- 既存のツリー操作（選択・展開/折りたたみ・キーボード操作・コンテキストメニュー・
  Reveal・ドラッグ）を壊さない。`DESIGN_DECISIONS.md` に採用値を出典付きで記録。
- `nimble clean` 禁止。コミットしない。
