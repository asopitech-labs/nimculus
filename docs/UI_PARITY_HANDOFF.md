# Zed UI パリティ作業 引き継ぎメモ

最終更新: 2026-08-15 / ブランチ `main`（push 済み、`5ba36f1`）

## 0. セッション引き継ぎ（2026-08-15 時点）

**次にやること**: 下記「`platformtrait` の続き」を先に検討すること
（`../nimculus-wt-platformtrait` に未完了のまま残置）。それ以外は
`docs/ZED_PORT_TASKS.md` の `[ ]` から新規タスクを選ぶ。
[nimculus-parallel-dev] スキルの手順でワークトリーを作り、
`.claude/port-briefs/briefs.json` の指示書を使う。

### 現在地

- 台帳: **228 / 116**（`docs/ZED_PORT_TASKS.md`、`[x]` 228 / `[ ]` 116）
- `main` は `git status` クリーン、push 済み。`.nimcache` 全消しで
  テストランナー 45/45、`nimble packageMacos` rc=0 を確認済み
- このセッションで `main` に入った項目（12件、すべて実測で確認済み）:
  - Entity handle + type-erased entity store（`src/nimnui/entity.nim`）
  - TextStyle and its refinement/highlight composition（`src/nimnui/text.nim`）
  - Double-buffered Frame with element-state carryover（2段階のバグ修正、VM 3回計測）
  - Context<'a,T> - entity-scoped view of App（`src/nimnui/entity_context.nim`、entity 依存）
  - Batching: merging sorted streams into draw calls（`src/nimnui/render.nim`、Step1のみ。
    Metal側の固定8パス削除＝Step2は別タスクとして残る）
  - Builder traits shared across components（`src/nimnui/controls.nim`）
  - **Sprite atlas with shelf packing and keyed tiles**（`ar`、下記参照。3ラウンド、VM計測5回）
  - Effect queue + flush_effects re-entrancy guard（`src/nimnui/effects.nim`、entity 依存）
  - Per-element retained state keyed by GlobalElementId（既存の double-buffered Frame と
    同じ土台に統合。`test_frame_double_buffer.nim` が壊れていないことを個別確認済み）
  - Icon source abstraction and square hit box（`src/nimnui/controls.nim`）
  - Hsla and alpha derivation（`src/nimnui/text.nim`。色ラダー置換はフォローアップで別途残る）
  - ListItem slot layout（`src/nimnui/controls.nim`。所有ファイル内の既存描画パス
    `paintOverlay` に実配線済み。ObjC側の行描画はフォローアップ）
- スクロール比（nimculus/zed の ms per 100px）の健全帯は概ね 0.85〜1.02
- unit-test 判定かつ `macos_platform.m`/`main.nim` 未変更（既存経路に未配線の純フレームワーク
  追加）のタスクは VM 計測を省略してよい、という判断基準を継続適用
- **受け入れ条件が所有外のファイル（大抵 `macos_platform.m`）を要求している一文が
  混じっていることがある**（`briefs.json` は自動生成のため）。指示書を作る前に
  acceptance 全文を読み、所有外を要求する部分は明示的に「このタスクの範囲外」と
  指示書に書いて除外すること（hsla・listitem・platformtrait で実施）

### `platformtrait`（The Platform trait as the OS boundary）— 未完了・main 未統合

`../nimculus-wt-platformtrait`（ブランチ `port/platformtrait`）にコミットせず残置。
`nim check` は通り、テストランナーも壊れていないが、**acceptance の数値ゲートを
満たしていない**と codex 自身が正直に報告して停止した。

acceptance:「`Platform*` レコードを作り、6つのクロージャフィールド（dispatcher/
clipboardGet/clipboardSet/promptForPaths/promptForNewPath/setCursorStyle）に
まとめたら、`platform.nim` 内の `importc: "nimculus_platform_` の出現数が
**最低6件減る**はず」。実際は既存の `clipboardGet`/`chooseOpenFile` 等の
`importc` 宣言をそのまま残して `Platform` レコードから呼び出す形にしたため、
新規に `platformSetCursorStyleNative` の importc が1件増え、**250→251件と
逆に増加した**。数値ゲートを満たすには、既存の6つの `importc` 宣言そのものを
どこかへ移すか消す必要があり、それは所有ファイル外（`dispatcher.nim` または
`macos_platform.m`）に触れることになるため、指示書の制約により実施せず停止した。

**次にやること**: acceptance の数値ゲートの意図を確認すること。おそらく
「個別の `importc` 宣言を残したまま record でラップする」のではなく、
「既存の `importc` 宣言自体を record 構築の内側だけに閉じ込め、`platform.nim`
の外側（`main.nim` 等）からは record 経由でしか呼べなくする」ことを求めている。
所有ファイルを広げて（`dispatcher.nim` を含める）再指示するか、数値ゲートを
達成可能な形に指示書側で調整してから再着手すること。

### `ar`（Sprite atlas with shelf packing and keyed tiles）— 完了・main に統合済み

3ラウンドかけて解決した。同種のタスク（VM実測でしか気付けない後退）に当たったときの
参考として経緯を残す。

