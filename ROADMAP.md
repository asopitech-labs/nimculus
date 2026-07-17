# Nimculus ロードマップ：macOS優先版

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

**目的：** NimNUI と Nimculus を含むモノレポの開発基盤を構築する。

**実装範囲：** Nim 2 系、ARC、Nimble workspace、macOS CI、Apple Silicon 向けビルド、formatter、linter、unit test / benchmark runner、mock renderer、`README.md`、`ARCHITECTURE.md`、`DESIGN_DECISIONS.md`、本ロードマップ。

**完了条件：** Apple Silicon macOS で `nimble build` が成功し、テストを実行できる。NimNUI と Nimculus のアプリ層が分離され、macOS CI が成功する。

### M1：macOS ウィンドウと Metal 描画

**目的：** macOS 上で NimNUI の最小描画基盤を成立させる。

**実装範囲：**

- macOS プラットフォーム層：Objective-C Runtime 連携、`NSApplication`、`NSWindow`、`NSView`、`CAMetalLayer`、イベントループ、Retina scale factor、リサイズ、フルスクリーン、最小化、最大化相当動作、複数モニター
- Metal：device、command queue、swapchain 相当管理、render pipeline、vertex / uniform buffer、rectangle、clear color、resize、frame timing
- 入力：キーボード、修飾キー、マウス、スクロール、トラックパッド、ウィンドウフォーカス

**成果物：** macOS で起動する Nimculus ウィンドウ、Metal 背景・Rectangle 描画、入力イベントログ、Retina 対応、macOS CI。

**完了条件：** Apple Silicon macOS で起動し、Metal 描画・リサイズ・Retina scale が維持され、キーボードとポインター入力を取得できる。

### M2：NimNUI 基礎 UI システム

**目的：** GPU ネイティブ UI を構築できる最小基盤を実装する。

**実装範囲：**

- レイアウト：Row、Column、Stack、固定・最小・最大サイズ、Padding、Gap、Alignment、Flex grow、Scroll container、Viewport clipping
- 描画：Rectangle、Border、Rounded rectangle、Text placeholder、Image、Clip、Transform、Shadow、Caret、Selection region、Scrollbar
- 状態：Node ID、世代付き ID、Focus、Hover、Active、Disabled、Dirty flag、layout / paint invalidation
- イベント：Capture / Target / Bubble、keyboard / pointer routing、focus traversal、command dispatch、shortcut resolution、macOS Command キー
- 基本 UI：Label、Button、Scroll view、Split pane、Tab bar、Context menu、Popup、Tooltip

**完了条件：** 分割ペインのドラッグ、スクロール・クリッピング、フォーカス移動、Command キーショートカット、dirty 領域のみの再描画が機能し、UI ギャラリーが macOS 上で安定動作する。

### M3：macOS テキスト描画と IME

**目的：** コードエディタに必要な文字表示と入力を完成させる。

**実装範囲：**

- フォント：Core Text / HarfBuzz の役割分担調査、フォント列挙・ロード・フォールバック、等幅、Bold、Italic、Retina 描画
- シェーピング：UTF-8、grapheme cluster、combining character、ligature、glyph positioning、fallback run、最低限の BiDi
- GPU 文字描画：glyph atlas、再利用・拡張、cache eviction、Metal texture、可視範囲描画、サブピクセル位置
- IME：`NSTextInputClient` 相当、composition の開始・更新・確定・キャンセル、候補位置、日本語、絵文字、クリップボード

**完了条件：** macOS 日本語 IME、カーソル位置の変換候補、grapheme 単位のカーソル、日本語・英語・記号・絵文字の混在表示、Retina 文字描画、1 万行相当の滑らかなスクロールが動作する。

### M4：エディタバッファと編集コア

**目的：** UI から独立した高速なテキスト編集エンジンを実装する。

**事前検証：** Rope、Piece Table、Piece Tree、Gap Buffer、Hybrid 構造を、ファイルロード、中央挿入、連続入力、大量削除、Undo/Redo、行位置変換、UTF-16 位置変換、メモリ使用量で比較する。

**実装範囲：** UTF-8 内部表現、line index、byte offset、codepoint / grapheme / UTF-16 LSP position、incremental edit、dirty state、Undo、Redo、複数カーソル、選択、編集グループ、保存地点管理。

