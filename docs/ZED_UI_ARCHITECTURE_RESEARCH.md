# Zed UI アーキテクチャ調査

調査日: 2026-07-29

この文書は、Nimculus の UI 実装を再開する前に行った Zed の一次調査記録である。
Zed に似せた見た目の部品を追加するためではなく、ユーザー操作から状態遷移、描画、
フォーカス、永続化までを一つの機能として設計するために用いる。

## 調査対象

- `references/zed/crates/workspace/src/workspace.rs`
- `references/zed/crates/workspace/src/dock.rs`
- `references/zed/crates/workspace/src/pane.rs`
- `references/zed/crates/workspace/src/pane_group.rs`
- `references/zed/crates/workspace/src/status_bar.rs`
- `references/zed/crates/workspace/src/multi_workspace.rs`
- `references/zed/crates/project_panel/src/project_panel.rs`
- [Zed glossary](https://zed.dev/docs/development/glossary)
- [Zed panel system](https://zed.dev/blog/new-panel-system)
- [Zed project-panel settings](https://zed.dev/docs/reference/all-settings)
- [Zed key-context documentation](https://zed.dev/docs/key-bindings)

## Zed の構造

Zed の中心概念は次のとおりである。

```text
MultiWorkspace
└── Workspace
    ├── Left Dock  ── Panel*  （Project Panel など）
    ├── Center     ── PaneGroup ── Pane* ── Item/Editor*
    ├── Right Dock ── Panel*
    ├── Bottom Dock ─ Panel*  （Terminal Panel など）
    ├── Status Bar
    └── Modal / Toast layers
```

- `Pane` は編集対象の `Item` をタブとして所有する。選択中アイテム、プレビュー、
  履歴、フォーカス、タブ操作はPaneの状態である。
- `PaneGroup` はPaneの再帰的な分割木である。分割方向、各子のflex、境界ボックスを
  所有する。単一ファイルの「二つ目のビュー」を持つだけではない。
- `Dock` はPaneとは別の開閉可能領域で、複数の `Panel` を登録できる。アクティブ
  Panel、開閉、リサイズ状態、フォーカスを所有する。
- `ProjectPanel` は表示文字列ではない。選択、複数選択、展開、インライン編集、
  ドラッグ先、スクロール、診断、Git状態を所有する状態機械である。
- `StatusBar` は単なる文字列ではない。左右それぞれの操作可能な状態項目を保持し、
  フォーカス可能なツールバーとして描画する。

## 操作契約

Zedは、UI部品のクリックとキーボード操作を同じアクションへ接続する。

| ユーザー操作 | 状態遷移 | 表示結果 |
| --- | --- | --- |
| Project Panelボタン | Dockを開く／閉じる、またはPanelへフォーカス | Project Panelが選択状態で表示される |
| ファイル行を選択 | ProjectPanelの選択状態を更新 | 行の選択・Git・診断表示が更新される |
| ファイルを開く | 対象PaneのItem集合とactive itemを更新 | タブと編集面が更新される |
| タブを選択 | Paneのactive itemを更新 | 編集面、状態バー、フォーカスが更新される |
| 分割 | PaneGroupの木を更新 | 両Paneに独立したタブ・フォーカス・スクロールが現れる |
| ターミナルボタン | Bottom DockのTerminal Panelを開く／閉じる | ターミナルPanelとそのフォーカスが更新される |
| Dock境界をドラッグ | DockのPanelSizeStateを更新・保存 | 幅または高さが連続的に変わる |

この契約により、メニュー、ショートカット、クリック、コマンドパレットが同じ状態遷移を
使う。Zedのkey contextも `Workspace > Dock > ProjectPanel` と
`Workspace > Pane > Editor` を区別する。

## 視覚レイアウトから得る要件

Classic editor layoutでは、Project Panelは通常左Dockにあり、既定幅は240pxである。
ただし固定の座標ではなく、Dockの状態としてリサイズ・永続化される。Centerは残余領域を
PaneGroupへ渡し、Bottom DockはCenterと左右Dockのどこまでを占めるかをレイアウト設定で
決める。境界線、Panel背景、Editor背景、Status Bar背景はテーマの別トークンである。

したがってNimculusで必要なのは、余白で囲んだ「ファイラ風の領域」ではない。以下が
最低要件になる。

1. 左Dock、Center、Bottom Dock、Status Barを別領域として定義する。
2. 各領域の可視性、サイズ、フォーカス、選択中コンテンツを状態として持つ。
3. 表示はその状態の投影とし、表示文字列を状態の正本にしない。
4. 各領域のUI要素に、クリック可能なhit target、選択状態、ホバー、キーボード操作、
   結果のフィードバックを与える。
5. 描画フレームワークとAppKit補助ビューの座標系・重なり順を一つの責務に集約する。

## Nimculus 現状との差分

現状の `main.nim` は、`EditorSidebarMode` と一つの文字列サイドバーへ、Files、Outline、
Git history、Git status、Git branchesを排他的に詰め込んでいる。タブは
`EditorSession`、分割は単一ドキュメントのsecondary view、ターミナルは可視フラグである。
この構造では次を正しく表現できない。

- ファイラを開いたままGit PanelやOutlineを切り替える
- Paneごとに異なるファイル集合・アクティブタブ・履歴を持つ
- Dockの開閉とフォーカス復帰
- ドラッグ可能で永続化されるDockサイズ
- 状態バー項目ごとの操作とキーボードフォーカス

## Nimculus 向けの最初の設計境界

実装開始前に、少なくとも次のNimNUI側モデルを決める。

```text
WorkspaceUiState
├── leftDock: DockState
│   └── activePanel: files | git | outline
├── bottomDock: DockState
│   └── activePanel: terminal | taskOutput
├── center: PaneTree
│   └── PaneState* (tabs, activeTab, view state, focus)
├── status: StatusState
└── transient: hover / drag / modal / focused region
```

`WorkspaceUiState` はアプリケーション層にあり、CocoaやMetal型を含めない。NimNUIは
この状態をレイアウトと描画へ投影し、pointer／keyboardイベントをアプリケーションの
アクションへ戻す。macOS固有のメニューとショートカットは同じアクションをdispatchする。

## 実装を開始してよい条件

次の全てを設計レビューで確定するまで、画面部品を追加しない。

- Dock、Panel、Pane、PaneTree、StatusのNimデータモデル
- 開閉、選択、フォーカス、リサイズ、永続化のアクション一覧
- 各アクションの入力元と表示上のフィードバック
- Metal/NimNUI/AppKitの描画責務と座標系
- ファイラ、エディタ、Git履歴、ターミナルを含む実機E2Eシナリオ