| ラウンド | やったこと | 実測結果 | 判定 |
| --- | --- | --- | --- |
| 1 | 「単一アトラスの高速描画パスに戻す」という仮説で修正 | VM 実測で **`scrolled 0px` が再現**（直っていなかった） | revert |
| 2 | 画像を目視して発見: **グリフがほぼ描画されていない**（21行中数文字しか見えない）。原因は CPU 側 sprite 構造体（68/84 bytes）と Metal 配列 stride（`float4` 整列で 80/96 bytes に丸められる）の不一致 | グリフ描画は完全復旧。キャリブレーションも成功。だがスクロール比が3回とも帯外（1.082/1.054/1.187、平均約1.1倍） | 正しさは直ったが性能が未達。revert |
| 3 | VM `profile` モード（1ms サンプリング）でホット行を特定 → `updateEditorGlyphAtlasFromLayout`+`atlasEntryForGlyph` が実働サンプルの約3割。ガター計測（`editorGutterMetrics`）が毎フレーム `CTFont`/`CTLine` を再構築していたのをキャッシュ化、per-glyph ホットパスの構造体値渡しをポインタ渡しに変更、ハッシュ関数をインライン化 | スクロール比3回とも帯内（1.017/0.982/1.020） | **統合。画素も目視で密なグリフ描画を確認** |

**得られた教訓**: VM `profile` モード（[nimculus-ui-test] 参照、`tools/hot_lines.py` で
ホット行を特定）は、比が帯外というだけでは分からない「どこが重いか」を具体的に示す。
勘で仮説を立てて直すより先に、まずプロファイルを取ること。

### このセッションで固まった検証ゲート（次セッションでも必須）

1. 衝突マーカー 0 件の確認
2. `nim check --mm:arc --nimcache:.nimcache/chk --path:src src/nimculus/main.nim`
3. テストランナー（`.nimcache` を**丸ごと**消してから。`macos_platform.m` を
   触った回はこれを飛ばすと ObjC 変更が見えないまま「通った」ことになる）
4. `NIMCULUS_ALLOW_ADHOC=1 nimble packageMacos` の**終了コード**（`nim check` と
   ランナーが通ってもリリースビルドだけ落ちることがある。`;` で繋がず `||` で受ける）
5. `tools/ui_test.sh parity` の画素一致率とスクロール比
   - `grep "ms per 100px"` した結果に **`nimculus:` と `zed:` の両方**が
     出ているか必ず確認する（片方だけならスクロール計測自体が失敗している）
   - 比が帯から外れたら**同じ計測をもう一度**回し、2回とも同じ傾向なら
     `revert` して同条件で比較する（ノイズと本物の後退を切り分ける）
   - **画素の一致率だけで「改善」と判断しない。** グリフがほぼ描画されて
     いなくても、背景色同士の一致で数値が上がることがある
     （2026-08-15、`ar` で実例）。必ずスクリーンショットを目視すること
6. **codex の「直った」報告は証拠にならない。** このセッションで `ar`/`as` とも
   1回目の修正は「ローカルゲート通過・報告は完了」だったが、**VM実測では
   直っていなかった**。ローカルゲートは自分で（`.nimcache` を消してから）
   再実行し、VM 計測も自分で行うこと。codex のテストランナー実行結果と
   自分の実行結果が食い違うことがある（サンドボックス環境依存のflaky）ので、
   件数の食い違いが出たら疑わず自分で再実行する

### unit-test 判定タスクは VM 計測を省略してよい

`briefs.json` の `verifiable_by: unit-test` かつ `files_to_touch` に
`macos_platform.m`/`main.nim` を含まない（=既存の描画・入力経路に未配線の
純フレームワーク追加）タスクは、VM 実測を省略してよい。ただし
「既存経路への配線を要求していないか」を acceptance 文面で必ず確認すること
（配線を求めているのに省略すると「二重実装」の罠に落ちる）。

### 差し戻しからの復旧手順（踏んだ罠）

`git revert` した項目を作り直して再統合するときは、**先に revert 自体を
revert する**（`git revert <revert コミット>`）。そのまま `git merge port/X` すると
git が「マージ済み」と判断し、修正差分だけが来て本体が来ず衝突する。

