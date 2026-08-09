# Zed 移植漏れの棚卸し

Nimculus は Zed の移植である。**「Nimculus にこれが無いのは設計上の制約」「今回の
スコープ外」と考えたら、まず `references/zed` を検索すること。** Zed にあれば、
それは仕様差ではなく移植漏れである。

## なぜこの文書があるか

移植漏れを、実測が詰まったときに 1 件ずつ発見していた。いずれも最初は
「Nimculus の制約」「スコープ外」と誤って扱っていた:

| 見つかったもの | 発見のきっかけ | 誤った当初の扱い |
| --- | --- | --- |
| `LineLayoutCache`（行レイアウトの 2 フレームキャッシュ） | スクロールが Zed の 2 倍遅い | 「最適化として後で」 |
| 層の誤り（キャッシュを platform に置こうとした） | 「Zed と違う形にせざるを得ない」が出た | 設計判断だと思っていた |
| `MonochromeSprite` のインスタンス描画 | CoreText を消したら別の場所が 77% に | 「今回のスコープ外」と明記していた |
| `RenderGlyphParams`（アトラスキー） | インスタンス化したら別の場所が 84% に | — |
| Accessibility（AccessKit 経由） | テスト VM で ScreenCaptureKit の TCC に阻まれた | 「独自 UI だから無いのは仕方ない」 |

同じ経緯を繰り返さないために、**先に棚卸しする**。

## 突き合わせの方法

```bash
ls references/zed/crates/gpui/src/*.rs        # framework
ls references/zed/crates/gpui_macos/src/*.rs  # platform
ls src/nimnui/*.nim                           # NimNUI
```

Zed 側にあるモジュールで、Nimculus 側に対応物が見当たらないものを洗い出す。
**「対応物が見当たらない」は grep の結果であって、移植漏れの確定ではない。**
確定するには、そのモジュールが何をしているかを読み、Nimculus のどこが同じ役割を
負っているかを確認する。下表の「状態」はその確認の進み具合を表す。

## gpui（framework）

