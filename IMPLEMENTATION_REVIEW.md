# Implementation review

最終確認日: 2026-07-18

この文書は、ロードマップのチェック済み表示をコード、テスト、Apple
Silicon macOSビルドの証拠と突き合わせたレビュー記録である。コードが
存在するだけでGUI実機確認済みとは扱わない。

## 確認済み

- M0: Nimble build、テストタスク、ベンチマークタスク、`nimpretty` formatter task、`nim check` lint task、macOS CI実行成功（run 29635552288）。
- M1: Cocoa/Metal/Retina/入力のmacOSネイティブコードがコンパイルされる。GUI起動・入力・リサイズは未確認。
- M1 uniform buffer: 基本rectangle/rounded rectangle描画でMetal shaderの`buffer(1)`へuniformを渡す契約を追加。
- M1 input bridge: mouse tracking area、window mouse-move受信、left/right drag callbackを追加。個別デバイスの実機確認は未完了。
- M1/M2 input event classification: AppKitのleft/right/other mouse down/up/drag、`flagsChanged`、`scrollWheel`をNSEvent typeごとに分類し、button番号とmodifier-changeをNimNUIへ保持。従来mouseDragged/type 6等がcommand扱いになる抜けを修正し、Zedのplatform event分類に合わせた回帰テストを追加。
- M2: UIツリー、レイアウト、イベント、hit-test、hover/active/focus状態、PaintList filtering、世代付きIDのunit test。PaintListの矩形コマンドをmacOS native ABI経由でMetalへ転送し、保持用scene textureをdirty領域だけ更新してdrawableへblitする経路を追加。GUIギャラリー実機確認は未完了。
- M2 layout: 子ノードごとのflex grow、preferred/min/maxサイズ制約をUIツリーへ追加し、Row/Columnの残余空間配分とテストを接続。
- M2 split interaction: split markerのpointer down/move/upをsplit ratioへ接続し、ドラッグ中にレイアウト・PaintListを再構築。
- M2 demo consistency: `setupDemoUi`のレイアウト結果をnative UI矩形へ直接渡し、main側の固定矩形上書きを除去。
- M2 UI gallery: 起動時PaintListを単一矩形からpanel、toolbar、rounded/border/shadow、nested clip、selection、caret、scrollbar、split markerを含む構成へ拡張。
- M1/M2 resize: AppKitの実測pointサイズを`windowResized`コマンドでNimへ戻し、レイアウト、PaintList、hit-test矩形を再計算する経路を追加。
- M6 multi-root: FileメニューのAdd Workspace Folderから複数ルートを追加し、各ルートをFSEvents監視へ登録、ルート別のツリーを最小表示する経路を追加。
- M6 multi-root mutation: Fileメニューの作成・削除・改名がprimary rootへ固定されていたため、絶対path payloadを登録済みrootへ解決し、secondary rootをroot指定APIで操作する経路とroot跨ぎrename拒否を追加。
- M6 workspace persistence: Workspace root一覧をEditorSessionへ保存し、再起動時に主ルート・追加ルートを復元して監視を再開する経路とsession unit testを追加。
- M6 Quick Open: FileメニューのQuick OpenからfuzzyFileSearchを実行し、候補をnative text surfaceへ表示、pointer clickを既存open経路へ接続。
- M6 search navigation: Workspace検索結果のクリックをファイルオープンと検索行・列へのカーソル移動へ接続。
- M6 path safety: mutation pathの実在部分をPOSIX `realpath`で検証し、シンボリックリンク経由でworkspace root外へ到達する操作を拒否。
- M6 preview coordinates: Workspace tree、Quick Open、検索結果の行選択を共有editor bounds原点から計算するよう修正。
- M2 renderer: rectangle、border、rounded rectangle、shadow、caret、selection、scrollbarの基本Metal描画をkind別に接続。GUIでの見た目確認は未完了。
- M2 renderer coverage: text/imageのplaceholder描画をnative kindへ接続し、PaintListにaffine transform stackを追加。実文字 shapingはM3、画像texture handleは後続拡張。
- M2 clipping: PaintListのclip stackと`popClip`を追加し、dirty領域との交差をnative scissorへ転送。
- M2 commands: `CommandRegistry`に未登録を安全に判別する`tryResolve`と、解決したコマンドを一度だけ実行する`dispatchShortcut`を追加し、Command/Shift修飾子の回帰テストを追加。
- M2 macOS modifiers: Zedの`gpui_macos`と同じNSEventModifierFlagsのビット契約を`macOSModifiers`でplatform-neutralなCommand/Option/Control/Shiftへ変換し、全ビットと無関係ビットの回帰テストを追加。
- M3: Core Text計測、UTF-8/grapheme、atlasモデル、IME状態のunit test。
- M3 native IME: marked rangeを文書UTF-16位置として保持し、候補矩形をeditor座標からNSView座標へ変換する経路を補正。日本語IMEの実機確認は未完了。
- M3 IME cancellation: AppKitの`unmarkText`がNim側compositionを取り残していたため、Zedの`InputHandler::unmark_text`相当として空のcomposing callbackを返し、ネイティブ表示と編集状態を同時に消去。
- M3 selection contract: `platformSetEditorSelection`でUTF-8 byte範囲をUTF-16へ変換してから、Core Text描画と`NSTextInputClient`へ渡す契約を確認。
- M3 text: Core Textのeditor textureをbacking scale factorで生成し、Retina scale変更時に再生成する経路を追加。Retina実機表示は未確認。
- M3/M5 text placement: NimNUIが算出したエディタ矩形をnativeへ渡し、Core Text textureを矩形サイズ・Retina scaleで再生成し、Metal quadを同じ矩形へ配置。
- M3 IME/hit-test origin: candidate rectangle、pointer hit-test、fraction問い合わせの全てでエディタ矩形原点を加減算し、window座標とtext-surface座標を混在させないよう修正。
- M3 viewport: native text textureの固定12行描画を廃止し、エディタ矩形の高さから可視行数を算出。scrollLineを共有して可視範囲、カーソル、pointer hit-test、IME位置、Tree-sitter highlightを同期。
- M3 glyph geometry: Core Textの`CTLineGetOffsetForStringIndex`を使い、UTF-8 byte cursorとUTF-16選択範囲を実際のglyph幅へ変換。固定幅8px依存をカーソル・選択描画から除去。実機表示は未確認。
- M3 glyph hit-test: `CTLineGetStringIndexForPosition`でクリック位置をCore Textの実測位置から取得し、エディタはUTF-8 byte offset、`NSTextInputClient`はUTF-16 offsetへ変換。日本語・絵文字を固定幅8pxで分割しない経路へ変更し、端点契約をnative testで確認。実機操作は未確認。
- M3 IME replacement range: Zedの`replace_and_mark_text_in_range`に合わせ、`setMarkedText:selectedRange:replacementRange:`のreplacement rangeを無視せず、UTF-16 document rangeをUTF-8 byte selectionへ変換してNimへ通知するcallbackを追加。現在選択範囲と異なるIME置換範囲でも編集対象を失わないよう修正。
- M2 stack layout: Stackの子を線形cursor計算から分離し、padding後のcontent rectangleへ重ねて配置。隣接矩形のhit-test境界をhalf-openへ統一し、境界上の二重ヒットを防止する回帰テストを追加。
- M4: Piece Table、Undo/Redo、原子的な複数編集、位置変換、fuzz、100MBベンチマーク、Chunked Rope/Gap Buffer/Piece Tree/Hybrid比較。
- M5: ファイル、CRLF/LF、検索/置換、外部変更、タブ/分割、セッション、recoveryのunit test。
- M5 command rendering: Undo/Redo後のbuffer・syntax・cursor同期と、selection変更時の即時native redrawを追加。
- M5 pointer editing: macOSのクリック/ドラッグを編集Viewのgrapheme境界へ変換し、カーソル・選択範囲へ接続。
- M5 standard movement: Shift selection extension、Option word movement、word-backspace selectorをeditor coreへ接続。
- M5 standard movement: macOSの上下移動、行頭/行末、文書先頭/末尾、改行、Tabの`doCommandBySelector:`を編集コアへ接続。
- M5 word movement: Option移動をgrapheme単位のUnicode whitespace / word / punctuation分類へ拡張し、Zedの句読点スキップ規則（`foo.bar`、`.hello`）と全角空白・改行を回帰テスト。
- M5 line movement: 行末計算がLFを含み次行先頭へ進む抜けを修正し、`lineEndByteOffset`で改行直前を返す回帰テストを追加。内部LF・保存時CRLFの境界を分離。
- M5 save boundary: CocoaのSave callback内で保存例外を捕捉し、C callback境界へ例外を漏らさずステータスへ表示。
- M5 save state: 書き込み成功前に`FileDocument.path`を変更しないよう保存先をローカル変数で扱い、失敗時の文書状態を保持。
- M5 persistence safety: session JSONとactive recoveryを同一ディレクトリの一時ファイルからrenameするatomic writeへ変更し、途中書き込みで既存状態を壊さない経路を追加。
- M5 document save safety: 通常の文書保存も同一ディレクトリの一時ファイルからrenameするatomic writeへ統一し、保存成功後にだけpath・外部変更stamp・dirty状態を更新。
- M5 Cmd+S behavior: 既存pathの文書でもSave Panelを毎回開いていたため、native Save commandをNimへ渡し、既存ファイルは直接保存、UntitledだけNSSavePanelを開く標準macOS経路へ修正。
- M5 close-save safety: Untitled文書の終了確認でSave Panel後に終了許可を無条件で立てていたため、保存成功時だけ`platformSetCloseDecision(true)`を呼ぶ契約へ修正。保存失敗時は終了を拒否する。
- M5 document mode safety: atomic replacement前に既存ファイルのUnix permissionsを一時ファイルへ引き継ぎ、実行可能なスクリプト等のモードを保存後も維持。
- M3/M5 grapheme editing: 左右移動、Backspace/Delete、word移動の境界をUTF-8 codepointから`textPositions`のgrapheme境界へ統一し、結合文字・絵文字ZWJ列を分割しない回帰テストを追加。
- M3 Unicode segmentation: Zedの`unicode-segmentation`依存に対応して、手書きの限定的なgrapheme判定を`nim-graphemes`のUnicode TR29 DFAへ置換。prepend、Indic conjunct、Hangul、emoji modifier/ZWJを含む回帰テストを追加。
- M3 visible text: `layoutVisibleText`の可視範囲をrune indexからgrapheme boundaryへ変更し、範囲端で結合文字・絵文字ZWJ列を分割しないテストを追加。
- M4 position contract: `lineColumn`の公開結果をUTF-8 byte列からgrapheme列へ修正し、UTF-16変換だけが明示的なbyte列経路を使うよう分離。日本語・絵文字行の上下移動に渡す列単位を統一。
- M4 edit boundary: PieceTableの低レベル`edit/applyEdits`でUTF-8 replacementとchar boundaryを事前検証し、partial codepoint編集が状態を壊さないよう回帰テストを追加。Zedのrope byte offsetとUnicode segmentationの責務分離を反映。
- M4 piece performance: `splitAt`、substring、UTF-8 boundary検証、line index rebuild、line lookupがbuffer全体の`toString()` flattenに依存しないpiece単位処理へ変更。100MBベンチマーク（約0.48秒のload/index）とfuzz/M4回帰テストを再実行。
- M4 dirty revision: 操作回数の`version`と内容状態のrevisionを分離し、Undo/Redoで保存済み内容へ戻った時にdirtyを解除。Redo履歴のrevision方向も回帰テストで検証。
- Zed reference audit: `references/zed` commit `858d317`の`crates/text/src/text.rs`、`editor/src/display_map.rs`、`gpui_macos/src/shaders.metal`を確認し、byte offset / grapheme display / named viewportの責務分離をNimculusへ反映。
- M6 watcher safety: FSEvents callbackとUI pollingが共有する変更キューを`Lock`で保護し、別スレッドからの変更通知でseqが競合しないよう修正。
- M6 watcher coalescing: Zedの`UpdatedEntriesSet`境界を参考に、FSEventsの変更pathをUIへ渡す前に正規化・順序保持の重複排除を行い、同一イベントバーストによる重複再描画を防止。
- M6 search invalidation: Workspace検索中または検索画面表示中にファイル変更を受けた場合、部分結果を破棄して同じqueryを再実行。Quick Openもqueryを保持して候補を再評価するよう修正。
- M6 search parsing: ripgrepの単純な`:`分割がコロンを含むmacOSパス・本文を壊していたため、NUL区切りの構造化レコードへ変更し、パス・行・列・本文を保持する回帰テストを追加。
- M6 search cancellation: ripgrepの`execCmdEx`による同期待ちを廃止し、POSIXでは一時出力・監視可能なProcess・`terminate`を使ってキャンセルを反映し、子プロセスを残さない`exec`起動に変更。
- M6 gitignore: 手書きの単純suffix matcherを廃止し、Zedの`ignore::gitignore::Gitignore`相当の`IgnoreStack`で階層`.gitignore`、否定・anchored glob、親ディレクトリsticky ignore、lazy cacheをrootごとに適用。
- M6 gitignore invalidation: FSEventsで`.gitignore`または`.git/info/exclude`が変更された時、rootごとのlazy IgnoreStackを置換して規則を即時再ロードする経路とテストを追加。
- M2 input clipping: `UiTree.hitTest`で祖先のviewport境界を遡って検証し、スクロール領域外の子へpointer eventが届かない契約と回帰テストを追加。
- M1/M2 coordinate boundary: AppKitの下原点view座標をNimNUIの上原点論理座標へUIイベント境界で一度だけ反転し、button/split/scrollのhit-testとevent routingを同じ座標系へ統一。
- M5 find: Editメニューの`Cmd+F`からnative入力を受け、active documentの最初の一致を選択する経路を追加。
- M5 replace: native Replace Allダイアログからquery/replacementを受け、編集コアの原子的置換と表示更新へ接続。
- M5 Go to Line / Command Palette: native入力を編集コアの位置移動と既存コマンド（New、Save、Find、Workspace Search、検索キャンセル）へ接続し、開いたファイルをrecentFilesへ記録。
- M5 Open Recent: recentFilesをmacOS Fileメニューのポップアップへ同期し、選択項目を既存のファイルオープン経路へ接続。
- M6: 遅延列挙、複数ルート、ファイル操作、ignore、キャンセル可能検索、fuzzy/ripgrep検索、macOS FSEventsブリッジ、Worktree列挙APIの実装。
- M6 multi-root ownership: Zedの`ProjectPath { worktree_id, path }`に合わせ、`WorkspaceEntry.rootPath`で所有rootを保持し、検索結果の絶対pathとroot相対relativePathを分離。root指定の作成・削除・改名APIを追加し、secondary rootへ誤ってprimary rootの操作を適用しない回帰テストを追加。
- M7: 6文法の独立C翻訳単位、FFI、増分parse、構文ノード、highlight/folding/outline/indentation/selection/navigation基盤、エディタ可視範囲からRGBA Metalテクスチャまでのunit test/build確認。
- M7 incremental editor path: `EditorSyntaxState.update`で旧ソースとの差分からUTF-8境界・行列を計算し、`SyntaxTree.edit`後に旧treeを渡して再parseする経路を追加。