マージ・revert・計測を 1 つのシェルコマンド列で `;` 連結しない。前段が
失敗・衝突しても後段が実行され、「衝突マーカー入りで計測が完走した」
「packageMacos が落ちたまま UI テストが走り、全部『アプリが見つからない』
で落ちた」という事故を2回起こしている。各段は `&&` か `||｀ で明示的に
受けること。

詳しい罠と手順は [`.claude/skills/nimculus-parallel-dev/SKILL.md`](../.claude/skills/nimculus-parallel-dev/SKILL.md)
と [`.claude/skills/nimculus-ui-test/SKILL.md`](../.claude/skills/nimculus-ui-test/SKILL.md) に
逐次追記している。**作業前に必ず読むこと**（このセッションだけで10件以上の罠を追加した）。

---


## 1. この作業のゴールと完了基準

**ゴール**: Zed の UI/UX を移植・クローンし、既定状態で見た目を再現する。

**完了基準は [`UI_PARITY_ACCEPTANCE.md`](./UI_PARITY_ACCEPTANCE.md) が正**。要点:

- 「Zed に対応する要素がある」ことは完了条件ではない。**実ピクセルの測定値**で判定する。
- 幾何は行ピッチ ±1px、その他 ±2px。構造条件（ガターがエディタ矩形の内側、
  スクロールバーがレイアウト幅を奪わない、アイコンとテキストが同一ベースライン）は 0 許容。
- 配色はエディタ／ガター背景が完全一致、その他は ±2/255。
- 意味論 6 条件（所属・意味・状態・ツールチップ・生存・無関係な装飾の禁止）。
- 未測定の項目は「未完了」として扱う。

**Zed は素の状態（インストール後に設定変更なし）**。その既定が移植先の既定。値は必ず
`references/zed`（vendored ソース）から読む。テーマ JSON の値と実際に描画される色は
一致しないことがあるので、**最終判断は必ず実ピクセル**（後述の失敗例を参照）。

## 2. 測定手順（これを使うこと）

### 前提
- 端末プロセス（このセッションでは `claude.app`）に **画面収録権限**が必要。
  権限がないと `screencapture` が "could not create image from display" で失敗する。
- 画面がロック／スリープしていると真っ黒な画像が撮れる。`caffeinate -u -t 120 &` で起こす。
  撮影後に `mean` が 0 に近ければ画面が消えているので測り直す。

### ツール
| ツール | 用途 |
| --- | --- |
| `tools/window_capture.swift` | **ウィンドウ単体**を Retina で取得（ScreenCaptureKit の `SCContentFilter(desktopIndependentWindow:)`）。重なった他ウィンドウの影響を受けない。`swiftc -O tools/window_capture.swift -o /tmp/wincap` でビルド |
| `tools/bitdiff.sh` | 両ウィンドウを撮ってビット差分と領域別内訳を出力 |
| `tools/ink_check.py` | エディタ本文の**インク量**を数える。ゼロ近傍なら FAIL |
| `tools/parity_report.sh` | 水平クロム帯の位置と色を Zed と突き合わせ |

`NIMCULUS_RECT_DEBUG=1` を付けて起動すると、`editor_rect` と `ui_rect`（＋Metal の
論理メトリクス）を stderr に出す。ジオメトリのずれが「Nim 側の計算」なのか
「ネイティブ側の配置」なのかを切り分けるのに使う。パッケージ済みバイナリを
直接起動すること: `NIMCULUS_RECT_DEBUG=1 build/macos/Nimculus.app/Contents/MacOS/Nimculus`。

### 条件を揃える（これを外すと測定は無意味）
1. 両ウィンドウを同じサイズにする（Zed は 1389×791 で運用中）。
   Nimculus は `osascript -e 'tell application "System Events" to tell process "Nimculus" to set size of window 1 to {1389, 791}'`。
2. 同じドキュメント（`DEVELOPMENT_GUIDELINES.md`）、同じスクロール位置（1 行目が先頭・
   カーソル 1:1）、タブ構成（1 枚目 `DEVELOPMENT_GUIDELINES.md`／2 枚目 `.gitignore`）も
   揃える。カーソル位置を揃えないとアクティブ行ハイライトの分だけ数値が動く。
   Zed 側はコマンドパレットが開いたままだと測定が壊れるので、撮影前に Esc を送る。Nimculus のセッションが汚れていたら
   `rm -f "$HOME/Library/Application Support/Nimculus/session.json" ...active.recovery` して再起動。
3. 同じテーマ（One Light）。Nimculus は
   `~/Library/Application Support/Nimculus/settings.json` に `{"theme":"light"}`。

### どの数値で判定するか

AppKit が塗った面は**±1 のディザが乗る**（Zed が一様 `#cfd1d2` の 1pt 罫線に対し、
こちらは画素ごとに 206/207/208 を混ぜて出す）。Metal が塗った面にはこれが無い。
そのため:

- **エディタ／ガター背景は `identical`** で判定する（受け入れ基準どおり完全一致が要件）。
- **AppKit 製クロム（タイトルバー・タブ・ツールバー・罫線）は `diff <= 2`** で判定する。
  この帯の `identical` はディザで 30% 台に張り付き、実際の一致度を表さない。
  帯の `identical` が数 % 動いても、それだけでは改善／悪化の証拠にならない。
- **全体の傾向は `mean` と `>32`** を見る。`>32` は「明らかに違う画素」の割合なので、
  構造のずれはここに出る。

### 検証は必ず 3 点セット
1. **ビット差分**の数値
2. **`ink_check.py`** でテキストが描かれていること
3. **キャプチャ画像の目視**

理由は §4 の失敗例。数値だけを見ると壊れているのに「改善」と読めてしまう。

## 3. 現在の到達点

**2026-08-10 に指標と揃え方を作り直した。** 下の推移表は古い測り方のもので、
現在の値とは比較できない。

### 指標を `identical` に変えた理由

それまで `>32`（明らかに違う画素）で追っていたが、
**2 段階の色差は 32 未満なので `>32` には現れない**。
テーマ表の観測値を直したとき、`>32` は 7.25% のまま動かず、
`identical` は 0.11% → 54.56% に動いた。
**ウィンドウの半分を覆う差に対して、`>32` は盲目だった。**

主指標は `identical`。`>32` は文字とジオメトリの差を見る補助。

### 揃える端（罠 18）

ウィンドウの高さが違う（Nimculus 1360 / Zed 1356 device px）。
**上部の帯は上端、ステータスバーは下端で揃える。**
下端揃えで上部を測ると 4px ずれて存在しない差が出る。

### 実測（`4625ff1`、テスト VM、One Light）

```
overall  identical 70.97%   diff<=2 71.53%   >32 7.29%   mean 12.02
  titlebar   identical 87.55%   >32 5.52%   (rows 0-68)
  tabbar     identical 89.29%   >32 6.03%   (rows 68-140)
  toolbar    identical 70.73%   >32 6.52%   (rows 140-225)
  editor     identical 69.50%   >32 6.16%   (rows 225-1240)
  statusbar  identical 80.69%   >32 6.58%   (下端揃え)
```

### 1 日での推移（2026-08-10）