**完了条件：** 100MB 級ファイルを開け、Undo/Redo・複数カーソル編集・UTF-8 / UTF-16 / 行列変換が正しく動作し、fuzz test で不整合が発生しない。

### M5：macOS 最小実用エディタ — `v0.1.0-alpha`

**目的：** macOS で日常利用できる単一ファイルエディタを完成させる。

**実装範囲：** 開く、新規、保存、名前を付けて保存、外部変更検知、未保存確認、タブ、分割、行番号、カーソル、選択、検索、置換、Go to line、ソフトラップ、スクロール、インデントガイド、ステータスバー、コマンドパレット、標準ショートカット、最近開いたファイル、セッション復元、クラッシュリカバリー。

**macOS 統合：** アプリケーションメニュー、File / Edit / View / Window メニュー、Dock、Open With、`Cmd+O` / `Cmd+S` / `Cmd+W` / `Cmd+Q` / `Cmd+,`、標準ファイルダイアログ。

**完了条件：** macOS 標準アプリとして自然に操作でき、日本語ファイルを安全に編集・保存できる。CRLF / LF、外部変更、2 時間以上の連続編集を安定して扱える。

### M6：macOS プロジェクト・ワークスペース — `v0.2.0-alpha`

**実装範囲：** フォルダ・複数ルート・Git Worktree、ワークスペース復元、ファイルツリー、遅延ロード、作成・削除・名前変更、Finder 連携、fuzzy file search、ripgrep 全文検索、`.gitignore`、FSEvents、変更集約、除外設定。

**完了条件：** 10 万ファイル級を開け、起動時に全内容を読み込まず、検索キャンセル、Git Worktree、大量変更時の UI 応答性を維持できる。

### M7：Tree-sitter

**初期対象：** Nim、Rust、TypeScript、Python、JSON、Markdown。

**実装範囲：** Tree-sitter FFI、grammar loader、incremental parse、syntax highlighting、bracket matching、indentation、folding、outline、selection expansion、syntax-aware navigation。

**完了条件：** 編集差分に応じた再解析、大規模ファイルの遅延ハイライト、構文エラー時の安定動作、grammar 追加手順の文書化。

### M8：LSP クライアント — `v0.3.0-alpha`

**初期対象：** Nim、Rust、TypeScript、Python。

**実装範囲：** JSON-RPC、stdio transport、cancellation、timeout、lifecycle、restart、diagnostics、completion、hover、definition、references、symbols、rename、formatting、code action、signature help、semantic tokens、inlay hints。

**完了条件：** Language Server の異常終了から復旧し、stale response を破棄できる。completion が入力をブロックせず、Tree-sitter と LSP 表示を統合できる。

### M9：macOS Git 統合

**実装範囲：** repository 検出、status、branch、diff、inline diff、gutter indicator、stage / unstage、commit、log、blame、checkout、conflict 表示。初期実装は Git CLI を使用する。

**完了条件：** 大規模リポジトリで UI を停止させず、Git 処理をキャンセルでき、Worktree ごとに状態を分離できる。

### M10：macOS 統合ターミナルとタスク — `v0.4.0-alpha`

**実装範囲：**

- ターミナル：macOS PTY、zsh / bash / fish、ANSI/VT parser、screen buffer、scrollback、選択、copy/paste、resize、複数セッション
- タスク：build、test、run、working directory、環境変数、cancellation、background task、problem matcher、output panel

**完了条件：** zsh を安定実行し、ターミナルリサイズ、複数セッション切替、長時間タスクの停止が機能する。

### M11：macOS 配布基盤 — `v0.5.0-beta`

**実装範囲：** `.app` bundle、アイコン、`Info.plist`、file association、URL scheme、code signing、hardened runtime、notarization、stapling、DMG、ZIP、自動更新基盤、crash report、session recovery。

**完了条件：** 署名済み Apple Silicon アプリを生成でき、Gatekeeper 警告なしで起動し、notarization を通過し、DMG からインストールできる。

### M12：設定・テーマ・キーバインド — `v0.6.0-beta`

**実装範囲：** global / workspace / language settings、schema validation、live reload、keymap、command registry、theme、icon theme、font / terminal / LSP settings。

**macOS 要件：** Command キー中心の標準キーマップ、Option キーの単語移動、標準編集操作、システム外観連動、Light / Dark 切替（アクセントカラー連動は任意）。

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
