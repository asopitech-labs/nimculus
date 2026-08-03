# Nimculus UI 再設計仕様（Zed 準拠）

このドキュメントは、Zed の実 UI と現行 Nimculus ビルドの実画面を突き合わせて行った
UI/UX 監査と、Zed を踏襲するための再設計仕様・段階的実装計画である。設計フェーズの成果物
であり、実装は `nimculus-ui-dev`、検証は `nimculus-ui-test` に引き継ぐ。根拠は
`DEVELOPMENT_GUIDELINES.md` / `docs/ZED_UI_ELEMENT_INVENTORY.md` /
`docs/MACOS_WINDOW_BAR_INVENTORY.md`。

## 1. 監査の方法

- Zed（`/Applications/Zed.app`）を本リポジトリで開き、実 UI を撮影（リファレンス）。
- 最新ビルド（`nimble build`）を `build/macos/Nimculus.app` に差し替え・ad-hoc 署名して
  起動し、実 UI を撮影（現状）。
- 「意味不明なアイコン列・ズレ・不自然な予約」の発生源を描画コードで特定。主因は
  `src/nimnui/platform/macos/macos_platform.m`（約 12,000 行）に集中。

## 2. Zed の構造（リファレンス／観察結果）

Zed のクロムは **2 段** で、各要素が意味を持ち余白が一定:

1. **タイトルバー**: 信号機 → プロジェクト名 → ブランチ（軽いテキスト、左寄せ・pill 背景なし）。
   右端に補助（Update/Sign In）。
2. **タブバー**: 左に戻る/進む（`←` `→`）→ **内容幅のタブ**（1 つだけなら 1 つ分の幅）→
   右端に `+`（新規）・分割・ズームの少数ボタン。
3. **パンくず行**: `path › section › subsection`。右端に preview/検索/format の少数アイコン。
4. **エディタ本体**。
5. **ステータスバー**: 左に dock トグル/AI/検索/診断、右に `24:25`（行:列）・`Markdown`（言語）・
   少数のトグル。

要点: 予約された空きバンドがない／タブは内容幅／コントロールは真の hover・tooltip 付き
ボタン／情報は 1 か所にのみ出す。

## 3. 現状 Nimculus の欠陥（観察 + コード対応）

### 3.1 タブバー（最も崩壊、`macos_platform.m` L3862–3956）

| 症状 | 原因（コード） |
| --- | --- |
| `2/41` の謎カウンタが左上に重なる | L3950–3953 `%lu/%lu` を手描き |
| `‹ › ⌄ + ⇲ □` が別背景で詰め込まれ、正体不明 | L3930–3943 **テキストグリフを手描き**（オフセット 8/29/52/70/33/59 のマジック数）。hover も tooltip もない |
| タブ数>1 で常に 160pt を予約（不自然な空き） | L3881 `navigationWidth = 160.0` 固定 |
| README と main の幅が同じで、ラベルと `×` が乖離 | L3885 `tabWidth = tabAreaWidth / visible`（均等割） |
| 非アクティブタブにも `×` 常時表示で雑然 | L3915 常時描画 |
| ナビ塊の背景だけ暗い block でギザつく | L3918–3922 白 0.11 で塗り分け |

### 3.2 上部クロムの段構成

- 現状は **タイトルバー → パンくず行 → タブ行** の **3 段**。Zed は 2 段（タブが先、
  パンくずが後）。段が 1 つ多く、順序も逆。
- ブランチが **タイトルバー中央に重い pill** で浮く（Zed は名前の隣に軽いテキスト）。

### 3.3 宙に浮くアイコン群（行 2 右端、L4368–4415 ほか）

- Files パネル用アクション（New File=`document.badge.plus` / New Folder=`folder.badge.plus`
  / Reveal Active File=`scope` / Collapse All=`rectangle.compress.vertical`）が
  **パネルヘッダーから切り離されて宙に浮く**。tooltip はあるがアイコン単体では意味不明
  （特に `scope`＝照準、`rectangle.compress`）。

### 3.4 アフォーダンスの不統一

- タブ側 = 手描きテキストグリフ（hover/tooltip/AX なし）。
- サイドバー側 = 正規 NSButton + SF Symbol（tooltip/AX あり）。
- 2 系統が混在し、見た目も操作感も割れている。**これが崩壊の主因。**

### 3.5 アクティビティバー（右端、L4549–4620 / L5665 `activityBarWidth=38`）

- 右端 30–38pt の細い縦列にアイコンを詰め込み。Files パネルとの境界で窮屈。

### 3.6 相対的に妥当な箇所

- ステータスバー（L4660 付近）は `main.nim · Ln 1, Col 1 · Spaces: 2 · UTF-8 · LF · nim ·
  LSP —` と Zed 相当。ただし `main.nim` はパンくずと重複、`LSP —` は難解。

## 4. 根本原因

