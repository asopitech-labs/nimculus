# macOS UI テスト指針

このリポジトリの macOS UI テストは、Apple 純正の **XCTest + XCUIAutomation** を
主軸にする。外部言語から操作したい場合は Appium Mac2 Driver、アプリ横断の
システムテストや既存 GUI の操作には AXUIElement / AppleScript UI Scripting を使う。

実行手順とコマンドは [`nimculus-ui-test`](../.claude/skills/nimculus-ui-test/SKILL.md)、
完了判定は [`UI_PARITY_ACCEPTANCE.md`](./UI_PARITY_ACCEPTANCE.md) を参照。

## 0. 実行環境: Tart + macOS VM + XCUITest（第一候補）

**GUI テストは開発機のデスクトップ上で直接回さない。** Apple Silicon 上の
macOS VM の中で回す。この Mac（Apple M3 / macOS Tahoe 26.5.2）での最適解は
**Tart + macOS VM + XCUITest**。

理由は「画面を隠したい」ではなく、**入力イベント空間そのものを分離したい**から。
Apple の Virtualization.framework は Apple Silicon 上の macOS guest を正式サポートし、
guest は独立した WindowServer・キーボード・マウス・Pasteboard・ログインセッションを持つ。
ホストで Terminal やエディタを操作していても、guest 内の XCUITest の `click()` や
`typeText()` が**ホストのフォーカスを奪わない**。

```
Apple M3 Mac / macOS 26.5.2
│
├─ Host macOS
│   ├─ IDE / Terminal / Browser
│   ├─ 自分の WindowServer / mouse / keyboard / clipboard
│
└─ Tart
    └─ macOS 26 VM
        ├─ 独立した WindowServer / clipboard
        ├─ auto-login: test user
        ├─ Xcode / xcodebuild / XCTest / XCUIAutomation
        └─ テスト対象 .app
```

### なぜ Virtual Display / 別ユーザーを第一候補にしないか

M3 + Tahoe なら Apple の High Performance Screen Sharing が 1〜2 個の virtual display を
正式サポートするが、それは**同じ kernel・同じ物理 OS の複数ログインセッション**である。
VM なら kernel / login session / WindowServer が完全に分離する。
「自分の作業を一切邪魔しない」が最優先条件なら、数 GB のメモリ節約より
**分離境界が明確な方**を取る。

### セットアップ

Tart は 2026 年に Cirrus Labs から OpenAI 側へ移管された。
**Homebrew の tap は旧 `cirruslabs/cli/tart` ではなく `openai/tools/tart`。**
現在のリポジトリは `openai/tart`。このリポジトリで実際に導入したのは **2.35.0**。

```bash
brew trust openai/tools          # 未 trust の tap は依存 formula の読み込みを拒否される
brew install openai/tools/tart
```

**golden image の作成・復旧・確認は手作業でなく `make vm-provision` /
`make vm-verify` / `make vm-recreate` を使うこと。** 以下の「golden image に
焼き込むもの」「初回起動の障害」の節は `tools/vm_golden_image.sh` が
冪等に自動化している内容の説明であり、手順書としては下記コマンドが正。
詳細と踏んだ罠は [`UI_PARITY_HANDOFF.md`](./UI_PARITY_HANDOFF.md) の
「VM ゴールデンイメージ」節を参照。

```bash
make vm-status      # 非破壊: 存在確認
make vm-verify       # 非破壊: 使い捨てクローンで packageMacos が通るか確認
make vm-provision     # 冪等: 無ければ作成、セットアップ手順を再適用（既存は消さない）
make vm-recreate      # 明示実行のみ: 既存を消してから作り直す
```

Tart の標準値は 2 CPU / 4GB。Xcode + App + WindowServer + XCTest を同居させるなら
**4 vCPU / 8GB を開始点**にする。本体 RAM が 16GB なら 4〜6GB へ下げ、24GB 以上なら 8GB。
このリポジトリの開発機は 24GB なので 8GB を採用。

