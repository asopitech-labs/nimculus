---
name: nimculus-ui-dev
description: >-
  Nimculus / NimNUI のデスクトップ UI を実装・変更するときに使う。NimNUI コントロールや
  Metal 描画パス、macOS プラットフォーム層（Cocoa/Metal/IME）、レイアウト・イベント・
  再描画のコードを書く／直す作業で必ず参照する。「UI を実装して」「NimNUI に手を入れる」
  「Metal 描画を直す」「macOS の入力/IME を実装」「ビルドが通らない」「format/lint したい」
  「nimble build/test を回す」「nimcache/ディスク容量の扱い」といった作業で発動する。
  ビルド・整形・静的検査コマンド、nimcache 規律、UI スレッド非ブロッキング、端末に配慮した
  検証出力の実務を扱う。設計判断は nimculus-ui-design、テスト実行は nimculus-ui-test を参照。
---

# Nimculus / NimNUI UI 実装

デスクトップ UI の実装フェーズを扱う。設計（層分割・依存方向・最小縦切り・設計記録）は
[nimculus-ui-design]、テスト/ベンチ/受け入れは [nimculus-ui-test] を使う。正となる規約は
`DEVELOPMENT_GUIDELINES.md`、構成は `ARCHITECTURE.md`。

対象ツールチェーン: Nim 2 系 / ARC / Nimble workspace / Apple Silicon macOS。
主要ソース: `src/nimnui/`（UI 基盤）, `src/nimnui/platform/{macos,windows,headless}/`
（バックエンド）, `src/nimculus/`（アプリ層）, `tests/`。

## 1. 標準ワークフロー（毎回このコマンドを使う）

自前で `nim c ...` を組み立てず、nimble タスクを使う。各タスクは専用 `--nimcache` を持ち、
生成物を共有しない設計になっている。

```bash
nimble build     # release ビルド (.nimcache/build へ固定)
nimble format    # nimpretty --maxLineLen:100（コミット前に必ず）
nimble lint      # nim check（静的検査）
nimble test      # unit + integration（詳細は nimculus-ui-test）
```

- **整形は `nimble format`、静的検査は `nimble lint`** を使う。手で整形しない。
- 依存ライブラリ追加は標準ツールで検出できない問題に限定し、理由を
  `DESIGN_DECISIONS.md` に記録してから入れる。
- macOS を先行する。この環境の当面の実装対象は macOS のみ。Windows/WSL/Linux/SSH の
  新規実装は macOS の完了条件を満たすまで始めない（Windows コードの compile 確認が CI に
  あっても macOS 完了の代替にはしない）。

## 2. 層と依存方向をコードで守る

実装は [nimculus-ui-design] の依存図に従う。

```text
platform → renderer → NimNUI → editor core → application services
```

- OS 固有型（`NSView`, `CAMetalLayer`, `NSTextInputClient`, Win32 ハンドル）を NimNUI
  コアや editor core に import しない。OS 変換は各 `platform/{macos,windows}` バックエンドに
  閉じ込め、Nim へは C ABI 契約（`src/nimnui/platform/contracts.nim` / `contracts.h`）越しに
  渡す。macOS 固有は `.m` / Objective-C runtime 側に置き、所有権と解放を明示する。
- NimNUI 内部でも layout / render / state / event を混ぜない
  (`layout.nim`, `render.nim`, `ui_tree.nim`, `events.nim`, `commands.nim`,
  `controls.nim`, `text.nim`, `ime.nim`)。
- Git / LSP / terminal / task / agent は application service（`src/nimculus/*_service.nim`
  等）として分離。UI コールバック内で直接 JSON を parse したり外部プロセスを読み切ったり
  しない。

## 3. UI スレッドをブロックしない

Metal 描画コールバックと AppKit イベント/idle ループ上で重い処理をしない。

