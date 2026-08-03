# Codex ブリーフ: フッター（ステータスバー）を Zed 準拠へ

macOS のみ。`DEVELOPMENT_GUIDELINES.md` 厳守（層分離・UI スレッド非ブロッキング・端末に
配慮したログ・専用 nimcache・`nimble format`/`nimble lint`・tooltip/AX 維持・既存テスト/
contract 不破壊）。`nimble clean` 禁止。コミットしない。主対象:
`src/nimnui/platform/macos/macos_platform.m` の `NimculusFooterOverlay`（L5021 付近）。

## Zed の実挙動（観察済み）

- **左**: dock トグル・AI・プロジェクト検索・**診断サマリ**（エラー/警告のアイコン＋件数、
  無ければ ✓）のアイコン status-item 群。
- **右**: `24:25`（カーソル行:列）・`Markdown`（言語）などの**クリック可能な text status
  ボタン**、続いてパネルトグルのアイコン列。

## 重要な適応（Zed をそのまま真似しない点）

Zed 右端の**パネルトグル**（terminal/debug/outline/collab/source-control/dock）は、
Nimculus では**左のアクティビティバー**が既に担っている。フッターへ重複配置しないこと。
フッターは「状態表示」に絞る。

## 現状（Nimculus）

- 左: `g_editor_status`（例「Git: 0 changed, 0 conflict(s)」）を素のテキスト描画。
- 右: `g_editor_footer` を `\t` 区切りで「Ln 1, Col 1 / Spaces: 2 / UTF-8 / LF / 言語」を
  右詰めテキスト描画（`·` 区切り、クリックで go to line / settings）。
- いずれも素の描画で、他クロムの ghost ボタン様式やアイコンと不統一。

## 目標フッター（Zed 準拠・Nimculus 適応）

高さ 24pt を維持。役割色 `statusBar`、デザイントークン（`space*`, `controlHit`）、
既存の `NimculusChromeButton`（ghost＋hover）を活用し、他クロムと統一する。

### 左クラスタ（アイコン status-item・左寄せ・ghost）

1. **診断サマリ**: `g_diagnostics`/`g_diagnostic_count` の severity を集計し、エラー数・
   警告数をアイコン＋件数で表示（例 `xmark.octagon`＋n / `exclamationmark.triangle`＋n）。
   0 件なら `checkmark`（Zed と同様に「問題なし」）。クリックで診断/Problems へ
   （既存 command 経路があればそれ、無ければ `commandPalette:` 相当）。
2. **Git**: source-control アイコン＋既存の Git 要約（`g_editor_status` を簡潔に。
   例「⑂ main · 3」）。クリックで Git パネルへ。テキストベタ描きをやめ、アイコン付きの
   コンパクト表示にする。
3. （任意）**LSP/language-server** 状態インジケータ（`LSP: なし`/接続中をアイコン化）。
   右の「LSP: なし」テキストはここへ移動して重複を避けてよい。

### 右クラスタ（クリック可能な text status・右寄せ・ghost）

- **カーソル位置**（`Ln 1, Col 1`。Zed 風に `1:1` へ簡潔化してもよい）→ go to line。
- **言語**（例 `nim`）→ 言語選択。
- **エンコーディング**（`UTF-8`）→ 設定。
- **改行コード**（`LF`）→ 設定。
- インデント（`Spaces: 2`）は任意で残す。各項目は ghost ボタン様式・hover 追従・tooltip/AX
  を持ち、既存のクリック command 経路を維持する（退行させない）。

## 制約

- 既存の情報とクリック先を失わない（診断・カーソル・言語・エンコーディング・改行・Git）。
- アクティビティバーのパネルトグルを重複させない。
- ライト/ダーク両方でコントラスト・整列が破綻しないこと。
- 右クリックメニュー（Status Bar Settings / Hide）は維持。

## 検証（必須・ライトとダーク両方）

```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```

- 全て通す。UI 系（`test_ui_text`, `test_workspace_ui`, `test_macos_file_panels`,
  `test_macos_modal_sheets`, `test_platform_contract`, `test_platform_headless`）を特に確認。
- 変更を `DESIGN_DECISIONS.md` に追記。`docs/*INVENTORY.md` のステータスバー項目を更新。
- `nimble clean` 禁止。コミットしない。
