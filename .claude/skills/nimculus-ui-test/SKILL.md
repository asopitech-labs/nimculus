---
name: nimculus-ui-test
description: >-
  Nimculus / NimNUI のデスクトップ UI を検証・テストするときに使う。unit/integration/
  fuzz/UI gallery テストの追加や実行、Metal 描画・IME・レイアウト・入力の検証、性能
  ベンチマーク（cold start / soak / frame time 等）、macOS 実機受け入れや E2E ゲートを
  扱う作業で必ず参照する。「テストを書きたい/回したい」「nimble test が落ちる」
  「UI の動作確認」「IME/Retina/描画を検証」「ベンチマーク/soak を取りたい」
  「macOS 受け入れ確認」「完了判定してよいか」「E2E ゲートを回す」といった相談で発動する。
  テストコマンド、専用 nimcache、完了判定基準、端末に配慮したログ運用を扱う。
  設計は nimculus-ui-design、実装は nimculus-ui-dev を参照。
---

# Nimculus / NimNUI UI 検証・テスト

デスクトップ UI の検証フェーズを扱う。設計は [nimculus-ui-design]、実装は
[nimculus-ui-dev]。正となる基準は `DEVELOPMENT_GUIDELINES.md` の「10. テストと品質基準」、
macOS 実機受け入れは `docs/MACOS_MANUAL_ACCEPTANCE.md`。

**完了はコードの存在ではなく、再現可能なテスト・ベンチマーク・実機確認で判定する。**
既知のデータ破損・入力不能・UI フリーズ・再現可能クラッシュ・配布不能を残して次へ進めない。

## 0. 検証の関門（最優先。これを間違えると他が全部無意味になる）

**`nimble` の終了コードを検証に使わないこと。** この環境の nimble 0.22.2 は
子プロセスの失敗を潰す。実測（2026-08-10）:

```
nimble nonexistenttask   → rc=0     ← 存在しない task でも 0
nimble test（1 件失敗）  → rc=0
```

`nimble test` / `build` / `lint` の rc は**すべて意味を持たない**。

正しい関門はランナーを直接走らせること:

```bash
nim c --mm:arc --nimcache:.nimcache/test_runner -r --path:src tests/test_runner.nim
```

これは全ファイルを走らせ、最後に要約を出し、**失敗すれば rc=1 を返す**。

```
実行: 27 / 成功: 26 / 失敗: 1
失敗したファイル:
  tests/test_platform_contract.nim
```

### なぜこれが要るか

2026-08-10 まで `task test` は `exec` を並べる形で、**最初の失敗で中断**していた。
`test_platform_contract` が落ちた結果 **27 本中 6 本しか走らず**、
それでも `nimble test` は 0 を返していた。
`test_lsp` / `test_settings` / `test_ui_text` / `test_editor` などは
**一度も走らないまま「テストが通った」と報告されていた。**

ランナーは `tests/test_*.nim` を**走査**する。一覧をハードコードしない。
登録を忘れて黙って走らない、という同じ失敗を繰り返さないため。
除外は `excludedTestFiles` に理由付きで書く（Windows 専用の 3 件は
`task testWindows` の担当）。

### 「走らなかった」と「成功した」を区別する

出力の `実行: N` を見る。件数が減っていたら、通ったのではなく走っていない。

### ランナーだけでは足りない — アプリ本体のビルドを必ず見る

**ランナーはテストファイルしかコンパイルしない。`src/nimculus/main.nim` は対象外。**
型を変えて呼び出し側が追随できていなくても、**テストは 27/27 で通る。**

2026-08-12 の実例: `src/nimnui/events.nim` の `UiEvent` を構造化したところ、
`main.nim:9731` が旧い平坦な生成を使っていてコンパイルできなくなった。
**ランナーは 27/27。** `nim check` で初めて分かった。

したがって関門は 2 つ:

