---
name: nimculus-ui-design
description: >-
  Nimculus / NimNUI のデスクトップ UI を設計するときに使う。新しい UI 要素・パネル・
  ウィンドウ・入力/IME 挙動・レイアウト・描画パス・テーマ/配色・キーバインドを追加または
  変更する前の設計フェーズで必ず参照する。「UI を追加したい」「パネル/タブ/メニューを設計」
  「NimNUI の新コントロール」「Metal 描画をどう分離するか」「macOS 統合をどう設計するか」
  「最小縦切りで進めたい」「この設計判断を記録したい」といった相談で発動する。実装コードを
  書き始める前の層分割・依存方向・受け入れ条件・DESIGN_DECISIONS 記録を扱う。実装手順は
  nimculus-ui-dev、検証は nimculus-ui-test を参照。
---

# Nimculus / NimNUI UI 設計

Nimculus は Metal を中心とする GPU ネイティブなコードエディタで、UI 基盤の NimNUI と
アプリ層 Nimculus が分離している。初期の主対象は Apple Silicon macOS。ここでは UI の
**設計フェーズ**（実装前）の判断を扱う。実装は [nimculus-ui-dev]、検証は
[nimculus-ui-test] を使う。

正となる文書は常にリポジトリ側:
- `DEVELOPMENT_GUIDELINES.md` — 開発規約（この設計の根拠）
- `ARCHITECTURE.md` — 層と依存関係
- `DESIGN_DECISIONS.md` — 設計判断の記録先（追記必須）
- `ROADMAP.md` — マイルストーンと完了条件（機能の優先度の正）
- `docs/ZED_UI_ARCHITECTURE_RESEARCH.md`, `docs/ZED_UI_ELEMENT_INVENTORY.md`,
  `docs/MACOS_WINDOW_BAR_INVENTORY.md` — UI 参照資料

設計を始める前にこれらの該当箇所を読む。ガイドラインと矛盾する設計を提案しない。矛盾が
避けられないと感じたら、勝手に破らず理由を添えてユーザーに確認する。

## 1. 設計の出発点は「最小縦切り」

抽象 API を先に広げない。ユーザーが画面で確認できる最小の縦切りを設計する。順序:

1. macOS 標準 API と最小の Nim ラッパーを接続する
2. 画面上の最小成果物（矩形・テキスト・1 コントロール）を出す
3. 入力/イベントを 1 経路だけ受ける
4. 状態変更をドメイン層へ伝える
5. 必要範囲だけ再描画する（dirty / paint invalidation）
6. Unit / Integration / ベンチマークの追加余地を設計に織り込む
7. 完了条件に沿った実機検証の観点を先に決める

「将来の移植性」や「汎用抽象」だけを理由に縦切りを広げない。共通 API は複数 OS で実際に
重複が確認された時点で抽出する（それまでは macOS 実装の質と速度を優先）。

## 2. 層と依存方向を壊さない

依存は一方向。設計時にどの層に何を置くかを必ず明示する。

```text
platform → renderer → NimNUI → editor core → application services
                                            ↘ Git / LSP / terminal / remote / agent
```

- プラットフォーム層の型・OS オブジェクト（`NSView`, `CAMetalLayer`, `NSTextInputClient`,
  Win32 ハンドル等）を NimNUI コアや editor core / ドメインモデルへ漏らさない。
- OS 固有 API は各バックエンド（`src/nimnui/platform/macos`, `.../windows`,
  `.../headless`）に閉じ込め、Nim へは小さな C ABI 契約（`platform/contracts.nim` /
  `contracts.h`）越しに渡す。不自然な共通抽象へ Cocoa と Win32 を押し込まない。
- Git / LSP / terminal / remote / agent は application service として分離し、UI から
  直接依存させない。

NimNUI コア自体もレイアウト・描画・状態・イベントを分離する（`layout.nim`, `render.nim`,
`ui_tree.nim`, `events.nim`, `commands.nim`, `controls.nim`, `text.nim`, `ime.nim`)。
新コントロールを設計するときは、この分離のどこに置くかを最初に決める。