**ディスクを大きく食う。** golden image は 87GB（`tart get` の Size）を使い、
OCI キャッシュが別に残る。導入で空きが 136GB → 66GB まで減った。
使わなくなったイメージは `tart delete` する。

### golden image に焼き込むもの

`macos-tahoe-xcode` イメージには Xcode / swiftc / python3 / git はあるが、
**このリポジトリの計測に要るものは入っていない**。golden image に焼き込む:

```bash
brew install nim                                        # Nim 2.2.10
python3 -m pip install --break-system-packages pillow numpy   # ink_check.py と captures 比較
brew install --cask zed                                 # Zed 比較の参照実装
```

使い捨て clone のたびに入れ直すと golden image の意味が消えるので、必ず焼き込む。

**Zed の quarantine は、Zed を一度も起動する前に外す。**

```bash
xattr -r -d com.apple.quarantine /Applications/Zed.app
```

Homebrew Cask は `com.apple.quarantine` を付ける。付いたまま起動すると Gatekeeper の
「インターネットからダウンロードされたアプリです」ダイアログが出て、**プロセスは
`ps` の `STAT` が `T`（停止）のまま 1 度も進まない**。この状態では XCUITest の
`launch()` が 70 秒待ってタイムアウトし、`open -a` は `-10673` を返す。
先に起動してしまうと、quarantine を外した後もダイアログが残り続けるので、
その VM は捨てて作り直す。

さらに golden image で片付けておく初回起動の障害:

| 障害 | 対処 |
| --- | --- |
| Zed のオンボーディング画面 | CLI で文書を開くと完了状態へ遷移する |
| Zed の「Unrecognized Project / Restricted Mode」信頼ダイアログ | XCUITest で `zed.activate()` してから `typeKey(.enter)`。**`launch()` では新規 untitled ウィンドウが開き、信頼はそのウィンドウに適用されて目的のプロジェクトには効かない** |
| タイトルバーの「Installing Zed Update」 | `~/.config/zed/settings.json` に `{"auto_update": false}` |
| 通知バナー（背景項目の通知、macOS の案内） | `launchctl unload -w /System/Library/LaunchAgents/com.apple.notificationcenterui.plist`。個別に kill しても復活し、`doNotDisturb` の `defaults` も効かない |
| Nimculus のテーマ | `~/Library/Application Support/Nimculus/settings.json` に `{"theme": "light"}` |

**guest で `osascript` を使わない。** 使うと `tart-guest-agent` に対する
「System Events を制御する許可」ダイアログが出て画面を塞ぐ。XCUITest は
System Events を必要としないので、そもそも呼ばない。

タイトルバーの「Sign In」は Zed 側の状態で消せない。§5.5 の
[`UI_PARITY_HANDOFF.md`](./UI_PARITY_HANDOFF.md) のとおり、
**タイトルバー帯は比較対象外**として扱う。

### 構築中の VM を目で確認する

golden image を作るときは、**画面を見ながら進める**。上の障害はいずれもログや
終了コードには出ず、ダイアログとして画面に出るだけだった。

ホストから Tart のウィンドウを撮るのが最も軽い。guest の権限を一切必要としない:

```bash
swiftc -O tools/window_capture.swift -o /tmp/wincap
/tmp/wincap Tart /tmp/vm.png
```

guest 内から撮るなら `XCUIScreen.main.screenshot()`（TCC 不要、2048×1536）。
ただしこちらは通知バナーなど重なった要素も一緒に写る。

### ホストからの実行は `tart exec`（SSH / ネットワークを経由しない）

**`tart exec` は `--` を取らない。** 2.35.0 の書式は
`tart exec [-i] [-t] <name> <command> ...`。`tart exec vm -- cmd` と書くと
`exec: "--": executable file not found in $PATH` になる。

```
Host shell → tart exec → Tart Guest Agent → guest login user → xcodebuild → XCUITest
```

Guest Agent は non-vanilla の Cirrus Labs イメージに同梱済み。

