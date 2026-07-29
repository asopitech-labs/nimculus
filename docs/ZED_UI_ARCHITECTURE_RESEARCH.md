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

## 追加監査: focused Pane からの tab close（2026-07-29）

Zed の `Pane::close_active_item` は Workspace 全体の active editor ではなく、当該
`Pane` の `active_item_index` を対象にする。close 判定、保存確認、item removal の後も、
各 Pane の focus と item selection は Pane-local なまま維持される。

Nimculus は document ownership を `EditorSession`、Pane 側を shared document index の投影と
している。このため close は次の一操作として扱う必要がある。

1. focused Pane から閉じる document index を解決する。
2. dirty document の場合はその document に対して保存／破棄を確認する。
3. `EditorSession.tabs` から document を削除する。
4. 全 Pane の mirrored index を再番号付けし、閉じた item を選んでいた Pane だけ次の
   item を選ぶ。

macOS bridge は document の dirty state を明示引数として受け、Nim 側が resolved tab index と
Pane identity を sheet completion まで保持する。Save / Don’t Save / Cancel と、untitled
document の後続 Save As panel はすべてこの pending target を使う。これは Zed と同じ Pane
ownership を優先し、誤った primary document を閉じる／未保存内容を失う回帰を防ぐ。

## 追加監査: 空 workspace の welcome page（2026-07-29）

Zed の Workspace は center Pane に `should_display_welcome_page` を設定し、worktree と
editor item がない場合は `WelcomePage` を配置する。welcome page は editor の代用品ではなく、
最初の Project/Open 操作へ到達するための workspace UI である。

Nimculus でも no-document 状態を明示的な UI state とし、New File、Open File、Open Folder、
Open Recent の入口を center に常設する。現段階は AppKit overlay を presenter に使い、既存の
native menu / OpenPanel callback と同じ action を dispatch する。GPU text renderer への移行後も
この state と action contract は維持する。

welcome page の表示中は、caret、line number、indent guide、scrollbar、focused-pane border のような
document 専用 chrome を出さない。これは空バッファを見せるのではなく、操作開始の画面を明確に
見せるための presenter 境界である。

Zed の welcome content は中央の縦 stack に heading と action entries を置く。Nimculus の macOS
presenter も同じ hierarchy を採り、Open Folder を primary、Open File / New File / Open Recent を
secondary とする。AppKit の intrinsic text width に任せると action が選択テキストのように見えるため、
全 action に固定の 260pt × 34pt hit target を与える。

## 追加監査: Git panel の repository 解決（2026-07-29）

Zed の `GitPanel` は作成時に `Project::active_repository` から repository を受け取る
（`crates/git_ui/src/git_panel.rs`）。つまり履歴・status・branch は、editor item がない
workspace でも project context から利用できる。

Nimculus も path を持つ active document があればその enclosing worktree を優先する。一方、
untitled/no-document 状態では workspace roots を順番に検査して最初の Git repository を使う。
これにより welcome から Open Folder した直後でも Git history を開け、複数 root でも選択規則が
安定する。

## 追加監査: Finder 起動時の file-open event（2026-07-29）

macOS の LaunchServices は app 起動中に `application:openFiles:` を先行して配送できる。
Zed のような workspace host では、platform event を workspace の復元完了後に routing する必要が
ある。Nimculus は Cocoa bridge に pending path queue を置き、Nim 側の file callback 登録後に受信順で
flush する。file と directory の区別は queue では行わず、既存の `receiveNativeFile` が directory を
workspace open、file を document open として一元的に扱う。

## 追加監査: Project/Git panel の情報階層（2026-07-29）

Zed の Project/Git panel は keyboard selection を保ったまま、header、tree disclosure、Git status、
commit hash を異なる typography/color で見せる。Nimculus は現在 shared `NSTextView` presenter を使うが、
行を複数化すると sidebar item index と click routing が崩れる。そのため row を一行のまま保ち、attributed
text で title/divider/disclosure/status/hash を分離する。これにより UI の情報設計を改善しつつ、既存の
Files / Git history の action contract を維持する。

## 追加監査: Project Panel context menu（2026-07-29）

Zed の Project Panel は右クリックを selected entry に結び、context menu をその entry の位置から
deploy する。Nimculus でも Files sidebar の right-click は最初に同じ row を選択し、その row の absolute
workspace path を Cocoa context menu に渡す。Cocoa は Open / Reveal / New File / New Folder / Rename /
Delete の prompt を表示するだけで、prompt 開始時の path を保持する。実際の create/rename/delete は Nim 側の
`Workspace` validation を通す。これにより UI action と安全な backend 契約を二重実装せずに結合できる。

## 追加監査: Git Panel tabs（2026-07-29）

Zed の Git Panel は `Changes` と `History` を常時見える tab とし、History の row 選択は commit detail/diff
を開く action へ流す。Nimculus は status / log / branch と history-row からの非同期 `git show --no-ext-diff`
を既に持つため、Git sidebar 上部に native segmented control を置いて同じ command boundary を呼ぶ。表示だけの
別 Git state を導入せず、Changes / History / Branches をユーザーが発見できる主要導線にする。

## 追加監査: Project Panel creation actions（2026-07-29）

Zed の Project Panel は `NewFile` / `NewDirectory` action を panel に登録し、選択中 entry を基準に
add-entry flow を開始する。Nimculus は row context menu の選択ディレクトリ基準作成と、workspace root への
一般作成を既に持つ。Files sidebar 上部の `New File` / `New Folder` は後者の既存 AppKit sheet を呼び、
入力後のパス検証・ファイル監視更新は Nim `Workspace` に一元化する。