## 3. NimNUI コントロール設計チェック

新しい UI 要素・パネルを設計するとき、最低限次を明示する。

- **ノード表現**: Node ID / 世代付き ID。Focus / Hover / Active / Disabled / Dirty flag を
  どう持つか。
- **レイアウト**: Row / Column / Stack と alignment、スクロールと viewport clipping の
  適用範囲。論理座標で設計し、ピクセル変換は platform 境界に任せる。
- **イベント**: Capture → Target → Bubble の順序。keyboard routing / pointer routing /
  focus traversal / command dispatch / shortcut resolution を独立させる。
- **再描画**: どの状態変化が dirty を立て、PaintList のどの範囲だけ再描画されるか。UI
  スレッド（Metal / AppKit イベントループ）をブロックしない。
- **状態の所在**: 表示状態は NimNUI、編集/ドメイン状態は editor core / service。どちら
  向きに通知が流れるか。

## 4. macOS 統合・入力・テキストの設計観点

- **ウィンドウ/描画**: `NSApplication` / `NSWindow` / `NSView` / `CAMetalLayer` は platform
  層に閉じ込める。Retina scale factor は論理↔ピクセル境界でのみ変換。リサイズ・
  フルスクリーン・最小化・最大化相当・複数モニターを設計対象にする。60Hz 安定、120Hz を
  阻害しない前提。
- **入力/IME**: キーボード・修飾キー・マウス・スクロール・トラックパッド・フォーカスを
  独立イベントとして扱う。Command / Option / 標準編集操作を優先。IME は
  `NSTextInputClient` 契約（composition の開始/更新/確定/キャンセルを個別に）。変換候補の
  表示位置は論理・Retina 座標と整合。日本語/英語/記号/絵文字の混在を設計時から想定する。
- **標準統合**: アプリメニュー（File/Edit/View/Window）、Dock、Finder の Open With、
  標準ファイルダイアログ、`.app` / `Info.plist` / アイコン / file association / URL scheme。
- **テキスト**: byte offset / codepoint / grapheme / UTF-16 (LSP position) を混同しない。
  どの単位で扱うかをコントロール設計に明記。glyph atlas の再利用・拡張・eviction を前提。

## 5. 設計判断は必ず `DESIGN_DECISIONS.md` に記録する

新機能・非自明な選択・ライブラリ採否・却下案は `DESIGN_DECISIONS.md` に追記する。含める:

- 対応マイルストーン（`ROADMAP.md`）と完了条件
- macOS 標準 API で解決できる範囲の確認結果
- 既存ライブラリと自作範囲の比較（依存追加は標準ツールで検出できない問題に限定）
- 採用案と却下案、その理由（後から追える形で）

設計に関わる変更では、影響に応じて `ARCHITECTURE.md` / `ROADMAP.md` /
`DEVELOPMENT_GUIDELINES.md` / `README.md` の該当箇所も更新提案する。

## 6. 設計レビュー・チェックリスト（実装へ渡す前）

- [ ] 対応マイルストーンと完了条件を明記した
- [ ] 最小縦切りとして成立している（抽象を先行させていない）
- [ ] 層と依存方向を壊していない（OS 固有型がコア層へ漏れない）
- [ ] NimNUI の layout/render/state/event 分離のどこに置くか決めた
- [ ] UI スレッドをブロックしない設計になっている
- [ ] 日本語 IME・Retina・Command/Option キーへの影響を検討した
- [ ] 文字単位（byte/codepoint/grapheme/UTF-16）を明示した
- [ ] macOS 標準 API の利用可否を確認した
- [ ] 追加すべき Unit/Integration/fuzz/ベンチマークの観点を洗い出した
- [ ] `DESIGN_DECISIONS.md`（必要なら `ARCHITECTURE.md`）へ記録する内容を用意した
- [ ] 次マイルストーンの機能を先取りしていない

設計が固まったら実装は [nimculus-ui-dev]、検証は [nimculus-ui-test] へ引き継ぐ。
