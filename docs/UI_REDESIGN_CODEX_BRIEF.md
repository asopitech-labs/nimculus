# Codex 実装ブリーフ: Nimculus UI 再設計（Zed 準拠）

あなた（Codex）は Nimculus のデスクトップ UI を Zed に準拠させる再設計を実装する。
このブリーフは自己完結している。まず次を読むこと（正となる文脈）:

- `docs/UI_REDESIGN_ZED_ALIGNMENT.md` — 監査結果・目標デザイン・段階計画（本作業の設計書）
- `DEVELOPMENT_GUIDELINES.md` — 遵守すべき開発規約
- `docs/ZED_UI_ELEMENT_INVENTORY.md`, `docs/MACOS_WINDOW_BAR_INVENTORY.md` — UI 契約

対象は Apple Silicon macOS のみ。Windows/Linux コードには触れない。

## 決定事項（変更しない前提）

1. サイドバーは **Zed 既定の左配置** に寄せる。
2. **ライト + ダーク両テーマ対応**。
3. **P0 → P1 → P2 を順に全て実装**。各段の完了後に format/lint/test を通す。

## 主対象ファイル

- `src/nimnui/platform/macos/macos_platform.m`（約 12,000 行、UI 描画の中心）
- 必要に応じて `src/nimculus/workspace_ui.nim`（レイアウト/ヒットテスト契約）、
  `src/nimculus/editor_view.nim`, `src/nimnui/render.nim`, `src/nimnui/controls.nim`。
- レイアウト定数（`DefaultStatusHeight` 等）は `workspace_ui.nim`。

## 守るべき規約（DEVELOPMENT_GUIDELINES より）

- 依存方向を壊さない。OS 固有型（`NSView` 等）を NimNUI コアや editor core へ漏らさない。
  UI の見た目は macOS 層に閉じ込める。
- UI スレッド（Metal/AppKit）をブロックしない。描画は既存の dirty/paint 経路を維持。
- 検証出力は端末へ流し続けない。ログは `/tmp/nimculus-<目的>.log` にリダイレクトし、
  成功は要約・失敗は末尾のみ表示。
- 各テスト/ビルドは専用 `--nimcache`（既存の nimble タスクがこれを満たす）。作業後に
  一時 cache と生成バイナリを整理し、`git status --short` で生成物混入がないか確認。
- 整形は `nimble format`、静的検査は `nimble lint`。手で整形しない。
- 既存のアクセシビリティ（tooltip / accessibilityLabel）と command 経路を維持・拡張する。
  退行させない。
- 既存テストを壊さない。契約（タブ close、pane split、dock resize、hit-test）を保つ。

## P0: タブバー刷新（最優先・崩壊の除去）

対象: `macos_platform.m` の `NimculusTabBarOverlay`（`drawRect:` 約 L3862–3956、
`mouseDown:` 約 L3957 以降、`tabIndexAtPoint:`, `visibleTabRange`）。

やること:
1. `%lu/%lu` カウンタ（約 L3950–3953）を削除。
2. タブ数>1 で常時 160pt を予約する `navigationWidth = 160.0`（約 L3881）を廃止。
   予約バンドの塗り分け（約 L3918–3922、白 0.11）も廃止。
3. 均等割 `tabWidth = tabAreaWidth / visible`（約 L3885）を廃止し、**内容幅タブ**にする。
   ラベル幅は `sizeWithAttributes:` で測り、上限幅で truncation。可視領域を超えたら
   横スクロール（`visibleTabRange` を内容幅ベースへ改修）。
4. 手描きグリフ `‹ › ⌄ + ⇲ □`（約 L3930–3943）を廃止。代わりに右端へ**正規 NSButton**
   （SF Symbol + tooltip + accessibilityLabel）を配置する。既存の
   `styleWorkspaceNavigationButton` を再利用。対応付け:
   - 戻る/進む: `chevron.left` / `chevron.right`
   - Open Tabs（overflow メニュー）: `chevron.down`
   - 新規: `plus`
   - 分割: `square.split.2x1`
   - ズーム: `arrow.up.left.and.arrow.down.right`
   これらは既存の command 経路（`selectPaneTab`, overflow メニュー, split, zoom, new）へ
   接続する。手描き時代のヒットテスト分岐は NSButton 化に伴い整理する。
5. 閉じる `×` は **アクティブ or hover のみ**表示。dirty は `•`、hover で `×`。
   （hover 描画が無い場合は tracking area を追加。）非アクティブ常時 `×`（約 L3915）を廃止。
6. Zed の戻る/進むはタブバー**左端**に置く（現状は右塊）。

受け入れ: タブが内容幅で並び、予約空白と `2/41` が消え、右端コントロールが hover/tooltip を
持つ。`test_ui_text`, `test_workspace_ui`, タブ overflow 系テストが通る。