| 変更 | identical |
| --- | --- |
| 朝（`#fcfcfc` の焼き込みあり）| **0.11%** |
| UI-112: `#fafafa` の焼き込みと 4 値 | 54.56% |
| UI-123: テーマ表 13 件 | 65.34% |
| カーソル位置を揃えた（罠 19）| 70.59% |
| UI-124: 見出しの色、Zed の復元バッファ | 70.95% |
| UI-125: ネイティブ予備表 12 件、sRGB 変換 | **70.97%** |

**新しい描画コードは 1 行も書いていない。** すべて
「参照ディスプレイでの観測値をテーマ値に戻す」と
「比較の条件を揃える」だけ。

### 残っている差

行グリッドは一致している（ピッチ 48 device px、開始 238 対 237）。
**残差は行内、つまりグリフの形と送り幅**で、
フォントのフォールバック方針（§5.1、受容と決定済み）の帰結。

### Zed のクロム帯（実測、One Light・1389×791）

| 帯 | 範囲 | 色 |
| --- | --- | --- |
| タイトルバー | 0–34pt | `#dcddde` |
| 罫線 | 34–35pt | `#cfd1d2`（`border`） |
| タブストリップ | 35–66pt | `#ececed` |
| 罫線 | 66–67pt | `#cfd1d2`（アクティブタブの下だけ描かない） |
| ツールバー（パンくず） | 67–111pt | `#fcfcfc`、内側 6+32+6pt |
| 罫線 | 111–112pt | `#dfe0e1`（`border.variant`） |
| エディタ本文 | 112–745pt | `#fcfcfc`、行ピッチ 24pt、テキスト列は x 92–1134pt |
| 縦スクロールバー | x 1134–1149pt | 罫線 `#efeff0`（`scrollbar.track.border`）＋サム `#ccced0` |
| ドック罫線 | x 1149–1150pt | `#cfd1d2`、ドックは 1150–1389pt（240pt のうち 1pt が罫線） |
| 水平スクロールバー | 745–760pt | サム `#ccced0`、x 92–915pt（トラックは 92–1134pt） |
| 罫線 | 760–761pt | `#cfd1d2`、**全幅**（ドックの上も通る） |
| ステータスバー | 761–791pt | `#dcddde` |

スクロールバー帯の中では、x 0–92pt（ガター）と 915–1134pt（トラックの残り）は
エディタ背景 `#fcfcfc`、x 1150pt 以降はドックの `#ececed` のまま。Zed はこの帯に
**本文の行を描き続ける**（実測時は 25 行目が 736–760pt にあり、帯の下に見えていた）。

一致済み（実測で確認）:
- ウィンドウ既定 1389×791、タイトルバー `#dcddde`、タブバー `#ececed`、
  ステータスバー `#dcddde`
  - **エディタ背景は一致していない（2026-08-09 訂正）。** ここに書いていた
    「`#fcfcfc` で一致」は参照ディスプレイでの観測値どうしの一致であって、
    Zed が塗る値ではない。テスト VM 内で測ると Zed はテーマ値 `#fafafa` を塗り、
    こちらは `#fcfcfc` を塗っている（`macos_platform.m:901` の焼き込み補正）。
    詳細と直し方は `DESIGN_DECISIONS.md` の UI-112。上の帯表の
    「エディタ本文 `#fcfcfc`」も同じ理由で Zed の値ではない
- 上の 3 本の罫線（位置・色とも完全一致）
- 行グリッド: ガター数字の上端 118.5 / 142.5 / 166.5pt（±0.5pt）
- アクティブ行ハイライト 112–136pt `#f0f0f1`（完全一致）
- ガター式（Zed の `max(実測, ch_advance*4) + ch*3 + ch*4`、margin `-descent`）= 87.026
- 行ピッチ 24pt
- テキスト開始 x: Zed 91.5pt / Nimculus 90.5pt（`a182b00` で 84.0 → 90.5）
- ステータスバーは**全幅**（ドックの下も `#dcddde`）
- ドック境界 1150pt、その左の 1pt 罫線 `#cfd1d2`（`5031673` で 1166 → 1150）
- 縦スクロールバー列（サムが無い y では完全一致）
- ツールバーのアクションは 23pt スロット、右端スロット中心はペイン右端の内側 20pt
- パンくずの区切り前後の間隔（3 セグメント目まで Zed と ±0.5pt）
- サイドバーは**右**（`project_panel.dock` の既定）

## 4. 踏んだ罠（同じ失敗を繰り返さないため）

1. **テーマ JSON を読んで色を決めた** → Markdown 見出しに `syntax.title`（赤 `#d3604f`）を
   適用したが、Zed の実描画は `#5d6165`（通常のグレー＋太字）だった。**必ず実ピクセルを見る**。
2. **「Zed の既定は左」と思い込んだ** → 実際は `project_panel.dock: "right"`。
   設定ファイルを確認せず実装して作り直しになった。
3. **ビット差分の数値だけで改善を判断した** → テキストが消えて真っ白になると、Zed の白背景と
   一致する画素が増えて**数値はむしろ良くなる**。全テストも通っていた。`ink_check.py` はこの穴を
   塞ぐために作った。**削除しないこと**（作業エージェントが一度消したので復元した経緯あり）。
4. **全画面キャプチャで測った** → 他ウィンドウ（Claude 自身など）が被って一致率が 52.76% →
   39.30% に「悪化」して見えた。**必ずウィンドウ単体キャプチャ**を使う。
5. **エージェントの「Fixed」報告を信じた** → タブクリック修正は 2 回とも実際には直っておらず、
   自分でクリックして初めて分かった。ウィンドウ非表示の回帰も「全チェック通過」報告の裏で
   起きていた。**必ず自分で再現・再測定する**。