1. **手描きグリフ + マジックナンバー**でコントロールを配置している（真のボタンでない）。
2. **内容に依存しない固定予約**（160pt バンド、均等割タブ）。
3. **情報の二重化**（ファイル名がタブ・パンくず・フッターに散在）。
4. **単一のデザイントークンが無い**（余白 4/8/10/21/34…、色 0.08/0.11/0.20 が個別散在）。

## 5. 目標デザイン（Zed 準拠）

### 5.1 デザイントークン（新設）

余白・色・寸法を 1 か所に集約（`macos_platform.m` 冒頭の定数 or 小さな C ヘッダ）。

- 間隔: `space1=4`, `space2=8`, `space3=12`。
- バー高: `rowHeight=28`。コントロール: `controlHit=24`（最小ヒット領域）。
- 役割色: `chromeBg`, `tabBar`, `tabActive`, `border`, `fgPrimary`, `fgMuted`, `accent`
  を `themeRoleColor` に集約（既存の関数を活用）。

### 5.2 上部クロムを 2 段へ

1. **タイトルバー**: 信号機 → プロジェクト名 → ブランチ（軽いテキストボタン、pill 廃止）。
   右端は既存の補助のみ。
2. **タブバー**: 左に戻る/進むボタン → **内容幅タブ**（`sizeToFit`、上限幅で truncation）→
   右端に `+`・分割・ズームの**正規 NSButton（SF Symbol + tooltip + AX）**。
3. **パンくず行はタブの下**（Zed 準拠）。パンくず右端に preview/検索/format の少数ボタン。

### 5.3 タブモデルの修正

- 均等割をやめ **内容幅**。可視領域を超えたら横スクロール（Zed のスクロール式）。
- `×` は **アクティブ or hover のみ**表示。dirty は `•`、hover で `×` に変わる。
- `2/41` カウンタと 160pt 固定予約を**削除**。overflow は右端の `⌄`（Open Tabs メニュー）
  だけで表現。

### 5.4 コントロールをボタンへ統一

- 手描きの `‹ › ⌄ + ⇲ □` を廃し、既存の `styleWorkspaceNavigationButton` 系の
  NSButton + SF Symbol に統一（`chevron.left/right`, `chevron.down`, `plus`,
  `square.split.2x1`, `arrow.up.left.and.arrow.down.right`）。hover/tooltip/AX を得る。

### 5.5 宙に浮くアイコンをヘッダーへ収容

- Files/Search/Git のアクション群は各**パネルヘッダー内**に置く（Zed 準拠）。
  エディタ上部に浮かせない。アイコンは意味の通るものへ（Reveal=`scope`→`sidebar.left`
  等は要検討、または短ラベル併記）。

### 5.6 アクティビティバー

- 幅・アイコンサイズ・間隔を token 化し、Files パネルとの境界に `border` を入れて分離。
  配置（右/左）は現状の `g_editor_sidebar_on_right` 契約を維持。

### 5.7 情報の重複解消

- ファイル名はパンくずを正とし、フッターの `main.nim` は撤去可否を検討。`LSP —` は
  `LSP: なし`/アイコン化。

## 6. 段階的実装計画（各段で format/lint/test）

- **P0（崩壊の除去・最優先）**: タブバー刷新。`2/41`・160pt 予約・均等割・手描きグリフ塊を
  除去し、内容幅タブ + 右端 NSButton 群 + hover `×` へ。→ 見た目の破綻が最も減る。
- **P1（段構成）**: 上部クロムを 2 段化（パンくずをタブ下へ、ブランチ pill 廃止）。宙に浮く
  Files アクションをパネルヘッダーへ移設。
- **P2（一貫性）**: デザイントークン導入で余白・色を集約。アクティビティバーの境界・寸法整理。
  フッターの重複/難解表現を整理。

各段の受け入れ:
- `nimble format` / `nimble lint` / 関連 `nimble test`（`test_ui_text`, `test_workspace_ui`,
  `test_macos_*`）を通す。
- GUI 実機で撮影し、Zed と段構成・余白・タブ幅・コントロールの hover/tooltip を突き合わせる。
- `docs/MACOS_WINDOW_BAR_INVENTORY.md` / `docs/ZED_UI_ELEMENT_INVENTORY.md` の
  チェックを再確認（1 workspace 名・1 branch・1 breadcrumb、tooltip/AX の有無）。
- 変更を `DESIGN_DECISIONS.md` に記録。

## 7. 確定事項（ユーザー決定）

1. **サイドバー配置は Zed 既定（左）へ寄せる。** `g_editor_sidebar_on_right` の既定を左に
   し、アクティビティバー・Files パネル・エディタの左右関係を Zed に合わせる。ヒットテスト
   （`presentedRegionAt` ほか）とリサイズ方向を配置に整合させる。
2. **ライト + ダーク両対応。** 役割色を `themeRoleColor` に集約し、両テーマで検証する。
   ハードコードの白/黒リテラルはトークン化する。
3. **P0–P2 を通しで実装する。**

実装は Codex CLI に委譲する（`docs/UI_REDESIGN_CODEX_BRIEF.md` を参照）。