| Zed モジュール | Nimculus の対応 | 状態 |
| --- | --- | --- |
| `window/a11y.rs` / `_accessibility.rs` | 無し | **移植漏れ確定。着手済み**（docs/MACOS_UI_TEST_GUIDELINES.md §4） |
| `text_system/line_layout.rs` | `src/nimnui/text.nim` | 移植済み（`LineLayout` / `LineLayoutCache` / `computeWrapBoundaries`） |
| `scene.rs` | `src/nimnui/render.nim`（`PaintList`）、`macos_platform.m`（`NimculusMonochromeSprite`） | **部分移植**。グリフの `MonochromeSprite` は入れたが、`PolychromeSprite` / `Quad` / `Shadow` / `Path` など他のプリミティブは未確認 |
| `taffy.rs` + `style.rs` | `src/nimnui/layout.nim` / `layout_types.nim` | **部分移植（2026-08-09 確認）**。`LayoutSpec` は direction / size / min / max / padding / gap / flexGrow / alignment。Zed の `Style`（style.rs:182-309）にある **`position` + `inset`（絶対配置）・`margin`・`overflow`・`align_items` と `justify_content` の分離・grid・`flex_shrink` / `flex_basis`・`display`** が無い。Zed は Taffy に委譲、こちらは自前の Row/Column/Stack |
| `bounds_tree.rs` | 無し（現時点では不要） | **`scene.rs` のバッチ化とセット（2026-08-09 調査）**。用途はヒットテストではなく**描画順序の割り当て**。`insert`（bounds_tree.rs:120）は「交差する既存プリミティブの最大 order + 1」を返し、`finish()`（scene.rs:150）が種別ごとに order で並べ替える。Zed は Shadows / Quads / Paths / Underlines / Sprites を**種別ごとにバッチ描画**する（`batches()` scene.rs:172）ので順序が崩れる。交差しないものを同じ order にまとめて 1 バッチに畳むための R-tree。<br>**Nimculus は種別バッチ化をしていない**（`drawPaintCommand` が PaintList を投入順に描き、グリフのインスタンスバッチは常に最後）ので、復元すべき順序が無い。`scene.rs` のプリミティブ体系を移植した時点で必要になる。棚卸し当初の「ヒットテスト／再描画範囲」は**誤り** |
| `tab_stop.rs` | `commands.nim:133` `focusNext` | **部分移植（2026-08-09 確認）**。Zed は `TabStopMap`（SumTree）で `tab_index` 順に巡回し、`window.rs:349` の `tab_stop` フラグで参加を制御する。こちらは毎回 `focusables` を線形に組み直し、**tab index による順序指定が無い**（宣言順のみ） |
| `key_dispatch.rs` / `keymap/` | `src/nimnui/commands.nim` | **部分移植（2026-08-09 確認）**。Zed は `DispatchTree` が `context_stack: Vec<KeyContext>`（key_dispatch.rs:73,127）を持ち、フォーカス位置に応じて同じキーを別アクションへ振り分ける。こちらは `CommandRegistry` が `Shortcut` → `Command` の**単一の平坦な表**で、コンテキストの概念が無い |
| `path_builder.rs` | 無し | **移植漏れ（2026-08-09 調査）。用途を特定済み**。Zed での利用は 3 箇所: `editor/src/element.rs:10519` の**角丸選択範囲**（`rounded_selection`、`editor_settings.rs:24`、**既定 `true`**）、`ui/src/components/divider.rs:105` の破線、circular progress。<br>角丸選択は**既定で有効なので UI パリティに直接効く**。こちらの選択範囲は `PaintKind.selection`（render.nim:6, macos_platform.m:2115）で矩形描画。`roundedRectangle` はあるが、Zed の角丸選択は**行をまたぐ連続領域の外周を 1 本のパスで丸める**もので、行ごとの角丸矩形では再現できない |
| `svg_renderer.rs` | AppKit の SF Symbols（`macos_platform.m:1147,4223,5231,5344-5348` の `imageWithSystemSymbolName:`） | **単独では移植できない（2026-08-09 調査）**。Zed は `svg()` 要素（elements/svg.rs:20）を `paint_svg`（:129,150）で描き、`AtlasKey::Svg` は Monochrome アトラスへ入る（platform.rs:1174）。**色は呼び出し側が渡す**（`style.text.color`）。<br>こちらのアイコンは **AppKit の `NSButton` に `NSImage` を設定**する形で、Metal のシーンに載っていない。SVG レンダラを入れても**描く先が無い**。<br>→ アイコンを AppKit ビューから Metal のスプライトへ移すのが先。これは「chrome を AppKit で描くか Metal で描くか」という**要素モデルより手前の大きな構造差** |
| `gestures.rs` | 無し（移植しない） | **macOS では Zed も使っていない（2026-08-09 調査）**。`GestureKinds { tap, long_press, pan, pinch }`（gestures.rs:60）は**タッチデバイス用**で、`PlatformGestures`（:107）の macOS 実装は `NullPlatformGestures`（:121、no-op）。当初「トラックパッドのピンチ・回転」と書いたのは**誤り**。<br>macOS のトラックパッドは `ScrollWheelEvent` の `TouchPhase`（events.rs:236-268）として扱われ、`OngoingScroll` の軸ロック（editor/src/scroll.rs:68,132）が本命 → **DESIGN_DECISIONS UI-104** |
| `asset_cache.rs` | 無し | **`svg_renderer` と同じ下流（2026-08-09 調査）**。キャッシュする対象（SVG / 画像）が Metal のシーンに載っていないので、キャッシュだけ入れても仕事が無い。`arena` / `bounds_tree` / `pasteboard` と同じ構造 |
| `arena.rs` | 無し | **単独では移植できない（2026-08-09 調査）**。Zed の `draw()` は `ArenaClearNeeded` を返し、次の draw の前に `clear()` される（window.rs:2679, :337）。`AnyElement::new` は要素を作るたびにアリーナから確保する（element.rs:596）。つまり**アリーナは即時モードの帰結**で、毎フレーム作り直される要素の置き場である。Nimculus は `UiTree` を保持し続ける保持モードなので、アリーナに入れるものが無い。→ 下の「要素モデル」の行を参照 |
| `executor.rs` / `platform_scheduler.rs` / `queue.rs` | `src/nimculus/poll_scheduler.nim`（アイドル間隔の調整のみ） | **方式が違う（2026-08-09 確認）**。Zed は `BackgroundExecutor` / `ForegroundExecutor` に future を `spawn` し、優先度も指定できる（executor.rs:14,22,89,101,314）。こちらに非同期実行基盤は無く、LSP は `poll()`（lsp.nim:811）をイベントループから叩き、プロセス終了は `waitForExit` で同期的に待つ。`git rev-parse` を同期で待って UI をブロックしていた過去の不具合（handoff §5）はこの構造に由来する |
| `inspector.rs` | 無し（移植しない） | **開発ビルド専用（2026-08-09 調査）**。`#[cfg(any(feature = "inspector", debug_assertions))]` で囲まれており、リリースビルドには入らない。`Inspector`（:60）は要素を拾って状態を表示する開発ツール。**製品の挙動に影響しない**。Nimculus は Accessibility Tree が入ったので、要素の調査は Accessibility Inspector と XCUITest で足りる（docs/MACOS_UI_TEST_GUIDELINES.md §8）。移植の利得が無い |
| `style.rs` / `styled.rs` / `color.rs` / `colors.rs` | `src/nimculus/settings.nim`（`ThemeColors`、settings.nim:315,629） | **部分移植（2026-08-09 確認）**。色の役割表は移植済みで実描画値まで合わせてある。一方 `style.rs` のレイアウト部分（`Style`）は `taffy.rs` の行を参照。`styled.rs` に相当する「要素にスタイルを積む API」は無く、コントロールごとに個別実装 |
| **要素モデル（即時 vs 保持）** | `src/nimnui/ui_tree.nim` | **問い自体が成立しない（2026-08-09 再調査）**。`UiTree` は**描画に使われていない**。`demoTree` から `PaintList` を作る経路が無く（`grep` で 0 件）、用途は Accessibility ツリーの構築（main.nim:276）と、AppKit ビューの矩形を追認すること（`:464-466` で `bounds` を代入）だけ。ノードは 10 個で実 UI の影。<br>chrome が AppKit である限り、要素ツリーが描画の源にならないので即時／保持の選択が意味を持たない。→ **UI-111（AppKit chrome）の下流** |
| `element.rs` / `interactive.rs`（要素モデル以外） | `src/nimnui/controls.nim` / `events.nim` | **部分移植（2026-08-09 確認）**。コントロール記述子と capture/target/bubble のイベント段階、`a11y_role` / `write_a11y_info`（element.rs:112,120）は移植済み。未確認は `interactive.rs` のドラッグ&ドロップとツールチップ経路 |
| `profiler.rs` | 無し（移植しない） | **executor のタスク計測（2026-08-09 調査）**。`get_all_timings` / `take_all_stats` は `ThreadTaskTimings` を集計するもので、**Zed 自身の非同期タスクの統計**。汎用プロファイラではない。Nimculus の executor は今回入ったばかりで、統計を取る対象となるタスクがまだ `newGitRepository` の 1 件のみ。**利用者が増えてから判断する**。UI の性能計測は `sample`(1) と `tools/ui_test.sh profile` で足りている |