## P1: 上部クロムの 2 段化 + 浮遊アイコン収容 + 左サイドバー

1. 段順序を Zed に合わせる: 〔タイトルバー〕→〔タブバー〕→〔パンくず〕→ エディタ。
   現状の「パンくずがタブの上」を入れ替える。`editorTop`/`sidebarTop` 等の算出
   （約 L5666 の「28pt tab strip と 28pt breadcrumb」コメント周辺）を新順序へ更新。
2. タイトルバーのブランチを**軽いテキストボタン**にする（中央の重い pill を廃止、名前の
   隣に左寄せ）。`NimculusTitlebarView` / workspaceName 描画（約 L2452–2515）と
   ブランチボタンを整理。1 workspace 名・1 branch・1 breadcrumb を維持
   （`MACOS_WINDOW_BAR_INVENTORY.md` の検証条件）。
3. 宙に浮く Files アクション群（`NimculusFilesSidebarActions` 約 L4368–4415、
   Search/Git も同様）を、各**パネルヘッダー内**へ収容する。エディタ上部に浮かせない。
   アイコンは意味の通るものへ（例: Reveal Active File の `scope` は用途が伝わる SF Symbol
   へ再検討、または短ラベル併記）。tooltip/AX は維持。
4. **サイドバーを左配置に寄せる**: `g_editor_sidebar_on_right` の既定値と、それに依存する
   x 座標算出（約 L5665–5707 の `activityBarX`/`sidebarX`）、ヒットテスト
   （`workspace_ui.nim` の `presentedRegionAt`/`dockResizeDivider`/`dockResizeRequest` の
   `dockOnRight` 経路）を左基準へ整合させる。アクティビティバー＝最外左、Files パネル＝その内側。

受け入れ: 上部が 2 段（タイトルバー＋タブ、パンくずはタブ下）。ブランチ pill が消える。
Files/Search/Git アクションがパネルヘッダー内にある。サイドバーが左。
`test_macos_*`, `test_workspace_ui` が通る。

## P2: デザイントークン + 一貫性

1. デザイントークンを 1 か所に集約する（`macos_platform.m` 冒頭付近の定数群、または小さな
   ヘルパ）:
   - 間隔 `space1=4`, `space2=8`, `space3=12`、バー高 `rowHeight=28`、
     コントロール最小ヒット `controlHit=24`。
   - 役割色を `themeRoleColor` に集約: `chromeBg`, `tabBar`, `tabActive`, `border`,
     `fgPrimary`, `fgMuted`, `accent`。散在するリテラル（0.08/0.11/0.20/0.88 等、
     余白 4/8/10/21/34…）を token 参照へ置換。
2. **ライト + ダーク両対応**: 上記役割色を両テーマで定義。ハードコード白黒を撤去。
   `g_theme_*` 経路と整合。
3. アクティビティバー: 幅・アイコンサイズ・間隔を token 化し、Files パネルとの境界に
   `border` を入れて分離（約 L4549–4620, L5665）。
4. フッター（約 L4660 付近）: パンくずと重複する `main.nim` の要否を見直し、`LSP —` を
   `LSP: なし` 等の分かる表現へ。

受け入れ: 余白・色が token 経由。ライト/ダーク両方で崩れない。アクティビティバーが分離。

## 完了時の検証（必須）

各段の後、そして最後にまとめて:

```sh
nimble format  > /tmp/nimculus-format.log 2>&1 || { tail -n 40 /tmp/nimculus-format.log; }
nimble lint    > /tmp/nimculus-lint.log   2>&1 || { tail -n 60 /tmp/nimculus-lint.log; exit 1; }
nimble test    > /tmp/nimculus-test.log    2>&1 || { tail -n 80 /tmp/nimculus-test.log; exit 1; }
nimble build   > /tmp/nimculus-build.log   2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```

- 上記が全て通ること。UI 系（`test_ui_text`, `test_workspace_ui`, `test_macos_file_panels`,
  `test_macos_modal_sheets`, `test_macos_application_alert_sheet`,
  `test_platform_contract`, `test_platform_headless`）を特に確認。
- 実装した設計判断を `DESIGN_DECISIONS.md` に追記（採用理由・却下案・対応マイルストーン）。
- 触れた内容に応じて `ARCHITECTURE.md` / `docs/*INVENTORY.md` のチェック項目を更新。
- 生成物・一時 cache を整理し、`git status --short` に不要物が出ないこと。

## やらないこと

- 機能の新規追加（Zed の未実装機能の実装）。本作業は**見た目・レイアウト・アフォーどンスの
  整理**に限定する。
- Windows/Linux/headless バックエンドの改変（macOS のみ）。
- 既存の command 名・contract・テストの破壊。
- GUI 実機スモーク（`macosE2E` 等）の起動は不要。ヘッドレス test とビルドで受け入れる。

作業はコミットせず、変更を作業ツリーに残す（レビューは人間が行う）。
