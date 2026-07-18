# Implementation review

最終確認日: 2026-07-18

この文書は、ロードマップのチェック済み表示をコード、テスト、Apple
Silicon macOSビルドの証拠と突き合わせたレビュー記録である。コードが
存在するだけでGUI実機確認済みとは扱わない。

## 確認済み

- M0: Nimble build、テストタスク、ベンチマークタスク、`nimpretty` formatter task、`nim check` lint task、macOS CI実行成功（run 29635552288）。
- M1: Cocoa/Metal/Retina/入力のmacOSネイティブコードがコンパイルされる。GUI起動・入力・リサイズは未確認。
- M1 input bridge: mouse tracking area、window mouse-move受信、left/right drag callbackを追加。個別デバイスの実機確認は未完了。
- M2: UIツリー、レイアウト、イベント、hit-test、hover/active/focus状態、PaintList filtering、世代付きIDのunit test。PaintListの矩形コマンドをmacOS native ABI経由でMetalへ転送し、保持用scene textureをdirty領域だけ更新してdrawableへblitする経路を追加。GUIギャラリー実機確認は未完了。
- M2 demo consistency: `setupDemoUi`のレイアウト結果をnative UI矩形へ直接渡し、main側の固定矩形上書きを除去。
- M2 UI gallery: 起動時PaintListを単一矩形からpanel、toolbar、rounded/border/shadow、nested clip、selection、caret、scrollbar、split markerを含む構成へ拡張。
- M1/M2 resize: AppKitの実測pointサイズを`windowResized`コマンドでNimへ戻し、レイアウト、PaintList、hit-test矩形を再計算する経路を追加。
- M6 multi-root: FileメニューのAdd Workspace Folderから複数ルートを追加し、各ルートをFSEvents監視へ登録、ルート別のツリーを最小表示する経路を追加。
- M6 workspace persistence: Workspace root一覧をEditorSessionへ保存し、再起動時に主ルート・追加ルートを復元して監視を再開する経路とsession unit testを追加。
- M6 Quick Open: FileメニューのQuick OpenからfuzzyFileSearchを実行し、候補をnative text surfaceへ表示、pointer clickを既存open経路へ接続。
- M2 renderer: rectangle、border、rounded rectangle、shadow、caret、selection、scrollbarの基本Metal描画をkind別に接続。GUIでの見た目確認は未完了。
- M2 clipping: PaintListのclip stackと`popClip`を追加し、dirty領域との交差をnative scissorへ転送。
- M3: Core Text計測、UTF-8/grapheme、atlasモデル、IME状態のunit test。
- M3 native IME: marked rangeを文書UTF-16位置として保持し、候補矩形をeditor座標からNSView座標へ変換する経路を補正。日本語IMEの実機確認は未完了。
- M3 text: Core Textのeditor textureをbacking scale factorで生成し、Retina scale変更時に再生成する経路を追加。Retina実機表示は未確認。
- M3 viewport: native text textureの先頭12行固定描画を廃止し、scrollLineを共有して可視範囲、カーソル、pointer hit-test、IME位置、Tree-sitter highlightを同期。
- M3 glyph geometry: Core Textの`CTLineGetOffsetForStringIndex`を使い、UTF-8 byte cursorとUTF-16選択範囲を実際のglyph幅へ変換。固定幅8px依存をカーソル・選択描画から除去。実機表示は未確認。
- M4: Piece Table、Undo/Redo、原子的な複数編集、位置変換、fuzz、100MBベンチマーク、Chunked Rope/Gap Buffer/Piece Tree/Hybrid比較。
- M5: ファイル、CRLF/LF、検索/置換、外部変更、タブ/分割、セッション、recoveryのunit test。
- M5 command rendering: Undo/Redo後のbuffer・syntax・cursor同期と、selection変更時の即時native redrawを追加。
- M5 pointer editing: macOSのクリック/ドラッグを編集Viewのgrapheme境界へ変換し、カーソル・選択範囲へ接続。
- M5 standard movement: Shift selection extension、Option word movement、word-backspace selectorをeditor coreへ接続。
- M5 find: Editメニューの`Cmd+F`からnative入力を受け、active documentの最初の一致を選択する経路を追加。
- M5 replace: native Replace Allダイアログからquery/replacementを受け、編集コアの原子的置換と表示更新へ接続。
- M5 Go to Line / Command Palette: native入力を編集コアの位置移動と既存コマンド（New、Save、Find、Workspace Search、検索キャンセル）へ接続し、開いたファイルをrecentFilesへ記録。
- M5 Open Recent: recentFilesをmacOS Fileメニューのポップアップへ同期し、選択項目を既存のファイルオープン経路へ接続。
- M6: 遅延列挙、複数ルート、ファイル操作、ignore、キャンセル可能検索、fuzzy/ripgrep検索、macOS FSEventsブリッジ、Worktree列挙APIの実装。
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