```bash
nim check --mm:arc --nimcache:.nimcache/chk --path:src src/nimculus/main.nim   # 本体が通るか
nim c --mm:arc --nimcache:.nimcache/test_runner -r --path:src tests/test_runner.nim  # テスト
```

`nimble lint` が前者に相当するが、**nimble の終了コードは当てにならない**ので
`nim check` を直接呼ぶ。出力に `Error:` が無いことを見る。

### 衝突マーカーが残っていてもテストは通る

キャッシュされたバイナリで走るため。マージ直後は

```bash
grep -c '^<<<<<<<' <衝突しうるファイル>
rm -rf .nimcache/test_runner
```

を先にやる。2026-08-12、16 個のマーカーが残った状態で 27/27 が出た。

### `.nimcache/test_runner` を消すだけでは足りない（2026-08-13）

**ランナーは各テストを `.nimcache/<テスト名>` で個別にビルドする**
（`tests/test_runner.nim:33`）。`.nimcache/test_runner` はランナー自身のぶんでしかない。

`macos_platform.m` を変えたとき、Nim は**各テストのキャッシュにある古い
`macos_platform.o` をそのままリンクする**。ObjC の変更が見えないまま
テストが走り、**通る**。

2026-08-13 の実例: コマンドパレットの候補配列を ObjC から削除したのに
ランナーは `実行: 27 / 成功: 27 / 失敗: 0` を出した。
`tests/test_platform_contract` を単体で走らせると
`[FAILED] command palette exposes the editor's major actions` で落ちる。
`.nimcache` を**丸ごと**消して測り直すと `26/27` になった。

**ObjC を触ったタスクの検証は、必ず `.nimcache` を丸ごと消す。**

```bash
rm -rf .nimcache          # test_runner だけではない
nim c --mm:arc --nimcache:.nimcache/test_runner -r --path:src tests/test_runner.nim
```

Nim だけの変更ならランナーのキャッシュ削除で足りる（`.nim` の依存は追える）。
判断に迷ったら丸ごと消す。全ビルドで 10 分ほど。


## 1. 必須テスト種別

新しい UI/機能には、該当する種別を必ず追加する。

- **Unit**: 編集コア、座標変換、状態、イベント、設定、プロトコル
- **Integration**: ウィンドウ、Metal、IME、ファイル、Git、LSP、PTY、agent
- **Fuzz**: 編集、Undo/Redo、UTF-8 / UTF-16 / grapheme 変換、プロトコル
- **UI Gallery**: レイアウト、フォーカス、スクロール、dirty 再描画
- **CI**: Apple Silicon macOS が必須

`tests/` の既存パターンに合わせて追加する。UI 系の参考:
`test_ui_text.nim`, `test_workspace_ui.nim`, `test_macos_modal_sheets.nim`,
`test_macos_file_panels.nim`, `test_macos_application_alert_sheet.nim`,
`test_platform_contract.nim`, `test_platform_headless.nim`,
`test_editor_fuzz.nim`。

## 2. テスト・ベンチ実行コマンド

nimble タスクを使う。各テストは専用 `--nimcache` を持ち、生成物を共有しない。

```bash
nimble test        # unit + integration 一式
nimble benchmark   # 性能スモーク一式
```

単一テストを回す場合も、専用 nimcache を使い共有しない（`nimble.nimble` の各行が手本）:

```bash
nim c --mm:arc --nimcache:.nimcache/test_ui_text -r --path:src tests/test_ui_text.nim
```

アドホック検証は `--nimcache:/tmp/nimculus-<目的>-cache` を使い、検証後に削除する。
共有 nimcache の破損や異なるコンパイル条件による再現性低下は、品質ゲートの失敗として扱う。

## 3. macOS 実機受け入れ（ヘッドレスだけで完了にしない）