**このホスト（macOS 26.5.2）では特に重要。** Tart には macOS 26.5.2 ホストで
Wi-Fi bridged networking が DHCP lease を取得できないという未解決 Issue #1289 が
2026-07-23 に報告されている。`--net-bridged=Wi-Fi` などに頼らず、
**default NAT + Guest Agent / `tart exec`** にする。テスト制御経路を
ネットワークから外せることが実用上の意味を持つ。

### VM は使い捨てにする

1 台の VM を汚しながら使い続けない。

```
ui-test-base ──clone──▶ ui-test-run-001 ──▶ build / XCUITest / screenshot / .xcresult ──▶ destroy
```

```bash
VM="ui-test-$(date +%s)"
tart clone ui-test-base "$VM"
tart run "$VM" &
tart exec "$VM" -- xcodebuild -project MyApp.xcodeproj -scheme MyApp -destination 'platform=macOS' test
tart stop "$VM"; tart delete "$VM"
```

毎回 UserDefaults / Keychain / Pasteboard / Documents / Caches / Application Support /
**TCC 状態** / テストデータが同じ初期状態から始まる。Tart はもともと CI 向けの
clone / disposable VM を想定した設計で、OCI registry に VM イメージを保存できる。

### macOS バージョンは 2 系統持つ

回帰テスト基盤として完成させる段階では、ホストと guest を同じ **26.5.2** に固定した
系統を 1 つ持つ（macOS 26.5.2 は 2026-06-29 リリース）。

```bash
tart create --from-ipsw=/path/to/macos.ipsw tahoe-26.5.2
tart create --from-ipsw=latest tahoe
```

- `tahoe-26.5.2-xcode` — 自分の実環境との一致確認
- `tahoe-current-xcode` — 次の OS 更新で壊れないかの先行確認

### GUI は VM 内では必ず生かす（headless と混同しない）

必要なのは「WindowServer なし」ではなく、
**guest 側には WindowServer が存在し、host 側には表示・入力を要求しない**こと。

| Host | Guest |
| --- | --- |
| 作業継続 / Terminal / Browser | Aqua login / WindowServer / AUT.app |
| keyboard・mouse・clipboard を**渡さない** | XCUI の keyboard / mouse / clipboard |

Virtualization の Paravirtualized Graphics が guest macOS 用に Metal アクセラレーションされた
仮想 graphics device を提供するので、**物理ディスプレイも HDMI dummy plug も不要**。

`--no-graphics` は最初は使わない。`tart run ui-test` で guest graphics device を生かす。
Tart の VM ウインドウは単なる guest display viewer であり、guest 内の XCUITest が
アプリを activate してもホストの Terminal を activate しない。安定動作後に、
`--no-graphics` でも WindowServer / XCUI click・typeText / screenshot /
visual regression が成立するかを個別に PoC する。

### ソース共有は read-only か rsync。DerivedData は guest ローカル

Tart には VirtioFS の read/write mount で Git repository の同期が不安定になる
Issue #1272 が 2026-06-18 現在オープン。**host の working tree を RW で共有したまま
本番運用しない。**

```
Host source → read-only mount / rsync / git → Guest local APFS worktree → DerivedData も Guest 内
```

Xcode は DerivedData / `.swiftpm` / `build/` / index を大量に書き換えるので、
host 共有ディレクトリに置かない。

### 採用構成（このリポジトリの固定値）

| 項目 | 採用 |
| --- | --- |
| 仮想化 | Apple Virtualization.framework |
| VM 管理 | Tart 2.34.x（`brew install openai/tools/tart`） |
| Guest | macOS Tahoe 26（可能なら 26.5.2 固定イメージ） |
| 開発ツール | Xcode 入り golden image |
| GUI session | auto-login した専用 test user |
| UI automation | XCTest / XCUIAutomation |
| Host→Guest 実行 | `tart exec` |
| Network | default NAT。**Wi-Fi bridge は避ける** |
| Source | Guest ローカルへコピー |
| Build cache | Guest APFS |
| 実行単位 | golden image からの使い捨て clone |
| 成果物 | `.xcresult` + screenshot |
| VM GUI | 通常は触らない |
| Host desktop | 完全に通常利用継続 |

