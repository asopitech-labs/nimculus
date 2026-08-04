# Codex ブリーフ: 検索 UI を Zed からクローン

ゴールは **Zed の UI/UX 完全再現**。今回はバッファ内検索（Find）とワークスペース検索
（Project Search）。Zed の実装は `references/zed/crates/search/`（`buffer_search.rs`,
`project_search.rs`, `search_bar.rs`）、配色は `assets/themes/one/one.json`。
**値・アイコン・トグル構成はそこから読む（推測禁止）**。macOS のみ。
`DEVELOPMENT_GUIDELINES.md` 厳守。`nimble clean` 禁止。コミットしない。

## Zed の構成（読むべき箇所）

`crates/search/src/buffer_search.rs`:
- 検索フィールドの右側に **SearchOption トグル**: Case Sensitive / Whole Word / Regex
  （`SearchOption::CaseSensitive.as_button(...)` など。IconButton 形状）
- 前/次マッチ（`SelectPreviousMatch` / `SelectNextMatch`）、全選択（`SelectAllMatches`）
- Replace トグル（`ToggleReplace`）で置換フィールドを開き、`ReplaceNext` / `ReplaceAll`
- マッチ件数表示（"n of m" 相当）
- 履歴（`PreviousHistoryQuery` / `NextHistoryQuery`）

`crates/search/src/project_search.rs`: 上記に加えて
- フィルタ切り替え（`toggle_filters`）で include/exclude パターン入力
- `ToggleIncludeIgnored`（gitignore 対象も検索）

## 実装

1. Nimculus の Find バー / ワークスペース検索パネルに、Zed と同じ
   **Case Sensitive / Whole Word / Regex のトグルボタン**を置く（アイコンは Zed の
   IconName に対応する SF Symbols、トグル状態は accent で示す）。既存の検索ロジックに
   これらのオプションを接続する（無ければ実装する）。
2. **前/次マッチ**ボタンとマッチ件数表示（"n of m"）を Zed と同じ位置・体裁で出す。
3. **Replace トグル**と置換フィールド、Replace Next / Replace All を Zed 同様に。
4. ワークスペース検索には **include/exclude フィルタ**と **Include Ignored** を追加。
5. 見た目は既存の ghost ボタン様式とテーマ役割色に合わせる（ライト/ダーク両対応）。
6. 既存のキーボード操作・コマンド経路・AX を壊さない。

## 検証（必須・ライトとダーク）
```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```
- **必ず `open build/macos/Nimculus.app` で起動確認**し、新しい
  `~/Library/Logs/DiagnosticReports/Nimculus-*.ips` が出ないこと。
- 検索オプション（case/word/regex）の回帰テストを追加。
- `DESIGN_DECISIONS.md` に出典を記録。`nimble clean` 禁止。コミットしない。
