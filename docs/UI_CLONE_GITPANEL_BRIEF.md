# Codex ブリーフ: Git パネルを Zed からクローン

ゴールは **Zed の UI/UX 完全再現**。今回は Git パネル。Zed の実装は
`references/zed/crates/git_ui/`（`git_panel.rs` ほか）、配色は
`assets/themes/one/one.json`。**値・構成はそこから読む（推測禁止）**。macOS のみ。
`DEVELOPMENT_GUIDELINES.md` 厳守。`nimble clean` 禁止。コミットしない。

## Zed の構成（`crates/git_ui/src/git_panel.rs`）

- 各変更エントリの左に **Checkbox** があり、チェックでステージ/アンステージ。
- ヘッダーに **Stage All / Unstage All**、コンテキストメニューに
  Restore All Changes / Discard Tracked Changes / Trash Untracked Files / Stash 系。
- **コミットメッセージエディタ**がパネル下部にあり、コミットボタンと
  ブランチ/リモート表示を伴う（`commit_modal.rs` の展開エディタも参照）。
- エントリ行はファイル名＋ディレクトリパス（muted）、右に status を示す
  文字/色（added/modified/deleted、`version_control.*` の色）。
- 競合（conflict）は専用セクション/色。

## 実装

1. Nimculus の Git パネル（Changes）を、Zed 同様に
   **チェックボックス付きエントリ**にし、チェックでステージ/アンステージする。
2. ヘッダーに Stage All / Unstage All を Zed の位置・体裁で置く（既存のアクションを流用）。
3. 各行を「ファイル名 + muted なディレクトリパス + status 色」で描く
   （`version_control.added/modified/deleted` の色を使う）。conflict は専用扱い。
4. パネル下部に **コミットメッセージ入力とコミットボタン** を Zed 同様に配置する
   （既存のコミット経路を使う）。
5. 既存のコンテキストメニュー・キーボード操作・AX を維持し、Zed のメニュー項目に
   近づける（Restore/Discard/Stash が既存機能にあれば並べる）。
6. ライト/ダーク両対応。ghost ボタン様式・役割色に合わせる。

## 検証（必須・ライトとダーク）
```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```
- **必ず `open build/macos/Nimculus.app` で起動し、さらに Git パネルを実際に開いて
  操作（表示・チェック・スクロール）まで行い**、新しい
  `~/Library/Logs/DiagnosticReports/Nimculus-*.ips` が出ないことを確認する。
  （過去にパネルを開いた時だけ落ちるクラッシュを見逃した実績があるため、起動だけの
  確認では不十分。）
- `DESIGN_DECISIONS.md` に出典を記録。`nimble clean` 禁止。コミットしない。