## gpui_macos（platform）

| Zed モジュール | Nimculus の対応 | 状態 |
| --- | --- | --- |
| `metal_renderer.rs` | `macos_platform.m` | 部分移植（インスタンス描画は入れた） |
| `metal_atlas.rs` | `macos_platform.m` のグリフアトラス | 部分移植（キーは `RenderGlyphParams` 相当へ移植済み） |
| `text_system.rs` | `macos_platform.m` の 1 行シェープ契約 | 移植済み |
| `window.rs`（a11y adapter を含む） | `macos_platform.m` | a11y 部分は**移植漏れ確定** |
| `display_link.rs` | `macos_platform.m:8243` `displayLinkDidFire:` / `:8250` `requestRedraw` | **移植済み（2026-08-09 確認）**。DisplayLink が唯一のフレーム所有者で、入力は dirty を立てるだけ。`preferredFrameRateRange` を画面の `maximumFramesPerSecond` に合わせる（60–120）。Zed が `CVDisplayLink` を使うのに対しこちらは `CADisplayLink`（macOS 14+ の後継 API） |
| `open_type.rs` | 無し | **移植漏れ。ただし既定状態では画面に出ない（2026-08-09 調査）**。`apply_features_and_fallbacks`（open_type.rs:34）が `kCTFontFeatureSettingsAttribute`（`buffer_font_features`）と `kCTFontCascadeListAttribute`（`buffer_font_fallbacks`）を CTFont に設定する。**Zed の既定は features が `{}`、fallbacks が `null`** なので、素の Zed と素の Nimculus で見た目は変わらない。こちらは `CTFontCreateWithName(name, size, NULL)` で属性なし。<br>効くのはユーザが設定を書いたときだけ。**UI パリティには影響しない**ので優先度は低い |
| `pasteboard.rs` | `macos_platform.m:16605-16627` | **部分移植（2026-08-09 調査）**。`NSPasteboardTypeString` を UTF-8 データとして読み書きする点は Zed に合わせてある（コメントに明記）。<br>未対応は `NSPasteboardTypePNG`（画像）と `NSFilenamesPboardType`（ファイル）。`read`（pasteboard.rs:50）は **filenames → string → image** の順に見る。<br>ただし `ExternalPaths` の主用途は**クリップボードではなくドラッグ&ドロップ**（`workspace/src/pane.rs:4484` の `on_drag_move::<ExternalPaths>`）。こちらは `registerForDraggedTypes` が 0 件で**ファイルドロップ自体が無い**。画像貼り付けも、表示できる先（画像を描くプリミティブ）が無い。<br>→ **単独では移植できない。** ドロップは受け口（`draggingEntered` / `performDragOperation`）から、画像は `scene.rs` の `PolychromeSprite` から先に要る |
| `screen_capture.rs` | 無し（移植しない） | **画面共有機能の一部（2026-08-09 調査）**。利用者は `collab_ui/src/collab_panel.rs` と `title_bar/src/collab.rs` — Zed の**共同編集（collab）機能**で自分の画面を相手に送るためのもの。Nimculus に collab 機能そのものが無く、ROADMAP にも無い。**機能が存在しないものの部品**なので移植対象外。UI テストのキャプチャは `tools/window_capture.swift` と `XCUIScreenshot` で別途足りている |
| `dispatcher.rs` | 無し | **移植漏れ（2026-08-09 確認）**。Zed は `dispatch`（優先度つき）と `dispatch_after` を platform に持ち、`executor.rs` の土台になる。framework 側の `executor.rs` の行と同根の欠落 |
| `keyboard.rs` / `events.rs` | `macos_platform.m` の `logInput` / `receiveNativeInput` | **部分移植（2026-08-09 確認）**。ホイールの `ScrollDelta`（precise/lines の分岐）は今回 Zed の式に合わせた。キーボードのレイアウト変更追従（`keyboard.rs`）は未確認 |
| `window_appearance.rs` | `macos_platform.m:15461` `effectiveAppearance` | **移植済み（2026-08-09 確認）**。`NSAppearanceNameAqua` / `NSAppearanceNameDarkAqua` を照合してテーマに反映する。Zed は Vibrant 系も見るが、こちらは Vibrant を使っていない |
| `display.rs` | `macos_platform.m:8275,10737,11000`（`NSScreen`） | **部分移植（2026-08-09 確認）**。画面のリフレッシュレートとスクリーン数の参照はある。Zed の `PlatformDisplay`（ID・境界の抽象）に相当する型は無く、複数モニタをまたぐウィンドウ配置の扱いは未確認 |