### この方針が解決する実害（現状の記録）

現在の UI パリティ実測はホストのデスクトップ上で直接行っており、次が起きている:

- 測定のたびに対象アプリを `activate` するのでユーザの作業フォーカスを奪う
- CGEvent 投入のために Terminal ウィンドウを開くのでデスクトップに残骸が溜まる
- 画面のスリープ／ロックで測定が黙って壊れる（キャプチャが真っ黒になる）
- ホストの TCC 権限・ウィンドウ位置・他アプリの重なりに結果が左右される

VM 内に閉じれば、これらはすべて構造的に消える。

## 1. 4 層で考える

| 層 | 技術 | 主用途 | 推奨度 |
| --- | --- | --- | --- |
| コンポーネント | XCTest / Swift Testing | ViewModel・ロジック | ★★★★★ |
| UI 操作 | XCUIAutomation / XCUITest | 実際のウィンドウ、ボタン、入力 | ★★★★★ |
| 外部 E2E | Appium Mac2 | Python/JS 等から macOS 操作 | ★★★★☆ |
| OS レベル | AXUIElement / AppleScript | Finder 等を含む複数アプリ操作 | ★★★☆☆ |

XCUIAutomation は macOS 上でクリック、キーボード入力、スクロール、
マウスポインタ操作を扱える。

## 2. 全部を UI テストにしない

配分の目安（全 1000 ケースなら）:

```
Unit             800
Component        150
XCUI              40
Full System E2E   10
```

```
Unit / Model  →  Component / Snapshot  →  XCUITest E2E  →  System E2E
   高速・大量        UI 見た目確認         主要フロー      Appium / AXUIElement
```

## 3. XCUITest が触るのは Accessibility Tree である

```
App UI  →  Accessibility Tree  →  XCUIAutomation
```

XCUIAutomation は `NSView` や SwiftUI View を直接触っているのではなく、
**macOS Accessibility Tree として公開されている UI 要素**を操作する。
`XCUIElementAttributes` が取得できるのも accessibility system に公開された情報だけ。

したがって対象は SwiftUI でも AppKit でも Objective-C でも構わない。
**UI ライブラリが何かより、Accessibility Tree を正しく提供できているかが本質。**

## 4. Nimculus にとっての最重要点: これは移植漏れである

**Zed は Accessibility を実装している。Nimculus はそれを移植していない。**
「独自 UI だから Accessibility Tree が無いのは仕方ない」ではなく、単なる移植漏れ。

Zed は AccessKit 経由で、テキストシステムとまったく同じ 3 層で実装している:

| 層 | Zed |
| --- | --- |
| element（app） | `crates/gpui/src/element.rs:112` `fn a11y_role(&self) -> Option<accesskit::Role>`、`:120` `write_a11y_info(&self, node: &mut accesskit::Node)`、`:228` `accesskit_node_id()` |
| framework | `crates/gpui/src/window/a11y.rs` — `A11y`(:166)、`A11ySubtreeBuilder`(:300)、`A11yNodeBuilder`(:386)。`accesskit::TreeUpdate` を組む |
| platform | `crates/gpui_macos/src/window.rs:535` `accesskit_macos::SubclassingAdapter`、`:1881` `a11y_tree_update`、`:1902` `ActivationHandler`、`:1908` `A11yActionHandler` |

設計解説は `crates/gpui/src/_accessibility.rs`。synthetic children（要素に対応しない
合成ノードの注入）もそこにあり、Metal で描いたエディタ本文のように
「1 個の要素の中に構造がある」ものはこれで公開する。

AccessKit は Rust のクレートで Nim に等価物が無いため、platform 層は
`accesskit_macos` が内部でやっていること（NSAccessibility プロトコルの実装）を
自前で持つ。これは Zed と違う形にすることではなく、**`accesskit_macos` に相当する層を
自分で持つ**ということ。element と framework の分かれ方、role の申告方法、
synthetic children の考え方は Zed のとおりにする。