## 追加監査: Git status row actions（2026-07-29）

Zed は `StageIntent` を row の section と status から解決し、conflict は Staged/Unstaged bulk 操作から
除外する。Nimculus の compact status list では右クリック menu に Open と可能な Stage/Unstage のみを表示する。
conflict は自動処理せず、個別 action は `git add -- <path>` / `git reset HEAD -- <path>` を cancellable Git job
として実行し、完了後に status を再読み込みする。

## 追加監査: Git commit context menu（2026-07-29）

Zed の Git Panel は commit context menu に `Copy SHA` と commit view を置く。Nimculus の History row は
`Open Commit` を既存 `git show --no-ext-diff` job に接続し、`Copy Commit SHA` は共通 clipboard bridge に
full hash を渡す。Git graph や外部 hosting 連携を前提にせず、履歴閲覧に必要な基本操作を完結させる。

## 追加監査: Command Palette action discovery（2026-07-29）

Zed は action registry を初期化し、action 名を humanize/normalize して Command Palette と keymap editor の
候補に渡す。Nimculus は任意の argument 付き command も維持する必要があるため、native `NSComboBox` に主要な
固定 action を候補として表示しつつ、自由入力をそのまま既存 dispatcher へ渡す構成にする。

## 追加監査: Terminal panel の session 操作（2026-07-29）

Zed の `terminal_view/src/terminal_panel.rs` は `apply_tab_bar_buttons` で terminal pane の tab bar に
New Terminal、task spawn、split pane の action を置く。`new_terminal` は現在 focus されている terminal
center pane か bottom terminal panel かを判定し、作成先を決める。したがって terminal session の作成・選択は
隠れた command ではなく、terminal presenter 固有の UI action である。

Nimculus はまだ terminal pane split を持たない。そこで同じ責務を最小に移植し、下部 terminal panel に
全 session を選べる native popup と常設の New/Close button を置く。popup は固定幅 tab よりも多数 session
で破綻せず、選択・作成・終了は既存の Nim PTY manager へ command callback だけで渡す。task output は terminal
session ではないため、同じ領域を利用してもこの presenter を表示しない。

## 追加監査: Commit detail の presenter 境界（2026-07-29）

Zed の `CommitView::open` は commit diff と commit details を並列ロードし、専用の workspace item として
開く。履歴の選択結果を terminal/log 出力へ流さず、commit を読んで戻るための独立した presentation を持つ。

Nimculus の現行レイアウトは単一 editor pane を維持しているため、CommitView を別 editor buffer に偽装しない。
代わりに既存の bounded lower output presenter に native title bar と close action を追加し、Git Commit、Task、
LSP result の種別を明示する。Git show の取得・cancel・安全な `--no-ext-diff` 実行境界は変更しない。

## 追加監査: Pane tab の close affordance（2026-07-29）

Zed の `Pane::render_tab` は各 closable item に `CloseActiveItem` を接続した close icon を描く。設定により
hover 時だけ非表示にできるが、tab 自体が閉じられることは常に一貫している。Nimculus の custom tab bar は
hover renderer を持たないため、background tab の close glyph を muted で常時表示する。クリックは既存の
`closePaneTab` が対象を選択してから unsaved confirmation を始めるため、dirty document の安全性を損なわない。

## 追加監査: Empty Project Panel の開始操作（2026-07-29）

Zed の `ProjectEmptyState` はProject Panelが空のときにOpen ProjectとClone Repoを主要操作として表示する。
ファイル作成・renameなどはproject contextが得られてから提供する。NimculusのFilesも同じ順序にし、workspace
がないときはOpen Folderだけを表示する。操作は既存のAppKit `NSOpenPanel` とfile callbackを通るため、Finderから
のfolder openと同じworkspace loading boundaryを共有する。

## 追加監査: Git Panel の no-repository 状態（2026-07-29）

Zed の `GitPanel` は active repository がないとき、History表示で `No repository found` placeholderを
renderする。NimculusもGit status/log/branches commandでrepositoryを解決できない場合、status barだけで終えず
Git sidebarをplaceholderへ置換する。Open Folder rowはFilesと同じnon-blocking `NSOpenPanel` を呼び、Git用の
別経路を作らない。

## 追加監査: Workspace chrome の tab-bar actions（2026-07-29）

Zed の `Pane::configure_tab_bar_start` はtab barを作るとき、workspace/action側が提供する左・右の
tab-bar buttonを恒常的に組み込む。TerminalPanelもこのextension pointへNew Terminalなどを置く。Nimculusの
editor rect上部には既にchrome用の高さが確保されていたため、Files / Outline / Git / Terminalをnative toolbar
として配置し、既存のcommand dispatcherへだけ接続する。これにより空白を増やさず、UI actionとbackend stateを
重複させない。

## 追加監査: Workspace chrome の active state（2026-07-29）

Zed の Pane tab-bar actions は workspace の active panel と terminal の表示状態を反映し、editor へ focus が
戻っても現在の作業領域を示し続ける。Nimculus の native toolbar も Files/Outline/Git を sidebar mode、Terminal
を lower panel visibility から毎回再計算する。toolbar自身は状態を保持せず、theme accent とtooltipだけを更新する
ため、既存のNim command dispatcherと各パネルの所有関係は変わらない。

macOS app bundle の LaunchServices 起動では process working directory が project root を意味
しない。空 launch でそれを workspace として開くと `/` の巨大な filesystem tree が Project
Panel に現れ、welcome UI の目的を失う。Nimculus は restored workspace または Finder/OpenPanel
で明示された folder だけを workspace として開く。