## 棚卸しの結論（2026-08-09、全 22 行を処理）

### 移植した（9 件）

| 項目 | 記録 |
| --- | --- |
| `executor` + `dispatcher` | UI-102。`Task[T]` は Nim の `Future[T]` |
| `taffy` / `style` の 4 項目 | UI-103。絶対配置・margin・overflow・軸分離 |
| `TouchPhase` + 軸ロック | UI-104。`gestures.rs` ではなくこちらが本命だった |
| 角丸選択 | UI-105。`path_builder` の実用途 |
| `open_type` | UI-106。features / fallbacks を CTFont 属性へ |
| `key_dispatch` の `KeyContext` | UI-107。`when` が設定にあるのに効いていなかった |
| `tab_stop` | UI-108。tab index 順の巡回 |
| `PolychromeSprite` | UI-110。**カラー絵文字の回帰修正** |
| emoji 判定のフォント識別化 | Zed に無い文字コード判定を削除 |

### 移植しない（6 件、理由つき）

| 項目 | 理由 |
| --- | --- |
| `gestures.rs` | タッチ用。macOS 実装は `NullPlatformGestures`（Zed も使っていない） |
| `scene.rs` の全面置換 | 分類の軸が違い（形 vs 意味）、見た目も性能も一致済み。動機が無い（UI-109） |
| 要素モデル（即時 vs 保持） | `UiTree` が描画に使われていないので問いが成立しない |
| `inspector.rs` | 開発ビルド専用。Accessibility Inspector と XCUITest で足りる |
| `profiler.rs` | executor のタスク統計。対象タスクが 1 件のみ。利用者が増えてから |
| `screen_capture.rs` | collab（共同編集）機能の部品。その機能自体が無い |

### UI-111（AppKit chrome）の下流（6 件）

