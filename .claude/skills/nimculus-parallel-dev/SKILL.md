---
name: nimculus-parallel-dev
description: >-
  Nimculus の移植作業を複数の codex に手分けして同時に走らせるときに使う。
  git worktree で作業を隔離し、ファイル所有を決め、排他資源（Tart VM）を直列化し、
  統合する手順を扱う。「並行してやって」「手分けして」「複数エージェントで」
  「同時に進めて」「ワークトリーを使って」「一気に片付けて」といった指示で必ず発動する。
  2 件以上の実装を同時に進めようとするとき、たとえ指示に「並行」の語が無くても参照する。
  docs/ZED_PORT_TASKS.md の未着手項目をまとめて消化する作業もここに当たる。
  設計は nimculus-ui-design、実装規約は nimculus-ui-dev、計測は nimculus-ui-test を参照。
---

# Nimculus 並行開発（ワークトリー）

移植タスクを複数同時に流すための手順。作業の中身は
[nimculus-ui-design]（設計）/ [nimculus-ui-dev]（実装規約）/
[nimculus-ui-test]（検証）に従う。ここは**同時に走らせるための隔離と直列化**だけを扱う。

`CLAUDE.md` の分担は並行時も変わらない。**codex が書き、こちらは決めて・指示して・測って・
コミットする。** 並行化しても「codex の報告は証拠にならない」は変わらず、
ワークトリーが増えるぶん**自分で測る対象も増える**。

## 1. 並行にできるもの、できないもの

| 作業 | 並行 | 根拠 |
| --- | --- | --- |
| Zed / 実装を読む調査 | **制限なし** | 書き込みが無い |
| codex による実装 | **ワークトリーごとに 1 本、3 本まで** | ホストは 8 CPU。Nim のビルドは 1 本で複数コアを使う |
| `nimble build` / `test` | ワークトリーごとに独立 | `nimculus.nimble` の `--nimcache:` は**相対パス**（`.nimcache/build` など）。`build/` も相対 |
| `tools/ui_test.sh`（画素・スクロール計測）| **排他。1 本だけ** | 下記 |

### VM が排他である理由

**(a) VM 名が秒単位で衝突する。** `tools/ui_test.sh:39` は
`RUN="ui-test-$(date +%s)"`。同じ秒に 2 本開始すると同名の VM を作りに行く。

**(b) 資源が足りない。** ゴールデンイメージは 4 CPU / 8GB。ホストは 8 CPU / 24GB。
2 台立てれば CPU を食い尽くす。

**(c) 計測値が壊れる。** これが決定的。2026-08-10、**同じコードで同じ計測を 2 回**回して
`nimculus 21.875` と `17.969`、`zed 20.208` と `15.313` が出た。ホストの負荷だけで
4〜5ms 動く。VM を 2 台走らせた計測は**数字として使えない**。

したがって: **実装は並行、計測は直列。** 各ワークトリーで
`nimble format` / `lint` とランナー（`tests/test_runner.nim`）まで済ませ、
**計測待ちの列に並べる**。`nimble test` の終了コードは当てにならない
（[nimculus-ui-test] の §0）。

## 2. ワークトリーを作る・畳む

```bash
# 作る（ブランチも同時に切る）
git worktree add ../nimculus-wt-<課題> -b port/<課題>

# 作った直後に必ずやる。これを飛ばすとビルドが通らない
cd ../nimculus-wt-<課題>
git submodule update --init --recursive
ln -s /Users/yoshinori/work/nimculus/references/zed references/zed

# 一覧
git worktree list

# 畳む（マージ後）
git worktree remove ../nimculus-wt-<課題>
git branch -d port/<課題>
```

置き場所はリポジトリの外（`../`）。中に作ると `git ls-files` に載り、
`tools/ui_test.sh` が VM へ配るソースに混入する。

**`nimble clean` は並行時も禁止。** `build/` が消えるのは各ワークトリーで同じ。

### `references/` は付いてこない（2026-08-10 に踏んだ）

`git worktree add` が展開するのは**追跡ファイルだけ**。この 2 つは来ない。