6. **`nimble format` が無関係な 24 ファイルを再整形する** → 機能変更と混ぜない。整形は
   独立コミットにする（`3223cd9` がその例）。
7. **`nimble clean` は `build/` を消す** → パッケージ済み `.app` が消えて起動確認ができなくなる。
   エージェントには毎回「実行禁止」と伝えること。
8. **`codex exec` はバックグラウンド実行時に stdin で固まる** → `< /dev/null` を必ず付ける
   （付け忘れて 4 時間ハングした）。
9. **`open -n` は二重起動になり `_RegisterApplication` で SIGABRT** する。通常は `open` を使う。
9b. **Claude Code がセッション中に自動更新すると画面収録・Apple Events が全部落ちる**。
    実行中プロセスのバンドル（`~/Library/Application Support/Claude/claude-code/<版>/`）が
    削除され、TCC が照合できなくなるため。`screencapture` が
    "could not create image from display" になったら、まず
    `ps -Ao comm= | grep claude-code` で動いている版とディスク上の版を比べる。
    直し方は Claude の完全終了と再起動（設定の再トグルでは直らない）。
10. **テーマ JSON の色をそのまま実装に写した** → 観測値と食い違う。**ただしこの項目の
    読み方には後日訂正がある（下記）**。
    `border` は JSON `#c9c9ca` に対し実描画 `#cfd1d2`、`border.variant` は `#dfdfe0`
    に対し `#dfe0e1`、`editor.background` は `#fafafa` に対し `#fcfcfc`。
    `settings.nim` のテーマ表には**実描画値**を入れる（他の役割は既にそうなっていた）。

    **訂正（2026-08-09）**: 「Zed の実描画は `#fcfcfc`」は誤り。テスト VM 内で
    測ると **Zed はテーマ JSON どおり `#fafafa` を塗っている**。`#fcfcfc` は
    参照ディスプレイでの**観測値**であって、Zed が塗る値ではない。
    この誤読が `macos_platform.m:894` の `#fafafa` → `#fcfcfc` という
    ディスプレイ依存の補正を実装へ持ち込んだ。詳細と直し方は
    `DESIGN_DECISIONS.md` の UI-112。
11. **帯の切り出し位置を自分の実装に合わせていた** → `bitdiff.sh` の旧帯定義は
    Nimculus 側の座標だったので、ジオメトリを直すとラベルと中身がずれ、
    「breadcrumb が悪化した」ように見えた。帯は**Zed の実測境界**で定義する。
12. **ink 帯検出のクロップ開始位置を変えて誤読した** → クロップ端で切れた帯が
    「最初の行」に見え、17.5pt ずれを 23.5pt と誤って読んだ。行位置を測るときは
    クロップ端に帯がかからない範囲を選ぶ（今の値は y=224 retina から測っている）。
13. **1 か所直すと隠れていたバグが出る** → エディタを 17.5pt 下げたら、
    `setScissorForRegion` の Y 反転（`logicalSize.height - bottom` を上端に使っていた）が
    表面化した。クリップが上下反転していても、全高クリップでは症状が出ない。
    ジオメトリを動かした後は**必ず全帯を測り直す**。
14. **測定の途中でカーソル位置が動いた** → ウィンドウ操作の副作用でカーソルが 18:9 に
    移動し、overall が 3.5pt 悪化して見えた。数値が理由なく動いたら、まず
    **キャプチャを目視**して条件が保たれているか確認する。

15. **ログのタイムスタンプを割合として読んだ** → 「ステータスバー帯だけ `>32` が
    21.04%」と書いたが、`21.04` は `xcuitest.log` の `t = 21.04s` であって
    割合ではない。実際に測り直すとステータスバー文字行は 7.64%（右半分 10.48%）で、
    タブバー 11.53% より低く、突出などしていなかった。
    **数値を主張に使う前に、その数値を出したコマンドをもう一度走らせる。**
    grep の 1 行を目で拾って割合だと思い込むのが原因。
    なおこの誤読から始めた調査自体は当たりで、キャプチャに写っている
    `LF` / `UTF-8` / `Spaces: 4` は Zed が既定で出さないものだった（UI-113）。
    **間違った理由で正しい所を掘ることはある。掘り当てた事実と、掘る動機にした
    数値は、別々に検証する。**

16. **テストが互いを汚染した** → 行内 blame の padding テストが開いた
    git リポジトリが、Nimculus の**セッション永続化**（`session.nim` の
    `workspaceRoots`）を通じて後続テストに残った。XCTest はアルファベット順に
    走るので、`testCaptureInlineBlame*` が selection とスクロールのテストより
    先に走り、サイドバーに `inline-blame-repo-padding-*` が写った状態で
    キャプチャされた（`nimculus-selection.png` で 1.141% の画素が変化）。
    **VM を毎回作り直しても、1 回の実行の中では状態が持ち越される。**
    テストごとにセッションを消すこと。

