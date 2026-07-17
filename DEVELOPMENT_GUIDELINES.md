# Nimculus 開発ガイドライン

## 1. 目的と適用範囲

この文書は、Nimculus および NimNUI の設計・実装・検証・リリースに共通して適用する開発規約である。機能の優先順位とマイルストーンの詳細は [`ROADMAP.md`](./ROADMAP.md) を正とする。

初期開発の主対象は Apple Silicon 搭載 macOS とする。macOS で GPU 描画、IME、標準 UI 統合、PTY、署名、notarization、`.app` / DMG 配布までを成立させた後、Windows、WSL、Linux、SSH へ展開する。

## 2. 基本原則

### 2.1 macOS を先行する

次の順序を変更しない。

1. macOS
2. Windows
3. WSL リモート
4. Linux
5. SSH リモート

WSL は Windows 版の完成後に着手する。macOS の完成度を下げて他プラットフォームを先行させない。

### 2.2 Apple Silicon を基準環境とする

初期の実装・テスト・ベンチマーク・配布物は Apple Silicon macOS を基準にする。Intel macOS と Windows ARM64 は、v1.0 での需要を確認してから優先度を決める。

### 2.3 動作契約を共有し、OS API は無理に共有しない

複数 OS 間で共有するのは、入力、描画、ファイル、ターミナル、リモート接続などの動作契約とデータモデルである。Cocoa、Win32、Wayland、X11、PTY、ConPTY などの OS 固有 API を、不自然な共通抽象へ押し込まない。

共通 API は、複数 OS で実際の重複と必要性が確認された時点で抽出する。将来の移植可能性だけを理由に、macOS 固有機能の品質や実装速度を犠牲にしない。

### 2.4 GPU ネイティブ UI を維持する

NimNUI は Metal を中心に GPU ネイティブ UI として設計する。描画、レイアウト、入力、状態、イベント、テキスト描画を分離し、UI から編集コアやリモートエージェントへ直接依存させない。

### 2.5 依存関係を一方向に保つ

基本的な依存関係は次のとおりとする。

```text
platform → renderer → NimNUI → editor core → application services
                                              ↘ Git / LSP / terminal / remote / agent
```

プラットフォーム層の型や OS オブジェクトを、編集コアやドメインモデルへ漏らさない。外部プロセス、Git、LSP、ターミナル、リモート機能はアプリケーションサービスとして分離する。

## 3. 開発環境とリポジトリ構成

### 3.1 基準ツールチェーン

- Nim 2 系
- ARC
- Nimble workspace
- Apple Silicon 向け macOS ビルド
- macOS CI
- formatter
- linter
- unit test runner
- benchmark runner
- mock renderer

モノレポの初期段階で、NimNUI と Nimculus のアプリ層を分離する。ビルド、テスト、ベンチマーク、モック描画を単独で実行できる状態を保つ。

### 3.2 ドキュメント

設計・運用に関係する変更では、必要に応じて次の文書も更新する。

- `README.md`：利用者・開発者向けの導入手順
- `ARCHITECTURE.md`：システム構成と依存関係
- `DESIGN_DECISIONS.md`：採用・不採用にした設計判断と理由
- `ROADMAP.md`：マイルストーン、完了条件、リリース計画
- `DEVELOPMENT_GUIDELINES.md`：本開発規約

## 4. マイルストーン開発プロセス

各マイルストーン開始前に、必ず次のゲートを通過する。

1. 前マイルストーンの完了条件を検証する
2. 対象機能の依存関係を確認する
3. 既存ライブラリと自作範囲を比較する
4. macOS 標準 API で解決できる範囲を確認する
5. 設計判断を `DESIGN_DECISIONS.md` に記録する
6. ベンチマークまたは計測基準を先に追加する
7. 最小縦切り実装を行う
8. Unit Test と Integration Test を追加する
9. Apple Silicon 環境で動作確認する
10. 完了条件を再検証してから次へ進む

次のマイルストーンへ先行着手しない。未達の完了条件、既知のクラッシュ、再現可能なデータ破損、または配布を妨げる問題がある場合は、現在のマイルストーンを完了扱いにしない。

## 5. 最小縦切りの進め方

新機能は、抽象 API を先に広げるのではなく、ユーザーが確認できる最小縦切りで実装する。

