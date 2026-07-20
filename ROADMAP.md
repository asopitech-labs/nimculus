# Nimculus ロードマップ：macOS優先版

## 現在の進捗

| マイルストーン | 状態 | 備考 |
|---|---|---|
| M0：モノレポ基盤 | ✅ 完了 | Apple Silicon のローカル build / test / benchmark / lint、およびmacOS CI（run 29635844053）を確認済み |
| M1：macOS ウィンドウと Metal 描画 | 🟡 実装済み・追加検証待ち | Cocoa / Metal / Retina / 基本入力を実装済み |
| M2：NimNUI 基礎 UI システム | 🟡 実装済み・GUI検証待ち | UIツリー、レイアウト、状態、イベント、PaintList、macOS入力を実装。世代付きIDのテストとネイティブMetalスモークは確認済み、GUIギャラリーの実機操作が残る |
| M3：macOS テキスト描画と IME | 🟡 実装済み・GUI実機検証待ち | Core Text、glyph atlas、動的Metal文字描画、Tree-sitter構文色、marked text表示、IME、候補位置、clipboardを実装。日本語IME、カーソル/選択、Retina文字表示の実機確認が残る |
| M4：エディタバッファと編集コア | ✅ 完了 | Piece Table、原子的編集、Undo/Redo、複数カーソル、位置変換、fuzz、候補構造比較を実装・検証済み |
| M5：macOS 最小実用エディタ | 🟡 実装済み・GUI実機検証待ち | 編集サービス、plain-text fallbackを含む動的文書表示、構文色、macOSメニュー/IME/Finder接続、Application Supportへのセッション復元・クラッシュリカバリー、`Cmd+,`の設定ファイル導線を実装。GUI実機確認が残る |
| M6：macOS プロジェクト・ワークスペース | 🟡 部分UI統合・高度なGit UI待ち | フォルダ選択、Fileメニューからの複数ルート追加、Quick Open fuzzy file search、クリック可能なルート直下ツリー、Workspace検索入力/結果/継続更新/キャンセル、Worktree branch/HEAD表示、標準Fileメニューからのファイル作成・フォルダ作成・名前変更・削除、Workspace rootのセッション復元を接続。複数ルート、`.gitignore`、fuzzy/ripgrep API、協調型検索ジョブ、FSEvents、Worktree状態分離、10万ファイル計測を実装。Git diff/stage等の高度なUIが残る |
| M7：Tree-sitter | 🟡 実装済み・GUI実機検証待ち | Nim/Rust/TypeScript/Python/JSON/MarkdownのFFI、増分解析、構文状態、可視範囲ハイライト、RGBA Metalテクスチャ接続、大規模ファイル計測を実装。GUI実機確認が残る |

チェック済み項目は、コード実装とローカル検証の両方を確認できたものを示す。CIの実行成功、実機での個別入力、未実装のAPIは未チェックのまま残す。

## 基本方針

Nimculus および NimNUI の初期主対象を macOS とする。初期開発環境は Apple Silicon 搭載 macOS を前提とし、Cocoa ウィンドウ、Metal 描画、Retina、macOS IME、標準メニュー、クリップボード、ファイルダイアログ、PTY、アプリ署名、notarization、`.app` / DMG 配布を最優先で完成させる。

プラットフォーム対応順は次のとおり。WSL 対応は Windows 版完成後に実施する。

1. macOS
2. Windows
3. WSL リモート
4. Linux
5. SSH リモート

## マイルストーン

### M0：モノレポ基盤

**進捗：** ✅ 完了

**目的：** NimNUI と Nimculus を含むモノレポの開発基盤を構築する。

**実装範囲：**

- [x] Nim 2 系
- [x] ARC（`nimble.workspace` と Nimble task に設定）
- [x] Nimble workspace
- [x] macOS CI 定義（`.github/workflows/macos.yml`）
- [x] Apple Silicon 向けビルド
- [x] formatter（Nim標準 `nimpretty` の Nimble task）
- [x] linter（Nim標準 `nim check` の Nimble task、およびmacOS CI）
- [x] unit test runner
- [x] benchmark runner
- [x] mock renderer
- [x] `README.md`
- [x] `ARCHITECTURE.md`
- [x] `DESIGN_DECISIONS.md`
- [x] `ROADMAP.md`

**完了条件：**