17. **1 回の絶対値でスクロールの回帰を判定しようとした** → 同じコードで
    2 回測ると nimculus 21.875 / 17.969、zed 20.208 / 15.313 と、
    実行ごとに 4〜5ms 動いた。帯（14.6〜17.7）だけ見ていると
    「1 回目は回帰、2 回目は許容」という別々の結論になる。

    **比（nimculus / zed）で見る。** VM の速さで正規化される。

    | | 比 |
    | --- | --- |
    | 過去 7 回（git 管理外の文書）| 0.77〜0.95 |
    | 汚染後 2 回（git リポジトリを開いた状態）| 1.08 / 1.17 |

    比が動いているので、これは実行ごとのばらつきではない。
    ただし**汚染は Nimculus 側にしか効かない**（Zed は毎回自分の引数で
    起動し、セッションを引き継がない）ので、この比の変化が

    - 「git リポジトリを開いている」という条件の差
    - 行内 blame の実装が持ち込んだ回帰

    のどちらかは、**同じ条件で新旧のビルドを比べないと言えない**。
    切り分けの手順:

    1. 汚染を直し、git 管理外の文書で測る → 比が 0.87 前後に戻るか
    2. git リポジトリを開いた状態で、現在のビルドを測る
    3. **git リポジトリを開いた状態で、UI-120 より前のビルドを測る**
       （`52f0047` 付近）

    3 が決め手。2 と 3 の差が実装の持ち込んだぶん。

18. **高さの違うウィンドウを下端で揃えて上部を比べた** → Nimculus 1360 /
    Zed 1356 device px。`n[n.shape[0]-h:]` で揃えると上部が 4px ずれ、
    「タイトルバーが 2pt 低い」という存在しない差を報告した。
    上端で揃えると罫線は両方 rows 68–69 で一致する。

    帯の数値も 4px ぶん狂う:

    | 帯 | 下端揃え（誤り）| 上端揃え（正しい）|
    | --- | --- | --- |
    | titlebar | 7.96% | 7.01% |
    | tabbar | 11.53% | 6.11% |

    **上部の帯は上端で、下部の帯は下端で揃える。**
    ウィンドウの高さが一致しない限り、片方の端でしか合わない。
    （ステータスバーの測定は下端揃えなので有効。）

19. **両エディタが違う状態で撮られていた（1 日で 4 回）** →

    | # | 何が違ったか | どう気づいたか |
    | --- | --- | --- |
    | 1 | Nimculus のエディタ対 Zed のオンボーディング画面 | 差が大きすぎた |
    | 2 | Zed にリポジトリを渡さず blame が出ていない | Zed 側だけ空だった |
    | 3 | カーソルが別の行（ウィンドウ高さが違い、正規化座標が別の行に落ちた）| ハイライトの位置を測った |
    | 4 | Zed がゴールデンイメージの**古い復元バッファ**を表示 | 先頭に無いはずの空行があった |

    **4 件とも、差を見つけてから条件の問題だと気づいた。**
    キャプチャ比較は両者が同じ状態にあることを前提にするが、
    その前提はハーネスが確かめていない。

    入れた対策:

    - カーソルは固定座標クリック＋Cmd+Up で先頭へ（正規化座標をやめる）
    - Zed の `workspaces` を全削除（`panes` / `items` / `editors` /
      選択・折りたたみは CASCADE で消える）。**発見したパスだけ消すのは不可**
    - Nimculus 側は本文・先頭行・emoji マーカーを assert

    **残る限界: Zed の表示内容を機械的に読めない。**
    AX にもクリップボードにも本文が出ないので、
    Zed が何を表示しているかはキャプチャを人が見るしかない。
    上の 4 件のうち 3 件は Zed 側の状態だったので、
    **Nimculus 側の assert だけでは半分しか塞げていない。**

## 5. 次にやること（優先順）

フォントのフォールバックは**現状のままで確定**（下記 1）。それ以外の箇所は
`5031673` までで実測に基づいて合わせてある。

### 0-A. スクロール性能の測り方（2026-08-09 に作り直した）

**ホストでは測らない。** `tools/ui_test.sh parity` がテスト VM の中で
Nimculus と Zed を連続測定する（[`MACOS_UI_TEST_GUIDELINES.md`](./MACOS_UI_TEST_GUIDELINES.md) §0）。

**必ず移動量で正規化する。** 同じ合成ホイールイベントでも両者の移動量は違うので、
`ms/event` は違う仕事量を比べてしまう。ハーネスは校正フェーズ（1/2/4/8/16
イベントで撮影し、相関が取れて画面内に収まる刻みを選ぶ）から `px/event` を求め、
**`ms per 100px`** を出す。

この経路に至るまでに、代理指標で 3 回すり抜けと誤診が起きた:

| 判定 | 何が起きたか |
| --- | --- |
| 「画像が違えば動いた」 | 1 画素の差（カーソル点滅）で通過 |
| 「差分画素率 3% 以上」 | 7.1% で通過。実際の移動量は 0px |
| `scroll_shift.py` の探索範囲 1200px | 1 行目→163 行目（約 7800px）を **0px と誤判定**。実装の回帰と誤認して差し戻した |
| Zed の `px/event` を総移動量÷40 で算出 | 末尾で clamp された分を平均に含め、**11 倍差という誤診**を生んだ |

**代理指標を見ない。移動量そのものを測る。** 校正は必ず clamp されない範囲で行う。

### 0. スクロール性能（旧・ホスト測定時の記録）

`tools/scroll_cost.sh` で実測（実ホイールイベント、同一文書・1389×791、先頭から
40 イベント × 5 行、両方とも描画変化を確認）:

| | CPU / スクロールイベント |
| --- | --- |
| Zed | 10.00 – 10.50 ms |
| Nimculus | 21.50 – 21.75 ms |

**この指標だけで判断しないこと。** Git リポジトリ解決の待ちを外したら CPU/イベントは
18.25 → 21.75 に「悪化」した。ブロックしていた間はメインスレッドが眠っていて
CPU を使わなかっただけで、体感は逆に良くなっている。CPU/イベントは
「待ちで隠れたコスト」を見落とす。ブロックの有無は `sample` の
`__semwait_signal` / `nanosleep` のサンプル数で見る（現在 0）。