`arena` / `bounds_tree` / `pasteboard` の画像・ファイル / `svg_renderer` /
`asset_cache` / `scene` プリミティブ体系。

**棚卸しで「独立した欠落」と数えたが、実は 1 つの構造差に集約された。**
Zed の AppKit ビューは信号機ボタン 3 つのみで、他は全て Metal。Nimculus は
42 のビュークラスで chrome を描く。詳細と着手順序は DESIGN_DECISIONS UI-111。

### 受容した差分

フォントのフォールバック（`UI_PARITY_HANDOFF.md` §5.1）。Menlo に無いグリフは
AppleColorEmoji へフォールバックするため、Zed が Lilex で白黒描画する文字
（`❌` U+274C など）が色付きになる。判定ロジックは Zed と一致している。

### この棚卸し自体の限界

- **grep で並べた項目は依存関係を持たない。** 6 件が「他の項目の下流」だったが、
  個別に調べるまで従属が見えなかった
- **「Zed に無いものを持っている」側は見つけられない。**
  `textContainsColorEmoji`、`fontRunsForLine` の sort/unique、
  文字コードでの絵文字判定は、いずれも**実測とキャプチャ比較**で見つかった
- **回帰は載らない。** カラー絵文字が描かれなくなっていた件は、
  codex が自己申告していたのに棚卸しへ記録されず、`PolychromeSprite` の
  設計調査中に再発見した

## 進め方

- **「未確認」を「無い」と読まない。** 対応物が別名で存在する場合がある
  （テキスト移植では、旧実装が改名されて残っていた事例もある）。
- 1 件ずつ、Zed 側のモジュールを読み、Nimculus のどこが同じ役割を負っているかを
  確認して、この表の状態を埋める。埋まっていない行は「未調査」であって
  「問題なし」ではない。
- 移植漏れと確定したものは `DESIGN_DECISIONS.md` に記録してから着手する。
- 着手の順序は、実測で効くもの・他の作業の前提になるものを優先する。
  Accessibility はテスト自動化全体の前提なので最優先。

## 実測で埋めた項目（2026-08-09）

スクロール応答を Zed と同等にするまでに移植した項目。すべて VM 内の実測で確認した。

| 移植項目 | Zed の参照箇所 | 効果（実測） |
| --- | --- | --- |
| `LineLayoutCache` + 旧 CoreText 文書組版の削除 | `text_system/line_layout.rs` | 構造は入ったが旧経路が並走し改善なし |
| `MonochromeSprite` インスタンス描画 | `scene.rs:677`、`gpui_macos/src/metal_renderer.rs:1325`、`shaders.metal:66` | ホスト 20.25 → 17.00 ms/scroll |
| `RenderGlyphParams` をアトラスキーに | `text_system.rs:1023`、`platform.rs:1148` | 回帰なし（文字列キー生成を除去） |
| **subpixel `SUBPIXEL_VARIANTS_Y = 1`** | `text_system.rs:45` | VM 61 → 54.5。縦を量子化していたため縦スクロールで全グリフが毎フレーム再ラスタライズされていた |
| `HashedCacheKey` / `shape_line_by_hash` | `line_layout.rs:843`、`text_system.rs:448` | 同上（ヒット時に本文を比較・確保しない） |
| アトラスのヒット経路を値ベース化 | `text_system.rs:1023`、`platform.rs:964` | 該当記号は消えたが合計時間は不変 |
| `from_chunks` 相当への簡約（sort/unique/再走査の削除） | `editor/src/element.rs:7045` | 同上 |
| **ホイール経路から UI ツリー再構築を除去** | `editor/src/element/mouse.rs:482-570` | 入力経路が 654 サンプル対 drawFrame 73。ここが主因だった |
| ホイール delta の式（`/24` 正規化の削除、`scroll_sensitivity`） | `gpui_macos/src/events.rs:267`、`mouse.rs:543` | Zed に無い正規化の除去 |
| Accessibility（AccessKit 3 層） | `element.rs:112`、`window/a11y.rs`、`gpui_macos/src/window.rs:535` | XCUITest が identifier で操作可能に |

**教訓**: プロファイルの上位だけを追うと外す。`atlasEntryForGlyph` が drawFrame の
92% を占めていたので 3 回続けて最適化したが、**drawFrame 自体が 73 サンプル**で、
入力経路の 654 サンプルのほうが桁違いに大きかった。呼び出し木の**絶対値**を見ること。
