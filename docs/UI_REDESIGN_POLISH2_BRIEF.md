# Codex ポリッシュブリーフ（第3段）: Zed 準拠の視覚仕上げ

再設計（P0–P2）とヘッダーインライン化は実装・main へマージ済み。ここは Zed とライト/ダーク
同一テーマで突き合わせて残る**視覚忠実度**の 2 点を詰める。macOS のみ、
`DEVELOPMENT_GUIDELINES.md` 厳守（層分離・UI スレッド非ブロッキング・端末に配慮したログ・
専用 nimcache・`nimble format`/`nimble lint`・tooltip/AX 維持・既存テスト/contract 不破壊）。
`nimble clean` は使わない（`build/` を消すため）。コミットしない。

主対象: `src/nimnui/platform/macos/macos_platform.m`。

## 観察（Zed 実挙動・同一テーマ比較）

- Zed のタブバー/コントロールは **枠なし（ghost）**。戻る/進む・open-tabs・新規・分割・
  ズーム、パネルヘッダーのアクションは**静止時は背景なし**、hover 時のみ淡い背景。
- Zed のアクティブタブは **明確に浮き上がる**（周囲より明るい面色＋上端のアクセント）。
- Nimculus 現状: コントロールボタンが `foreground 0.08` の**常時背景ボックス**で重い
  （`styleWorkspaceNavigationButton` L444 付近）。アクティブタブは `tabActive` **0.20α の
  淡い tint のみ**（L4185 付近）で、特にライトで区別が弱い。

## 調整 A: コントロールを ghost 化（hover 追従）

`styleWorkspaceNavigationButton`（L444 付近）とサイドバーヘッダーのアクションボタンを対象に:

- **静止時は背景・境界なし（透明）**。アイコン/ラベルは既存の tint のみ。常時 0.08 の
  背景塗りを廃止。
- **hover 時のみ**淡い背景（`element`/`fgMuted` 系トークンで alpha 0.08–0.12 程度）と
  角丸（`NimculusSpace1`）を表示。マウス離脱で戻す。
- 実装は軽量な `NSButton` サブクラス（tracking area で `mouseEntered:`/`mouseExited:`)、
  または既存の hover 機構に倣う。タブの `hoveredTabIndex` 方式と一貫させてよい。
- **active 状態**（選択中の意味を持つボタン）は従来どおりアクセントで示す。
- tooltip・accessibilityLabel・command 経路・押下時の見た目は維持。全ボタン生成箇所に
  一貫適用（タブバー制御群、Files/Search/Git ヘッダーアクション、該当すればアクティビティ
  バー）。

受け入れ: 静止時にグレーのボックスが消え、hover で背景が出る。ライト/ダーク両方で自然。

## 調整 B: アクティブタブを Zed のように浮かせる

タブ描画（L4183–4207 付近）:

- アクティブタブの塗りを、淡い 0.20α tint から **面として読める背景**へ強める
  （`element`/`surface`/`tabActive` 系トークンで、tabBar 背景より明確に明るい/濃い面色。
  ライトでは白寄りに浮く、ダークでは一段明るい面）。
- アクティブタブ上端に **2pt のアクセントバー**（`accent` トークン）を描く（Zed 準拠）。
- 非アクティブ/hover の扱いは現状維持（hover は既存の `hoveredTabIndex`）。`×`/`•` の位置は
  維持。ライト/ダークで背景と前景のコントラストが確保されること。

受け入れ: アクティブタブが周囲から明確に浮き、上端アクセントで選択が一目で分かる。

## 検証（必須・ライトとダーク両方）

```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```

- 全て通す。UI 系テスト（`test_ui_text`, `test_workspace_ui`, `test_macos_file_panels`,
  `test_macos_modal_sheets`, `test_platform_contract`, `test_platform_headless`）を特に確認。
- 変更点を `DESIGN_DECISIONS.md` に追記。`nimble clean` 禁止。コミットしない。

## やらないこと

- 新機能・機能変更、Windows/Linux/headless 改変、command/contract/テストの破壊、
  `nimble clean`。