1. macOS の標準 API と最小の Nim ラッパーを接続する
2. 画面上の最小成果物を表示する
3. 入力またはイベントを受け取る
4. 状態変更をドメイン層へ伝える
5. 必要範囲だけ再描画する
6. Unit Test、Integration Test、ベンチマークを追加する
7. 完了条件に沿った実機検証を行う

この手順は、ウィンドウ、Metal、UI、IME、編集、ワークスペース、LSP、ターミナル、リモート機能に適用する。

## 6. macOS プラットフォーム規約

### 6.1 ウィンドウ・描画

- `NSApplication`、`NSWindow`、`NSView`、`CAMetalLayer` を macOS プラットフォーム層に閉じ込める
- Objective-C Runtime 連携の宣言と所有権を明示する
- Retina scale factor は論理座標とピクセル座標の境界で変換する
- ウィンドウリサイズ、フルスクリーン、最小化、最大化相当動作、複数モニターを検証対象にする
- Metal device、command queue、render pipeline、buffer、texture、frame timing のライフサイクルを管理する
- リサイズ後も描画を維持し、60Hz で安定し、120Hz を阻害しない設計にする

### 6.2 入力・IME

- キーボード、修飾キー、マウス、スクロール、トラックパッド、フォーカスを独立したイベントとして扱う
- macOS の Command キー、Option キー、標準編集操作を優先する
- IME は `NSTextInputClient` 相当の契約を満たす
- composition の開始、更新、確定、キャンセルを個別に扱う
- 変換候補の表示位置は論理座標・Retina 座標と整合させる
- 日本語、英語、記号、絵文字を混在させた入力を必ず検証する

### 6.3 macOS 統合と配布

- アプリケーションメニュー、File / Edit / View / Window メニューを標準的に提供する
- Dock、Finder の Open With、Finder からのファイルオープン、標準ファイルダイアログを実装する
- `.app` bundle、`Info.plist`、アイコン、file association、URL scheme を管理する
- hardened runtime、code signing、notarization、stapling を CI で検証する
- Gatekeeper 警告なしの起動、DMG / ZIP インストール、Apple Silicon 配布物生成をリリース条件とする

## 7. UI・テキスト・編集コアの規約

### 7.1 NimNUI

レイアウト、描画、状態、イベントを分離する。Node ID と世代付き ID を使用し、Focus、Hover、Active、Disabled、Dirty flag を明示的に管理する。

イベントは Capture、Target、Bubble の順序を持ち、keyboard routing、pointer routing、focus traversal、command dispatch、shortcut resolution を独立させる。Scroll container は viewport clipping と組み合わせ、dirty / paint invalidation により必要範囲のみを再描画する。

### 7.2 テキスト描画

Core Text と HarfBuzz の役割分担を実測と要件に基づいて決定する。UTF-8、grapheme cluster、combining character、ligature、glyph positioning、fallback run を正しく扱い、glyph atlas は再利用・拡張・eviction を備える。

カーソル位置、選択範囲、行列変換は byte offset、codepoint、grapheme、UTF-16 LSP position の間で明示的に変換する。文字単位を混同しない。

### 7.3 編集バッファ

Rope、Piece Table、Piece Tree、Gap Buffer、Hybrid 構造を、実際の操作負荷で比較してから採用する。ファイルロード、中央挿入、連続入力、大量削除、Undo/Redo、行位置・UTF-16 変換、メモリ使用量をベンチマークする。

編集操作は複数カーソルを含めて原子的に処理する。Undo/Redo、dirty state、編集グループ、保存地点を UI から独立させ、fuzz test で不整合を検出する。

## 8. 外部サービスとリモート機能

### 8.1 Git、LSP、Tree-sitter

- Git の初期実装は Git CLI を使用する
- Git、LSP、検索、タスクは UI スレッドをブロックしない
- 長時間処理は cancellation と timeout を持つ
- LSP は JSON-RPC、stdio、lifecycle、restart、stale response 破棄を実装する
- Tree-sitter は incremental parse と遅延ハイライトを前提とする
- 初期言語対象は Nim、Rust、TypeScript、Python。Tree-sitter では JSON、Markdown も対象とする

### 8.2 ターミナルとタスク

macOS では PTY と zsh を第一対象とし、bash / fish も扱う。ANSI/VT parser、screen buffer、scrollback、選択、copy/paste、resize、複数セッションを分離してテストする。タスクは build、test、run、作業ディレクトリ、環境変数、停止、バックグラウンド実行、problem matcher を備える。

