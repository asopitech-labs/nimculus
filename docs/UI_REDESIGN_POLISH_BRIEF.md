# Codex ポリッシュブリーフ: Nimculus UI 調整（Zed 準拠・第2段）

P0–P2 の再設計（`docs/UI_REDESIGN_ZED_ALIGNMENT.md`）は実装・コミット済み。ここでは
Zed と突き合わせて残る視覚的ズレを詰める。対象は macOS のみ、`DEVELOPMENT_GUIDELINES.md`
を厳守（層分離・UI スレッド非ブロッキング・端末に配慮したログ・専用 nimcache・
`nimble format`/`nimble lint`・tooltip/AX 維持・既存テストと contract を壊さない）。

主対象: `src/nimnui/platform/macos/macos_platform.m`。

## 基準（Zed の実挙動・観察済み）

- **パネルヘッダーは単一行**。プロジェクト/パネル名（例「Files」）＋アクションは同一行に
  右寄せ。アクションを名前の**上に別行**で浮かせない（現状 Nimculus はここが崩れている）。
- タブは内容幅、コントロールは正規ボタン（実装済み・維持）。
- 行の高さ・余白は一定（トークン化済み・維持/活用）。

## 調整項目

### A. パネルヘッダーのアクションをインライン化（最優先）

現状、`NimculusFilesSidebarActions`（および Search/Git の対応アクション群）が Files パネルの
**タイトル行の上に独立した行**として配置され、宙に浮いて見える。これを Zed のように
**パネルヘッダーのタイトルと同一行・右寄せ**へ収める。

- Files パネルヘッダー行 = 左に「Files」（またはプロジェクト名）、右端にアクション
  （New File / New Folder / Reveal Active File / Collapse All）を 24pt の正規ボタンで
  右寄せ配置。タイトルの上の別行は廃止。
- Search / Git（Changes）パネルも同様に、各ヘッダーのタイトル行右端へアクションを収める。
- 配置の x/y はハードコードのマジック数ではなく、確立済みのトークン（`space1/2/3`,
  `rowHeight`, `controlHit`）と NSStackView の右寄せで求める。
- tooltip と accessibilityLabel、既存 command 経路は維持。

### B. アイコンの可読性

- Reveal Active File の `scope` は用途が伝わりにくい。より意味の通る SF Symbol へ差し替える
  （候補: `scope`→`location.magnifyingglass` など、tree 内で現在ファイルを探す意味が伝わるもの）。
  最終判断は任せるが、tooltip は「Reveal Active File」を保持。
- 他のヘッダー/アクティビティバーアイコンも 24pt で潰れず判別できるか確認し、必要なら
  weight/size をトークンに合わせて調整。

### C. Zed との最終突き合わせ（一般調整）

以下を Zed と比べ、明確なズレがあれば詰める（過剰な作り込みは不要、崩れの除去が目的）:

- タブの左右パディング・アクティブタブのアクセント・`×`/`•` の位置が均一か。
- タイトルバー（プロジェクト名＋ブランチ）→ タブ → パンくず の行高・余白が一定か。
- アクティビティバーと Files パネルの境界 `border`、フッターの項目間隔。
- ライト/ダーク両方で、上記すべてがコントラスト・整列ともに破綻しないこと。

## 検証（必須）

```sh
nimble format  > /tmp/nimculus-fmt.log   2>&1
nimble lint    > /tmp/nimculus-lint.log  2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log  2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```

- 全て通すこと。UI 系テスト（`test_ui_text`, `test_workspace_ui`, `test_macos_file_panels`,
  `test_macos_modal_sheets`, `test_platform_contract`, `test_platform_headless`）を特に確認。
- 変更点を `DESIGN_DECISIONS.md` に追記。触れた項目は `docs/*INVENTORY.md` のチェックも更新。
- 生成物・一時 cache を整理。`nimble clean` は使わない（`build/` を消さない）。
- コミットしない。変更は作業ツリーに残す（人間がレビュー・コミットする）。

## やらないこと

- 新機能追加、Windows/Linux/headless の改変、command 名や contract・テストの破壊。
- `nimble clean`（`build/macos/Nimculus.app` を破壊するため使用禁止）。