ヘッドレス契約テストだけで完了扱いにしない。GUI セッションを使える Apple Silicon macOS で
実機確認する。確認項目: ウィンドウ、Metal 描画、リサイズ、Retina、入力、日本語 IME、
標準メニュー、ファイルダイアログ、PTY、長時間操作。手順は `docs/MACOS_MANUAL_ACCEPTANCE.md`。

release candidate 以降は個別 GUI 手順ではなく一括 E2E ゲートを使う（unit/integration・
native Cocoa/Metal contract・cold start・soak・DMG mount 後起動を 1 ログで検証）:

```bash
nimble macosE2E        # 統合 E2E ゲート（既定 soak は CI 向け 20 秒）
nimble macosGuiE2E     # GUI ログイン下のワークスペース E2E
```

release acceptance の 8 時間 soak は `NIMCULUS_E2E_SOAK_SECONDS=28800` を指定する。

## 4. 性能計測

次を TSV で計測可能にする: `cold start`, `idle memory`, `input latency`, `frame time`,
`layout time`, `text shaping`, `workspace load`, `file watcher load`, `LSP memory`,
`terminal memory`, `remote latency`, `allocation count`。

```bash
bash scripts/benchmark_cold_start.sh   # 実アプリ cold start（GUI セッション必須）
bash scripts/benchmark_soak.sh         # idle soak（既定 8 時間 / 短縮可）
```

短縮例（動作確認）:

```bash
NIMCULUS_SOAK_SECONDS=60 NIMCULUS_SOAK_INTERVAL_SECONDS=10 bash scripts/benchmark_soak.sh
NIMCULUS_COLD_START_RUNS=10 bash scripts/benchmark_cold_start.sh
```

目標値の目安: 通常起動 1 秒未満、空ワークスペース 50〜100MB 以内、100MB 級ファイル・
10 万ファイル級ワークスペース・8 時間連続利用に耐え、長時間アイドルでメモリが増え続けない。
soak の既定上限は resident 128MiB / live blocks 50,000（`NIMCULUS_SOAK_MAX_*` で調整）。
計測ハーネスを追加しただけでは 8 時間連続利用の完了とみなさない。

**サンドボックス注意**: サンドボックス内から `NSApplication sharedApplication` を直接
起動すると、アプリ不具合ではなく macOS の `_RegisterApplication` で `SIGABRT` になる場合が
ある。その場合はフレームゲートを弱めず、サンドボックス外の同一コマンドで再検証する。検証
結果には実行環境と `frames=` を必ず残す。

## 5. 端末に配慮した検証ログ

コンパイル/テスト/ベンチ/GUI スモークの出力を長時間そのまま端末へ流さない。

```bash
nimble test > /tmp/nimculus-test.log 2>&1 || { tail -n 60 /tmp/nimculus-test.log; exit 1; }
```

- 成功時は要約、失敗時は末尾の限定行 + 終了コードだけ表示。ログ本体は
  `/tmp/nimculus-<目的>.log` に置き、不要になったら削除する。
- 実行前後で `df -h / /tmp` と `git status --short` を確認し、生成物が追跡対象に混ざって
  いないこと・空き容量を確認する。詳しい nimcache 規律は [nimculus-ui-dev]。

## 6. 完了判定チェックリスト

- [ ] 該当する Unit / Integration を追加し、`nimble test` が通る
- [ ] 編集・変換・プロトコル系は fuzz test で不整合が出ない
- [ ] UI Gallery 観点（レイアウト/フォーカス/スクロール/dirty 再描画）を確認した
- [ ] 日本語 IME・Retina・Command/Option・リサイズ・複数モニターを実機確認した
- [ ] 必要な性能指標を計測し、目標範囲内（またはロードマップの許容内）
- [ ] soak でメモリが増加し続けないことを確認した（該当マイルストーンで）
- [ ] 既知のクラッシュ・データ破損・UI フリーズ・入力不能を残していない
- [ ] 各テスト/ベンチが専用 nimcache を使い、再現可能
- [ ] 検証結果に実行環境（と GUI/soak なら `frames=` 等）を記録した