実際、UI パリティの実測で `System Events` に対して
`count of windows` が不安定に 0 を返し、要素単位の検証がまったくできないため、
ウィンドウ単体キャプチャのピクセル比較（`tools/bitdiff.sh`、`tools/ink_check.py`）と
CGEvent の直接投入（`tools/post_scroll.swift`）で代替している。これは
「Accessibility Tree が薄い」ことの直接の帰結であり、テストが壊れやすい原因でもある。

**したがって Nimculus では、UI 要素を Accessibility Tree に公開する実装が
テスト自動化の前提条件になる。** Metal で描いた面であっても、対応する
accessibility element（role / title / value / identifier / children / parent）を
提供すれば、XCUITest・Appium・AXUIElement のすべてから同じ UI を操作できる。

これは新しい UI を設計するときの必須検討項目とする
（[`.claude/skills/nimculus-ui-design`](../.claude/skills/nimculus-ui-design/SKILL.md) の
設計チェックに含める）。

## 5. Accessibility Identifier を「テスト用 API」として設計する

Web の `data-testid` 相当として体系化し、UI 設計段階から仕込む。後から自動化しない。

```
toolbar.new
toolbar.open
toolbar.save
sidebar.projects
sidebar.settings
editor.filename
editor.content
dialog.confirm.ok
dialog.confirm.cancel
```

SwiftUI なら `.accessibilityIdentifier("saveButton")`、
テスト側は `app.buttons["saveButton"].click()`。表示 UI を変えずに要素を一意に
識別できる。

## 6. XCUITest の書き方

```swift
import XCTest

final class MyAppUITests: XCTestCase {
    func testCreateDocument() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["newDocument"].click()
        app.textFields["documentName"].click()
        app.textFields["documentName"].typeText("test")
        app.buttons["save"].click()
        XCTAssertTrue(app.staticTexts["test"].exists)
    }
}
```

### Recorder の出力はそのまま残さない

Xcode の UI Automation record/replay でコードを生成してよいが、生成された

```swift
app.windows["Main"].groups.children(matching: .group)
    .element(boundBy: 1)
    .buttons.element(boundBy: 3).click()
```

は、レイアウトを少し変えただけで壊れる。必ず

```swift
app.buttons["saveButton"].click()
```

へ書き換える。

## 7. 機能テストと見た目テストを分ける

XCUITest では「ボタンが存在する / クリックできる」は検証できるが、
**画面外へのはみ出し、5px のずれ、文字切れ、背景色の異常**は検出できない。

`XCUIScreenshot` と `XCTAttachment` でスクリーンショットを記録し、
snapshot テストとして分離する。

```swift
let shot = XCUIScreen.main.screenshot()
let attachment = XCTAttachment(screenshot: shot)
attachment.lifetime = .keepAlways
add(attachment)
```

このリポジトリの `tools/bitdiff.sh` / `tools/ink_check.py` は、Accessibility Tree が
未整備な現状における snapshot テストの代替である。§4 が解決したら
XCUITest 側へ寄せていく。

## 8. Accessibility Inspector を併用する

Xcode 付属の Accessibility Inspector は、アクセシビリティ対応のためだけの
ツールではない。**UI テスト側から何が見えているか**（Role / Title / Value /
Identifier / Children / Parent）を確認できる。

```
Accessibility Inspector  →  XCUIAutomation
```

をセットで使う。Nimculus では §4 の実装が進んでいるかの確認手段にもなる。

## 9. Appium Mac2 を使う場合

裏側で Apple の XCTest を使う。

```
Python / TypeScript / Java  →  WebDriver  →  Appium  →  Mac2 Driver
    →  XCTest  →  macOS Accessibility  →  Application
```

```python
driver.find_element("accessibility id", "saveButton").click()
```

**自社 macOS アプリだけをテストするなら XCUITest を選ぶ。** Xcode 統合、
Swift の型安全、`.xcresult`、Recorder、スクリーンショット、動画、CI 統合が揃う。
Appium は macOS + Windows などのクロスプラットフォーム E2E を統一したいときに使う。
Nimculus は Windows 対応（ROADMAP M13）を予定しているので、その時点で再検討する。