- [x] Apple Silicon macOS で `nimble build` が成功する
- [x] テストが実行できる
- [x] NimNUI と Nimculus アプリ層が分離されている
- [x] CI が macOS 上で成功する（GitHub Actions run [29635844053](https://github.com/asopitech-labs/nimculus/actions/runs/29635844053)でBuild / Lint / Test成功）

### M1：macOS ウィンドウと Metal 描画

**進捗：** 🟡 実装済み・追加検証待ち

**目的：** macOS 上で NimNUI の最小描画基盤を成立させる。

**実装範囲：**

- [x] macOS プラットフォーム層：Objective-C Runtime 連携、`NSApplication`、`NSWindow`、`NSView`、`CAMetalLayer`、イベントループ
- [x] Retina scale factor
- [x] `viewDidChangeBackingProperties`によるディスプレイ移動時のdrawable・文字テクスチャ再生成
- [x] ウィンドウリサイズ
- [x] リサイズ時のNimNUIレイアウト・PaintList・hit-test再計算
- [ ] フルスクリーンの実機検証
- [x] 最小化
- [x] 最大化相当動作（標準ウィンドウ機能）
- [ ] 複数モニターの実機検証
- [x] Metal device
- [x] command queue
- [x] swapchain 相当管理（`nextDrawable`）
- [x] render pipeline
- [x] vertex buffer
- [x] uniform buffer（基本描画shaderのbuffer(1)へopacity uniformを接続）
- [x] rectangle 描画
- [x] clear color
- [x] resize 対応
- [x] frame timing 計測
- [x] キーボード
- [x] 修飾キー
- [x] マウス
- [x] mouse tracking、左/右ドラッグ
- [x] left/right/other mouse down/up/drag、modifier-changeをNimNUIイベントへ分類しbuttonを保持
- [x] tracking areaのmouse enter/exitをpointer enter/exitへ分類しhover解除へ接続
- [x] AppKit下原点入力をNimNUI上原点座標へ正規化
- [x] スクロール（wheelのline deltaとtrackpadのprecise pixel deltaを区別し、行高換算の残差を蓄積）
- [ ] トラックパッドの個別検証
- [x] ウィンドウフォーカス

**成果物：**

- [x] macOS で起動する Nimculus ウィンドウ
- [x] Metal 背景・Rectangle 描画
- [x] 入力イベントログ（`NSLog`）
- [x] Retina 対応
- [x] macOS CI 定義

**完了条件：**

- [ ] Apple Silicon macOS で起動する（arm64 buildは確認済み、GUI起動未確認）
- [ ] Metal で描画される（native contract/buildは確認済み、GUI描画未確認）
- [ ] リサイズ後も描画を維持する（native再レイアウト経路実装済み、GUI操作未確認）
- [ ] Retina スケールが正しく反映される（drawable計算実装済み、GUI表示未確認）
- [ ] キーボードとポインター入力を取得できる（callback実装済み、GUI操作未確認）
- [ ] フルスクリーン、複数モニター、トラックパッドの個別実機検証

### M2：NimNUI 基礎 UI システム

**進捗：** 🟡 実装済み・GUI検証待ち

**目的：** GPU ネイティブ UI を構築できる最小基盤を実装する。

**実装範囲：**

- [x] UIツリー、Node ID、親子関係
- [x] 世代付きNodeHandleとstale handle検証
- [x] Row / Column / Stack レイアウト
- [x] 固定・最小・最大サイズのデータモデル
- [x] Padding、Gap
- [x] Alignment、Flex grow のレイアウト計算（cross-axis stretchとmin/max制約を含む）
- [x] 子ノード単位のflex grow、preferred/min/maxサイズ制約
- [x] Scroll container、Viewport clipping、PaintList clip stack（push/pop。幅または高さの片方が0のdegenerate clipも保持）
- [x] Viewport外の子ノードをpointer hit-test対象から除外
- [x] Focus、Hover / Active / Disabled の状態モデル
- [x] Focus / Hover / Active / Disabledを独立状態として保持し、visual stateの優先順位を分離
- [x] Disabled nodeとdisabled ancestor配下をpointer hit-test / focus対象から除外し、focus traversalでもスキップ。無効化されたfocus pathはfocus ownerも解放
- [x] macOS application deactivation時にpointer capture、active、hover、editor/split dragを解除
- [x] Dirty flag、layout / paint invalidation
- [x] Capture / Target / Bubble イベントフェーズ
- [x] keyboard / pointer routing のOSイベント統合（hit-test、hover/active、focus、modifier/deltaを含む）
- [x] command dispatch / shortcut resolution（未登録ショートカットの判定とCommand等の修飾子テストを含む）
- [x] macOS keyDownをCommandRegistryへ接続し、handled時はIME/AppKitへ伝播させず、未handled時は通常のinterpretKeyEventsへフォールバック
- [x] 基本コントロールの型（Label、Button、Scroll view、Split pane、Tab bar、Context menu、Popup、Tooltip）
- [x] `PaintList`の描画コマンドをmacOS native ABI経由でMetalへ転送（rectangle、border、rounded rectangle、shadow、caret、selection、scrollbarの基本描画）
- [x] Text placeholder / image commandをnative Metalへ転送し、元geometryと累積affine transformをMetal頂点へ適用（実文字はM3、画像はRGBA8 texture ID登録・描画APIを実装。未登録IDはplaceholder）

**完了条件：**

- [x] 分割ペインをドラッグ操作できる（split ratioをnative pointer eventへ接続、GUI操作未確認）
- [ ] スクロール領域が正しくクリップされる（layout/PaintListテスト済み、GUI表示未確認）
- [x] フォーカス移動の基盤が機能する（disabled controlのスキップを含むunit test済み）
- [ ] Command キーを含むショートカットを処理できる（routing実装済み、GUI操作未確認）
- [x] dirty / paint invalidation を管理できる
- [x] dirty 領域だけをMetal実画面へ部分再描画できる（保持用scene textureをdirty領域のみ再描画し、drawableへblit）
- [ ] UIギャラリーがmacOS上で安定動作する（基本PaintKindを含む起動シーンは実装済み、実機操作未確認）

### M3：macOS テキスト描画と IME

**進捗：** 🟡 実装済み・GUI実機検証待ち

**目的：** コードエディタに必要な文字表示と入力を完成させる。

**実装範囲：**

- [x] Core Text / HarfBuzz の役割分担調査（Core TextをmacOS標準経路として採用）
- [x] macOSフォント列挙・フォントロード・フォールバック（未知フォントのavailable判定はCore Text登録名を直接照合）
- [x] 編集テキストの計測・描画・hit-test全経路でpreferred font失敗時にsystem fontへfallback
- [x] 等幅 / Bold / Italic / Retinaフォント描画基盤（Core Text textureをbacking scale factorで生成）
- [x] UTF-8位置計算
- [x] native text surfaceとCore Text計測へ本文をNUL終端ではなくUTF-8 byte length付きで渡し、U+0000を含む文書を切断しない
- [x] Unicode TR29準拠のgrapheme cluster境界（`graphemes`依存）
- [x] 編集カーソル・削除・word移動のgrapheme境界適用（Unicode空白・句読点分類を含む）
- [x] combining characterの位置統合
- [x] ligature、glyph positioning、fallback run、BiDi（Core Text shaping経路）
- [x] glyph atlasの配置・再利用基盤（Core Text glyph runをfont・scale・glyph IDでキャッシュし、Metal R8 textureへ配置）
- [x] atlas拡張、cache eviction、Metal texture、可視範囲描画、サブピクセル位置（2048px shelf atlas、容量超過時の全体eviction、可視行のみのquad生成、native cache-hit smoke test、atlas利用不能時のCore Text全文fallback）
- [x] スクロール行をnative text texture、カーソル、IME候補位置、構文ハイライトへ同期
- [x] Workspace / search / Quick Openのpreview text surface切替時にselection、caret、scroll、compositionをリセット
- [x] エディタ矩形の高さから可視行数を算出し、描画・スクロール・構文ハイライト範囲を統一
- [x] 可視テキスト範囲をgrapheme boundary単位で切り出す
- [x] エディタ矩形をnative Metal text quadへ渡し、リサイズ時にテクスチャ寸法と配置を更新
- [x] Retina text texture内のbaseline、selection、marked text、caretをlogical座標で描画
- [x] 初回window attachment時にもCAMetalLayerのcontentsScale / drawableSizeを初期化
- [x] macOS `NSTextInputClient` 相当のネイティブ契約
- [x] composition開始・更新・確定・キャンセルの受け口
- [x] IME committed文字列のセッション間蓄積を行わず、文書切替時にcompositionをリセット
- [x] 文書切替時にNim側compositionとnative `markedText`/`markedTextRange`を同時に解除
- [x] marked textを編集バッファと分離してカーソル位置へ表示する経路
- [x] UTF-16選択範囲、提案文字列、文字位置問い合わせをNimの編集状態へ同期する経路
- [x] optional `attributedString`がmarked textではなく確定済みdocument textを返す
- [x] `setMarkedText`のreplacement rangeをUTF-16からUTF-8 byte選択へ変換して編集コアへ通知
- [x] `insertText`のreplacement rangeもUTF-16からUTF-8 byte選択へ変換し、サロゲートペア途中を境界にしない
- [x] エディタのUTF-8 byte選択範囲をNSTextInputClientのUTF-16 selectedRangeへ変換
- [x] ネイティブから返る選択位置をgrapheme boundaryへクランプ
- [x] Zed/AppKit契約を確認し、`NSTextInputClient`に存在しない`setSelectedRange:`は追加せず、Nim→nativeの選択同期とIME replacement callbackを分離
- [x] 選択範囲とカーソルをテキスト面へ描画する経路（cursor/selection変更時のoverlay再生成を含む）
- [x] Core Textのglyph offsetでUTF-8 byte cursorと選択範囲を実ピクセル位置へ変換
- [x] Core Textの逆方向hit-testでクリック位置をUTF-8 byte offset、NSTextInputClient位置問い合わせをUTF-16 offsetへ変換
- [x] `NSTextInputClient`のscreen座標問い合わせをwindow/view座標へ正規化してからhit-test
- [x] 日本語IME・絵文字入力のネイティブ受け口
- [x] 変換候補位置と編集バッファの統合受け口
- [x] `firstRectForCharacterRange:`のUTF-16 rangeから候補行・glyph位置を計算
- [x] カーソル・スクロール・選択変更後に`NSTextInputContext`の候補座標キャッシュを無効化
- [x] クリップボード統合

**完了条件：**

- [ ] macOS 日本語 IMEで入力できる（ネイティブ受け口は実装済み、実機操作未確認）
- [ ] 変換候補がカーソル位置に表示される（ネイティブ座標計算は実装済み、実機操作未確認）
- [x] grapheme cluster単位でカーソル位置を計算できる
- [ ] 日本語、英語、記号、絵文字をGPU上で混在表示できる（Core Text fallback runとMetal atlas経路は実装済み、実機表示未確認）
- [ ] Retina環境で文字が崩れない（Metalスモーク済み、文字表示の実機確認未了）
- [x] 1万行相当の表示経路を構築できる（可視範囲レイアウト。滑らかさの実機計測は未了）

### M4：エディタバッファと編集コア

**進捗：** ✅ 完了

**目的：** UI から独立した高速なテキスト編集エンジンを実装する。

**事前検証：** Piece Table を選定し、ロード、中央挿入、連続入力、Undo/Redo、行位置変換、UTF-16 位置変換、メモリ負荷をベンチマークする。選定理由は、元ファイルと追加領域を分離でき、編集履歴と相性がよく、M4の100MB級ロード要件に適合するためである。

**実装範囲：**

- [x] Piece Table（original / additions / pieces）
- [x] UTF-8 内部表現、line index、byte offset
- [x] codepoint / grapheme / UTF-16 LSP position
- [x] 公開line-columnをgrapheme列として統一し、byte列変換を内部経路へ限定
- [x] incremental edit
- [x] edit/applyEditsのUTF-8・char boundary検証（graphemeはUIカーソル層で検証）
- [x] dirty state、保存地点管理
- [x] 内容リビジョンでdirtyを判定し、保存済み内容へのUndo/Redo復帰を正しく扱う
- [x] Undo / Redo
- [x] 複数カーソルの原子的編集
- [x] 選択、編集グループ
- [x] 100MB級ロードベンチマーク
- [x] 編集・substring・UTF-8境界検証・行index lookupをpiece単位で処理し、編集時の全体flattenを回避
- [x] Piece Table / Chunked Rope / Gap Buffer / Piece Tree / Hybridの比較ベンチマーク
- [x] 決定的fuzz test

**完了条件：**

- [x] 100MB 級ファイルを開ける
- [x] Undo/Redoで内容が破損しない
- [x] 複数カーソル編集が原子的に処理される
- [x] UTF-8、UTF-16、行列変換が正しい
- [x] fuzz testで不整合が発生しない

### M5：macOS 最小実用エディタ — `v0.1.0-alpha`

**進捗：** 🟡 実装済み・GUI実機検証待ち

**目的：** macOS で日常利用できる単一ファイルエディタを完成させる。

**実装範囲：**

- [x] 開く、新規、保存、名前を付けて保存
- [x] CRLF / LF保持
- [x] 外部変更検知、未保存状態
- [x] Cmd+W / Cmd+Q の未保存変更確認（Save / Don't Save / Cancel）
- [x] Cmd+W / File > Closeはactive tabを閉じ、最後のtab以外ではwindowを終了しない
- [x] Cmd+Qは全dirty tabをSave All / Don't Save / Cancelで解決してから終了する
- [x] macOS外部変更AlertからReload / Keep Editingを選択する経路
- [x] タブ、分割
- [x] WindowメニューのPrevious / Next Tabからactive bufferを切り替え、IME・selection・syntax・scrollを再同期
- [x] タブごとのselection、scroll、表示設定を分離し、session保存・復元時にgrapheme境界と文書長へclamp
- [x] Untitledタブの本文、dirty状態、改行形式、view stateをsessionへ保存・復元
- [x] 行番号、カーソル、選択、Go to line相当の位置モデル
- [x] editor viewport内のpointer downから選択を開始し、drag中はviewport外でもpointer-upまで継続
- [x] 検索、置換
- [x] ソフトラップ/スクロール/インデントガイドのView状態
- [x] ステータスバー、コマンドパレット状態
- [x] 標準ショートカット基盤
- [x] macOS標準の上下移動、行頭/行末、文書先頭/末尾、改行、TabをNSTextInputClientから編集コアへ接続
- [x] `Cmd+F`のnative Findダイアログとactive documentの一致選択
- [x] native Replace Allダイアログと編集コアの置換結果同期
- [x] native Go to Lineダイアログとgrapheme境界への位置移動
- [x] native Command Paletteダイアログから主要コマンドを実行
- [x] 最近開いたファイル
- [x] macOS File > Open Recentから最近のファイルを選択
- [x] セッション復元
- [x] クラッシュリカバリー（recovery file）
- [x] ディスクから削除・移動されたdirty名前付きタブをsession本文から復元
- [x] session / recovery / 文書保存のatomic writeと、保存成功後だけ終了を許可するclose-save境界
- [x] Don’t Save終了時にdirty bufferを次回sessionへ持ち越さない
- [x] atomic保存時の既存Unix file permissions保持

**macOS 統合：**

- [x] アプリケーションメニュー
- [x] File / Edit / View / Window メニュー
- [x] Dock / Open With のアプリ基盤
- [x] `Cmd+O` / `Cmd+S` / `Cmd+W` / `Cmd+Q`（未保存変更確認を含む）
- [x] `Cmd+S`は既存ファイルを直接保存し、UntitledのみSave Panelを表示
- [x] `Cmd+N`（New）
- [x] `Cmd+,`でApplication Supportの`settings.json`を生成/表示（専用設定UIはM12の残課題）
- [x] 標準 `NSOpenPanel` / `NSSavePanel`

**完了条件：**

- [ ] macOS標準メニュー・ファイルダイアログを利用できる（実装済み、GUI操作未確認）
- [ ] 日本語ファイルを安全に編集・保存できる（編集コアのテスト済み、GUI操作未確認）
- [x] CRLF / LFを扱える
- [ ] 外部変更を検出できる（サービス実装・テスト済み、GUI通知未確認）
- [x] 外部変更のReloadでcursor、selection、scroll、表示設定を保持し、新文書境界へclamp
- [x] 連続編集・大量編集のストレステストを実行できる

### M6：macOS プロジェクト・ワークスペース — `v0.2.0-alpha`

**進捗：** 🟡 部分UI統合・高度なGit UI待ち

**実装範囲：** フォルダ、複数ルート、遅延ファイルツリー、ファイル作成・削除・名前変更、`.gitignore`、fuzzy検索、ripgrep互換全文検索、変更集約用FSEventsブリッジ、Git Worktree列挙、除外設定。

**完了条件：** [x] 起動時に全ファイル内容を読み込まず列挙、[x] FSEvents変更通知、[x] FSEvents監視をWorkspaceライフサイクルへ接続、[x] 複数ルートごとの`.gitignore`適用、[x] 複数ルート・ファイル操作・fuzzy/ripgrep検索API、[x] secondary rootへのFileメニュー操作をabsolute pathからroot解決、[x] Quick Openからfuzzy候補を表示・クリックで開く、[x] Quick Openのbounded pollingとキャンセル、[x] UIから分割実行できる協調型検索ジョブ、[x] Workspace検索結果をクリックしてファイル・行・列を開く、[x] Fileメニューからの複数ルート追加、[x] Workspace root一覧のセッション保存・起動時復元、[x] ルート直下ファイルツリーの表示とクリックによるファイル/フォルダオープン、[x] Workspace検索入力/結果/継続更新/キャンセルの最小表示、[x] Worktree branch/HEADの最小表示、[x] 10万ファイル列挙ベンチマーク、[x] Worktree rootごとのHEAD/branch状態分離API。Git diff/stage等は残る。Git UI統合の本実装はM9で実施する。

追加接続：**[x]** active documentが残る状態でも、tree preview表示中のFSEvents変更を反映する。

検索状態管理：**[x]** Workspace切替、Workspace Search/Quick Open切替、空クエリで古い検索ジョブと結果を破棄する。**[x]** ripgrepの同一ファイル複数一致を個別結果として保持する。

### M7：Tree-sitter

**進捗：** 🟡 実装済み・計測/GUI検証待ち

**初期対象：** Nim、Rust、TypeScript、Python、JSON、Markdown。

**実装範囲：** Tree-sitter FFI、静的grammar loader、incremental parse、構文ノード収集、syntax highlighting、bracket matching、folding、outline（宣言シンボル名抽出）、indentation、selection expansion、syntax node navigationの基盤。各生成文法は独立C翻訳単位でビルドする。

**完了条件：** [x] UTF-8境界を含む編集差分から`TSInputEdit`を生成してincremental parse、[x] 初期6文法のロード、[x] 構文ノードから表示・構造サービスを生成、[x] 実エディタの可視範囲ハイライトとRGBA Metalテクスチャへ接続、[x] 1MB級大規模ファイルのparse/可視範囲計測、[x] 文法追加手順を文書化。GUI実機での色表示確認が残る。

### M8：LSP クライアント — `v0.3.0-alpha`

**進捗：** 🟡 プロトコル・stdio・要求/応答アダプタ・エディタ診断表示を実装済み・主要UI統合待ち

**初期対象：** Nim、Rust、TypeScript、Python。

**実装範囲：** JSON-RPC、stdio transport、cancellation、timeout、lifecycle、restart、diagnostics、completion、hover、definition、references、symbols、rename、formatting、code action、signature help、semantic tokens、inlay hints。

**実装済み基盤：** UTF-8 byte-accurate `Content-Length` framing、partial/multiple frame decoder、JSON-RPC request construction、method generationによるstale response破棄、cancel/timeout状態管理、POSIX non-blocking stdio process transport、EOF/exit状態、stop/restart、initialize handshake、active documentの`didOpen`/full `didChange`/`didClose`、file URI・language ID・version管理、diagnostics parsing/cache、UTF-16→UTF-8 byte診断範囲変換、completion requestのUTF-16 cursor変換・response store・stale-safe candidate state・Unicode word range edit・macOS候補popup、hover requestの250ms遅延・位置stale破棄・macOS tooltip表示、definition requestのUTF-16 cursor変換・location response store・file URI復号・別ファイル移動、formatting requestの文書世代検証・LSP UTF-16範囲からPiece Tableへの原子的編集変換・Command Palette接続、references/symbols/rename/code action/signature help/semantic tokens/inlay hintsの要求生成・応答デコード・世代付きresponse store、locations/text edits/completion/hover/symbols/code actions/workspace edits/signature/tokens/inlay hints parser、初期化capability広告、syntax highlightと分離したdiagnostic span ABI、severity別のCore Text/Metal overlay下線表示を実装。Command Paletteからreferences、document symbols、rename preview、code actions、signature help、inlay hintsを要求し、既存Task Output overlayへ結果を表示する縦切りを接続した。symbol結果は階層childrenを展開し、番号選択でUTF-16位置からカーソル移動できる。semantic tokenは文書snapshotに紐づけてstale結果を破棄し、既存NativeHighlight spanへ変換して表示する。rename/code actionは番号付きプレビュー後に明示コマンドで適用し、UTF-16範囲をファイルごとに原子的なPiece Table編集へ変換する。`documentChanges`形式のWorkspaceEditを解析し、編集を伴わないCode Actionは`workspace/executeCommand`へ転送する。遅延解決型Code Actionは`codeAction/resolve`を経由して完全な編集を取得し、明示適用へ接続する。signature helpはactive signatureをカーソル付近のmacOS hover popoverへ表示し、inlay hintsは本文を変更しないannotation overlayへ行・列位置付きで描画し、カーソル/文書移動時に破棄する（`src/nimculus/lsp.nim`、`src/nimculus/lsp_editor_bridge.nim`、`src/nimculus/editor_diagnostics.nim`、`src/nimnui/platform/macos/macos_platform.m`）。専用の常設symbol tree UIは残る。

**完了条件：** Language Server の異常終了から復旧し、stale response を破棄できる。completion が入力をブロックせず、Tree-sitter と LSP 表示を統合できる。

**stale対策補足：** 文書世代が進んだ時点でreferences、symbols、code actions、rename、signature help、semantic tokens、inlay hints、execute commandの保留要求と結果キャッシュを破棄し、旧スナップショットの応答がエディタへ到達しないことをテストで検証する。

**動作確認用設定：** `NIMCULUS_LSP_COMMAND` にLanguage Server実行ファイル、`NIMCULUS_LSP_ARGS` に空白区切り引数を指定すると、macOS実行時にactive documentの同期とdiagnostics表示を有効化する。設定未指定時はLanguage Serverを自動起動しない。

### M9：macOS Git 統合

**進捗：** 🟡 Git CLIサービス・非同期UI統合済み・実機検証待ち

**実装範囲：** repository 検出、status、branch、diff、inline diff、gutter indicator、stage / unstage、commit、log、blame、checkout、conflict 表示。初期実装は Git CLI を使用する。

**実装済み基盤：** `GitRepository` によるrepository検出、porcelain v1 NUL status解析（rename/copy/conflictを含む）、unstaged/staged diff、unified diff hunkの行範囲・追加削除数解析、stage/unstage、hunk単位stage/unstage、commit、branch/HEAD、log、line blame、checkout、conflict path取得、終了コードを保持するGitJobと明示的cancel（`src/nimculus/git_service.nim`）。active documentの所属Workspace rootに対する非同期diff取得、追加/削除/変更を表すmacOS gutter ABI、gutter通常クリックによるstage、Option-clickによるunstage、Command PaletteからのGit status/stage all/unstage all/カーソル行のhunk stage・unstage/commit/log/blame/checkoutを非同期ジョブへ接続済み。hunk操作はdiff取得とpatch適用を分離し、文書切替時の古い結果を破棄する。`cancel git`で実行中のGit操作を停止できる。実機でのinline diff/gutter確認は残る。

**完了条件：** 大規模リポジトリで UI を停止させず、Git 処理をキャンセルでき、Worktree ごとに状態を分離できる。

### M10：macOS 統合ターミナルとタスク — `v0.4.0-alpha`

**進捗：** 🟡 端末コア・macOS最小UI統合済み・VT高度機能/実機検証待ち

**実装済み基盤：** ZedのPTYイベントループとTerminalPanelのセッション責務分離を参考に、macOS `forkpty`、non-blocking master、shell起動、入力書き込み、終了処理、ウィンドウサイズ通知、CSIカーソル移動/消去/スクロール領域/行・文字挿入削除、SGRの標準/明色/256色/RGB属性、OSCメタデータとOSC 8 hyperlink、DEC alternate screen、cursor visibility、application cursor、origin、bracketed paste、UTF-8 glyph、wide glyphのleading/continuation cell、画面バッファ、scrollback、resizeを`src/nimculus/terminal.nim`へ実装。DEC mouse tracking（click/drag/motion、normal/UTF-8/SGR形式）のPTYレポート生成も実装し、端末overlayのpointer/scrollイベントからPTYへ接続済み。TerminalScreenは可視行とscrollbackを含むcell selectionを保持し、NimNUI clipboardへコピーできる。SGR属性とOSC 8リンクはterminal cellからmacOS attributed overlayへrun単位で転送し、標準/256色/RGB、太字、dim、italic、underline、inverse、strikethrough、リンク属性を表示へ反映する。さらにZedのTaskSpec境界を参考に、working directory・引数・環境変数・終了コード・stdout/stderr統合・cancelを`src/nimculus/task_service.nim`へ実装し、Command Paletteの`run task <command>` / `cancel task`、idle polling、成功/失敗/キャンセルのstatus表示へ接続済み。macOS Metal editor上へPTY用とtask output用の非編集AppKit overlayを分離して追加し、`toggle terminal` / `new terminal` / `next terminal` / `previous terminal` / `toggle task output`、複数PTYの独立poll、PTY出力表示、task出力保持/表示、selection/copy/paste、bracketed paste、application cursor入力、Enter/Tab/Backspace/矢印/Ctrl-C入力、resize追従、終了時の全PTY停止を接続済み。PTY実行・複数セッション・画面更新・ANSI/OSC/SGR・OSC 8 hyperlink・alternate screen・selection・UTF-8・wide glyph・mouse report・resize・属性run・task実行・失敗・cancelを統合テストで検証済み。kitty拡張、属性付きGPU描画、実機検証は残る。

**実装範囲：**

- ターミナル：macOS PTY、zsh / bash / fish、ANSI/VT parser、screen buffer、scrollback、選択、copy/paste、resize、複数セッション
- タスク：build、test、run、working directory、環境変数、cancellation、background task、problem matcher、output panel

**完了条件：** zsh を安定実行し、ターミナルリサイズ、複数セッション切替、長時間タスクの停止が機能する。

Task出力のproblem matcherは、標準的な`path:line:column: message`と`path:line: message`を`TaskProblem`へ変換し、終了ステータス表示へ問題件数を反映する。

Task stdout/stderrはPOSIX pipeをnon-blockingでpollし、プロセス終了前からTask Output overlayへ増分反映する。

### M11：macOS 配布基盤 — `v0.5.0-beta`

**進捗：** 🟡 配布スクリプトと署名検証ゲートを実装済み・Apple資格情報によるnotarization実行待ち

**実装済み基盤：** `packaging/macos/Info.plist`、file associationと`nimculus://` URL scheme、Finder/Open WithとURLイベントのAppDelegate受信、hardened runtime用entitlements、Apple Silicon/x86_64を選べる`scripts/package_macos.sh` による`.app`生成、codesign、`codesign --verify --deep --strict`、Developer ID署名時の`spctl --assess`、ZIP/DMG生成、`xcrun notarytool`提出、stapling、stapler validateを接続。署名IDなしではadhoc許可を明示しない限り失敗し、notarization指定時はApple ID・Team ID・app-specific passwordを必須化する。

**実装範囲：** `.app` bundle、アイコン、`Info.plist`、file association、URL scheme、code signing、hardened runtime、notarization、stapling、DMG、ZIP、自動更新基盤、crash report、session recovery。

**完了条件：** 署名済み Apple Silicon アプリを生成でき、Gatekeeper 警告なしで起動し、notarization を通過し、DMG からインストールできる。

### M12：設定・テーマ・キーバインド — `v0.6.0-beta`

設定live reloadはmtimeの秒精度に依存せず、ファイル内容のリビジョンで同一秒内の編集も検出する。

**進捗：** 🟡 設定コア・階層マージ・型検証・live reload・基本keymap反映・macOS設定ファイル導線を実装済み・専用設定UI/テーマ registry反映待ち

**実装済み基盤：** ZedのSettingsStore/KeymapFileを参考に、global/workspace/language設定の再帰マージ、JSON型検証、診断保持、ファイルmtimeによる再読み込み、machine-readable settings schema、theme color、icon/theme設定値、keymap配列、terminal shell、LSP commandの設定取得を`src/nimculus/settings.nim`へ実装。macOS起動時にApplication Supportのglobal settingsとworkspace `.nimculus/settings.json`を読み込み、idle時の変更検知とterminal shell/LSP command/theme colorへの反映を接続済み。`Cmd+,`でglobal settingsを生成/表示し、`cmd+shift+p`等のkeymap表記をNimNUI Shortcutへ変換して既存command registryへ反映する。専用設定UI、標準Command/Optionキーマップ全体の設定ファイル反映、完全なテーマ registry、icon themeは残る。

**実装範囲：** global / workspace / language settings、schema validation、live reload、keymap、command registry、theme、icon theme、font / terminal / LSP settings。

**macOS 要件：** Command キー中心の標準キーマップ、Option キーの単語移動、標準編集操作、システム外観連動、Light / Dark 切替（アクセントカラー連動は任意）。

システム外観はAppKitの`effectiveAppearance`を参照し、`theme: "system"`でLight / Darkをidle時に追従する。`theme: "light"` / `"dark"`による明示指定と`themeColors.background`による個別上書きを優先する。

### M13：Windows 対応 — `v0.7.0-beta`

Win32、GPU backend（Direct3D または `wgpu-native`）、DPI、keyboard、IME、clipboard、drag and drop、file dialogs、font discovery、ConPTY、installer を実装する。

macOS 実装の API 契約は維持するが、macOS 固有概念を無理に共通化しない。共通化対象は OS API ではなく動作契約とする。

**完了条件：** 主要機能、日本語 IME、ConPTY、Windows インストーラーが動作し、macOS 固有コードがコアへ漏れない。

### M14：WSL リモート — `v0.8.0-beta`

Windows 側に Nimculus GUI、NimNUI、GPU 描画、入力、セッション管理を置き、WSL 側に `nimculus-agent`、ファイル I/O、Git、LSP、検索、ターミナル、タスクを置く。

**実装範囲：** distribution 検出、agent 配置、version negotiation、remote file API、watcher、search、Git、LSP、terminal、tasks、reconnect、agent update。

**完了条件：** `\\wsl$` 経由の直接監視なしで開発でき、LSP・Git・検索・ターミナルが WSL 側で動作し、接続断から復旧し、複数ディストリビューションを扱える。

### M15：Linux 対応 — `v0.9.0-beta`

Ubuntu LTS を初期対象とし、Wayland を優先、X11 を fallback とする。window / GPU backend、keyboard、IME、clipboard、drag and drop、file dialogs、font discovery、PTY、packaging を実装する。

**完了条件：** Wayland、X11 fallback、日本語 IME が動作し、AppImage または deb を生成できる。

### M16：SSH リモート

WSL リモート基盤を一般化し、SSH 接続、agent 配置、鍵認証、`known_hosts`、reconnect、remote terminal / LSP / search / Git、agent update を実装する。

**完了条件：** Linux サーバー上のプロジェクトを編集でき、切断後に復旧し、WSL と共通プロトコルを使用できる。

### M17：拡張システム

**第 1 段階：** language definition、Tree-sitter grammar、LSP configuration、theme、icon theme、snippets、tasks、commands。

**第 2 段階：** WASM extension、external process extension、permission model、versioned API。

**禁止事項：** Node.js runtime を組み込まない。VSCode Extension API 互換を目標にしない。信頼できないネイティブ共有ライブラリを本体へ直接ロードしない。

### M18：AI エージェント統合

**初期対象：** Codex CLI、Claude Code、OpenCode、任意 CLI エージェント。

**実装範囲：** agent session、working directory、terminal integration、file change detection、diff review、approve / reject、patch apply、process stop、concurrent sessions、Git Worktree assignment。

**完了条件：** 複数エージェントを別 Worktree で実行し、差分をレビューし、プロセスを確実に終了できる。特定 AI ベンダーに依存しない。

### M19：DAP デバッガー

DAP client、launch、attach、breakpoints、stack frames、variables、watches、stepping、debug console、remote DAP を実装する。初期対象は Nim、Rust、C/C++、Python。

### M20：性能・安定性強化

**必須計測：** cold start、idle memory、input latency、frame time、layout time、text shaping、workspace load、file watcher load、LSP memory、terminal memory、remote latency、allocation count。

**目標：** macOS 通常起動 1 秒未満、空ワークスペース 50〜100MB 以内、60Hz で安定描画、120Hz を阻害しない設計、100MB 級ファイル、10 万ファイル級ワークスペース、8 時間連続利用、長時間アイドルでメモリが増加し続けないこと。

### M21：v1.0 正式リリース

**必須対象：** macOS、Windows、Linux、単一ファイル編集、ワークスペース、Tree-sitter、LSP、Git、ターミナル、タスク、WSL、SSH、設定、テーマ、キーバインド、language extension、CLI 型 AI エージェント統合、基本 DAP。

**配布優先順位：** 1. macOS Apple Silicon、2. Windows x64、3. Linux x64、4. macOS Intel（需要確認後）、5. Windows ARM64（需要確認後）。

## リリース系列

| バージョン | 内容 |
|---|---|
| `v0.1.0-alpha` | macOS 単一ファイル実用エディタ |
| `v0.2.0-alpha` | macOS ワークスペース・検索 |
| `v0.3.0-alpha` | Tree-sitter・LSP |
| `v0.4.0-alpha` | Git・ターミナル・タスク |
| `v0.5.0-beta` | macOS 署名・notarization・配布 |
| `v0.6.0-beta` | 設定・テーマ・キーバインド |
| `v0.7.0-beta` | Windows 版 |
| `v0.8.0-beta` | WSL リモート |
| `v0.9.0-beta` | Linux 版 |
| `v0.10.0-rc` | SSH・拡張・AI・DAP |
| `v1.0.0` | 正式版 |

## 依存関係

```text
M0 → M1 → M2 → M3 → M4 → M5 → M6 → M7 → M8 → M9 → M10 → M11 → M12
  → M13 → M14 → M15 → M16 → M17 → M18 → M19 → M20 → M21
```

## Codex への実装規則

各マイルストーン開始前に必ず次を実施する。

1. 前マイルストーンの完了条件を検証する
2. 対象機能の依存関係を確認する
3. 既存ライブラリと自作範囲を比較する
4. macOS 標準 API で解決できる範囲を先に確認する
5. 設計判断を `DESIGN_DECISIONS.md` に記録する
6. ベンチマークまたは計測基準を先に追加する
7. 最小縦切り実装を行う
8. Unit Test と Integration Test を追加する
9. Apple Silicon 環境で動作確認する
10. 次マイルストーンへ先行着手しない

macOS 固有機能を、将来の Windows / Linux 対応だけを理由に不自然な共通抽象へ押し込まない。共通 API は、複数 OS で実際に必要性が確認された時点で抽出する。

この順序では、M5 で macOS 実用版、M11 で署名・notarization 済みの配布可能版を先に成立させ、その後 Windows・WSL・Linux へ展開する。