**キーイベントで測ってはいけない。** Nimculus は Page Down / Page Up を処理しない
（Zed は処理する）ので、キー駆動の測定は「捨てられたイベント」のコストを測る。
実際これで一度 6ms と誤報告した（実体は 39ms）。`tools/post_scroll.swift` が
実ホイールイベントを送る。ポインタ位置のウィンドウに配送されるので、必ず
エディタ上へワープさせること。

済んだこと（39.25 → 20 ms 前後）:
- 入力ごとの再同期に早期リターン（text / soft_wrap / completions / git_hunks /
  cursor / selections / diagnostics が同値なら何もしない）
- 折り返し行数のメモ化（毎回 CTTypesetter を行ごとに作っていた）
- `editorFont` のキャッシュ（呼ばれるたびに書体を名前から再構築していた）

**試して逆効果だったので戻したもの**: ホイール分岐から `refreshEditorSyntax()` を
外す → 32.5ms が 35.0ms に**悪化**した（3 回とも再現）。ネイティブ側の状態が
古いままになり別経路で作業が増えるらしい。理屈で消すのではなく、外した状態を
必ず測ること。

追加で潰したもの:
- `set_editor_selection`（単数形）と `set_editor_folds` の早期リターン
  （どちらも毎イベントでテキストテクスチャを再構築していた）
- **`newGitRepository` のキャッシュ** — `git rev-parse --show-toplevel` を
  サブプロセスで起動し、その完了を `sleep(1)` ループで待っていた。これが
  **スクロールのたびにメインスレッドをブロック**していた（`__semwait_signal`
  299/1529 サンプル）。パスに対する答えは変わらないので記憶する。
  `clearGitRepositoryCache()` を用意してあるので、clone / `git init` /
  ワークスペース切り替えの際はそこから呼ぶこと。

### 残差は実装方式の差（ここから先は設計変更）

Zed のスクロールハンドラ（`references/zed/crates/editor/src/element/mouse.rs`
の `ScrollWheelEvent`）は**スクロール位置を計算して `editor.scroll` を呼ぶだけ**。
構文解析もリポジトリ解決もバッファ再送出もしない。こちらもホイール分岐を
それに合わせた（`refreshEditorSyntax` の呼び出しを削除）。

それでも 20ms 前後から下がらない。プロファイルの残りは全部ここ:

```
syncEditorCursor → set_editor_input_pane / set_editor_cursor_byte
  → updateEditorTextTexture
     → CTFramesetterCreateWithAttributedString   （可視行を毎回組版）
     → [IOGPUMetalTexture replaceRegion:...]     （テクスチャ全面アップロード）
```

**フレームごとに可視テキストをテクスチャへ描き直している**のが方式そのものの差。
セッター側の重複呼び出しはフレーム 1 回に集約済み（`scheduleEditorTextTextureRebuild`）
なので、これ以上はセッターを塞いでも減らない。

Zed は行レイアウトを一度シェープしてキャッシュし、フレームでは四角形を
並べ直すだけ（`crates/gpui/src/text_system/line_layout.rs` の `LineLayoutCache`）。
キーは (テキスト, フォント, サイズ, ラン)、`previous_frame` / `current_frame` の
2 枚持ちで、フレーム終端に未使用分を落とす。スクロールで表示範囲が動いても、
**残った行のレイアウトはそのまま再利用される**。

### 実装すべきもの（`updateEditorTextTexture` の作り替え）— **完了（2026-08-09）**

**この節は実施済み。** `LineLayoutCache` は `src/nimnui/text.nim` にあり、
`main.nim:265` が持ち、`:4065` と `:5024` が使い、`:497` と `:4968` が
`finishFrame()` で 2 フレーム目を落としている。
`CTFramesetterCreateWithAttributedString` は macOS 側から消えている。

ただし**スクロールが速くなった主因はこれではなかった**。決め手はホイール経路から
`setupDemoUi`（UI ツリー全体の再構築）と `reloadStatusItems` を外したこと。
プロファイルの入力経路 654 サンプルに対し `drawFrame` は 73 サンプルで、
割合の大きい `atlasEntryForGlyph`（`drawFrame` の 92%）を 3 周追いかけて外した。
**呼び出しツリーは割合ではなく絶対サンプル数で読む。**

以下は着手前の記録として残す:


現状の `macos_platform.m:2882` は、**可視行を 1 本の NSAttributedString に連結して
CTFramesetter を毎フレーム作り直している**。連結しているので、行が 1 行ぶん
スクロールしただけでもキー全体が変わり、キャッシュが効かない構造になっている。

やること:

1. `updateEditorTextTexture` を「連結ブロックを 1 回組版」から
   **「ソース行ごとに CTLine を作り、各行の y に描く」**へ変える。
2. `CTLine` を (行テキスト, フォント, サイズ, ハイライトのラン) をキーに
   キャッシュする。Zed と同じく 2 フレーム持ちにして、使われなかった行を落とす。
3. 選択・診断の下線は現在 UTF-16 の絶対オフセットを連結ブロックに対して
   計算している（`editorProjectedUTF16RangeForBytes`）。行単位に変えると
   行ローカルのレンジになるので、ここも合わせて書き換える。
4. 折り返しは行ごとに `CTTypesetterSuggestLineBreak` で分割し、
   分割位置も行キャッシュに載せる（今の `editorSoftWrapRowCount` の
   メモ化と統合できる）。