- Git / LSP / 検索 / task は非同期サービス越しに接続し、cancel・進捗・完了通知を持つ。
- 外部プロセスの stdout/stderr を `readAll` で無制限保持しない。非ブロッキングで消費し、
  機能ごとの出力上限・UTF-8 境界・切り詰め状態を定義する。
- 長時間処理は cancellation と timeout を持たせる。LSP の `readMessages` を Metal render
  コールバック経路に置かない。
- 再描画は dirty / paint invalidation で必要範囲だけ。リサイズ後も描画を維持し、60Hz 安定・
  120Hz を阻害しない。

## 4. macOS プラットフォーム実装の要点

- **描画**: Metal device / command queue / render pipeline / buffer / texture / frame timing の
  ライフサイクルを管理。Retina scale factor は論理↔ピクセル境界でのみ変換。
- **入力/IME**: キーボード・修飾キー・マウス・スクロール・トラックパッド・フォーカスを
  独立イベントで扱う。Command/Option/標準編集操作を優先。IME は composition の
  開始/更新/確定/キャンセルを個別処理し、候補ウィンドウ座標を論理・Retina 座標と整合させる。
  日本語/英語/記号/絵文字混在を実装時に必ず動かす。
- **テキスト**: byte offset / codepoint / grapheme / UTF-16 (LSP) を明示変換。混同しない。
  glyph atlas は再利用・拡張・eviction を維持。
- **統合**: アプリメニュー、Dock、Finder Open With、標準ファイルダイアログ、close request の
  明示的な accept/reject（dirty バッファや PTY cleanup をバイパスしない）。

## 5. nimcache とディスク容量の規律

ビルド・テスト・ベンチの前後で必ず確認する。放置すると再現性が落ちる。

```bash
df -h / /tmp                 # 空き容量
git status --short           # 生成物が追跡対象に混ざっていないか
```

- アドホックな検証は専用 `--nimcache:/tmp/nimculus-<目的>-cache` を使い、検証後に一時
  cache と生成バイナリを削除する。通常の `nimble build` は `.nimcache/build` に固定。
- workspace 内 cache が 500MB 超、またはディスク空きが 20% 未満なら、次の作業前に
  `nimble clean` などで整理する。`.gitignore` 済みを理由に放置しない。
- 削除対象は再生成可能なビルド cache のみ。参照リポジトリやユーザーのソース・設定は消さない。

## 6. 端末に配慮した検証出力

Nim のコンパイルログや反復テストを長時間そのまま端末へ流さない。

- 出力は一時ログへリダイレクトし、成功時は要約、失敗時は末尾の限定行 + 終了コードだけ表示。
  ログ本体は `/tmp/nimculus-<目的>.log` に置き、不要になったら削除する。
- 例:

```bash
nimble build > /tmp/nimculus-build.log 2>&1 || { tail -n 40 /tmp/nimculus-build.log; exit 1; }
```

- AppKit/Metal を起動する検証は短命の独立プロセスとして、専用 `HOME`・専用 `--nimcache`・
  明示的タイムアウトで実行する。クラッシュ時は終了コード・DiagnosticReports・実行環境を
  確認してから再実行し、フレーム数や条件を弱めて成功扱いにしない。

## 7. 実装完了前チェックリスト

- [ ] `nimble format` と `nimble lint` を通した
- [ ] 関連する `nimble test` を通した（詳細/追加は nimculus-ui-test）
- [ ] OS 固有型がコア層へ漏れていない／依存方向を保った
- [ ] UI スレッド（Metal/AppKit）をブロックしていない
- [ ] 日本語 IME・Retina・Command/Option キーへの影響を実機観点で確認した
- [ ] 文字単位（byte/codepoint/grapheme/UTF-16）の変換が正しい
- [ ] Unit/Integration/（必要なら fuzz/bench）を追加した
- [ ] nimcache・生成物・ディスク空き容量を確認し、不要 cache を整理した
- [ ] 影響に応じて `ARCHITECTURE.md` / `DESIGN_DECISIONS.md` を更新した
- [ ] 次マイルストーンの機能を先取り実装していない
