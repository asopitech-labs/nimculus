# Implementation review

最終確認日: 2026-07-18

この文書は、ロードマップのチェック済み表示をコード、テスト、Apple
Silicon macOSビルドの証拠と突き合わせたレビュー記録である。コードが
存在するだけでGUI実機確認済みとは扱わない。

## 確認済み

- M0: Nimble build、テストタスク、ベンチマークタスク、macOS CI定義。
- M1: Cocoa/Metal/Retina/入力のmacOSネイティブコードがコンパイルされる。
- M2: UIツリー、レイアウト、イベント、dirty paintのunit test。世代付きIDとGUIギャラリー実機確認は未完了。
- M3: Core Text計測、UTF-8/grapheme、atlasモデル、IME状態のunit test。
- M4: Piece Table、Undo/Redo、原子的な複数編集、位置変換、fuzz、100MBベンチマーク、Chunked Rope/Gap Buffer/Piece Tree/Hybrid比較。
- M5: ファイル、CRLF/LF、検索/置換、外部変更、タブ/分割、セッション、recoveryのunit test。
- M6: 遅延列挙、複数ルート、ファイル操作、ignore、キャンセル可能検索、fuzzy/ripgrep検索、macOS FSEventsブリッジ、Worktree列挙APIの実装。
- M7: 6文法の独立C翻訳単位、FFI、増分parse、構文ノード、highlight/folding/outline/indentation/selection/navigation基盤のunit test。

## 修正済みの問題

- 複数編集の範囲検証前に変更を適用していたため、重複編集を事前拒否。
- 外部ファイル削除を変更として扱っていなかったため、削除を検知。
- 部分的・不正なセッションJSONで起動が失敗するため、復旧可能な既定値へフォールバック。
- macOSメニューのOpen/Saveがログ出力だけだったため、EditorSessionへ接続。
- IME確定文字列が編集バッファへ届かなかったため、選択範囲を置換。
- Finderの`openFiles:`、標準Edit/View/Windowメニューをネイティブ層へ追加。
- Workspaceの複数ルート、ファイル操作、fuzzy/ripgrep検索、Git Worktree列挙APIを追加。
- 10,000ファイル生成ワークスペースの列挙ベンチマークを追加。
- UI NodeHandleへgenerationを追加し、stale handleを検証可能にした。
- PieceTree/Hybridを含むM4候補構造比較ベンチマークを追加。
- 標準Undo/Redo/Cut/Copy/Paste、カーソル移動、UTF-8境界削除をmacOSコマンドコールバックへ接続。

## 未完了として明示した項目

GUI実機での日本語IME、カーソル・選択・文字描画、実ファイル
Open With、リサイズ・複数モニターの操作確認は、ヘッドレスunit testや
コンパイルだけでは証明できないため完了扱いにしていない。M6の10万ファイル
計測とWorktree状態分離、M7の遅延ハイライト実エディタ接続も残っている。