## 10. AXUIElement / AppleScript

```
AXUIElementCreateApplication(pid) → AXChildren → AXButton → AXPress
```

複数アプリをまたぐ統合テスト（自作アプリ → Finder → System Settings）を作れるが、
テストフレームワークとしての機能はほぼ自作になる。

AppleScript の UI Scripting は

```applescript
tell application "System Events"
    tell process "MyApp"
        click button "Save" of window 1
    end tell
end tell
```

の形で、インストーラー確認・Finder 連携・ファイルダイアログ・他アプリ連携に便利。
ただし GUI automation であってテストフレームワークではないので、
アプリ内部の大量の回帰テストには XCUITest を使う。

## 11. macOS 固有の落とし穴: Accessibility 権限

iOS と大きく違う点。外部プロセスが UI を制御するため
System Settings → Privacy & Security → Accessibility の権限が必要になる。
Appium Mac2 では加えて macOS 12 以降の testmanagerd UIAutomation 認証が要る
（`appium driver doctor mac2` で診断できる）。

**権限の持ち主を取り違えないこと。** 実測で踏んだ実例:

- `osascript` 経由の AX 参照は **System Events 自身**の権限で通るので成功する
- CGEvent の投入は **投げる側のプロセス**の権限が要るので失敗する

この非対称のせいで「ウィンドウは読めるのにスクロールが届かない」という状態になり、
**イベントが 1 つも届いていないのに `1.25 ms/scroll` という「速すぎる」偽の値**が出た。
入力を伴う測定では、必ず前後のウィンドウキャプチャを比較して
**実際に画面が変化したこと**を確認する。

## 12. CI

```bash
xcodebuild -project MyApp.xcodeproj -scheme MyApp -destination 'platform=macOS' test
```

結果は `.xcresult` に test results / failures / screenshots / coverage が入る。

### ローカルと CI で同じ VM を使う

ビルドと unit test は GitHub-hosted macOS runner でよい。
**GUI / Accessibility を伴う完全な Desktop E2E は §0 の Tart VM で回す。**
ログイン GUI セッション、Accessibility 権限、画面収録権限、ウィンドウサイズ、
解像度、locale、キーボードレイアウトを固定したいため。golden image に焼き込めば、
開発機でも self-hosted runner でも同じ初期状態で走る。

Xcode Cloud も選択肢だが、通常の XCUI テストと OS 全体を触る Desktop E2E は
別物として扱う。後者は VM のほうが自由度が高い。

### Test Harness の 3 段階

```
make test
    ├─ Unit tests        … Host で実行
    ├─ Integration tests … Host で実行
    └─ make ui-smoke
          → Tart clone → macOS VM boot → tart exec → xcodebuild test
            （XCUI click/type / screenshot / clipboard test）
          → .xcresult 回収 → VM delete
```

夜間だけ `make ui-regression` で全 UI 回帰テストを走らせる。
日常開発で `make ui-smoke` を実行しても、**自分は Terminal・エディタ・ブラウザを
そのまま触り続けられる**という状態にする。

### 実行タイミング

```
PR      → Unit / Component → XCUI smoke → merge
nightly → XCUI full regression → Screenshot → System E2E
          artifact: .xcresult + video + screenshots
```

## 13. 移植漏れを個別に発見しない

§4 の Accessibility は、**実測が詰まって初めて「Zed にはあるのに移植していない」と
気づいた**。テキストレイアウトの `LineLayoutCache` も、グリフのインスタンス描画も、
グリフアトラスのキーも、すべて同じ経緯で見つかっている。いずれも最初は
「Nimculus の設計上の制約」「今回のスコープ外」と誤って扱っていた。

**「Nimculus にこれが無いのは仕方ない」と考えたら、まず `references/zed` を検索する。**
Zed にあれば、それは仕様差ではなく移植漏れである。

移植漏れの棚卸しは [`docs/ZED_PORT_GAPS.md`](./ZED_PORT_GAPS.md) に集約する。