## 修正済みの問題

- 複数編集の範囲検証前に変更を適用していたため、重複編集を事前拒否。
- 外部ファイル削除を変更として扱っていなかったため、削除を検知。
- 部分的・不正なセッションJSONで起動が失敗するため、復旧可能な既定値へフォールバック。
- macOSメニューのOpen/Saveがログ出力だけだったため、EditorSessionへ接続。
- IME確定文字列が編集バッファへ届かなかったため、選択範囲を置換。
- Finderの`openFiles:`、標準Edit/View/Windowメニューをネイティブ層へ追加。
- Workspaceの複数ルート、ファイル操作、fuzzy/ripgrep検索、Git Worktree列挙APIを追加。
- 大規模検索がUIを占有しないよう、ファイル単位でyieldできる協調型`SearchJob`とキャンセルテストを追加。
- フォルダ選択をWorkspaceオープンへ接続し、ルート直下の遅延ファイルツリーをMetalテキスト表示する最小縦切りを追加。
- macOS標準検索入力、Workspace検索結果、Worktree branch/HEADの最小表示をMetalテキストへ接続。
- Cocoa timerからSearchJobを継続pollし、検索結果を段階的にMetal表示する経路を追加。
- Workspaceオープン時にFSEvents監視を開始し、変更時にルート直下ツリーを再列挙する経路を追加。
- 複数Workspace rootごとに`.gitignore`とFSEvents watcherを分離。
- Editメニューから検索ジョブをキャンセルし、部分結果をstale状態で残さない経路を追加。
- IME marked textを編集バッファへ確定する前に、カーソル位置へ下線付きでMetalテキスト表示する経路を追加。
- `NSTextInputClient`の提案文字列、UTF-16 selectedRange、characterIndex問い合わせを実装し、Nimのbyte範囲と同期。
- UTF-16選択範囲を行内矩形へ変換し、RGBAテキスト面に選択背景とカーソルを描画。
- grapheme位置計算に地域指示子ペアとCRLF境界のテストを追加。
- macOS FileメニューのNew/`Cmd+N`を新規`FileDocument`へ接続。
- 外部変更検知をメインループtickへ接続し、Reload / Keep Editingの標準Alertを追加。
- 10,000ファイル生成ワークスペースの列挙ベンチマークを追加。
- 100,000ファイル生成ワークスペースの列挙計測（約0.78秒）を実行。
- 1MB級Tree-sitter入力のparse・可視範囲highlightベンチマークを追加。
- Tree-sitterの構文状態をエディタ更新経路へ接続し、可視範囲ハイライトを取得可能にした。
- アクティブ文書の内容をCore Text経由のMetalテクスチャへ更新し、編集後に再描画する経路を追加。
- UTF-8 byte offsetからUTF-16描画範囲へ変換し、Tree-sitter spanごとのCore Text色付けを追加。
- Metal device、CAMetalLayer、Retina drawable sizeを確認するネイティブスモークテストを追加。Metal deviceを公開しないヘッドレス/端末セッションでは、テストを失敗扱いにせずスキップする。
- Worktree rootをキーにHEAD/branch状態を分離するAPIとテストを追加。
- UI NodeHandleへgenerationを追加し、stale handleを検証可能にした。
- PieceTree/Hybridを含むM4候補構造比較ベンチマークを追加。
- 標準Undo/Redo/Cut/Copy/Paste、カーソル移動、UTF-8境界削除をmacOSコマンドコールバックへ接続し、編集後に表示・構文色を同期。
- macOS FileメニューのNew File/New Folder/Rename/DeleteをWorkspace相対パスのAPIへ接続し、成功時にプレビューとFSEvents監視を更新。
- Workspaceのファイル操作APIで空相対パスを拒否し、UI経由でなくてもルート自体を削除・移動できない回帰テストを追加。
- Workspaceルート直下の表示項目をmacOSポインターの行位置へ対応付け、ファイルクリックで文書を開き、ディレクトリクリックでWorkspaceを切り替える経路を追加。
- macOSのWindow close / application terminateをdirty状態へ接続し、Cmd+W / Cmd+QでSave・Don't Save・Cancelを選べる終了確認を追加。Untitled文書のSaveは標準NSSavePanelへ接続。
- M5のSession/Recovery APIをmacOS起動・終了経路へ接続。`~/Library/Application Support/Nimculus/session.json`を保存・復元し、dirtyなアクティブ文書を`active.recovery`へ定期保存、起動時に復元する。

## 未完了として明示した項目

GUI実機での日本語IME、カーソル・選択・文字描画、実ファイル
Open With、リサイズ・複数モニターの操作確認は、ヘッドレスunit testや
コンパイルだけでは証明できないため完了扱いにしていない。M6の10万ファイル
計測、Worktree状態分離、構文色のRGBA Metalテクスチャ接続、ネイティブスモークは
完了したが、`Cmd+,`設定画面、Git diff/stage等の高度なUI、IMEの実機操作、カーソル/選択/文字表示のGUI確認は残っている。