### 8.3 WSL・SSH

リモート側に `nimculus-agent` を配置し、GUI と agent の責務を分離する。version negotiation、remote file API、watcher、search、Git、LSP、terminal、tasks、reconnect、agent update を共通プロトコルで扱う。

WSL では `\\wsl$` 経由の直接監視に依存しない。複数ディストリビューション、ネットワーク切断、agent 異常終了、再接続を検証する。SSH は WSL 基盤を一般化して実装する。

## 9. 拡張・AI・デバッグ

拡張の第 1 段階は language definition、Tree-sitter grammar、LSP configuration、theme、icon theme、snippets、tasks、commands とする。第 2 段階で WASM extension、external process extension、permission model、versioned API を追加する。

Node.js runtime を組み込まず、VSCode Extension API 互換を目標にしない。信頼できないネイティブ共有ライブラリを本体へ直接ロードしない。

AI エージェントは Codex CLI、Claude Code、OpenCode、任意 CLI を対象とし、agent session、Worktree、差分レビュー、approve / reject、patch apply、停止、同時実行を提供する。特定 AI ベンダーの API に依存しない。

DAP は Nim、Rust、C/C++、Python を初期対象とし、launch、attach、breakpoint、stack、variables、watches、stepping、debug console、remote DAP を実装する。

## 10. テストと品質基準

### 10.1 必須テスト

- Unit Test：編集コア、座標変換、状態、イベント、設定、プロトコル
- Integration Test：ウィンドウ、Metal、IME、ファイル、Git、LSP、PTY、agent
- Fuzz Test：編集、Undo/Redo、UTF-8 / UTF-16 / grapheme 変換、プロトコル
- UI Gallery Test：レイアウト、フォーカス、スクロール、dirty 再描画
- CI Test：Apple Silicon macOS を必須とし、対応 OS 追加後は各 OS の CI を追加する

### 10.2 完了判定

完了条件は、コードが存在することではなく、再現可能なテスト・ベンチマーク・実機確認で判定する。既知のデータ破損、入力不能、UI フリーズ、再現可能なクラッシュ、配布不能の問題を残したまま次のマイルストーンへ進めない。

### 10.3 性能計測

次の指標を計測可能にする。

`cold start`、`idle memory`、`input latency`、`frame time`、`layout time`、`text shaping`、`workspace load`、`file watcher load`、`LSP memory`、`terminal memory`、`remote latency`、`allocation count`。

目標は、通常起動 1 秒未満、空ワークスペース 50〜100MB 以内、100MB 級ファイル、10 万ファイル級ワークスペース、8 時間連続利用、長時間アイドルでメモリが増加し続けないこととする。

## 11. リリース運用

リリース系列は次の順序とする。

| バージョン | 到達点 |
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

v1.0 の必須対象は macOS、Windows、Linux、単一ファイル編集、ワークスペース、Tree-sitter、LSP、Git、ターミナル、タスク、WSL、SSH、設定、テーマ、キーバインド、language extension、CLI 型 AI エージェント統合、基本 DAP とする。配布優先順位は macOS Apple Silicon、Windows x64、Linux x64、macOS Intel、Windows ARM64 の順とする。

## 12. 変更レビューのチェックリスト

- [ ] 対応するマイルストーンと完了条件を明記した
- [ ] macOS 標準 API の利用可否を確認した
- [ ] OS 固有コードがコア層へ漏れていない
- [ ] 依存関係と所有権を説明できる
- [ ] Unit Test / Integration Test を追加した
- [ ] 必要な fuzz test またはベンチマークを追加した
- [ ] UI スレッドをブロックしていない
- [ ] 日本語 IME、Retina、Command / Option キーへの影響を確認した
- [ ] Apple Silicon macOS で動作確認した
- [ ] `ARCHITECTURE.md` または `DESIGN_DECISIONS.md` を更新した
- [ ] 次マイルストーンの機能を先行実装していない

## 13. 最終方針

M5 で macOS 実用版、M11 で署名・notarization 済みの配布可能版を成立させる。その後に Windows、WSL、Linux、SSH へ展開する。macOS を単なる最初の移植先ではなく、GPU、IME、標準統合、配布、性能、安定性を検証する第一の製品基盤として扱う。