| | 状態 | 結果 |
| --- | --- | --- |
| `references/tree-sitter*` | **サブモジュール** | 空ディレクトリになる |
| `references/zed` | **`.gitignore:27`** | 存在しない |

3 本を同時に流して**3 本ともビルドが落ちた**。`nimble build` は tree-sitter の
ソースを要求し、指示書は `references/zed` の行番号を参照する。
どちらも無いので、codex は「参照先が無い」と報告して止まる。

`zed` は 148 万行あるのでコピーしない。**読むだけなのでシンボリックリンクで共有する。**

### 隔離が効いていることの実測（2026-08-10）

```
ワークトリーで nimble lint を実行
  → ワークトリー側に .nimcache が生成される
  → 本体の .nimcache の mtime は変化しない
git ls-files に ../nimculus-wt-* は載らない
```

**ディスクを見積もる。** 本体の `.nimcache` は **720MB** まで育つ。
ワークトリーはビルドするたびに自分のぶんを持つので、3 本並べれば数 GB 増える。
空きが 10GB を切ったら並列度を下げる。`nimble clean` で消してはいけないので、
畳むときに `git worktree remove` ごと消すのが唯一の回収経路。

作りっぱなしにしない。ワークトリーは作業ツリーの実体なので、
放置すると `main` の状態が分からなくなる。**マージしたら畳む。**

## 3. 作業の割り当て — ファイルを 1 タスクだけが所有する

Nimculus は Zed のような層分割が済んでおらず、実装が 2 ファイルに集中している。

| ファイル | 行数 | 状態 |
| --- | ---: | --- |
| `src/nimnui/platform/macos/macos_platform.m` | 18,718 | **最大の競合点** |
| `src/nimculus/main.nim` | 9,845 | **次点** |

**同じファイルを触る 2 タスクを同時に流さない。** ワークトリーが分かれていても
マージで衝突し、解決の過程で片方の変更が消える。今日 `git add -A` で
無関係な変更を巻き込んだ事例があり、衝突解決はそれより危険。

指示書に**所有ファイルを明記**する:

```
## このタスクが所有するファイル

- src/nimculus/lsp.nim
- tests/test_lsp.nim

上記以外を変更しないこと。必要になったら報告して止めること。
```

割り当ての作り方:

1. `docs/ZED_PORT_TASKS.md` から `[ ]` を選ぶ
2. 各項目の `files_to_touch` を見る
3. **ファイル集合が交わらないものを束ねる**
4. 交わるものは同じワークトリーに入れて 1 本の指示にするか、順番に流す

交わらない組の例:

| ワークトリー | 所有 |
| --- | --- |
| A | `src/nimculus/lsp.nim`, `lsp_editor_bridge.nim`, `tests/test_lsp.nim` |
| B | `src/nimculus/settings.nim`, `syntax.nim`, `tests/test_settings.nim` |
| C | `src/nimnui/text.nim`, `tests/test_ui_text.nim` |

### 受け入れ条件が所有外を要求していないか確かめる

**指示書の受け入れ条件が、所有していないファイルの変更を要求していたら、
そのタスクは並列に流せない。**

2026-08-10 の実例: `Hsla とアルファの導出` を
`geometry.nim` / `render.nim` / `text.nim` の所有で流したが、
受け入れ条件に「`macos_platform.m` の色梯子を置き換えてキャプチャで確認」が
入っていた。codex は**所有外に手を出さず、止めて報告した**。指示どおりの正しい振る舞いで、
誤っていたのは束ね方。

束ねる前に、`files_to_touch` だけでなく **`acceptance` が要求するファイルも**見る。
画素で判定する項目（`verifiable_by: capture-pixels`）はほぼ必ず
`macos_platform.m` を要求するので、**画素判定のものは並列に回さない**。
unit test で判定できるものが並列向き。

`macos_platform.m` を触るタスクは**常に 1 本だけ**。これが並列度の上限を決める。
UI パリティの作業はほぼ全部この 1 ファイルに落ちるので、**そこが本当のボトルネック**。
層を分ければ並列度が上がる（`docs/ZED_ARCHITECTURE.md` を参照）。

