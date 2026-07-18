# Implementation review

最終確認日: 2026-07-18

この文書は、ロードマップのチェック済み表示をコード、テスト、Apple
Silicon macOSビルドの証拠と突き合わせたレビュー記録である。コードが
存在するだけでGUI実機確認済みとは扱わない。

## 確認済み

- M0: Nimble build、テストタスク、ベンチマークタスク、`nimpretty` formatter task、`nim check` lint task、macOS CI定義。
- M1: Cocoa/Metal/Retina/入力のmacOSネイティブコードがコンパイルされる。
- M2: UIツリー、レイアウト、イベント、dirty paint、世代付きIDのunit test。Metal deviceが利用可能な実行環境でネイティブスモークを確認し、GUIギャラリー実機確認は未完了。
- M3: Core Text計測、UTF-8/grapheme、atlasモデル、IME状態のunit test。
- M4: Piece Table、Undo/Redo、原子的な複数編集、位置変換、fuzz、100MBベンチマーク、Chunked Rope/Gap Buffer/Piece Tree/Hybrid比較。
- M5: ファイル、CRLF/LF、検索/置換、外部変更、タブ/分割、セッション、recoveryのunit test。
- M6: 遅延列挙、複数ルート、ファイル操作、ignore、キャンセル可能検索、fuzzy/ripgrep検索、macOS FSEventsブリッジ、Worktree列挙APIの実装。
- M7: 6文法の独立C翻訳単位、FFI、増分parse、構文ノード、highlight/folding/outline/indentation/selection/navigation基盤、エディタ可視範囲からRGBA Metalテクスチャまでのunit test/build確認。

## 修正済みの問題

- 複数編集の範囲検証前に変更を適用していたため、重複編集を事前拒否。
- 外部ファイル削除を変更として扱っていなかったため、削除を検知。
- 部分的・不正なセッションJSONで起動が失敗するため、復旧可能な既定値へフォールバック。
- macOSメニューのOpen/Saveがログ出力だけだったため、EditorSessionへ接続。
- IME確定文字列が編集バッファへ届かなかったため、選択範囲を置換。
- Finderの`openFiles:`、標準Edit/View/Windowメニューをネイティブ層へ追加。
- Workspaceの複数ルート、ファイル操作、fuzzy/ripgrep検索、Git Worktree列挙APIを追加。
- 大規模検索がUIを占有しないよう、ファイル単位でyieldできる協調型`SearchJob`とキャンセルテストを追加。
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
- 標準Undo/Redo/Cut/Copy/Paste、カーソル移動、UTF-8境界削除をmacOSコマンドコールバックへ接続。

## 未完了として明示した項目

GUI実機での日本語IME、カーソル・選択・文字描画、実ファイル
Open With、リサイズ・複数モニターの操作確認は、ヘッドレスunit testや
コンパイルだけでは証明できないため完了扱いにしていない。M6の10万ファイル
計測、Worktree状態分離、構文色のRGBA Metalテクスチャ接続、ネイティブスモークは
完了したが、M6検索ジョブのアプリUI接続とGUI実機操作確認は残っている。