3 が一番の作業量。ここを飛ばすと選択とエラー下線が壊れるので、
**変更後は必ず選択とエラー表示をキャプチャで確認すること**。

### 1. エディタ本文のフォントメトリクス（フォールバック維持で確定・残差として受容）

Zed の既定 `buffer_font_family` は `.ZedMono` = **Lilex**（`references/zed/assets/fonts/lilex`、
OFL）。こちらはシステム等幅にフォールバックしていて、実測で:

- ASCII 送り: こちら 9.272pt / Lilex 9.0pt（15pt 時）→ こちらが約 3% 広い
- CJK 送り: こちら約 13.5pt / Zed 約 14.4pt → こちらが約 7% 狭い

この差で**折り返し位置が全行ずれる**（7 行目は Zed が `.app` / で折り、こちらは
`DMG 配` まで載せる）。エディタ帯の残差の大半はこれ。

**方針: システム等幅へのフォールバックを維持する**（2026-08-07 に確定）。したがって
以下の残差は「未完了」ではなく**受容した差分**として扱う。折り返し位置と CJK 由来の
グリフ幅差、およびそれに連動するタブ幅・水平スクロールバーのサム長は、この方針の
帰結であり、追わない。

参考: **Lilex の同梱は一度試して差し戻した**（`a182b00` のコミットメッセージ参照）。
`packaging/macos/fonts/` に置き、`Info.plist` の `ATSApplicationFontsPath` で
登録し、`resolveMonospacedFontName` で `.ZedMono` → `Lilex` に解決する、までは
動く。しかし**ガターの行番号と Metal のテキスト層が別々のメトリクスで折り返しを
計算している**ため、フォントを差し替えると両者がずれ、行番号が対応する行から
外れる（5 行目の番号が空行に付く）。まず**この 2 経路の折り返し計算を一本化する**
こと。それが済めば Lilex 同梱は上の手順で入る。

### 2. 水平スクロールバーの実装（シーム帯 745–760pt、>32 が 24.02% と最悪）

`e661fff` で罫線を入れ、帯をガターとドックから外したが、**サムの長さは未対応**で
テキスト列の全幅（84–1166pt）を塗ったままの暫定。実測データ:

| Zed ウィンドウ幅 | トラック | サム |
| --- | --- | --- |
| 1389pt | 92–1134pt | 92–915pt |
| 1200pt | 92–945pt | **なし** |
| 1000pt | 92–745pt | 92–525pt |
| 900pt | 92–645pt | **なし** |

幅によって出たり消えたりするので、**内容依存＝本物のスクロールバー**で確定。
Zed のラップ幅は `element.rs` の
`editor_width = bounds.width - gutter.width - gutter.margin - 2*em_width -
vertical_scrollbar_width - minimap_width`。この式と 1 の折り返し一本化が済めば、
`main.nim` の `horizontalEditorScrollbar` がそのまま正しいサムを出すはず。
なお `editorGap` を 745pt より下へ伸ばすと**本文の行を塗り潰す**（不透明な
AppKit ビュー）。伸ばさないこと。

### 3. ツールバー/パンくず（>32 9.63%）

帯の位置・罫線・テキスト上端（82.0pt）は一致済み。残差はグリフそのものなので、
1 のフォント差を直してから再測定する。マーカー（`#`/`##`）の淡色具合と見出しの
太さを実ピクセルで比較する。

### 4. タブバー

アクティブタブの面は Zed が x 61.0–314.5pt、Nimculus が 60.0–299.5pt。幅 14pt の
差はラベルのフォントメトリクス（1）由来の可能性が高いので、これも 1 の後に再測定。
Zed は 2 タブ目が斜体＋グレー背景、未保存は青ドット。

### 5. タイトルバー

Zed 側に "Restart to Update" / "Sign In" / `main` ブランチ表示が出ている間は
**構造的に一致し得ない**。比較前に Zed のこれらの状態を揃えるか、この帯は対象外と
明記すること。

### 6. その先

ライト以外（One Dark）でも同じ測定を通す。テーマ表の `border` / `borderVariant` は
light のみ実描画値に直したので、**dark は未対応**。パネル内部（Files/Git/Outline の
行高、アイコン位置）は未測定のまま。

## 6. 作業の進め方

- **コーディングとコードレビューは codex に任せる**（[`CLAUDE.md`](../CLAUDE.md)）。
  こちらの担当は「Zed の参照実装から移植すべき構造を決める」「codex に受け入れ
  条件つきで指示する」「実測で検証する」「測定値を添えてコミットする」。
  `codex exec "<指示>" < /dev/null` — `< /dev/null` を外すと固まる。
  指示の受け入れ条件は数値で書く（例:「`tools/scroll_cost.sh 40` で 12ms 以下」）。
- 差分の原因は**必ず実測で特定してから**修正する（どの画素が、何 px、どの色ずれているか）。
- 修正はエージェントに投げてよいが、**証拠の提示を必須条件**にする:
  「再ビルドして `.app` を起動し、ウィンドウ単体キャプチャを撮り、
  該当箇所の実測値と bitdiff の数値を貼ること。コード確認やテスト通過だけでは成功と認めない」。
- 変更後は `nimble format` / `lint` / `test` / `build` を通す。テストは 380 checks / 0 failures が現状。
  `test_lsp` は外部プロセス依存でまれに落ちる（再実行で通る）。
- コミットメッセージには**測定値の前後**を書く。後から効果を追跡できる。
