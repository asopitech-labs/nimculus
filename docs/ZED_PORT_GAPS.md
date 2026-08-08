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
| `bounds_tree.rs` | 無し | **移植漏れ（2026-08-09 確認）**。Zed は `scene.rs:43` で `primitive_bounds: BoundsTree<ScaledPixels>` として使い、プリミティブの重なり順を R-tree で解決する。こちらは `ui_tree.nim:134` の `hitTest` が全ノードを逆順に線形走査するのみで、描画側に相当物が無い |
| `tab_stop.rs` | `commands.nim:133` `focusNext` | **部分移植（2026-08-09 確認）**。Zed は `TabStopMap`（SumTree）で `tab_index` 順に巡回し、`window.rs:349` の `tab_stop` フラグで参加を制御する。こちらは毎回 `focusables` を線形に組み直し、**tab index による順序指定が無い**（宣言順のみ） |
| `key_dispatch.rs` / `keymap/` | `src/nimnui/commands.nim` | **部分移植（2026-08-09 確認）**。Zed は `DispatchTree` が `context_stack: Vec<KeyContext>`（key_dispatch.rs:73,127）を持ち、フォーカス位置に応じて同じキーを別アクションへ振り分ける。こちらは `CommandRegistry` が `Shortcut` → `Command` の**単一の平坦な表**で、コンテキストの概念が無い |
| `path_builder.rs` | 無し | **移植漏れ（2026-08-09 確認）**。Zed は `Primitive::Path`（scene.rs:111,893）を描画プリミティブとして持ち、lyon でパスを組む。`render.nim` の `PaintKind` は rectangle / border / roundedRectangle / text / image / clip / transform / shadow / caret / selection / scrollbar 等で、**任意パスが無い** |
| `svg_renderer.rs` | `macos_platform.m:4587`（`NSImage initWithData:`） | **方式が違う（2026-08-09 確認）**。Zed は `SvgRenderer` を `App` が保持し（app.rs:203,727）、`AssetSource` から SVG を読んでラスタライズしアトラスへ載せる。こちらは AppKit の `NSImage` に丸投げで、framework 層に相当物が無い |
| `gestures.rs` | 無し | **移植漏れ（2026-08-09 確認）**。Zed は `TouchEvent` からジェスチャを認識する語彙を framework に持つ。こちらの `gesture` という語はコメント中の用法のみで、ピンチ・回転・スワイプの認識が無い。macOS のトラックパッド操作に関わる |
| `asset_cache.rs` | 無し | **移植漏れ（2026-08-09 確認）**。Zed は非同期に解決したアセットをキャッシュする。こちらにアセットの概念自体が無い（アイコンは AppKit の SF Symbols / NSImage 直結） |
| `arena.rs` | 無し | **移植漏れ（2026-08-09 確認）**。Zed は `window.rs:273` で `ELEMENT_ARENA: RefCell<Arena>`（1MB）をフレームごとの要素確保に使う。こちらは Nim の GC 任せ。スクロールのプロファイルに malloc/free が出ていたので、実測で効く可能性がある |
| `executor.rs` / `platform_scheduler.rs` / `queue.rs` | 見当たらない | **未確認**。非同期実行基盤 |
| `inspector.rs` | 見当たらない（`macos_platform.m` の言及は別物） | **未確認**。UI デバッグ用インスペクタ |
| `style.rs` / `styled.rs` / `color.rs` / `colors.rs` | `src/nimculus/settings.nim` のテーマ表 | **未確認** |
| `element.rs` / `view.rs` / `interactive.rs` | `src/nimnui/ui_tree.nim` / `controls.nim` / `events.nim` | **未確認** |
| `profiler.rs` | 見当たらない | **未確認** |

## gpui_macos（platform）

| Zed モジュール | Nimculus の対応 | 状態 |
| --- | --- | --- |
| `metal_renderer.rs` | `macos_platform.m` | 部分移植（インスタンス描画は入れた） |
| `metal_atlas.rs` | `macos_platform.m` のグリフアトラス | 部分移植（キーは `RenderGlyphParams` 相当へ移植済み） |
| `text_system.rs` | `macos_platform.m` の 1 行シェープ契約 | 移植済み |
| `window.rs`（a11y adapter を含む） | `macos_platform.m` | a11y 部分は**移植漏れ確定** |
| `display_link.rs` | `macos_platform.m`（DisplayLink 経路あり） | **未確認** |
| `open_type.rs` | 見当たらない | **未確認**。フォントフィーチャ |
| `pasteboard.rs` | `macos_platform.m`（クリップボード契約あり） | **未確認** |
| `screen_capture.rs` | 見当たらない | **未確認** |
| `dispatcher.rs` | 見当たらない | **未確認** |
| `keyboard.rs` / `events.rs` | `macos_platform.m` | **未確認** |
| `window_appearance.rs` | `macos_platform.m` のテーマ経路 | **未確認** |
| `display.rs` | `macos_platform.m` | **未確認** |

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
