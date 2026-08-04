# Codex ブリーフ: ステータスバーを Zed からクローン

ゴールは **Zed の UI/UX 完全再現**。今回はステータスバー（フッター）。Zed の実装は
`references/zed/crates/zed/src/zed.rs`（項目登録）と各 crate。**値・書式はそこから読む**。
macOS のみ。`DEVELOPMENT_GUIDELINES.md` 厳守。`nimble clean` 禁止。コミットしない。

## Zed の実構成（`crates/zed/src/zed.rs` L635-649）

左（`add_left_item` の順）:
1. project search button, 2. lsp button, 3. diagnostic summary,
4. active file name, 5. git blame status, 6. merge conflict indicator,
7. activity indicator

右（`add_right_item` の順）:
1. edit prediction, 2. buffer encoding, 3. buffer language, 4. active toolchain,
5. line ending indicator, 6. vim mode indicator, 7. cursor position, 8. image info

### 各項目の見え方（Zed 実装）
- **診断サマリ**（`crates/diagnostics/src/items.rs`）: 問題ゼロなら `Check` アイコンのみ。
  それ以外は `XCircle` + エラー数、`Warning` + 警告数を small ラベルで並べる。
- **カーソル位置**（`crates/go_to_line/src/cursor_position.rs`）: `line:character` 形式
  （1 始まり。例 `24:24`）。複数選択時は選択数も出す。
- **言語 / エンコーディング / 改行コード**: それぞれクリックでセレクタを開くテキスト項目。

## 現状 Nimculus との差分
- 左: `✓ OK`（診断）/ Git / LSP を出しているが、Zed の並び順（検索→LSP→診断→ファイル名→
  blame→conflict→activity）と異なる。project search ボタンとファイル名が無い。
- 右: `Ln 1, Col 1` という独自書式。Zed は **`24:24`**（line:character）。
  並び順も Zed（encoding→language→toolchain→line ending→cursor）と異なる。
- 診断の見せ方が Zed（ゼロ時は Check のみ、非ゼロは XCircle+数/Warning+数）と異なる。

## 実装

1. **並び順を Zed に合わせる**。Nimculus に無い項目（edit prediction, vim mode, image info,
   toolchain）は該当機能が無ければ出さない。ファイル名は Zed 同様に左へ置く
   （パンくずと重複するが Zed がそうしているので合わせる）。
2. **カーソル位置を `line:character` 形式**にする（`Ln 1, Col 1` をやめる）。
   複数選択時は Zed と同じく選択数を併記。
3. **診断サマリを Zed の見せ方**にする（0 件 = Check アイコンのみ、エラー/警告は
   XCircle/Warning アイコン + 数値）。色は theme の error/warning。
4. project search ボタン（左端）を追加し、クリックでワークスペース検索を開く。
5. 既存のクリック経路・tooltip・AX・右クリックメニューは維持。ghost ボタン様式を維持。

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
