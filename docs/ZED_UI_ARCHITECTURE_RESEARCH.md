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

## 追加調査: Pane と macOS 描画の境界（2026-07-29）

次の縦切りを実装する前に、PaneGroup と macOS の描画・入力契約を再確認した。

### 一次資料

- `references/zed/crates/workspace/src/pane_group.rs`
  - `PaneGroup::split` は、対象Paneを持つ木の位置を置換する。
  - `Member::render` / `PaneAxis::render` は木を再帰的に描画し、各Paneに固有の
    active状態を渡す。
  - PaneAxisは各子の境界ボックスとflexを保持し、hit testとリサイズにも同じ木を使う。
- `references/zed/crates/workspace/src/pane.rs`
  - Paneはタブ、アクティブItem、フォーカスを所有する。分割は同じ画面を二枚並べる
    表現ではない。
- `references/zed/crates/workspace/src/dock.rs`
  - DockはPanelの登録、開閉、アクティブPanel、サイズを所有し、Panelの表示文字列を
    状態の正本にしない。
- [Apple: Managing your game window for Metal in macOS](https://developer.apple.com/documentation/metal/managing-your-game-window-for-metal-in-macos)
  - AppKitのレイアウトはpointで扱い、`CAMetalLayer.drawableSize`だけを
    `convertSizeToBacking:` によりbacking pixelへ同期する。
- [Apple: NSTextInputClient](https://developer.apple.com/documentation/AppKit/NSTextInputClient)
  - 独自テキスト面はNSTextInputClientを実装し、候補ウィンドウの位置を
    `firstRect(forCharacterRange:actualRange:)` で正確に返す。

### 現行実装の確認結果

Nimculusには既にprimary / secondaryのネイティブ文字テクスチャ、各ビュー固有の
カーソル、選択、スクロール、soft-wrap、入力Pane選択がある。しかし、二面は同じ
アクティブDocumentを表示する移行実装であり、`WorkspaceUiState.PaneTree` の葉ごとの
タブ選択・文書選択には接続されていない。また、`PaneTree`はルートsplitまでしか
レイアウトへ投影していない。

### 採用する順序

1. `PaneTree`を唯一のペイン幾何の正本とし、再帰レイアウトとhit testを追加する。
2. 各Paneの選択・フォーカスを、既存のprimary / secondary view stateへ明示的に対応
   付ける。クリック、ショートカット、分割境界ドラッグはこの対応を通す。
3. secondary側が別Documentを表示できるよう、ネイティブ文字描画・入力・IMEの
   Document文脈をPaneごとに分離する。
4. 二ペインで操作・保存・IMEが一貫してから、任意深さの木と三面以上へ拡張する。

この順序は、既存のmacOS IME・LSP・編集コアを壊さず、Zedと同じ「Paneが状態を持つ」
構造へ移行するためのものである。二面を同一Documentのまま増やしたり、AppKitの
オーバーレイだけでタブを偽装したりはしない。

## 追加監査: focused pane ごとの IME 文書契約（2026-07-29）

Pane ごとに異なる文書を表示する実装へ進む前に、Zed の入力境界、AppKit の
`NSTextInputClient`、および Nimculus の primary / secondary presenter を API 単位で
照合した。

### 一次資料から確定したこと

- Zed の `Pane` は `items`、`active_item_index`、focus handle、タブ履歴を所有する。
  `activate_item` は item の切替、履歴、toolbar、status、フォーカスを同じ遷移で更新する。
- Zed の `PaneGroup::split` は対象 Pane を新しい Pane と置換し、各 Pane の item と
  capability を保持したまま、分割木を更新する。表示上の二枚目ではない。
- Zed の macOS backend は `InputHandler` を `NSTextInputClient` の 1:1 境界として扱う。
  選択範囲、marked range、文字列取得、置換、候補矩形、point-to-character の全てを
  同一のフォーカス中 document に対する UTF-16 座標として扱う。
- Apple の `firstRect(forCharacterRange:actualRange:)` は screen coordinates を返し、
  `characterIndex(for:)` も screen coordinates を受ける。`insertText` と
  `setMarkedText` の replacement range は document の UTF-16 範囲である。

参照箇所:

- `references/zed/crates/workspace/src/pane.rs` (`Pane`, `activate_item`)
- `references/zed/crates/workspace/src/pane_group.rs` (`PaneGroup::split`, hit test)
- `references/zed/crates/gpui/src/platform.rs` (`InputHandler`)
- `references/zed/crates/gpui_macos/src/window.rs` (`NSTextInputClient` 登録)
- [Apple: NSTextInputClient](https://developer.apple.com/documentation/AppKit/NSTextInputClient)
- [Apple: firstRect(forCharacterRange:actualRange:)](https://developer.apple.com/documentation/appkit/nstextinputclient/firstrect%28forcharacterrange%3Aactualrange%3A%29)

### Nimculus の現在地と不足点

Nimculus は `PaneTree` の葉ごとに tab index を持ち、secondary presenter に別文書の
文字列・カーソル・選択・スクロールを渡せる。これは必要な土台である。一方で、Cocoa
側の API が primary と secondary の文書状態を完全には同じ文脈で参照していなかった。

| Cocoa API / 更新 API | 要求される文書 | 監査結果 | 対応 |
| --- | --- | --- | --- |
| `attributedSubstring` / `attributedString` | focused pane | 対応済み | 維持 |
| `setMarkedText` / `insertText` の UTF-16→UTF-8 変換 | focused pane | `insertText` は修正中 | secondary text を使用 |
| `firstRectForCharacterRange` | focused pane の text、scroll、rect | text index の切替が必要 | text state も一時切替 |
| `characterIndexForPoint` | focused pane の text、line index、rect、scroll、wrap | text / line index の切替が不足 | 全 text state を一時切替 |
| secondary cursor byte→座標 | secondary text、line index、scroll、wrap | 対応済み | 維持 |
| secondary selection byte→UTF-16 | secondary text | primary text を誤参照 | secondary text を使用 |
| pointer byte hit test | secondary text、rect、scroll | 対応済み | 維持 |

この表の一行でも primary 文書を参照すると、primary と secondary の文字数、改行、
サロゲートペアが異なる場合に、変換候補の位置・選択置換・入力位置のどれかが壊れる。
従って同じ text state を使う API は、矩形だけでなく text、行 UTF-16 index、行 UTF-8
index、line count を同時に切り替えなければならない。

### 実装前に固定する不変条件

1. `g_editor_input_pane` が選択する Pane は、`NSTextInputClient` の全 required method
   に対する唯一の document context である。
2. UTF-16 範囲は Cocoa 境界でのみ扱い、Nim 側 editor core へ渡す前に、その Pane の
   document を基準に UTF-8 byte offset へ変換する。
3. screen/view 座標変換は一度だけ行い、変換後は PaneTree 由来の同じ logical rect を
   描画、hit test、IME candidate rect に使う。
4. primary と secondary の text texture、selection、cursor、scroll、soft-wrap は
   独立する。temporary state swap は文字列と行 index を原子的に切り替え、戻す。
5. 回帰テストは primary / secondary に異なる UTF-8・改行・絵文字を設定し、secondary
   での replacement range、character index、candidate rect、pointer hit test を一つの
   native contract で検証する。同じサンプル文字列を二面に置く試験は不十分である。

### 実装順

1. `NSTextInputClient` の focused-pane state swap を helper として限定し、既存の
   secondary state の一部だけを切り替えるコードを置換する。
2. secondary selection と `characterIndexForPoint:` をその helper 経由にする。
3. primary / secondary が異なる文書の native contract を追加する。
4. Nim 側で secondary Pane の文書を編集する editor-layer test と、分割を開く実機 E2E
   をまとめて実行する。

この監査を満たすまで、任意深さの第三ペイン、見た目だけの tab bar、別の UI 機能へは
進まない。Pane ごとの文書・入力の正しさが、Zed に寄せる UI/UX の基本契約だからである。

## 追加監査: Project Panel と Git list の操作契約（2026-07-29）

ファイラと Git 履歴を実用的な左 Dock にする前に、Zed の Project Panel / Git Panel と
Nimculus の native sidebar を照合した。

### Zed の一次実装

- `ProjectPanel` は `selection`、複数選択、visible entries、展開状態、scroll handle、
  focus handle を所有する。`Open`、`OpenPermanent`、vertical/horizontal split、new file、
  new directory は選択状態を起点に処理する。
- `open_internal` は選択がファイルなら対象 Pane へ開き、ディレクトリなら展開を切り替える。
  同じ操作がキーボード、クリック、コンテキストメニューから到達する。
- `GitPanel` は Changes / History、選択中 entry、next/previous/first/last、tree 展開、
  staged/unstaged diff を action として持つ。表示行が action を決めるのではない。

参照箇所:

- `references/zed/crates/project_panel/src/project_panel.rs`
  (`ProjectPanel`, `select_previous`, `open_internal`, `open_entry`)
- `references/zed/crates/git_ui/src/git_panel.rs`
  (Git panel actions)

### Nimculus の差分

現在の `refreshWorkspacePreview` と Git renderer は、行を文字列へ直列化し、AppKit の
`NSTextView` overlay が click index を `sidebarItem:N` として返す。ファイルを開く、
ディレクトリ展開、commit show、status file open、branch switch は実装済みだが、次が
欠けている。

| 要件 | 現在 | 必要な状態／action |
| --- | --- | --- |
| 選択行の可視フィードバック | なし | panel ごとの selected item key / index |
| Up / Down / Home / End | なし | selection move actions |
| Enter で開く／展開 | なし | selection と open を分離 |
| click の意味 | 即時 open | select、double-click / Enter で open |
| フォーカス | Cocoa overlay は focus を拒否 | Dock focus と native responder の同期 |
| refresh 後の選択 | 暗黙に失う | stable item key で選択を復元 |

Metal renderer は workspace panel/background/separator を描く一方、任意 UI text の
`PaintKind.text` はまだ placeholder である。従ってこの段階で AppKit text overlay を
取り除くと、操作可能なファイラ／Git 表示を失う。Cocoa presenter は移行中の text raster
surfaceとして残し、状態・操作・hit mapping はプラットフォーム非依存の
`WorkspaceUiState` に置く。GPU text renderer が完成した時点で、同じ state/action を
Metal renderer へ投影して presenter だけを置換する。

### 採用する最小縦切り

1. `WorkspaceUiState` に panel ごとの list selection（stable key、選択 index、focus）を
   持たせ、items refresh が key を保つ限り選択を保持する。
2. Cocoa sidebar は click で select、double-click か Enter で open、矢印／Home／End で
   move command を dispatch する。Nim が state を更新して選択表示を送り返す。
3. Files と Git の履歴／status／branches は共通の selection action を使うが、open action
   はそれぞれの domain handler に委譲する。
4. model test は item refresh、境界移動、panel 間の独立選択を確認し、native contract は
   selected row と keyboard dispatch を確認する。

この縦切りにより、ファイラと Git は「クリック時だけ動く文字列」ではなく、ユーザーが
現在位置を見て、キーボードとポインターを併用できる UI になる。

### 追加確認: ファイルを開く Pane の決定

`ProjectPanel::open_internal` は選択 entry を `open_entry` または `split_entry` event として
Workspace に渡す。Zed の Pane は active item を自身で所有するため、Project Panel からの
open は「グローバル active tab を切り替える」操作ではなく、対象 Pane の item を更新する。

Nimculus の `receiveNativeFile` は Finder、Open dialog、recent file、sidebar の共通 callback
として実装され、現在は `EditorSession.activeTab` を常に更新する。これをそのまま sidebar
から使うと、secondary pane をフォーカスして Files Dock から開いても primary が変わる。

採用する境界は次のとおりである。

1. Finder／Open dialog／Apple Event は既存どおり primary session activation を使用する。
2. Files Dock は `WorkspaceUiState.focusedPane` を target とする専用 open action を使う。
3. 既存 tab ならその Pane の selected tab を切り替え、新規 file なら document store へ一度だけ
   追加して target Pane の selected tab にする。
4. primary session active tab は secondary-pane open の副作用で変えない。secondary の text、
   selection、IME context は既存の focused-pane presenter 同期を通す。

これにより、Pane を表示だけ別にするのではなく、ファイラ操作の結果まで Pane-local にする。

## 追加監査: Pane ごとの tab bar（2026-07-29）

Zed の `Pane::render_tab_bar` は、その Pane の `items` と `active_item_index` を描画し、
tab click を同じ Pane の `activate_item` へ送る。tab close、preview の固定化、drag/drop も
Pane の item collection を起点とする。

Nimculus の既存 `NimculusTabBarOverlay` は tab title 配列と active index を一組だけ持ち、
primary editor rectangle の上だけに配置される。その click は global `selectTab:N` を送る。
このままでは secondary Pane が異なる document を表示していても、その選択を UI で確認・
変更できない。

最小縦切りでは、primary と secondary に別の native tab presenter/state を持たせ、click
action を `selectPaneTab:<pane-index>:<tab-index>` にする。Nim 側は PaneTree の leaf selection
を更新し、primary の場合だけ session active tab も更新する。これにより text presenter、
IME、Files Dock と tab bar が一つの Pane selection を共有する。