## 4. 各ワークトリーで codex を回す

```bash
cd ../nimculus-wt-<課題>
codex exec "$(cat <指示書>)" < /dev/null > <ログ> 2>&1
```

`< /dev/null` は並行時も必須（付け忘れて 4 時間ハングした実績）。
出力は**必ずファイルへ落とす**。`| tail -N` で切ると原因の説明が消える。
2026-08-10、`tail -25` で codex の原因究明の記述を切り捨て、
差分を読み直すまで実体が分からなかった。

複数本を同時に投げるときは背景実行にし、**ログのパスを課題ごとに分ける**。

### 終了コードを見る

並行時は目視で追えないぶん、**コマンドが実際に走ったかを確かめる**。

このスキルを書いたその日に踏んだ例: ワークトリーの隔離を確かめようとして
`timeout 900 nimble lint` と書いた。**macOS に `timeout` は無い**（GNU coreutils）。
`rc=127` で lint は 1 行も走らず、それでも「本体の `.nimcache` は無傷」という
**合格が出た**。何も実行しなければ何も触らない。

`&&` で繋いだ検証は、前段が落ちると後段が「差が無い」を報告する。
**差が無いことを確かめる検証ほど、実行されたことを別に確かめる。**

## 5. 統合の順序

**計測が済んだものから `main` へ入れる。** 未計測のものを先に入れない。

```bash
cd /Users/yoshinori/work/nimculus
git merge --no-ff port/<課題>
```

順序の決め方:

1. **他のタスクが依存しているものを先に。** `docs/ZED_PORT_TASKS.md` の
   `blocked_by` に名前が出ているものが先
2. **触るファイルが多いものを先に。** 後続の衝突が小さくなる
3. 残りは計測が終わった順

衝突したら、**衝突解決の結果をもう一度計測する。** 解決の過程で片方の変更が
欠けても、テストは通ることがある。今日「テストは緑、画面は変わらず」を
3 回踏んでいる。

## 6. 計測は 1 本ずつ、比で判定する

各ワークトリーの成果を `main` に入れたあと、**まとめて 1 回**計測するのではなく、
**1 件入れるごとに計測する**。まとめると、どれが効いたか分からなくなる。

```bash
NIMCULUS_ALLOW_ADHOC=1 nimble packageMacos
tools/ui_test.sh parity
```

判定は [nimculus-ui-test] に従う。並行時に特に効く点:

- **スクロールは比（nimculus / zed）で見る。** 絶対値はホストの状態で 4〜5ms 動く。
  他のワークトリーでビルドが走っていればなおさら
- **画素は `identical` を主指標にする。** 大きな差だけ数える指標は
  2 段階の色ずれに盲目で、実際にウィンドウの半分を覆う差を見逃していた

計測中は**他のワークトリーでビルドを走らせない**。`nimble build` は
複数コアを食い、VM の中の計測に効く。

## 7. チェックリスト

投入前:

- [ ] 各タスクの所有ファイルが交わっていない
- [ ] `macos_platform.m` を触るタスクが 1 本以下
- [ ] 同時に走る codex が 3 本以下
- [ ] 各指示書に所有ファイルと受け入れ条件（数値）が書いてある
- [ ] `< /dev/null` が付いている / 出力をファイルへ落としている

統合前（ワークトリーごと）:

- [ ] `nimble format` / `lint` を実行した
- [ ] **ランナーで検証した**（`nim c --mm:arc -r --path:src tests/test_runner.nim` の rc=0）。
      `nimble test` の rc は当てにならない — nimble はこの環境で常に 0 を返す
- [ ] `NIMCULUS_ALLOW_ADHOC=1 nimble packageMacos` が通る
- [ ] 計測が要る項目は**計測待ちの列に入れた**（ここでは計測しない）

統合後（1 件ごと）:

- [ ] 計測した（画素は `identical`、スクロールは比）
- [ ] 衝突を解決した場合、解決後にもう一度計測した
- [ ] `docs/ZED_PORT_TASKS.md` の該当項目を `[x]` にした
- [ ] ワークトリーを畳み、ブランチを消した
