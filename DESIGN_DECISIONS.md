# Design Decisions

## UI-111: 最大の構造差 — chrome を AppKit で描いていること

対応マイルストーンは ROADMAP.md 全体に関わる。
**この項目は着手の可否を判断するための調査記録であり、実装指示は出さない。**
これまでの調査で「他の項目の上流」として繰り返し現れたものの正体。

### 事実

**Zed は UI を GPUI/Metal で全部描く。** `crates/gpui_macos/src/window.rs:483` の
`TrafficLightButtons { close, minimize, zoom }` が唯一の AppKit ビューで、
これはウィンドウの信号機ボタン、つまり **OS が提供するウィンドウ装飾**である。
タブバーもツールバーもサイドバーもコマンドパレットも、すべてシーンに描かれる。

**Nimculus は chrome を AppKit ビューで描く。** `macos_platform.m`（16,950 行）に
42 個の `Nimculus*` ビュークラスがある:

```
NimculusTabBarOverlay        NimculusWorkspaceToolbar     NimculusFooterOverlay
NimculusStatusOverlay        NimculusSidebarHeader        NimculusCommandPaletteOverlay
NimculusDocumentSearchOverlay NimculusOutlineOverlay      NimculusSettingsOverlay
NimculusTerminalOverlay      NimculusWelcomeOverlay       NimculusGitCommitOverlay
NimculusLineNumberOverlay    NimculusIndentGuideOverlay   NimculusPickerListView
（ほか）
```

Metal で描いているのは**エディタ本文のグリフと矩形だけ**。

### これが上流にある項目

調査の過程で「単独では移植できない」と判定した項目のうち、次はこの差の下流:

| 項目 | 記録 |
| --- | --- |
| `svg_renderer.rs` | アイコンが `NSButton` の `NSImage` なので、SVG を描く先が無い |
| `asset_cache.rs` | キャッシュする対象がシーンに載っていない |
| `scene.rs` のプリミティブ体系 | chrome が AppKit なので、`Quad` / `Shadow` / `Underline` の描き先が本文しかない |
| `bounds_tree.rs` | 上記の帰結（バッチ化する対象が少ない） |
| `taffy.rs` の完全移植 | chrome のレイアウトは AppKit の制約系が持っている |
| 要素モデル（即時 vs 保持） | chrome が AppKit である限り、要素ツリーの対象はエディタ本文に限られる |

**「Zed にあるのに移植していない」と数えた項目の多くが、実はこの 1 点に集約される。**

### この差は記録されていなかった

`DESIGN_DECISIONS.md` に AppKit chrome を選んだ判断の記録は無い。
`ARCHITECTURE.md` も「NimNUI text, selection, cursor, status and native AppKit
services」と書くにとどまり、**chrome 全体が AppKit ビューであることを述べていない**。
明示的な設計判断ではなく、実装の積み重ねでそうなったと見られる。

### 現状の評価

**見た目は既に Zed と一致している。** UI パリティの実測（`tools/bitdiff.sh` の
overall identical 73.59%、帯ごとの比較、`tools/ui_test.sh` のキャプチャ）で
確認済みで、AppKit で描いていることが見た目の差として現れてはいない。

**性能も一致している。** スクロールは移動量あたり Zed と同等
（Nimculus 17.969 / Zed 18.125 ms per 100px）。

つまり**この差は現時点で実害として観測されていない**。実害は「Zed にある機能を
移植しようとすると、描く先が無い」という形で現れる。

### 移植した場合の規模

42 のビュークラスすべてを Metal のシーンへ移すことになる。加えて:

- テキスト入力（`NSTextField` / `NSSearchField` を使っている箇所）を
  自前で描き、IME を通す必要がある。IME は `NSTextInputClient` として
  `NimculusMetalView` に既にあるが、**フィールドごとの入力状態管理**は AppKit 任せ
- スクロールビュー、テーブル、ピッカーの挙動を自前で持つ
- Accessibility は今回 NimNUI 側に移植済みなので、そこは活きる

**これはリライトに近い規模**であり、「移植漏れを 1 件潰す」作業ではない。

### 判断

**着手しない。記録にとどめる。**

理由:

1. 見た目・性能とも現時点で Zed と一致しており、**実測上の動機が無い**
2. 規模がリライトに近く、`nimculus-ui-design` の「最小縦切り」に反する
3. 下流の項目（SVG / アセット / シーンのプリミティブ）は、**それぞれが必要に
   なった時点で**個別に判断できる。例えばアイコンを Metal で描く必要が出たら、
   その時に chrome 全体ではなくアイコンだけを移せばよい

**ただし「移植漏れではない」とは言わない。** Zed との構造差として実在し、
下流の項目を塞いでいる。この記録は、次に誰かが `svg_renderer` を見て
「なぜ移植しないのか」と考えたときの答えである。

### 着手する場合の順序（将来の参考）

1. アイコン（`NSButton` の `NSImage`）を Metal のスプライトへ。`PolychromeSprite`
   と `svg_renderer` がここで要る
2. 静的な chrome（タブバー・ツールバー・フッターの背景と罫線）を `Quad` へ
3. テキスト入力を含むもの（検索・コマンドパレット・設定）を最後に。IME の
   扱いが最も難しい

## UI-110: PolychromeSprite を入れて、まずカラー絵文字を描く

対応マイルストーンは ROADMAP.md の M3（macOS テキスト描画と IME）。
完了条件は、カラー絵文字が本文に描かれること、キャプチャで確認できること。

### Zed の構造

`crates/gpui/src/scene.rs:715` `PolychromeSprite`:

```rust
pub struct PolychromeSprite {
    pub order: DrawOrder, pub pad: u32,
    pub grayscale: PaddedBool32, pub opacity: f32,
    pub bounds: Bounds<ScaledPixels>,
    pub content_mask: ContentMask<ScaledPixels>,
    pub corner_radii: Corners<ScaledPixels>,
    pub tile: AtlasTile,
}
```

描画は `crates/gpui_macos/src/metal_renderer.rs:1396` `draw_polychrome_sprites`、
シェーダは `shaders.metal:688` `polychrome_sprite_vertex` / `:711` の fragment。
`MonochromeSprite`（グリフ）と同じインスタンス描画で、**テクスチャがカラー**である点が違う。

アトラスの振り分けは `crates/gpui/src/platform.rs:1163` `texture_kind()`:

| キー | テクスチャ種別 |
| --- | --- |
| `AtlasKey::Glyph` で `is_emoji` | **`Polychrome`** |
| `AtlasKey::Glyph` で `subpixel_rendering` | `Subpixel` |
| `AtlasKey::Glyph`（通常） | `Monochrome` |
| `AtlasKey::Svg` | `Monochrome` |
| `AtlasKey::Image` | `Polychrome` |

**カラー絵文字は画像と同じ Polychrome アトラスに入る。**

### 現状の Nimculus

グリフアトラスは `MTLPixelFormatR8Unorm`（単色）1 枚だけ
（`macos_platform.m:3375`, `:11019`）。そして
**`macos_platform.m:3840` の `if (colorEmojiGlyph) continue;` で
カラー絵文字が描画から落ちている。**

これはテキスト移植の際に「新経路が emoji glyph をスキップしている」として
自己申告されていた残件で、`ZED_PORT_GAPS.md` には記録されていなかった。

ROADMAP の M3 完了条件には「日本語、英語、記号、絵文字をGPU上で混在表示できる」
とあり、以前は Core Text の RGBA テクスチャ経路で満たしていた。その経路を
インスタンス描画への移植で外したまま、代替を入れていない。**回帰である。**

### 移植する範囲

1. **カラーのアトラステクスチャを持つ**（`MTLPixelFormatBGRA8Unorm`）。
   既存の単色アトラス（R8）と 2 枚立てにする。Zed の `AtlasTextureKind` と同じ区別。
2. **`PolychromeSprite` 相当**を足す。既存の `NimculusMonochromeSprite` の隣。
   フィールドは Zed の `PolychromeSprite` に合わせる（`grayscale` / `opacity` /
   `corner_radii` / `tile`）。
3. **振り分け**を `texture_kind()` と同じ形にする。`is_emoji` なら Polychrome へ。
4. `macos_platform.m:3840` の `continue` を外し、カラー絵文字を Polychrome 経路へ流す。
5. シェーダを足す。`shaders.metal:688,711` の polychrome 版に対応するもの。
   既存のグリフシェーダ（単色 + 頂点色）とは別に、**テクスチャの色をそのまま使う**。

### 却下案

**(a) Core Text の RGBA テクスチャ経路を復活させる。** 移植前の実装がこれだったが、
テキスト移植で消したもの。文書全体を CPU でラスタライズする方式に戻ることになる。却下。

**(b) 絵文字を単色で描く。** 見た目が違う。却下。

**(c) `PolychromeSprite` を汎用の画像描画として先に作り、絵文字は後。**
利用者のいない基盤を先に作ることになる。絵文字は**既に回帰している**ので、
それを最初の利用者にするのが最小縦切り。却下。

### 文字単位・スレッド・UI ブロッキング

絵文字は複数コードポイント（ZWJ 連結・キーキャップ）を含む。既存の
`colorEmojiAtUTF16Index`（`macos_platform.m:3178`）が UTF-16 位置で判定しており、
そこは変えない。ラスタライズはミス時のみ、フレーム内で完結する。

### テスト観点

- unit: `is_emoji` のグリフが Polychrome アトラスへ振り分けられること
- キャプチャ: **絵文字を含む文書を表示し、色付きで描かれていること**。
  現状は描かれていないので、キャプチャの差で確認できる
- 通常のグリフが従来どおり単色アトラスで描かれること（回帰）

## UI-109: Zed の Primitive は「形」で、Nimculus の PaintKind は「意味」で分かれている

対応マイルストーンは ROADMAP.md の M2（NimNUI 基礎 UI システム）／M20。
**この項目は着手の可否を判断するための調査記録であり、実装はまだ始めない。**

### Zed の構造

`crates/gpui/src/scene.rs:222` `Primitive` は 8 種:

| 種別 | 定義 | 主なフィールド |
| --- | --- | --- |
| `Quad` | :501 | `background` / `border_color` / `corner_radii` / `border_widths` / `border_style` |
| `Underline` | :521 | `color` / `thickness` / `wavy` |
| `Shadow` | :540 | `blur_radius` / `corner_radii` / `element_bounds` / `inset` |
| `MonochromeSprite` | :677 | `color` / `tile` / `transformation`（**移植済み** = グリフ） |
| `SubpixelSprite` | — | サブピクセル描画のグリフ |
| `PolychromeSprite` | :715 | `grayscale` / `opacity` / `corner_radii` / `tile`（カラー画像） |
| `PaintSurface` | :734 | 動画などの外部サーフェス |
| `Path` | :755 | 三角形分割済みの頂点列 |

**分類の軸は「形」**である。どれも `order` と `content_mask` を持ち、
種別ごとにバッチ描画される（`batches()` :172）。

### 現状の Nimculus

`src/nimnui/render.nim:4` の `PaintKind` は 19 種:

```
rectangle, border, roundedRectangle, text, image, clip, transform,
shadow, caret, selection, scrollbar,
workspaceBackground, workspacePanel, workspaceSeparator,
editorActiveLine, editorBackground, scrollbarTrack, editorDiagnostic,
roundedSelection
```

**分類の軸が違う。** `workspaceBackground` / `editorActiveLine` /
`scrollbarTrack` / `editorDiagnostic` は**用途**で分かれており、形としては
どれも矩形である。コメントにも「Metal バックエンドが固定色ではなく
アクティブなテーマを使えるように、意味づけされた paint kind を持つ」とある。

Metal 側の分岐は 18 箇所（`grep -c "paint.kind =="`）。

### これは移植漏れか

**単純な移植漏れではない。** Zed は色を `Quad.background` に値として持たせ、
テーマの解決を呼び出し側で行う。Nimculus は種別に意味を持たせ、
テーマの解決を Metal 側で行う。**どちらも動いており、見た目は既に一致している**
（UI パリティの実測で確認済み）。

移植の利得は次の 2 点に限られる:

1. **種別バッチ描画が可能になる**（現状は投入順に 1 つずつ描画）。
   ただし現在スクロールは Zed と同等の性能が出ており、
   プロファイル上 `drawPaintCommand` は上位に出ない。**実測上の動機が無い**
2. **`PolychromeSprite` が入ると画像が描ける**。これは `pasteboard` の画像貼り付けと
   `asset_cache` / `svg_renderer` の前提になる（UI-109 時点で 3 項目が待っている）

### 判断

**(2) だけを目的に、`PolychromeSprite` 相当を足す。** 形の体系への全面的な
置き換えはしない。

理由:

- 全面置換は 19 種の `PaintKind` と 18 箇所の Metal 分岐を作り替える大工事で、
  **見た目も性能も現状で Zed と一致している**ところに手を入れることになる
- 実測上の動機（性能）が無い。`bounds_tree` が必要になるのは種別バッチ化を
  したときで、それ自体が目的化している
- 一方 `PolychromeSprite` は**3 項目が待っている**具体的な前提であり、
  既存の `MonochromeSprite`（グリフ）の隣に足すだけで済む

### 却下案

**(a) `Primitive` の 8 種すべてに置き換える。** 上記のとおり動機が無く、
リスクだけが大きい。`nimculus-ui-design` の「最小縦切り」にも反する。却下。

**(b) 何もしない。** `pasteboard` の画像・`asset_cache` / `svg_renderer` が
永久に着手できない。却下。

**(c) `bounds_tree` を先に入れる。** バッチ化しない限り仕事が無い
（ZED_PORT_GAPS.md に記録済み）。却下。

### 次にやること

`PolychromeSprite` 相当（カラー画像のアトラス描画）を移植する。それが入った後、
`asset_cache` → `svg_renderer` → `pasteboard` の画像、の順に解ける。

## UI-108: Tab-order focus traversal, and the fact that Tab is not bound to it

対応マイルストーンは ROADMAP.md の M2（NimNUI 基礎 UI システム）／M12。
完了条件は、フォーカス巡回が宣言順ではなく tab index 順になること、
`tab_stop` に参加しない要素が飛ばされること、unit テストで検証されていること。

### Zed の構造

`crates/gpui/src/tab_stop.rs:11` `TabStopMap`。要素は
`window.rs:348,387` の `tab_index: isize` と `tab_stop: bool` を持つ。

- `insert`（tab_stop.rs:78）は `current_path` に `tab_index` を積んだ**経路**を鍵にして
  `order`（SumTree）へ入れる
- `begin_group`（:92）で入れ子のグループを開き、経路が深くなる
- `next` / `prev`（:111, :148）は経路の順序で次を探し、`tab_stop` が false の
  要素は飛ばして `next_inner` を辿る

つまり**順序は宣言順ではなく、(グループ, tab_index) の経路の辞書順**である。

### 現状の Nimculus

`src/nimnui/commands.nim:161` `focusNext`:

```nim
var focusables: seq[NodeId]
for node in tree.nodes:
  if node.focusable and not tree.isDisabledPath(node.id): focusables.add(node.id)
```

- 毎回 `focusables` を線形に組み直す
- **順序は `tree.nodes` の宣言順のみ**。tab index が無い
- `tab_stop` に相当する「フォーカス可能だが Tab では飛ばす」の区別が無い
  （`focusable` の 1 値だけ）
- `focusPrev` が無い（Shift+Tab に相当するものが無い）

### 着手前に確認したこと: Tab キーは束縛されていない

`grep -rn "focusNext" src/ tests/` の結果、**呼び出しは unit テストの 3 箇所のみ**。
アプリのキー経路から呼ばれていない。`commands.nim:107` に `"tab": 48` の
キーコード変換はあるが、束縛が無い。

Zed 側では `assets/keymaps/default-macos.json` で `"tab"` は
`menu::SelectNext` / `editor::Tab` / `buffer_search::FocusEditor` などに
**コンテキストごとに別のコマンド**として束縛されている。汎用の
「次のフォーカスへ」ではない。

### 採用案

**(1) `TabStopMap` 相当を移植し、(2) Tab の束縛は今回入れない。**

理由: Zed の Tab は文脈依存のコマンド（エディタでは字下げ、メニューでは次項目）で、
**汎用のフォーカス巡回に直接束縛されてはいない**。束縛を決めるには、
どのコンテキストで何をするかという設計が別途要る。UI-107 で `when` が
効くようになったので、その土台の上で改めて決める。

今回は巡回の仕組みだけを Zed の形にする:

- `UiNode` に `tabIndex: int` と `tabStop: bool` を足す
- 経路（グループ + tab index）で順序を決める
- `focusNext` / `focusPrev` を経路順で実装し、`tabStop` が false の要素を飛ばす

### 却下案

**(a) Tab キーを `focusNext` に束縛する。** Zed はそうしていない。エディタで
Tab を押したら字下げが入るべきで、フォーカスが飛ぶのは誤り。却下。

**(b) `focusable` を流用して `tab_stop` を作らない。** Zed は 2 つの値を分けている
（クリックでフォーカスできるが Tab では飛ばす要素がある）。却下。

### 文字単位・スレッド・UI ブロッキング

文字を扱わない。巡回はキー入力時のみ。

### テスト観点

- unit: tab index 順に巡回すること（宣言順と異なる並びで検証）
- グループの入れ子で経路の辞書順になること
- `tabStop` が false の要素が飛ばされること
- `focusPrev` が逆順に辿ること
- **既存の `focusNext` のテスト 3 件が通ること（回帰）**

## UI-107: Context-dependent key dispatch, and the `when` clause already being parsed

対応マイルストーンは ROADMAP.md の M12（設定・テーマ・キーバインド）。
完了条件は、同じキーがフォーカス位置に応じて別のコマンドへ解決されること、
`keymap` の `when` が実際に効くこと、unit テストで検証されていること。

### Zed の構造

`crates/gpui/src/keymap/context.rs:10` `KeyContext(Vec<ContextEntry>)`。
`new_with_defaults` は `os` などの既定エントリを入れる。

`crates/gpui/src/key_dispatch.rs:73,127` の `DispatchTree` が
`context_stack: Vec<KeyContext>` を持ち、`:448` `bindings_for_input` が
**フォーカスからルートまでの dispatch path のノードのコンテキストを集めて**
スタックを作り、`:483` `dispatch_key` がそれで束縛を絞る。

キーマップ側の指定は `assets/keymaps/default-macos.json` にあり、
実際に使われている:

```json
{ "context": "menu" }
{ "context": "Editor" }
{ "context": "Editor && mode == full" }
{ "context": "Editor && multibuffer" }
{ "context": "Editor && mode == full && edit_prediction" }
```

`&&` と `==` を含む式である。

### 現状の Nimculus

**設定は受け付けているが、捨てている。**

- `settings.nim:305` のスキーマに `"when": {"type": "string"}` がある
- `settings.nim:676` が `whenClause` として読み取る
- しかし `whenClause` の参照は**この 2 箇所だけ**（`grep -rn "whenClause"`）
- `nimnui/commands.nim:12` の `Command` は `name` / `shortcut` / `action` のみ
- `resolve` / `tryResolve`（同 :39, :45）は keyCode と modifiers だけで照合する

つまり `when` を書いても効かない。**設定として露出しているのに動作しないのは、
移植漏れの中でも質が悪い**（利用者は効くと思って書く）。

### 移植する範囲

1. `Command` に context 条件を持たせる（`when` の式）。
2. **コンテキストのスタック**を持つ。Zed の `DispatchTree` はフォーカスから
   ルートまでのノードのコンテキストを集める。こちらは `UiTree` に
   フォーカスと親子関係があるので、同じ形にできる。
3. `resolve` / `tryResolve` を、キー一致に加えて**コンテキスト式の評価**で
   絞るようにする。
4. 式の構文は Zed に合わせる。`keymap/context.rs:172` の
   `KeyBindingContextPredicate` を読んで確認した全 7 種:

   | 種別 | 構文 | 意味 |
   | --- | --- | --- |
   | `Identifier` | `Editor` | その識別子がコンテキストにある |
   | `Equal` | `mode == full` | キーと値が一致 |
   | `NotEqual` | `mode != full` | 一致しない |
   | `And` | `a && b` | 両方 |
   | `Or` | `a \|\| b` | どちらか |
   | `Not` | `!a` / `!(expr)` | 否定 |
   | `Descendant` | `a > b` | **要素ツリー上で a の下に b がある** |

   `Descendant`（`:181`、表示は `:205` の `"{parent} > {child}"`）は
   コンテキストスタックの親子関係を見るもので、単純な述語ではない。
   これを含めて 7 種すべて実装する。**独自の演算子を足さないこと。**

### 却下案

**(a) `when` を単純な文字列一致にする。** `"Editor && mode == full"` のような
式が Zed の既定キーマップに実在するので、一致では表現できない。却下。

**(b) `when` をスキーマから外す。** 設定として既に露出しており、外すと
後方互換が壊れる。効かせるほうが正しい。却下。

### 文字単位・スレッド・UI ブロッキング

文字を扱わない。キー入力ごとに式を評価するので、**評価はキー 1 回あたり
数個の比較に収まること**。Zed も同じ経路で毎キー評価している。

### テスト観点

- unit: 同じキーが、フォーカス位置の違いで別のコマンドに解決されること
- `&&` と `==` を含む式が正しく評価されること
- コンテキストが一致しないときは束縛が無視され、より外側の束縛が使われること
- **`when` を持たない既存の束縛が従来どおり効くこと（回帰）**

## UI-106: Font features and fallbacks as CTFont attributes

対応マイルストーンは ROADMAP.md の M3（macOS テキスト描画と IME）／M12（設定）。
完了条件は、`buffer_font_features` / `buffer_font_fallbacks` に相当する設定が
CTFont の属性として反映され、unit テストで検証されていること。

### Zed の構造

`references/zed/crates/gpui_macos/src/open_type.rs:34`
`apply_features_and_fallbacks(font, features, fallbacks)` が CTFont に 2 つの
属性を設定する:

| 属性 | 設定キー | Zed の既定 |
| --- | --- | --- |
| `kCTFontFeatureSettingsAttribute` | `buffer_font_features` | `{}`（`"calt": false` は例としてコメントアウト） |
| `kCTFontCascadeListAttribute` | `buffer_font_fallbacks` | `null`（プラットフォーム既定とマージされる） |

呼び出しは `crates/gpui_macos/src/text_system.rs:293`。

### 現状の Nimculus

`macos_platform.m:2664` の `editorFont` が
`CTFontCreateWithName(name, size, NULL)` で**属性なし**にフォントを作る。
どちらの設定も存在しない（`settings.nim:224` の `editor` は fontSize /
fontFamily / tabSize / insertSpaces のみ）。

### 優先度の位置づけ

**既定状態では画面に出ない。** Zed の既定が features `{}` / fallbacks `null` なので、
素の Zed と素の Nimculus で描画は変わらない。UI パリティには影響せず、
効くのはユーザが設定を書いたときだけ。角丸選択（既定で差が見えた）とは
性質が違う。

それでも実装するのは、**コストが小さく既存経路に載る**ため。CTFont の生成箇所は
`editorFont` に集約されており、設定は `editor.*` に足すだけで済む。

### 採用案

1. 設定に `editor.fontFeatures`（オブジェクト、キーは 4 文字のフィーチャタグ、
   値は真偽）と `editor.fontFallbacks`（文字列配列）を足す。
   **Zed のキー名（`buffer_font_features` / `buffer_font_fallbacks`）ではなく
   既存の `editor.*` 名前空間に合わせる** — このリポジトリの設定は
   `editor.fontSize` / `editor.fontFamily` という形で既に Zed とキー名が違う。
   ここだけ Zed のキー名にすると一貫性が壊れる。
2. platform 契約に渡し、`editorFont` で `CTFontDescriptorCreateWithAttributes` を
   使って `kCTFontFeatureSettingsAttribute` と `kCTFontCascadeListAttribute` を
   設定する。Zed の `open_type.rs` の属性の組み立て方に合わせる。
3. **フォントキャッシュのキーに features と fallbacks を含める。**
   現状 `editorFont` は名前とサイズだけでキャッシュしており、設定変更が
   反映されなくなる。

### 却下案

**(a) Zed のキー名をそのまま使う。** `buffer_font_features` を足すと、
`editor.fontSize` などと名前空間が混在する。既存の設定と揃えるほうが一貫する。却下。

**(b) 既定では画面に出ないので実装しない。** 実装コストが小さく既存経路に
載るので、見送る理由が弱い。ただし優先度は低いものとして扱い、
これより先に `key_dispatch` の `KeyContext` を片付ける。**今回は実装する。**

### 文字単位・スレッド・UI ブロッキング

フィーチャタグは 4 文字の ASCII。フォント生成はフレーム内で完結し、
キャッシュがあるので設定変更時のみ再構築される。

### テスト観点

- unit: 設定のパースと platform 契約への受け渡し、フォントキャッシュのキーに
  features / fallbacks が含まれること（設定を変えると再構築されること）
- 既定（features 空・fallbacks 空）で従来と同じフォントが得られること（回帰）

## UI-105: Rounded selection first, as a shaped primitive rather than a path engine

対応マイルストーンは ROADMAP.md の M5（macOS 最小実用エディタ）／UI パリティ。
完了条件は、選択範囲が Zed の既定（`rounded_selection: true`）と同じ見え方に
なり、`tools/bitdiff.sh` 相当のキャプチャ比較で選択帯の差が縮むこと。

### 何が足りないか

Zed は選択範囲を `PathBuilder`（`crates/gpui/src/path_builder.rs:25`）で組み、
`Primitive::Path`（`scene.rs:111,893`）として描く。角丸は
`editor/src/element.rs:10519` の `PathBuilder::fill()` と `curve_to`。
`rounded_selection` は `editor_settings.rs:24`、`assets/settings/default.json:310`
で **既定 `true`**。素の Zed の選択範囲は角丸である。

Nimculus は `PaintKind.selection`（render.nim:6）で矩形を描く。

**行ごとの角丸矩形では再現できない。** Zed は「連続する行がなす領域の外周」を
1 本のパスとして丸めるので、行の幅が変わる箇所の**内側の角**も丸まる。

### 依存の調査（2026-08-09）

Zed は lyon（Rust の 2D パス三角形分割ライブラリ）に委譲している。
Nim の等価物を `nimble search` で探した:

- `tessellation` / `triangulate` / `lyon` — **該当なし**
- `bezier` — ベジエ曲線のツールのみ。三角形分割は無い
- `pixie` — フル機能の 2D グラフィックスライブラリ（paths / stroke / fill /
  svg / font）。**ただし CPU ラスタライザ**で、Metal の頂点を作るものではない

**Metal でパスを塗るための三角形分割器は Nim に無い。**

### 採用案: 選択範囲に限定した形状プリミティブ

汎用のパスエンジンを作らず、**`PaintKind` に「角丸の複数行選択」を足す**。
入力は行ごとの矩形の並びで、外周の角を丸めた形状を描く。

理由:

1. **今この形が必要な唯一の用途が選択範囲**である。Zed の他 2 用途（破線 divider、
   circular progress）に対応する UI が Nimculus に無い
2. `nimculus-ui-design` の「抽象 API を先に広げない」に従う
3. 三角形分割器が無いので、汎用パスは分割器の自作から始まる。**使う当てのない
   基盤を先に作ることになる**

実装は Metal 側で角丸を扱えばよい。既に `roundedRectangle` の描画があり
（render.nim:5、macos_platform.m）、角の丸めは同じ手法で足せる。
外周の内側の角（行幅が変わる箇所）の扱いを Zed の `curve_to` と合わせること。

### 却下案

**(a) `PathBuilder` + `Primitive::Path` を汎用に移植する。** 三角形分割器が
Nim に無く、自作するか `pixie` を CPU ラスタライザとして挟むことになる。
前者は使う当てのない基盤、後者は GPU 経路から外れる。**用途が増えた時点で
再検討する。** 今は却下。

**(b) `pixie` を依存に追加する。** CPU ラスタライザなので、グリフをアトラス化して
GPU で描いている現在の経路と噛み合わない。SVG アイコンのラスタライズ
（`svg_renderer.rs` の行）で再検討の余地はあるが、選択範囲には不要。今は却下。

**(c) 行ごとの角丸矩形で近似する。** 内側の角が丸まらず、Zed と見た目が違う。
UI パリティが目的なので却下。

### `scene.rs` のプリミティブ体系との関係

`bounds_tree.rs` の調査で「`scene.rs` のプリミティブ体系を先に移植すべき」と
結論した。本項目はその一部（`Primitive::Path`）に見えるが、**汎用パスではなく
選択範囲という具体的な形状**として入れる。汎用化は用途が 2 つ目になったときに
行う。

### 文字単位・スレッド・UI ブロッキング

文字を扱わない。描画はフレーム内で完結する。

### テスト観点

- unit: 行ごとの矩形列から外周形状が正しく組まれること（行幅が変わる箇所の
  内側の角を含む）
- キャプチャ: 複数行選択のスクリーンショットを Zed と比較し、角の丸みが一致すること

## UI-104: Port Zed's ongoing-scroll axis lock, not its touch gestures

対応マイルストーンは ROADMAP.md の M3（macOS テキスト描画と IME）／M20。
完了条件は、トラックパッドの 2 本指スクロールで軸がロックされ、Zed と同じ
しきい値で解除されること。unit テストで検証されていること。

### `gestures.rs` は macOS では使われていない（棚卸しの記述を訂正）

`references/zed/crates/gpui/src/gestures.rs` が定義するのは
`GestureKinds { tap, long_press, pan, pinch }`（:60）で、**タッチデバイス用**。
`PlatformGestures` トレイト（:107）の macOS 実装は無く、`NullPlatformGestures`
（:121、no-op）のままである。

`docs/ZED_PORT_GAPS.md` に「トラックパッドのピンチ・回転・スワイプ。macOS では
体感に直結」と書いたのは**誤り**。Zed 自身が macOS でピンチ・回転を扱っていない。

### 本命: `TouchPhase` と軸ロック

macOS のトラックパッドは、Zed では**スクロールイベントに付随する情報**として
扱われる。`references/zed/crates/gpui_macos/src/events.rs:236-268` が
`NSEvent.phase` を `TouchPhase`（Started / Ended / Moved）へ変換し、
`ScrollWheelEvent` に載せる。

これを使うのが `references/zed/crates/editor/src/scroll.rs:68` の `OngoingScroll`:

```rust
pub struct OngoingScroll { last_event: Instant, axis: Option<Axis> }

pub fn filter(&self, delta: &mut gpui::Point<Pixels>) -> Option<Axis> {
    const UNLOCK_PERCENT: f32 = 1.9;
    const UNLOCK_LOWER_BOUND: Pixels = px(6.);
    // 前のイベントから SCROLL_EVENT_SEPARATION 以上空いていれば新しいスクロール:
    //   |x| <= |y| なら Vertical、そうでなければ Horizontal に軸を決める
    // 継続中なら、直交方向が UNLOCK_PERCENT 倍を超えたときだけロックを外す
}
```

`element/mouse.rs:539` の `ScrollDelta::Pixels` 分岐が
`position_map.snapshot.ongoing_scroll.filter(&mut pixels)` を呼び、
**トラックパッドのときだけ**軸ロックを適用する（ホイールの `Lines` 分岐は
`axis = None` で素通し）。

### 現状の Nimculus

- `NimculusInputEvent` に `precise_scrolling` はあるが **`phase` が無い**
- 軸ロックが**無い**（`grep -rn "axis\|ongoing"` で該当なし）

そのため、トラックパッドで縦にスクロールする際、指のわずかな横ぶれがそのまま
水平スクロールとして出る。Zed は軸をロックしてこれを抑えている。**体感に直結する
挙動差**であり、`gestures.rs` ではなくこちらが移植すべきものだった。

### 移植する範囲

1. `TouchPhase`（Started / Moved / Ended）を platform の入力イベントに載せる。
   `NSEvent.phase` からの変換は `events.rs:236-268` のとおり。
2. `OngoingScroll` 相当を editor 側に持つ。`filter` の定数（`UNLOCK_PERCENT` 1.9、
   `UNLOCK_LOWER_BOUND` 6px、`SCROLL_EVENT_SEPARATION`）を Zed と同じにする。
3. **精密デルタ（トラックパッド）のときだけ**適用する。ホイールには適用しない
   （`mouse.rs:539` の分岐と同じ）。

`gestures.rs` そのものは**移植しない**。macOS で Zed が使っていないものを
入れる理由がない。タッチデバイス対応が視野に入った時点で再検討する。

### 却下案

**(a) `gestures.rs` を移植する。** macOS 実装が `NullPlatformGestures` である以上、
入れても動く先が無い。棚卸しの誤読から出た案。却下。

**(b) 軸ロックを自前のしきい値で作る。** Zed と体感を揃えるのが目的なので、
定数は Zed と同じにする。独自の値にする理由がない。却下。

### 文字単位・スレッド・UI ブロッキング

文字を扱わない。入力イベント経路に載るのでメインスレッドで完結し、
1 イベントあたりの追加計算は比較 2 回と時刻差分のみ。

### テスト観点

- unit: 新しいスクロール開始時に `|x| <= |y|` で縦、そうでなければ横に軸が決まること。
  継続中に直交方向が 1.9 倍かつ 6px を超えたときだけロックが外れること。
  `SCROLL_EVENT_SEPARATION` を超えたら軸が決め直されること
- 精密デルタでないとき（ホイール）は軸ロックが適用されないこと
- 実測: `tools/ui_test.sh parity` の非回帰

## UI-103: Extend the layout spec toward Zed's Style, without adopting a layout engine

対応マイルストーンは ROADMAP.md の M2（NimNUI 基礎 UI システム）。完了条件は、
Zed が `Style` で表現していて Nimculus に無い項目のうち、**実際に使う UI がある
もの**を `LayoutSpec` に足し、`nimble test` で検証されていること。

### Zed の構造

`crates/gpui/src/taffy.rs:65` の `request_layout(style, rem_size, scale_factor,
children)` は `Style` の値と子 ID を受け取るだけで、要素の生存期間に触れない。
`style.to_taffy()`（同 :445）は `Style` を Taffy のスタイルへ写す純粋な変換で、
レイアウト計算そのものは Taffy（外部クレート）が行う。

**したがってこの項目は要素モデル（即時 vs 保持）に依存しない。**
`arena.rs` と `bounds_tree.rs` は依存したので着手を見送ったが、これは独立して進む。

### 差分

`src/nimnui/layout_types.nim` の `LayoutSpec` は direction / size / minSize /
maxSize / padding / gap / flexGrow / alignment / scrollOffset / viewport。
`src/nimnui/layout.nim`（115 行）が Row / Column / Stack を自前で計算する。

Zed の `Style`（style.rs:182-309）にあって無いもの:

| 項目 | 用途 | 実際に要るか |
| --- | --- | --- |
| `position` + `inset` | 絶対配置 | **要る**。ポップアップ・ツールチップ・オーバーレイ。現状は Stack と viewport で代用している |
| `margin` | 外側の余白 | **要る**。`padding`（内側）だけでは表現できない配置がある |
| `overflow` | クリップとスクロールバー領域 | **要る**。現状は `viewport` で代用 |
| `align_items` / `justify_content` の分離 | 主軸と交差軸の別指定 | **要る**。現状は `alignment` 1 つ |
| `display` / grid / `aspect_ratio` / `flex_shrink` / `flex_basis` | — | **今は要らない**。grid を使う UI が無い |

### 依存追加の調査（2026-08-09）

Zed は Taffy に丸投げしている。Nim に等価物があるかを `nimble search` で調べた:

- `flex` — **該当パッケージ無し**
- `layout` — `cssgrid`（CSS Grid 専用、Flexbox ではない）、`buju`（layout.h ベースの
  簡易エンジン）、`karkas`（Karax 用のヘルパー、無関係）

**Nim に Taffy 相当の Flexbox 実装は存在しない。**

### 採用案

**既存の `layout.nim` を拡張する。** 上表の「要る」4 項目を `LayoutSpec` に足し、
`layoutNodeRecursive` で処理する。Zed の `Style` のフィールド名・意味論に合わせる
（`position` / `inset` / `margin` / `overflow` / `alignItems` / `justifyContent`）。

これは「Zed と違う形」ではない。**Zed が Taffy に委譲している計算を自前で持つ**
という点は既にそうなっており、変わるのは表現できる項目の範囲だけである。
Zed 側の意味論（Flexbox の主軸・交差軸、`position: absolute` は親の content box
基準、`overflow: hidden` はクリップ）に合わせること。

### 却下案

**(a) `buju` を依存に追加する。** layout.h ベースの簡易エンジンで、Flexbox の
`justify_content` / `align_items` の完全な意味論を持たない。既存の `layout.nim` が
既に同等以上を実装しており、置き換える利得が無い。`DEVELOPMENT_GUIDELINES` の
「依存追加は標準ツールで検出できない問題に限定」にも合わない。却下。

**(b) `cssgrid` を依存に追加する。** CSS Grid 専用で Flexbox ではない。
Zed も grid は `Display::Grid` として持つが、Nimculus に grid を使う UI が無い。
grid が必要になった時点で再検討する。今は却下。

**(c) Taffy 相当を新規に自作する（完全な Flexbox エンジン）。** `display` / grid /
`aspect_ratio` / `flex_shrink` / `flex_basis` まで含む完全実装は、使う UI が無い
まま作ることになる。`nimculus-ui-design` の「抽象 API を先に広げない」に反する。
必要な項目を必要になった時点で足す方針を採る。却下。

### 文字単位・スレッド・UI ブロッキング

この作業は文字を扱わない。レイアウトはメインスレッドのフレーム内で完結し、
非同期化しない（Zed も同じ）。

### テスト観点

- unit: 絶対配置が親の content box 基準になること、`margin` が兄弟間の間隔に
  加算されること、`overflow: hidden` が子をクリップすること、
  `justifyContent` と `alignItems` が主軸・交差軸へ独立に効くこと
- 既存の Row / Column / Stack の挙動が変わらないこと（回帰）

## UI-102: Port Zed's async execution on Nim's own Future

対応マイルストーンは ROADMAP.md の M20（性能・安定性強化）。完了条件は、
(1) platform 層が Zed の `PlatformDispatcher` と同じ粒度の契約を持つ、
(2) framework 層に `BackgroundExecutor` / `ForegroundExecutor` 相当が載る、
(3) `newGitRepository` の `git rev-parse` がメインスレッドをブロックしない、
(4) `tools/ui_test.sh parity` / `smoke` が非回帰である、の 4 点。

### なぜこの設計判断を記録するか

一度、調査せずに「Nim には Rust の `Future` が無いので、`Task<R>` は完了時に
呼ばれるコールバックで表現する」と決めて実装指示を出した。**これは誤りだった。**
`lib/pure/asyncfutures.nim` に `Future[T]` があり、`complete` / `fail` /
`callback` / `read` を備え、`asyncdispatch` の `async` / `await` マクロも使える。
実現手段を調べずに代替へ逃げた判断であり、取り消した。

### 実測した実現可能性（2026-08-09）

`--mm:arc --threads:on -d:release` で実際にコンパイルして確かめた。

| 検証 | 結果 |
| --- | --- |
| フレームループから 1 tick ずつ回せるか（`poll(0)`） | **成立**。60Hz 相当のループで 3 フレーム後に `Future` が完了 |
| `poll(0)` はフレームをブロックしないか | **最悪 36µs**。フレーム予算 16ms に対して無視できる |
| 保留が無いときの `poll(0)` は例外を投げるか | **投げない**（`runOnce` は `timeout == 0` なら早期 return）。`hasPendingOperations()` で守る必要すらないが、明示しておく |
| 背景スレッドの結果を `Future` へ渡せるか | **成立**。ワーカーが結果を置き、**Future を所有するスレッドが `complete` する**形で 4 フレーム後に完了 |

### 層の対応

| 層 | Zed | Nimculus |
| --- | --- | --- |
| platform | `crates/gpui/src/platform.rs:917` `PlatformDispatcher`（`is_main_thread` / `dispatch` / `dispatch_on_main_thread` / `dispatch_after`）。macOS 実装は `crates/gpui_macos/src/dispatcher.rs:30-70` で GCD 直結 | `src/nimnui/platform/contracts.h` / `contracts.nim` の C ABI と `macos_platform.m` の GCD 実装。優先度 High / Medium / Low をグローバルキューの優先度へ写す |
| framework | `crates/gpui/src/executor.rs:14,22` `BackgroundExecutor` / `ForegroundExecutor`、`Task<R>` | NimNUI に同名の層を置き、**`Task<R>` は `Future[T]` そのもの**。`await` が使える |
| app | 利用者 | `src/nimculus/git_service.nim` ほか |

### スレッド境界の扱い（Zed との対応が非自明な唯一の点）

Nim の `asyncdispatch` はグローバル dispatcher を `{.threadvar.}`（同 :354）で持つ。
つまり **`Future[T]` は生成したスレッドに属する**。

Zed も同じ区別を型で表現している:

- `BackgroundExecutor::spawn`（executor.rs:89）は `Future + Send` と `R: Send` を要求
- `ForegroundExecutor::spawn`（同 :314）は `Send` を要求せず `boxed_local()` を使う

したがって「Future がスレッドに属する」ことは Nim 固有の制約ではなく、**Zed が
Send 境界で表現しているものと同じ区別**である。Nim では型で強制されないので、
規約として次を守る:

- `Future[T]` の生成・`complete`・`read` は**所有スレッドのみ**
- 背景の仕事は platform の `dispatch` でスレッドへ渡し、**結果だけ**を
  `dispatch_on_main_thread` で戻して、所有スレッドが `complete` する
- 検証 4 がこの形の実証にあたる

### 却下案

**(a) コールバック方式**（完了時にメインスレッドで呼ばれる proc を渡す）。
`Future` が無いという誤った前提から出た案。`await` による逐次記述ができず、
合成もキャンセルも自前になり、Zed の `Task<R>` に対応するものが消える。却下。

**(b) `chronos` の依存追加**。既存依存は `graphemes` / `gitignore` のみで、
DEVELOPMENT_GUIDELINES は依存追加を「標準ツールで検出できない問題に限定」する。
標準 `asyncdispatch` で実現可能性が確認できた以上、理由がない。却下。

**(c) `std/tasks` + `threadpool` のみ**。分離クロージャをスレッドへ送る手段としては
有用で、platform の `dispatch` の実装候補ではある。ただし `Future` / `await` に
相当するものが無く、framework 層の `Task<R>` を表現できない。**単独では却下**、
platform 実装の内部手段としては可。

### 文字単位・スレッド・UI ブロッキング

この作業は文字を扱わない。UI スレッドは `poll(0)` を 1 フレームに 1 回だけ叩き、
実測で最悪 36µs。背景の仕事は GCD のグローバルキューで行い、メインスレッドは
結果の受け取りのみ。

### テスト観点

- unit: `Future` の完了がフレームループの tick で観測できること、保留が無いときの
  tick が例外を投げないこと、背景スレッドの結果が所有スレッドで `complete` されること
- integration: `newGitRepository` が呼び出し側をブロックせずに解決すること
- ベンチマーク: `tools/ui_test.sh parity` の非回帰（現状 Nimculus と Zed は
  移動量あたり同等）

## UI-100: Port Zed's text-layout layers without moving document state into platform

対応マイルストーンは ROADMAP.md の M3（macOS テキスト描画・IME）と M20（性能・安定性強化）。
完了条件は、(1) platform が 1 行のシェープと glyph/font の OS 実装だけを公開する、
(2) `src/nimnui/text.nim` が OS 非依存の `LineLayout` / `WrappedLineLayout` /
`LineLayoutCache` を持ち、`CacheKey` は text・font size・font runs・wrap width・force
width だけで構成する、(3) app が可視表示行レンジを閉じた行ローカルの decoration runs を
組み立てる、(4) soft-wrap 境界を同じ cache から得る、(5) glyph ごとの emoji 判定を使い
全文走査をしない、(6) 指定の unit / integration / benchmark と macOS の capture、
`tools/scroll_cost.sh 40`、`bitdiff.sh`、`ink_check.py`、`nimble format/lint/test/build`
を実測して記録する、である。

Zed の 3 層は `references/zed/crates/gpui/src/platform.rs:947`
（`PlatformTextSystem`、`layout_line` は 1 行）、
`references/zed/crates/gpui/src/text_system.rs:51,365`
（`TextSystem` / `WindowTextSystem`）、
`references/zed/crates/gpui/src/text_system/line_layout.rs:16,32,40,212,393,497,577,815,825`
（layout 型と 2-frame cache）、および
`references/zed/crates/editor/src/element.rs:3051,7045`
（可視 display row と行ローカル `from_chunks`）で確認した。

Nimculus では platform は `src/nimnui/platform/contracts.h` / `contracts.nim` と
`src/nimnui/platform/macos/macos_platform.m` の font metrics、1 行シェープ、glyph
rasterization に対応させる。framework は `src/nimnui/text.nim` の
`LineLayout`、`ShapedRun`、`ShapedGlyph`、`WrappedLineLayout`、`FontRun`、`CacheKey`、
`LineLayoutCache` に対応させる。app は `src/nimculus/` の editor display-row map と
可視行ごとの `TextRun` / decoration を対応させ、platform へ document、scroll、fold、
highlight、selection、diagnostic の状態を個別 setter で渡さない。文字単位は、文書と
decoration の境界を UTF-8 byte、シェープ glyph の対応を codepoint / grapheme 境界、
Core Text / IME の OS 境界を UTF-16、layout cache の `len` を UTF-8 byte と明示する。

却下案は「`macos_platform.m` の中に `LineLayoutCache` を足す」案である。これは Zed が
framework (`gpui/src/text_system`) に置く OS 非依存 cache を platform 層へ移すため、層が
違う。文書全体・スクロール・折り返し・装飾を platform に残す追認にもなるので採用しない。

UI スレッドは 1 行シェープ結果と cache の同期的な小さな lookup のみを扱い、全文再走査、
可視行以外の組版、別経路の CTTypesetter 再作成を frame callback で行わない。必要な全文
index / syntax / LSP 更新は app の既存非同期境界で完了させ、描画時は可視 display row
だけを消費する。Unit は cache key の色非依存性、current/previous の移送、frame swap/clear、
wrap boundary、UTF-8/UTF-16 行内 range、emoji flag を検証する。Integration は macOS
platform contract と selection / diagnostic / fold / soft-wrap の split-pane isolation、
行番号対応を検証する。Benchmark は cache hit/miss、visible-row shaping、wrap lookup、
scroll cost、text shaping と M20 の frame/layout 指標を記録する。

## UI-099: Preserve the fractional editor scroll phase

The editor viewport follows Zed's fractional display-row model. The continuous
pixel position (`scrollYPixels`) is authoritative; `scrollLine` selects the
source row with `floor`, and `scrollYFraction` is the remaining pixel offset
used to clip the first row and position every following row on the fixed line
grid. When older callers or persisted state change only `scrollLine`, the
existing fractional remainder is retained rather than resetting the viewport
to a whole-line boundary. This keeps legacy navigation compatible without
discarding trackpad or restored sub-line scroll state.

## UI-098: Match Zed's singleton editor gutter geometry

The macOS editor now derives its singleton-buffer gutter from the same Zed
formula as the vendored editor implementation: the line-number span is the
maximum of the measured widest line number and four ch advances, with a
three-ch leading padding span and a four-ch trailing span. Line numbers are
right-aligned at the line-number span's trailing edge; Git markers stay in the
leading padding and fold markers stay in the trailing padding, so indicators
never widen the gutter.

The gutter margin is the negative descent of the active editor font. The text
origin, viewport, wrapping, cursor, selection, hit testing, and IME
coordinates all consume that origin, while native gutter frames are bounded
to the editor pane. This preserves the Zed content offset and prevents narrow
panes from painting or routing input outside their editor rectangle.

## UI-097: Group the terminal toggle with the status-bar dock controls

The terminal glyph is a panel action, not a buffer-status readout. Keep the
icon-only `Toggle Terminal` control contiguous with `Toggle Panel Dock` at the
far-left edge of the footer, then use the existing themed divider before the
diagnostics, active-file, and Git text readouts. The right cluster remains
plain text for encoding, language, line ending, and cursor position.

This preserves the existing `commandPalette:toggle terminal` dispatch and
keyboard shortcut while making the visual order match Zed's status-bar
composition. The shared 28pt row / 24pt hit-area tokens, semantic border role,
and SF Symbol configuration apply in both One Light and One Dark.

## UI-096: Keep footer status semantics text-only and remove dead breadcrumb actions

The macOS footer now keeps the right-side buffer selectors as plain clickable
text in Zed's order: encoding, language, line ending, and cursor position.
Panel toggles, including Terminal, stay in the left icon-only cluster, while
the Git item is a text-only branch/status item; its branch glyph no longer
decorates a text status. This prevents an unrelated terminal icon from being
read as part of the encoding selector and keeps the two footer clusters
semantically distinct in both light and dark themes.

The breadcrumb row retains only actions that are wired to Nimculus commands:
`Find in file` uses the magnifying-glass symbol and opens the document find
bar, while `Format buffer` uses the refresh/reformat symbol and dispatches the
LSP formatting command. The previous Markdown preview eye was removed because
Nimculus has no implemented preview target. Both remaining controls use the
shared 28pt row / 24pt hit-area tokens, explicit tooltips, accessibility labels,
and configured SF Symbol sizing.

## UI-095: Use Zed search glyph geometry and one find-row baseline

The find bar's three search-option controls now use the vendored Zed SVG
geometry for Case Sensitivity (`Aa`), Whole Words (a word with its boundary
bar), and Regular Expressions (the dot-and-asterisk mark). Each control uses
Zed's exact tooltip and accessibility label: `Match Case Sensitivity`,
`Match Whole Words`, and `Use Regular Expressions`. This keeps the visual
meaning discoverable without relying on the previous ambiguous `Abc`, list,
or braces glyphs.

The existing native chrome styling remains the state owner: inactive icons use
the foreground role, while active icons use the accent role and a rounded,
accent-tinted fill in both light and dark themes. The document and workspace
find rows now share `NimculusFindBarRowHeight` and
`NimculusFindBarRowPadding`; the query field, match count, previous/next
controls, option toggles, and close button therefore share one vertical row
metric instead of using control-specific offsets.

The SVGs are embedded as template `NSImage` data rather than added as bundle
resources, preserving the existing macOS packaging contract while retaining
the reference artwork's geometry.

## UI-094: Make editor chrome container-owned and overlay-safe

The macOS editor now treats the pane rectangle as the owner of all document
coordinates. The line-number gutter is framed at the editor's left edge,
right-aligned inside a Zed-compatible measured width, and the text origin is
derived from that gutter and its font-descent margin. Core Text, Metal glyphs, selections,
caret, diagnostics, indent guides, Git gutter routing, pointer hit testing, and
IME candidate coordinates all consume the same origin and viewport helpers;
line numbers are never placed in the sidebar or clipped by the window edge.

Scrollbars are overlays. Their visibility does not subtract from the text
viewport or wrapping width, and their retained paint scissor uses the owning
editor pane so thumbs can float over content without changing layout. The
find bar is an editor-owned toolbar row at the pane's top boundary; opening it
adds a toolbar inset to document content rather than covering the first text
rows. Its match count is a child of the query field at the trailing baseline,
and its Case Sensitive, Whole Word, and Regex controls use semantic SF Symbol
buttons with tooltip/accessibility labels and accent-colored active states.

Tabs, breadcrumbs, panel headers, search, and the status footer use the shared
28pt chrome row token and centered control hit boxes. SF Symbols are configured
with the body text style before the point-size/weight override, keeping icon
optical centers paired with the neighboring text metrics in both One Light and
One Dark.

## UI-093: Condense the status-bar dock controls to a Zed-style left cluster

The first status-bar dock pass moved every Files, Search, Outline, Git, and
Debug panel button into the footer, then added a second project-search button.
That made the left edge crowded and rendered the magnifying-glass affordance
twice. Zed treats the dock as one status-bar toggle; the selected panel stays
inside the dock and panel-specific commands remain available through the View,
Agent, Debug, and Search surfaces and their existing keybindings.

The final macOS footer therefore begins with one ghost `Toggle Panel Dock`
button, a 1px themed divider, one compact Agent button, one project-search
button, and the existing diagnostics indicator. The active file name and Git
summary remain unchanged. The dock toggle changes only left-dock visibility,
preserving the selected panel, while `Toggle Panel Dock` is also exposed in the
View menu. Search's native panel header retains New Search and Cancel Search;
Files, Outline, Git, Terminal, and Debug remain reachable through their existing
menu and shortcut routes, so removing per-panel footer buttons does not strand
any panel.

The source reference is Zed's `crates/zed/src/zed.rs` status registration and
`crates/workspace/src/status_bar.rs`; the local implementation is the native
`NimculusFooterOverlay`. The divider uses the shared `border` role in both One
Light and One Dark, and all new controls retain the existing ghost-button and
accessibility contracts.

## UI-092: Replace the left activity rail with Zed-style status-bar panel buttons

_Superseded in the final footer composition by UI-093; the activity rail
removal and panel command routes remain in force._

The current workspace follows Zed's `crates/workspace/src/dock.rs` contract:
panel identity supplies an icon, tooltip, and accessible label, while the
status bar owns `PanelButtons`. Nimculus removes the permanent
`NimculusActivityBar` overlay and places Files, Search, Outline, Git, and
Debug buttons in the status bar's left cluster; Terminal leads the
bottom-dock controls in the right cluster. Buttons dispatch the existing panel
commands, highlight from the existing native sidebar/terminal state, and keep
ghost styling in both One light and One dark themes.

This reclaims the former rail width. The logical workspace dock now maps
directly to the native Files/Git/Outline presenter, so editor geometry,
presented-region hit testing, and dock divider resizing share one boundary.
Accessibility labels, keyboard shortcuts, command routing, and persisted dock
state remain unchanged because the status buttons are only a new pointer
surface over the existing workspace state machine.

The source reference is `references/zed/crates/workspace/src/dock.rs`, with
status-bar registration mirrored by the local `NimculusFooterOverlay`.

## UI-084: Clone Zed's Outline and diagnostic presentation

The macOS Outline presenter follows the vendored Zed implementation contract:
the existing local/LSP symbol stream remains authoritative, while the native
panel adds a `Search buffer symbols…` field, depth-derived guide lines,
symbol-kind SF Symbols, themed hover/selection rows, and an overlay scroll
container. Filtering is represented by an explicit visible-index-to-source
index map in Nim, so keyboard navigation, accessibility selection, and
jump-to-symbol continue to target the original UTF-16 range. Cmd+Shift+O now
opens a sparse symbol picker using the same elevated command-palette chrome and
match highlighting.

Diagnostics use the One theme's exact `error`, `warning`, `info`, and `hint`
roles from `references/zed/assets/themes/one/one.json` in both light and dark
themes. Editor decorations render a repeating squiggle path below the affected
text instead of a solid underline; the status footer also exposes severity
icons/counts for all four roles. The Zed source references are
`references/zed/crates/outline_panel/src/outline_panel.rs`,
`references/zed/crates/outline/src/outline.rs`, and
`references/zed/crates/diagnostics/`.

## UI-083: Use Zed One terminal palettes as the native terminal source of truth

Nimculus now carries Zed's One Dark and One Light terminal roles from
`references/zed/assets/themes/one/one.json` through the existing theme JSON
boundary. Each built-in theme includes the exact terminal background,
foreground, bright/dim foreground, and ANSI normal/bright/dim tables. The
macOS renderer uses those values for default and indexed colors in both the
Metal glyph path and the AppKit text fallback, including SGR dim output.

The terminal cursor maps to the palette's `brightForeground` role and terminal
selection maps to `dimForeground`; Zed's One theme does not publish separate
terminal cursor/selection tokens. This keeps both affordances in the terminal
role family instead of reusing editor chrome colors. Zed's default terminal
settings in `references/zed/assets/settings/default.json` specify standard
line height (1.3x) and otherwise inherit the buffer defaults, so Nimculus uses
15pt `.ZedMono` and a 1.3x terminal line-height multiplier.

## UI-082: Adopt Zed One themes and a single comfortable editor line metric

The built-in light and dark themes copy the semantic colors from
`references/zed/assets/themes/one/one.json`: editor and gutter backgrounds,
editor foreground, active-line alpha, panel/surface/elevated chrome, tabs,
status/title bars, borders, text roles, scrollbar tokens, line-number roles,
caret, and the keyword/string/comment/function/type/number/title syntax
palette. The syntax entries retain Zed's regular title weight and bold
`emphasis.strong` weight. Native fallback values use the same tokens so a
palette update and the macOS renderer cannot diverge.

Editor typography follows
`references/zed/assets/settings/default.json`: buffer size 15, `.ZedMono`
with a sensible native fallback, and `comfortable` line height at 1.618x the
font size (24.27px at the default size). `editorLineHeight()` is now the
single Nim-side source for cursor placement, scrolling, hit testing, IME
coordinates, line numbers, Git gutter actions, diagnostics, and session
scroll restoration; the platform line-height export is the native authority.

The line-number gutter follows the vendored Zed editor contract: a minimum of
four digits, digit-count-based width, one character of right padding, and
right-aligned numbers. Its background is the editor background, the active row
uses the active-line token across the full row, and the active number uses the
emphasized line-number token. The caret uses Zed's player cursor color and a
2px bar. Markdown ATX headings use the editor's muted text treatment for both
the `#` markers and heading text; the markers are italic and the heading text
is bold. This follows the Markdown language capture (`title.markup`) falling
back to the ordinary text treatment in the One theme rather than using the
generic `title` syntax color.

## UX-028: Align macOS titlebar and breadcrumb actions with Zed

The macOS titlebar keeps the native traffic lights, but places the regular-weight
`Nimculus` workspace label immediately before the Git branch icon and branch
name. The branch control is left-aligned in that same group rather than being
centered independently, so the light and dark layouts preserve the same visual
relationship.

The filename-first breadcrumb remains the existing native document-navigation
contract. Its Markdown heading and symbol segments are rendered as an
attributed string so heading components receive a modest semibold emphasis
while filenames, separators, and paths remain muted. Three right-aligned
ghost `NimculusChromeButton` controls share the existing hover, tooltip, and
accessibility treatment: document Find and buffer formatting route through the
existing command callback, while Markdown Preview activates only when the
application delegate exposes that optional action.

## UX-027: Align macOS editor tabs and breadcrumbs with Zed

The macOS editor tab bar now follows the verified Zed light-theme geometry and
keeps the same contract in dark mode and split panes. Previous/next use arrow
SF Symbols, tabs retain measured content widths, and the active tab is marked
only by its raised surface. A dirty tab renders a bullet, while the close
target and glyph are reserved for the hovered tab; this keeps the active tab
from carrying a permanent close affordance.

Visible named-tab labels are derived from the document basename plus extension
without changing the persisted title field, so restored sessions and Save As
semantics remain stable while `DEVELOPMENT_GUIDELINES.md` is shown in chrome.
The label uses a 12pt leading inset and the existing trailing control hit area,
with tail truncation inside the measured content-width tab.

The breadcrumb is now a document navigation path: it begins with the complete
filename at the pane's far-left edge, then adds cursor-containing Markdown
heading levels or available LSP/local symbol ranges. If no hierarchy is
available it shows only the filename. The application/workspace title remains
independent of this document breadcrumb, preventing a filename change from
renaming the titlebar.

## UI-081: Make editor and project-panel chrome share hard Zed-style edges

The macOS workspace no longer emits an accent-colored active-pane rectangle at
the editor's left edge. That rectangle crossed the breadcrumb and editor body
and made a focus affordance look like a stray blue bar; caret rendering remains
independent and unchanged. The normal editor path also omits the outer pane
border so focus does not create a second left-edge line.

Editor panes now begin exactly at the logical dock boundary and consume the
remaining center width. The breadcrumb begins at that pane edge, while tab
labels retain their own content inset. Scrollbar thumbs float over the pane and
do not reserve a right edge in the text layout; the shared text viewport still
ends 14pt above the footer so the bottom overlay cannot clip glyphs. Vertical
scrollbar geometry and line-number clipping use that same top/bottom contract
in both light and dark themes.

The Metal project-panel surface now starts at the content origin and ends at the
status bar (or bottom-dock boundary), matching the native Files scroll view and
activity bar. The activity bar and Files panel share the full dock height with
no artificial horizontal or vertical spacer at their shared edges.

This is a geometry-only chrome change: split panes, welcome presentation,
secondary editor state, caret/selection, native tab and breadcrumb controls,
and semantic light/dark theme roles remain intact.

## UI-079: Make unwrapped editor scrolling Zed-compatible

The editor now defaults new and legacy-restored views to no soft wrap, while
an explicitly saved `softWrap: true` remains authoritative. In macOS no-wrap
mode, each pane owns an independently clamped horizontal offset. Trackpad and
wheel input, scrollbar clicks/drags, cursor reveal, selection, hit testing,
and IME coordinates all consume that same offset; the line-number gutter stays
fixed.

The native macOS backend measures the currently visible lines with Core Text
and is the authority for the widest-line width and maximum horizontal offset.
The Nim scrollbar geometry mirrors the native text viewport without reserving a
vertical-scrollbar edge, so horizontal and vertical thumbs float over the pane
and the horizontal thumb cannot be under-sized by a monospace estimate.
Horizontal-thumb visibility is derived only from that measured widest visible
line versus the text viewport. Core Text reports zero while wrapping is active,
so the geometry does not consult a separately tracked Nim soft-wrap flag that
could become stale. The paint list is recomposed after native text, wrap, and
viewport synchronization so edits and View > Toggle Soft Wrap publish the
current measured thumb in the live frame. Its Y coordinate is clamped to the
editor pane's bottom edge, immediately above the footer.
Scrollbar changes continue through the existing `requestRedraw` and damage
paths; no frame-count or display-link semantics are changed.

## UX-026: Make the macOS footer a Zed-aligned status-only toolbar

**Context.** The previous footer painted one left status string and a
tab-separated right string directly into the view. That kept the information
visible but made the controls inconsistent with the rest of the workspace
chrome, provided no native hover state for the status entries, and left the
language-server state beside the editor metadata. Zed groups diagnostic,
source-control, and language-server state on the left and makes cursor,
language, encoding, and line-ending entries quiet clickable controls on the
right.

**Decision.** Keep the 24pt statusBar footer and its existing
tab-separated payload, but present it as two native NSStackView clusters of
NimculusChromeButton controls. The left cluster contains a severity-counted
diagnostics button, a compact Git branch/status button, and an iconized LSP
state button. The right cluster contains cursor position, language, encoding,
line ending, and the existing indentation entry. Each item keeps an explicit
tooltip, accessibility label, and its previous command destination; the
diagnostics item uses the new commandPalette:show problems route. The
existing Status Bar Settings / Hide context menu remains available from the
bar and every status button.

Panel destinations are intentionally represented once in the footer. Files,
Search, Outline, Git, and Debug use the left status-bar cluster; Terminal uses
the bottom-dock position in the right cluster. Split remains an editor action
in its existing command/toolbar path, avoiding competing control surfaces.

**Consequences.** Theme roles, spacing tokens, and the ghost hover treatment
are shared with the rest of macOS chrome. Diagnostics refresh the summary
from the existing primary-pane severity spans, while footer payload updates
rebuild only the native status controls; no service or editor-core state is
duplicated. The footer remains status-only and keeps the existing right-click
contract in both light and dark themes.

## UI-078: macOS workspace presenters are single-row and pane-clipped

ZedのProject PanelとGit UIは、ファイル名・コミット行を複数行へ折り返さず、
表示領域内で省略して選択状態を別のモデル状態として保持する。NimculusのAppKit
presenterも同じ契約にし、Files/Gitの`NSTextView`へ末尾省略とクリップを設定する。
タブバーは復元された長いタイトルやclose glyphが本文へ描画されないよう専用の
クリップ領域を持ち、status表示は単一行末尾省略とする。これにより、表示行数と
クリック・キーボード選択の論理行数がずれず、狭いmacOSウィンドウでも右端・下端の
pane chromeを侵食しない。native platform contractで、サイドバーのtext container、
tab strip、既存のselection/scroll boundsを同時に検証する。

## UI-074: macOS新規エディタはソフトラップを既定で有効にする

長い行を右端で切ったまま表示すると、ユーザーが行末へ到達できず、
エディタの表示領域から文字がはみ出したように見える。新規ビューおよび
欠落したセッション設定では `softWrap=true` を既定にする。保存済みの
明示的な `false` は保持し、UI-076の横スクロールで行末へ到達できる。

## UI-076: 未折返し編集は主・副ペイン共通の横スクロール境界を使う

Zedの未折返し編集と同じく、soft wrapを無効にした場合はトラックパッドの
水平スクロール、またはShift+ホイールで横方向へ移動できる。スクロール量は
primary/secondary paneごとにsessionへ保存し、描画、カーソル追従、クリックの
UTF-8/UTF-16 hit-test、NSTextInputClientのIME候補位置、selection、diagnostic
underline、glyph atlasのすべてが同じオフセットを消費する。soft wrapを再度
有効にした時は横オフセットを0へ戻し、縦のラップ表示と不整合を起こさない。

## UI-077: ワークスペースの空エディタはWelcomeを表示しFilesを残す

フォルダを開いた直後にアクティブ文書がない状態は、編集可能な空バッファ
ではなく、ユーザーが次の操作を選ぶワークスペース入口である。中央にだけ
Welcome（Open Folder、Open File、New File、Open Recent）を表示し、Files
ツリーとactivity barは残す。これによりフォルダを開いたのに本文が空白で
操作対象が見えない状態を避け、ZedのProject Panelと中央entry surfaceの
役割分担に合わせる。文書を開いた時点でWelcomeと関連overlayを隠す。

## UI-075: Filesの選択identityはアクティブ文書のcanonical pathで再解決する

ZedのProject Panelでは、アクティブなエディタ項目がファイルツリーの
選択行として常に表示される。FSEventsや外部ファイル更新でツリーが再構築
されるときも、行番号ではなくcanonical pathで現在の文書を再検索する。
これにより、ルート行を選択したまま実際のファイルを開いているように見える
状態を防ぎ、表示・selection・キーボード操作の対象を同じ項目へ揃える。
AppKitの非アクティブ選択色は使わず、`NSTextView`の行フラグメントを1行分
補正したテーマ色の背景を描画して、選択identityと視覚行を一致させる。

## UI-001: UI を機能の入口として扱う

ZedのWorkspace、Dock、Pane、ProjectPanelを調査した結果、Nimculusの既存UIは
ファイル、Git、アウトラインを単一の文字列サイドバーへ投影するだけで、ユーザーが
操作するPanel、Pane、Dockの状態を持っていなかった。内部サービスが存在しても、
ユーザーが発見し、操作し、状態と結果を確認できなければ機能は完成していない。

以後、機能の完了条件には、操作導線、hit target、キーボードフォーカス、状態表示、
失敗時のフィードバック、実機スクリーンショットを含める。UI実装は見た目を後付けする
工程ではなく、アクションから状態遷移、描画までを含む機能実装として扱う。調査内容と
再設計の前提は `docs/ZED_UI_ARCHITECTURE_RESEARCH.md` に記録する。

## M1-017: Bind window lifecycle callbacks to the application delegate

Zed registers macOS window callbacks for both close handling and display
changes, refreshing its drawable when AppKit moves the window to another
screen. Nimculus already implemented `windowShouldClose:` but had not assigned
the application delegate as the `NSWindow` delegate. The main window now binds
that delegate, so dirty-document close confirmation is reached in normal use.
`windowDidChangeScreen:` refreshes the Metal layer, metrics, and scale-bound
text resources even when no resize occurs. The native contract verifies both
callback bindings and the resulting drawable-size refresh.

## M1-016: Restrict real fullscreen transitions to the dedicated GUI runner

Zed invokes AppKit's asynchronous `toggleFullScreen:` and tracks the entered
and restored fullscreen states through the native window lifecycle. Nimculus
now exercises the same transition with a temporary Cocoa/Metal window, waiting
for `NSWindowDidEnterFullScreenNotification` / `NSWindowDidExitFullScreenNotification`
as well as the corresponding `NSWindowStyleMaskFullScreen` state. Fullscreen
temporarily changes the active GUI space, so this contract is opt-in through
`NIMCULUS_REQUIRE_FULLSCREEN_TRANSITION=1`. The self-hosted Actions runner is
a GUI-login service but does not reliably receive Mission Control space
transitions: runs [30141031600](https://github.com/asopitech-labs/nimculus/actions/runs/30141031600)
and [30141147508](https://github.com/asopitech-labs/nimculus/actions/runs/30141147508)
did not receive the enter notification. It therefore remains disabled in CI
and is reserved for an interactive macOS session. Normal local and
push-triggered tests never change the developer's workspace.

## M2-014: Verify viewport clipping at the Metal backing-pixel boundary

Zed intersects every nested content mask before it submits a primitive and
snaps that mask to backing pixels. Nimculus already converts the `PaintList`
clip (and partial repaint's `dirty ∩ clip`) into a Metal scissor rectangle.
The macOS platform contract now renders a full logical rectangle into a 2x
offscreen Metal target and reads the pixels back: only the intended scroll
viewport may be red, and a partial repaint may reach only `dirty ∩ viewport`.
This covers the coordinate inversion and Retina scale at the native rendering
boundary without relying on an unchecked visual inspection. Interactive
scrolling in a real GUI remains a separate roadmap acceptance condition.

## M0-008: Keep Nimble build outputs bounded and explicitly cleanable

Zed keeps generated build state separate from source and reference trees and
has explicit cleanup boundaries for generated artifacts. Nimculus now routes
the regular `nimble build` cache to `.nimcache/build`, ignores generated test
and benchmark executables without ignoring their `.nim` sources, and provides
`nimble clean` for disposable caches and local build/distribution outputs.
This makes the disk-usage check enforceable rather than dependent on each
developer remembering Nim's default user cache location.

## M20-006: Make large benchmark workspaces exception-safe

Zed's large workspace tests isolate generated projects in process-specific
temporary directories and keep cleanup alive until the test scope exits.
Nimculus now gives the 100k-file workspace benchmarks a PID-scoped root and a
scope-bound `defer` cleanup. A failed enumeration or file write no longer
leaves a large generated tree in the system temporary directory.

## M20-007: Measure bounded service memory at lifecycle boundaries

Zed's reliability loop records resident memory at a process boundary, while
its workspace and language-server services keep ownership and shutdown tied to
the owning scope. Nimculus's M20 benchmark now records resident-memory samples
around terminal parsing, bounded LSP frame decoding, workspace enumeration, and
file-watcher registration. Each sample includes the workload size and the
before/after resident bytes; the watcher is stopped before its temporary root
is removed. This makes service-level growth visible without treating Nim's
allocator count as a complete measure of native resources.

## M20-008: Measure cold start at the first platform idle callback

Zed records startup relative to the application lifecycle rather than treating
compile time as startup time. Nimculus now captures the process start before
application initialization and, only when `NIMCULUS_BENCH_COLD_START=1` is set,
reports the elapsed time at the first platform idle callback. The benchmark
then requests a normal platform quit, so the measured boundary includes
session/settings/workspace setup and native window initialization without
altering normal launches. `scripts/benchmark_cold_start.sh` builds in a
PID-scoped temporary cache and removes it after repeated runs.

The launcher applies a positive timeout to every child process so a failed GUI
startup cannot leave a benchmark or CI job running indefinitely.

The cold-start launcher creates a minimal `.app` bundle before starting the
executable. A raw executable does not provide the LaunchServices bundle
identity that AppKit uses for the normal application lifecycle, which can
leave a direct developer launch without a reliable finish/terminate sequence.
The probe now measures the same bundle boundary as distribution, and a
provided raw binary is wrapped in that temporary bundle as well.

The same bundle boundary is used by `scripts/benchmark_soak.sh`; otherwise a
soak run could report a timeout caused by raw AppKit launch behavior instead
of measuring the application loop.

## M5-013: Initialize macOS settings before the first workspace preview

The first macOS workspace open refreshes the preview and resolves file icons
through `SettingsStore`. Initializing the workspace before the settings store
caused a reproducible nil dereference during cold start. The application now
constructs the global/workspace settings layer before opening the workspace,
and the preview boundary remains safe while settings are unavailable during
future reconfiguration.

## M20-011: Quit lifecycle probes without a dirty-document confirmation

Cold-start and soak probes do not edit a document. They therefore use the
platform's confirmed termination entry point directly, while normal Cmd+Q
continues through the dirty-document confirmation path. This prevents a
benchmark from presenting a user modal and makes its timeout a real startup
failure rather than an unattended dialog.

## M11-006: Verify the app from the mounted DMG

Generating a DMG and running `hdiutil verify` does not prove that the
distribution contains a launchable application. `scripts/verify_macos_package.sh`
therefore mounts the DMG read-only, verifies the embedded app signature, runs
the bundle cold-start probe against the mounted executable, and detaches the
volume in a cleanup trap. This follows the distribution boundary used by the
packaging workflow and keeps writable application state in a temporary HOME.

## M11-007: Keep the cold-start runner compatible with macOS Bash 3.2

The normal macOS CI cold-start job supplies a startup path, while mounted-DMG
verification intentionally launches without one. Bash 3.2 with `set -u` treats
an empty array expansion as an unset variable, so representing that optional
argument as `startup_args=()` made the package verifier fail before it launched
the application.

The benchmark now invokes the executable through explicit startup-path and
no-path branches. This covers both CI paths without requiring a newer
user-installed shell. The ad-hoc package verifier now reaches a rendered
Cocoa/Metal frame from the read-only mounted DMG before it detaches it.

## M20-012: Keep settings application out of the idle render loop

Zed applies settings changes through explicit settings updates rather than
rebuilding text resources on every frame. Nimculus now applies the macOS
theme/font settings at startup and only after `SettingsStore.reload()` reports
a change. This prevents repeated Core Text shaping and Metal glyph-atlas
uploads, and keeps the idle callback bounded for long-running sessions.

## M1-014: Read macOS event fields according to event type

AppKit raises an internal exception when `NSEvent.keyCode` is queried for a
mouse or tracking event. The macOS input bridge now supplies keyCode only for
keyDown, keyUp, and flagsChanged events, while pointer events use zero. This
keeps tracking-area events safe during normal window-idle operation.

The macOS platform contract also constructs real AppKit mouse and keyboard
events and routes them through the input logger. This exercises the field
access boundary without requiring Accessibility permission; the live
MouseEntered/MouseExited callbacks continue to use the same non-keyboard path.

The contract also constructs `flagsChanged`, `scrollWheel`, and both tracking
events through their AppKit-specific factories. This keeps keyboard-only
`keyCode` access and precise-scrolling access covered for every event family
that the view receives.

## M1-015: Exercise the real window resize boundary without leaking test state

The macOS platform contract attaches `NimculusMetalView` to an `NSWindow`,
changes the content size, and checks that the CAMetalLayer drawable remains
aligned with the backing scale. AppKit can deliver one final layout callback
while an autorelease pool drains, so the test restores observable platform
metrics only after that boundary. This keeps the native smoke reusable by
later text and hit-test contracts.

## M3-009: Verify clipboard round trips without changing user state

The macOS platform contract writes a Japanese/emoji UTF-8 sample to the real
general pasteboard, reads it back, and restores the previous string afterward.
This verifies the `NSPasteboardTypeString` boundary rather than only the
in-process cache, while avoiding a persistent change to the developer's
clipboard during local tests. The payload is written as UTF-8 `NSData`, matching
Zed's `Pasteboard::write_plaintext` path; reading the data first preserves exact
byte length and embedded NULs, with `stringForType:` retained only as a
compatibility fallback.

## M5-014: Preserve explicit macOS menu shortcut overrides

The standard menu builder applies Command modifiers to ordinary Edit items,
but must not overwrite explicit combinations such as Command-Shift-P for the
Command Palette. The native menu contract enumerates the real AppKit menu
hierarchy and checks the standard File shortcuts, Settings comma shortcut,
and the palette modifier mask.

## M5-015: Test Finder and URL opens at the AppDelegate boundary

Finder `openFiles:` and registered `nimculus://` URLs enter through different
AppKit delegate callbacks. The native contract invokes both callbacks with
representative absolute paths and restores the previous file callback after
checking the received path and non-saving flag. This covers Open With and URL
scheme routing without opening a user dialog or creating a file.

## M20-009: Report live allocation blocks with explicit platform limits

Zed's allocator and profiler boundaries distinguish process-level memory from
instrumented allocation domains; a single number must not be presented as a
complete allocation history. Nimculus therefore exposes
`platformLiveAllocationCount` as a diagnostic sample. macOS reports
`malloc_default_zone()`'s `blocks_in_use`, while Windows walks the process
heaps and counts `PROCESS_HEAP_ENTRY_BUSY` entries. The benchmark emits this
as `allocation_count` with `kind=live_blocks`, outside the timed workload.
It is not a cumulative event counter and does not include allocations hidden
behind allocator implementations that are outside the reported zone/heap.

## M20-010: Use an idle-boundary reliability heartbeat for soak runs

Zed's reliability loop samples resident memory on a short poll interval and
emits a heartbeat less frequently, while also logging significant changes.
Nimculus keeps the benchmark deterministic and portable: when
`NIMCULUS_BENCH_SOAK=1` is set, the existing macOS/Windows idle callback emits
resident bytes, live allocation blocks, frame count, and input count at the
configured interval, then requests a normal platform quit at the configured
duration. `scripts/benchmark_soak.sh` supplies an eight-hour default and a
timeout greater than the duration. This measures the real application loop;
it does not claim an eight-hour result until the script has actually completed
on the target GUI environment.

## M20-013: Require rendered-frame evidence in startup and soak probes

An idle callback proves only that the application loop is alive; it does not
prove that `CAMetalLayer` returned a drawable and that a command buffer was
committed. Cold-start output therefore includes the native frame count and
drawable dimensions, and `benchmark_cold_start.sh` rejects a run with zero
frames. Soak samples already include frame counts; `benchmark_soak.sh` now
requires at least one sample with a rendered frame before accepting
`soak_complete`. This keeps the reliability gates aligned with M1's actual
Metal rendering requirement.

## M20-016: Emit frame and input latency diagnostics from real soak runs

Zed keeps input latency as a separate distribution so a reliability run can
distinguish memory growth from an interaction regression. Nimculus's macOS
soak samples now carry the last frame duration and input-to-presentation
latency alongside the bounded distribution's sample count, p95 latency, and
p95 coalesced events per frame. `benchmark_soak.sh` requires these fields to
be present while allowing idle runs to report zero input samples. They are
therefore guaranteed diagnostics rather than a synthetic-input performance
gate; the existing rendered-frame and memory-growth requirements remain the
soak acceptance contract.

## M20-017: Retain bounded frame-time percentiles for macOS rendering

Zed's frame profiler retains a bounded timing history rather than allowing a
single last-frame value to hide a render spike. Nimculus now records the CPU
render-through-Metal-submit duration for the most recent 256 rendered frames.
The macOS contract exposes sample count, average, p95, maximum, and counts
over 16.667 ms and 33.333 ms. These are explicitly CPU submission timings,
not display-vsync intervals; their purpose is to identify renderer work that
would threaten the 60Hz/30Hz frame budgets. Soak output requires the frame
diagnostics while preserving its existing memory-growth gate.

## M11-011: Validate distribution containers at every packaging boundary

Zed's macOS bundle flow treats the DMG as a release artifact that must remain
valid through signing and notarization. Nimculus now verifies that the ZIP and
DMG are non-empty immediately after creation, and runs `hdiutil verify` on the
DMG. The same checks run again after notarization rebuilds the containers, so
an apparently successful signing step cannot publish a truncated or invalid
distribution artifact.

## M11-012: Prefer keychain profiles or API keys for notarization

Apple's current `notarytool` workflow supports keychain profiles and App Store
Connect API keys in addition to app-specific Apple ID passwords. Nimculus now
accepts `APPLE_NOTARY_PROFILE` or the API-key triplet
`APPLE_NOTARY_KEY`/`APPLE_NOTARY_KEY_ID`/`APPLE_NOTARY_ISSUER_ID`, and retains
the legacy environment-variable credentials only as a fallback. Partial API
key configuration and unreadable key files fail before submission, preventing
an ambiguous or insecure packaging run.

## M11-014: Make stapled distribution verification an explicit release gate

The normal macOS CI package smoke intentionally uses an ad-hoc signature, so it
cannot prove Developer ID or Apple notary service acceptance. The mounted-DMG
verifier now accepts `NIMCULUS_REQUIRE_NOTARIZATION=1`; in that mode it runs
`stapler validate` and Gatekeeper assessment for both the mounted app and the
DMG. A manually dispatched `macos-release.yml` workflow installs the
Developer ID certificate into a runner-only keychain, decodes an App Store
Connect API key from a GitHub secret, runs `notarytool`, staples the app and
DMG, and invokes that strict verifier. No signing or notarization material is
stored in the repository. This follows Apple's required hardened-runtime,
Developer ID, `notarytool`, and stapling sequence while keeping the ordinary
adhoc regression gate credential-free.

## M11-013: Generate the ICNS container with ImageIO

The Apple iconset contract still requires the ten 1x/2x PNG renditions, but
the local `iconutil` conversion rejected the generated set even when its names
and pixel dimensions matched that contract. The macOS packaging path therefore
keeps generating the documented iconset and uses ImageIO's
`com.apple.icns` destination to write the final ICNS container directly. The
package script verifies the resulting ICNS and falls back to Apple's
`iconutil` when an older runner image lacks that ImageIO destination. The
package smoke test validates the signed app, ZIP, and DMG at the release
boundary.

## M11-015: Keep Swift packaging caches inside the disposable build boundary

The icon generator is a Swift program and the compiler may otherwise write its
Clang module cache under the user's home directory. That made an otherwise
valid package smoke fail in restricted environments and violated the cache
cleanup rule. `package_macos.sh` now sets `CLANG_MODULE_CACHE_PATH` beneath its
per-run temporary Nim cache, which is removed by the existing cleanup trap.
The source tree and user cache are therefore not used as hidden packaging
state.

## M0-009: Install Nimble dependencies without rebuilding the workspace

`nimble install` may build the current package in a temporary dependency tree.
That breaks this repository's `nimble.workspace` source layout because the
temporary tree does not contain the sibling `nimnui` package. CI and Windows
packaging therefore run `nimble install --depsOnly -y` from the standalone
`ci/dependencies.nimble` manifest; the project itself is compiled by the
explicit build step.

## M13-053: Run the Windows native contract test on the Windows runner

The macOS workflow can only compile the Windows portable boundary because it
does not have the Windows SDK. The Windows workflow now compiles and runs a
native platform contract test before packaging. It checks the shared ABI
sizes, DPI/frame metric shape, resident/live-allocation counters, and input
counter monotonicity. A missing native symbol or incorrect C/Nim declaration
therefore fails on the target runner instead of being hidden by a portable
no-op build.

## M13-054: Cache the Windows DirectWrite text format by render configuration

Zed's Windows text system retains font-system state instead of constructing
font resources for every visible line and frame. Nimculus now caches the
`IDWriteTextFormat` used by the DirectWrite editor path, keyed by font size,
per-monitor scale factor, and soft-wrap mode. Font and wrap setters invalidate
the cache, and shutdown releases it before the DirectWrite factory. The
Windows native contract verifies that an unchanged configuration returns the
same COM object.

## M13-055: Acquire IDWriteFactory2 before implementing the Windows glyph atlas

Zed's Windows text path uses `CreateGlyphRunAnalysis`, which is exposed by
the newer DirectWrite factory interface. Nimculus previously kept only the
base `IDWriteFactory`, so an atlas implementation could not use the official
glyph rasterization API safely. The Windows boundary now queries and owns
`IDWriteFactory2`, releases it during shutdown, and exposes a native contract
that verifies the interface is available. This is an atlas prerequisite, not
the completion of the persistent atlas itself.

## M13-056: Implement the DirectWrite glyph raster cache before GPU upload

The Windows text path now resolves the configured font face, builds a
`DWRITE_GLYPH_RUN`, obtains `IDWriteGlyphRunAnalysis` bounds, and stores the
grayscale alpha bitmap in a bounded 1024-entry LRU cache keyed by glyph ID,
font size, scale, and 4x4 subpixel variant. Font changes invalidate the cache;
size and scale are part of the key. A native contract rasterizes the same
glyph twice and verifies the second request is a cache hit. The cache is the
CPU rasterization stage of the Zed-style atlas pipeline; D3D texture/SRV
upload and visible glyph draw remain a separate M13 step.

## M6-007: Exercise FSEvents through the main run loop in integration tests

Zed's filesystem tests drive the platform watcher until events are delivered
and keep the watcher handle alive until the owning scope is torn down. The
macOS FSEvents bridge schedules its stream on `CFRunLoopGetMain()`, so the
Nimculus macOS integration test now pumps that run loop while waiting for
create, rename, delete, and coalesced write events. Cleanup stops the watcher
before removing the temporary root. This closes the gap where the primary
macOS watcher had implementation code but only the Windows path was exercised.

## M11-006: Bound update artifacts before verification and installation

Zed downloads update bodies in bounded chunks and verifies the completed
artifact before installation. Nimculus now gives curl a 1 GiB maximum, checks
the destination size while an asynchronous download is running, terminates
and removes an oversized file, and repeats the size check before SHA-256
verification. This prevents a malformed or compromised update endpoint from
consuming unbounded disk space.

## M11-007: Keep the macOS mount point and cleanup boundary exact

Zed passes the installer directory used by `hdiutil` as the mount root and
always awaits unmounting before its temporary installer directory is removed.
`hdiutil -mountroot root` creates `root/<volume-name>`; Nimculus therefore
uses `NimculusUpdateMount/Nimculus` for both the mounted app and detach path,
matching the `Nimculus` volume emitted by the package script. It then removes
the mount directory and consumed DMG in a `finally` cleanup path. This avoids
verifying one path while detaching another and prevents stale update artifacts
from accumulating in the temporary directory.

## M11-008: Verify update downloads before publishing the destination path

Zed keeps an update inside its installer directory until the download and
verification lifecycle completes. Nimculus now downloads to
`<destination>.part`, removes stale destination/partial files before a new
attempt, checks size and SHA-256 on the partial file, and moves it into the
destination only after verification. Failed or interrupted downloads cannot
be mistaken for an installable DMG.

## M11-009: Drain update-tool diagnostics with a bounded runner

Zed keeps update work off the UI path and awaits each external operation as a
separate lifecycle step. Nimculus now uses one bounded process runner for
`shasum`, `curl`, `codesign`, `spctl`, `hdiutil`, and `rsync`: POSIX output is
drained non-blockingly while the process runs, retained diagnostics are capped
at 64 KiB, and the process is not allowed to block on a full pipe. This keeps
verification and installation bounded even when a tool emits unexpected
diagnostic output.

## M11-010: Make update cancellation and tool shutdown finite

Zed models updating as a cancellable asynchronous lifecycle, so a stalled
download must not prevent the application from closing. Nimculus now gives
`curl` one second to exit after cancellation and one further second after a
forced termination, removes both the partial and published destination, and
cancels an active download when the user quits. The bounded verifier/installer
runner also enforces a 60-second timeout for `shasum`, signature checks, DMG
mount/detach, and `rsync`, preventing an unresponsive external tool from
holding the macOS termination path indefinitely.

## M13-052: Fail cleanly when the Windows GPU backend cannot initialize

Zed's Windows platform startup treats GPU/device initialization as a
fallible boundary and does not continue with a partially initialized window.
Nimculus now releases render target, DirectWrite, pipeline, swap-chain, and
device resources on each D3D11 setup failure and returns `false` from the
platform runner instead of entering the message loop without a renderer.

## M9-006: Bound Git process output before it reaches UI state

Zed compresses large commit diffs for presentation and applies explicit
limits before exposing process output to UI state. Nimculus now consumes Git
stdout/stderr through a non-blocking stream while the process is running,
keeps at most `MaxGitOutputBytes` (16 MiB), and records `outputTruncated`.
The retained suffix is cut only at UTF-8 and complete-line boundaries. This
applies to status, diff, log, blame, and command results, preventing a large
repository or generated diff from blocking on a full pipe or growing the
editor's memory without limit.

## M9-007: Drain and bound repository discovery

Zed gives each real repository a background executor, keeping Git work away
from window refreshes. Nimculus now drains Git stdout on every poll rather
than only after child exit, so a verbose status/diff command cannot deadlock
on a full pipe. Repository discovery uses the same `GitJob` lifecycle and
returns no repository after a two-second bounded probe, rather than calling a
blocking stream read from the macOS UI path. Tests cover a nonresponsive Git
binary and a one-megabyte stdout stream.

## M6-004: Invalidate lazy workspace entries at the filesystem event boundary

Zed's worktree scanner treats filesystem events as the boundary for updating
the in-memory entry snapshot and removes deleted entries instead of leaving
stale paths in the project model. Nimculus now removes the changed path and
all cached descendants from `Workspace.entries` when `changedPaths()` drains
the coalesced event set. The next lazy tree/search operation rescans the
affected path, which handles delete and rename events without retaining stale
entries or requiring a full workspace enumeration.

## M6-007: Bound workspace search results and ripgrep output

Zed's project search limits returned files and ranges and streams candidates
through bounded asynchronous channels. Nimculus now caps a search at 10,000
matches and caps the ripgrep temporary output at 32 MiB. When ripgrep exceeds
the output cap, its process is stopped and the safely readable prefix is
parsed; the cooperative fallback and search jobs use the same match cap.
The cooperative fallback reads files line-by-line rather than flattening a
whole file into memory. This prevents a broad query from retaining an
unbounded result sequence, file body, or temporary file while preserving
cancellation. The same temporary-file path is used on Windows; the portable
fallback must not use `execCmdEx`, whose all-at-once output buffer would bypass
the search limit in the Windows/WSL workflow.

## M6-008: Bound external search cancellation

Zed's project searches are asynchronous and cancellation is part of the job
lifecycle; cancelling a search must not wait for an uncooperative child
process. Nimculus now gives the macOS ripgrep process a one-second graceful
termination window, then sends a forced termination and waits one more bounded
window before closing the process. The same boundary is used when the 32 MiB
temporary output limit is reached. This prevents a cancelled or over-producing
search from blocking the Cocoa event loop indefinitely.

## M6-009: Keep macOS Worktree metadata off the Cocoa event loop

Zed keeps project/worktree discovery in asynchronous tasks rather than
running Git metadata commands inside window refresh callbacks. Nimculus now
uses the bounded temporary-file process runner for macOS `git worktree list`,
`rev-parse`, and `symbolic-ref` calls, with a 64 KiB output cap and a
two-second runtime limit. A failed, timed-out, or truncated metadata command
is omitted from the preview instead of blocking or publishing partial state.

## M10-005: Compact scrollback in batches without changing its public shape

Zed's terminal configuration passes an explicit maximum scroll history to a
deque-backed terminal implementation. Nimculus already exposes a sequence for
compatibility, so replacing the field type would be an unnecessary API break.
Instead, history now retains the newest rows and compacts in batches below the
configured limit. This keeps memory bounded and avoids repeatedly shifting the
whole sequence with `delete(0)` during long-running terminal sessions.

## M10-006: Queue partial non-blocking PTY writes

Zed sends terminal input through an asynchronous PTY channel, so a short
kernel write cannot discard the remaining bytes. Nimculus set the macOS PTY
master to non-blocking but previously returned the first `write` count and the
UI discarded it; a large paste could therefore lose its tail under backpressure.

Each macOS `TerminalPty` now owns a pending input buffer and byte offset.
`writeInput` accepts the full payload, drains immediately when possible, and
`pollOutput` drains the remaining tail on subsequent idle ticks. Terminal
protocol responses use the same queue. The queue is cleared during close, and
the native PTY integration test verifies that a large Japanese paste retains a
non-empty pending tail rather than being dropped.

## M10-007: Validate terminal launch configuration before fork

Zed resolves its shell command from the configured environment before it
creates the terminal subprocess. Nimculus previously let `chdir` and `execl`
fail only in the forked child. An invalid directory silently inherited the
editor process directory; a bare configured shell name such as `fish` could
also fail because `execl` does not search `PATH`.

The macOS PTY constructor now resolves non-absolute shell names with `PATH`
and validates both the executable and requested working directory before
forking. Invalid settings surface as a normal terminal creation error, while
configured `zsh`, `bash`, or `fish` names can use the standard shell path.

## M10-008: Drain PTY output to a bounded idle budget

Zed gives terminal I/O its own event loop, while Nimculus polls the macOS PTY
at the Cocoa idle boundary. One 8 KiB read per tick leaves high-volume build
output visibly behind. A short non-blocking read is not evidence that the PTY
has no more data, so stopping after one short chunk is equally incorrect.

`pollOutput` now drains successive reads until EAGAIN or a 64 KiB per-idle
budget. The budget keeps rendering responsive; the repeated reads prevent a
short PTY chunk from delaying ready output to later frames. An integration test
starts continuous output, synchronizes command acceptance, and verifies that
one poll returns more than a single 8 KiB chunk without exceeding the budget.

## M10-004: Bound task output like terminal output

Zed applies an explicit byte limit when exposing terminal output and preserves
UTF-8 boundaries while avoiding a partial final line. Nimculus applies the
same boundary to task polling: the in-memory task log keeps the newest output
within `MaxTaskOutputBytes` (4 MiB), trims at a UTF-8-safe line boundary when
possible, and records that truncation occurred. This prevents a long-running
build or test process from growing the editor's memory without limit while
keeping the existing task output and problem-matcher contract.

## M13-046: Keep Windows native editor state synchronized on tab lifecycle

The Windows text backend owns a copy of the active document and its highlight,
composition, selection, and cursor state. Creating a document or closing the
last tab must clear or refresh that native copy at the same application-boundary
point as macOS; otherwise the renderer continues to display the previous
document even though the editor model has changed. Settings keymap reload is
also enabled on Windows so the registry and platform shortcut normalization
observe the same live configuration contract.

## M13-049: Implement the Windows editor chrome contract

The Windows editor already receives cursor and text state through the native
boundary, but its line-number, tab, dirty, status, indent-guide, and soft-wrap
calls were still inherited from the headless backend. These calls now have
native storage and are rendered in a separate GDI editor-chrome pass, while
DirectWrite remains responsible for text and syntax runs. This preserves the
Zed-style separation between editor state and platform presentation without
making the application layer depend on Win32 drawing types. The
`nimculusPortableOnly` Windows build keeps the same API as safe no-ops so the
platform-selection boundary remains buildable without the Windows SDK.

## M13-050: Route Windows tab hit-testing before editor input

The Windows tab bar is painted by the native chrome pass, so tab selection
must be resolved at the same logical-point boundary before pointer events enter
the editor text hit-test. The application calculates the same bounded tab
geometry as the renderer and dispatches the existing `selectTab:<index>` command;
this keeps tab state mutation in the application layer, matching Zed's tab
component click dispatch, rather than duplicating session state in C.

## M13-051: Synchronize the Windows editor rectangle from NimNUI layout

The Windows native renderer previously used fixed editor coordinates even
though NimNUI recalculated the editor bounds after resize and split-pane
changes. Following Zed's layout/paint boundary, the application now sends the
logical editor rectangle to the native backend. DirectWrite, GDI fallback,
line-number, and indent-guide rendering consume that same rectangle after the
backend applies the current DPI scale. The native backend keeps only a bounded
default for startup before the first layout frame; it does not own editor
layout state.

## M2-021: Coalesce overlapping paint damage regions

Zed's renderer treats damage as a set of regions rather than replaying the
same paint command once per overlapping invalidation. NimNUI now coalesces
overlapping `PaintList.dirty` rectangles before command generation, while
discarding zero-area damage. The native backends therefore receive a smaller,
non-duplicated damage list without changing command clipping semantics.

## M13-052: Validate Windows package outputs before upload

Zed's release flow treats artifact creation and artifact validation as separate
boundaries. Nimculus now clears stale Inno Setup output before each Windows
package, rejects empty executables and ZIPs, requires exactly one non-empty
installer, and repeats the ZIP/installer checks in GitHub Actions before
uploading the artifact. This prevents a previous build's installer from
masking a failed current build.

## M2-020: Store layout specs per node and recurse through the UI tree

Zed's GPUI layout path computes a hierarchical layout tree rather than only
assigning bounds to a root's immediate children. NimNUI now keeps a
`LayoutSpec` on each `UiNode`; `layoutNode` uses the explicit spec for the
root and recursively applies each descendant's spec. This preserves the
existing root API while making nested Row/Column/Stack controls participate
in layout, clipping, and dirty-state propagation.

The same node-local spec is also synchronized with the existing preferred,
minimum, and maximum size fields used by parent allocation. This prevents a
declared fixed/min/max size from becoming metadata that the layout engine
ignores.
Root layout uses the same resolution path, so its containing bounds remain the
available space while an explicitly styled root size is still respected.
Updating a node style replaces its size constraints instead of merging stale
values from the previous style; an omitted maximum is normalized to the
finite internal default.

## M17-003: Add Zed-compatible process WIT capability incrementally

Zed's `since_v0_8_0/process.wit` defines `process.run-command` as a structured
record/result API, and Zed's `CapabilityGranter::grant_exec` checks the command
before spawning it. Nimculus exposes this import only when the extension
manifest grants `process`; filesystem-only Components do not receive the
process linker instance. The macOS host uses `posix_spawnp` with the extension
root as cwd, passes argv without a shell, merges manifest environment pairs
into the inherited environment, and returns bounded stdout/stderr plus an exit
status or signal state. Each stream is capped at 1 MiB and execution is capped
at 10 seconds. Unknown imports and `network` remain denied. The ABI is kept in
the local Wasmtime value definitions because the application dynamically loads
the optional C library and must still build without Wasmtime headers.

## M20-003: Measure input latency through the next presented frame

Zed's input-latency tracker records the first input received in a frame
interval, counts coalesced events, and reports a distribution instead of only
the final value. Nimculus records the first macOS event with
`mach_absolute_time`, samples it when the resulting Metal frame is committed
for presentation, and resets the pending timestamp. The macOS backend keeps
fixed 256-sample rings for both latency and events coalesced per frame. It
exposes sample/event counts plus recent average, p95, and maximum without
allocating during normal interaction. This avoids reporting input received
after the frame's input interval, preserves a useful regression signal, and
bounds the metric's memory cost.

## M20-002: Measure resident memory at the platform boundary

Zed's reliability loop observes resident memory rather than allocator-only
counts, because native GPU and OS resources are outside Nim's heap. Nimculus
now exposes a platform resident-memory query: macOS uses task_info, Windows
uses GetProcessMemoryInfo, and the headless/portable backend returns zero.
The M20 benchmark emits an idle_memory TSV sample through this contract.

## M20-001: Record Windows frame duration at successful Present

Zed records frame duration around the render/present boundary and keeps the
last presented value for diagnostics. The Windows backend now uses
QueryPerformanceCounter from the beginning of render_frame through a
successful DXGI Present, then stores the duration in the existing
PlatformMetrics.last_frame_time_ms ABI. Device-loss frames are not reported as
successful presents.

## M3-024: Include quantized subpixel variants in the macOS glyph atlas

Zed's glyph cache keys include the quantized subpixel origin in addition to
font, glyph, size, and scale. Nimculus now uses a 4x4 logical subpixel grid
and includes the Core Text font size in its key:
the shaped glyph origin is quantized before the quad is emitted, and the
corresponding fractional offset is applied while Core Text rasterizes the
atlas entry. This prevents a glyph raster generated at one fractional origin
from being reused at another origin, while retaining atlas reuse for identical
positions.

## M3-025: Make the shared glyph atlas key raster-complete

Zed's `RenderGlyphParams` hashes the font ID, glyph ID, font size, scale
factor, quantized subpixel variant, and rendering flags rather than using a
Unicode character alone. The shared NimNUI atlas previously keyed only on
`Rune`, which could reuse a Menlo/2x glyph for another font or scale. It now
exposes `GlyphKey` and `insertGlyphVariant`; the compatibility `insertGlyph`
API creates the default key. The key also includes glyph ID, emoji/color
status, subpixel rendering mode, and dilation so a ligature or color glyph
cannot alias a normal character raster. Platform code is responsible for
quantizing the fractional origin to the same 4x4 grid before insertion.

## M3-026: Keep macOS color emoji out of the monochrome glyph atlas

Zed uses a separate polychrome atlas for emoji. Nimculus's current Metal
glyph atlas is intentionally `R8Unorm`, so putting Apple Color Emoji into it
would produce a silently monochrome or missing glyph. The macOS text path now
detects emoji scalars, skips the monochrome atlas for that text update, and
renders the complete visible text through the existing Core Text RGBA texture
fallback. That texture is still uploaded and sampled by Metal. Normal text
continues to use the persistent glyph atlas; a future polychrome atlas can
replace this fallback without changing the editor contract.
The macOS platform contract exercises this path by generating an emoji sample
and checking that a texture exists while monochrome glyph rendering is
disabled.

## M3-027: Reject invalid glyph atlas tiles before mutating the shelf allocator

The shared atlas now rejects zero, negative, and oversized tile dimensions
before changing `nextX`, `nextY`, or `rowHeight`. This keeps a failed glyph
rasterization from corrupting subsequent placement and matches the defensive
allocation boundary used by Zed's atlas allocator.

## M13-052: Match Windows tab primary and auxiliary clicks to Zed

Zed activates a tab from its primary click handler and closes an unpinned tab
from a separate middle-click handler. Windows now preserves that distinction:
button 0 activates the hit-tested tab, while button 2 first activates the tab
and then enters the existing application close-request path. Dirty tabs are
reported as unsaved and remain open; they are never force-closed by the native
tab bar.

## M13-047: Keep Windows command palette input at the native UI boundary

The Windows command palette uses a small native `EDIT` control rather than
making Win32 window types visible to NimNUI. Like Zed's picker, it owns focus,
IME text entry, Enter confirmation, and Escape dismissal, then emits one
`commandPalette:<query>` command through the existing callback. Command
resolution and task execution remain in the application layer, so this native
surface does not duplicate command definitions or process logic.

## M13-048: Reuse workspace search jobs on Windows

Workspace search and Quick Open are application-layer jobs, not macOS APIs.
Their previous rendering and polling guards accidentally made the Windows
search surface inert after the workspace preview was added. The Windows idle
boundary now consumes the same bounded search batches, rerenders the native
editor preview, and maps preview rows back to file or search-result locations.
Only the native input/presentation boundary remains platform-specific.

## M0-001: Use Nim standard tooling for the first quality gate

`nimpretty` is exposed through `nimble format` and `nim check` through
`nimble lint`. Both run without an additional package manager dependency and
the static check is part of the macOS CI gate. A third-party linter can be
added later only when it covers a demonstrated gap.

The macOS workflow installs Nim with Homebrew rather than the third-party
setup action because the latter failed before Build on the macOS-14 runner.
The successful workflow run is recorded in `ROADMAP.md`.

## M1-001: Keep the macOS bridge in Objective-C

The first macOS vertical slice uses Objective-C for Cocoa and Metal APIs and
exposes a small C ABI to Nim. This keeps Objective-C Runtime details and
framework ownership out of NimNUI and the application layer while the platform
contract is still evolving.

## M1-002: Use CAMetalLayer directly

NimNUI owns a `CAMetalLayer` through its macOS view. Drawable size is derived
from the backing scale factor during layout, so logical points and drawable
pixels remain distinct for Retina displays.

## M8-002: Bound LSP frames and foreground message bursts

Zed's LSP stdout handler caps the incoming message channel at 128 entries so
that a slow foreground consumer applies backpressure to the language server
instead of accumulating notifications without limit. Nimculus now retains
unconsumed complete frames in the incremental decoder, processes at most 128
per poll, and rejects headers larger than 64 KiB or frames larger than 16 MiB.
These limits bound malformed-server memory use while preserving partial-frame
and multi-frame protocol behavior.

## M8-001: Make LSP framing byte-accurate and generation-aware

The LSP foundation encodes `Content-Length` from the UTF-8 byte length of the
JSON body and decodes frames incrementally, because one pipe read may contain
partial headers, a partial multibyte body, or multiple messages. Requests are
tracked by method and generation; only the newest non-cancelled request for a
method may update editor state. This mirrors Zed's transport/store boundary
and prevents a slow completion or hover response from overwriting newer
document state. The process lifecycle and feature adapters remain outside the
codec and consume this contract. `LspProcess` keeps stdout separate from
stderr, writes through stdio with flushes, detects EOF/exit status, supports
explicit stop/restart, and reads only after pipe readiness. Its blocking read
is deliberately a worker-task API, never a UI or render callback API.
`LspSession` consumes the initialize response before sending `initialized`,
stores `publishDiagnostics` by URI, and tolerates a server that exits after a
final response so shutdown races do not turn a valid response into a protocol
error.

## M8-002: Parse standard LSP response shapes at the protocol boundary

Locations, hover marked strings, completion arrays/items, text edits, and
document symbols are converted from JSON before feature code consumes them.
The parser accepts the LSP alternatives that matter for these results (for
example completion array versus completion-list object) while keeping raw
JSON available for features that need additional fields. The request tracker
must accept the response first; a stale response is therefore never turned
into visible completion, hover, or navigation state.

## M8-003: Resolve diagnostics at the editor position boundary

LSP diagnostics use UTF-16 code units while the Piece Table and renderer use
UTF-8 byte offsets. `byteOffsetAtUtf16Position` walks Unicode scalar values,
clamps a position that lands inside a surrogate pair to a safe rune boundary,
and clamps beyond-line positions to the line end. Diagnostics are then stored
as byte ranges, matching the editor's existing edit and selection contracts.

## M8-004: Keep diagnostics separate from syntax spans

Diagnostics use a separate native span array and overlay texture path rather
than being merged into syntax highlight spans. This follows Zed's separation
between syntax styling and diagnostic decorations: a diagnostic update cannot
overwrite syntax colors, and a renderer can update underlines without
rebuilding the glyph atlas. The ABI carries UTF-8 byte ranges and LSP severity;
the macOS surface converts each visible range to Core Text units and draws a
severity-colored underline over the Metal editor surface.

## M8-005: Poll LSP stdout without blocking the UI

The macOS/POSIX transport obtains the child stdout file descriptor and reads
it in non-blocking mode. A generic `readStr(4096)` can wait for the entire
requested size after a short LSP response, which would stall AppKit input and
rendering. Readiness is therefore handled at the fd boundary, while the
incremental frame decoder remains responsible for partial headers and bodies.
The existing AppKit timer invokes the Nim idle callback so diagnostics arrive
even when the user is not generating input events.

## M8-006: Bind completion results to the cursor snapshot

Completion requests store the UTF-16 position and byte cursor used to create
the request. The session keeps accepted response payloads by request ID, and
the editor bridge consumes only the current completion request. A document
change cancels and hides the current menu before sending `didChange`; an old
response therefore cannot replace the menu for a newer cursor. The native
popup receives only display text, while acceptance computes a Unicode-aware
 word range in the Piece Table and applies one atomic edit.

## M8-007: Delay hover requests and invalidate by pointer position

Hover is scheduled only after the pointer remains on a buffer position for
five 50ms idle ticks. Moving the pointer cancels the pending request and hides
the current tooltip. The bridge compares the response's cursor snapshot with
the current target before exposing the text, matching Zed's hover state rather
than allowing a late response to appear beside a different symbol.

## M9-001: Keep Git CLI behind a cancellable repository service

Zed's Git integration separates repository operations and status parsing from
editor rendering, and uses porcelain status records plus explicit stage
operations. Nimculus follows that boundary in `git_service.nim`: the service
passes argument arrays to `git` instead of interpolating paths into shell
commands, parses `--porcelain=v1 -z` without losing rename/copy paths, and
represents conflicts from the index/worktree status columns. Mutating and
query operations return an explicit exit code, while longer commands can be
started as `GitJob` instances and terminated by the owner. Inline diff and
gutter rendering remain consumers of this service rather than being embedded
in process management.

Unified diff headers are parsed into old/new line ranges and added/removed
counts before the UI sees them. This mirrors Zed's `DiffHunkStatus` boundary:
gutter and inline rendering can remain incremental consumers, while staging
and checkout continue to operate through explicit repository commands.

The macOS editor resolves the Git repository from the file's owning workspace
root before scheduling a diff job. A secondary root therefore cannot
accidentally use the primary root's index, matching Zed's worktree/path
ownership boundary.

Hunk staging is implemented by extracting one unified hunk and sending it to
`git apply --cached` through stdin; unstage uses the same patch with
`--reverse`. This keeps the operation atomic at the hunk boundary used by
Zed, avoids shell interpolation of paths, and leaves the remaining hunks in
the working tree untouched. The macOS Command Palette exposes repository
status, all-stage, all-unstage, and commit-message commands on top of the same
service.

Log, current-line blame, and file checkout use the same Command Palette entry
point. Checkout reloads the active document only after Git reports success;
failed checkout leaves the editor buffer untouched. Status reports conflict
count separately so an unmerged worktree is not presented as an ordinary set
of modified files.

## M8-008: Navigate to LSP definitions through the editor bridge

Zed keeps definition requests asynchronous and ties the returned locations to
the request generation that initiated them. Nimculus stores the definition
request ID in `LspEditorBridge`, cancels it on document changes or a newer
request, and exposes locations only after the matching response is accepted.
The macOS Command Palette then decodes the file URI, opens the target through
the normal document path, and converts the LSP UTF-16 location with
`byteOffsetAtUtf16Position`; it never treats an LSP UTF-16 character as a
grapheme or byte column.

## M8-009: Apply LSP document formatting only to the current document version

Zed treats formatting as an asynchronous edit transaction and does not apply
the result after the buffer has advanced. Nimculus records the editor version
when it sends `textDocument/formatting`, cancels pending formatting on document
updates or close, and accepts the response only when that version still
matches. Each LSP UTF-16 range is converted against the current Piece Table,
then passed as one `applyEdits` transaction so overlapping or invalid UTF-8
boundaries fail atomically. The macOS Command Palette is the initial trigger;
formatting is not run implicitly on every keystroke.

## M8-010: Keep all LSP feature responses behind the bridge boundary

Zed keeps request generation, cancellation, and response decoding in the LSP
store instead of letting UI code inspect raw JSON. Nimculus now applies that
boundary to references, document symbols, rename workspace edits, code
actions, signature help, semantic tokens, and inlay hints. Each feature has a
request ID and is decoded only after the session accepts the corresponding
response; document close cancels and clears every pending feature request.
The decoded values are deliberately exposed as editor-domain data so later
UI work cannot accidentally depend on server-specific JSON shapes.

## M12-001: Layer settings before exposing them to platform code

Zed separates settings loading and validation from the UI and applies global,
workspace, and language overlays before consumers read a value. Nimculus uses
the same boundary in `settings.nim`: JSON files are recursively merged,
invalid values become diagnostics instead of crashing startup, and mtime-based
reload replaces the complete validated snapshot atomically. The macOS layer
currently consumes only terminal shell and LSP command values; keymap and
theme registry consumers remain explicit follow-up integrations. The current
background/foreground/accent values are converted at the macOS platform
boundary and applied to editor glyphs and terminal overlays. Keymap strings
are converted at the NimNUI command boundary rather than teaching the
settings loader about AppKit key codes.

## M8-011: Reuse a bounded result surface for initial LSP feature UI

Zed keeps asynchronous LSP results in feature-specific stores and renders
them through dedicated editor surfaces. Nimculus first connects references,
symbols, code actions, rename previews, signature help, and inlay hints to the
existing bounded Task Output overlay. This keeps response lifetime and stale
request handling in `LspEditorBridge` while leaving selection/apply UI as a
separate step; raw server JSON never crosses into the native platform layer.

## M10-001: Keep the PTY transport separate from the terminal screen model

Zed separates the PTY event loop from the terminal emulator state so process
I/O, resize, scrollback, and rendering can evolve independently. Nimculus
follows the same boundary: `TerminalPty` owns the macOS `forkpty` master,
non-blocking reads/writes, child lifecycle, and window-size ioctl, while
`TerminalScreen` owns ANSI/VT state, UTF-8 cells, cursor movement, visible
rows, and scrollback. The initial implementation deliberately accepts only
the basic CSI subset needed for the first vertical slice; unsupported control
sequences are ignored rather than rendered into the screen.

## M11-001: Make macOS packaging fail closed around signing and notarization

Zed's release bundling treats the application bundle as the signed unit and
creates distribution containers only after the bundle is valid. Nimculus uses
the same order in `scripts/package_macos.sh`: compile the selected Apple
Silicon or Intel binary, create the bundle, apply hardened-runtime signing,
verify it with `codesign --verify --deep --strict`, and then create ZIP/DMG
artifacts. Ad-hoc signing is available only with an explicit local-build
flag. A notarized build requires an identity and Apple credentials, staples
the app before rebuilding the containers, and validates both the app and DMG.

## M10-002: Treat tasks as cancellable process jobs

Zed keeps task specification (command, arguments, working directory, and
environment) separate from terminal presentation. Nimculus follows that
boundary in `task_service.nim`: a task owns its process, merged output, exit
status, and cancellation state, while a future terminal/output panel can
consume `TaskResult` without changing process control. Environment overrides
are merged with the parent environment, and nonzero exits remain distinct from
explicit cancellation.

The first UI slice exposes `run task <command>` and `cancel task` through the
macOS Command Palette and reports the terminal line of the completed result in
the status bar. The first terminal UI slice uses a non-editable AppKit overlay
above the Metal editor surface; input remains on the existing Metal view and
is forwarded to the PTY. This keeps process lifecycle and screen state
independent from editor text/IME state while allowing the overlay to be
replaced by a GPU-native terminal panel later.

## M9-001: Schedule Git actions outside the UI event handler

Git operations invoked by the Command Palette and gutter are scheduled through
`GitJob` and polled from the native idle callback. This follows Zed's
background task boundary: status, stage/unstage, commit, log, blame, checkout,
and hunk operations do not synchronously wait on the UI event handler. Hunk
actions first obtain the relevant diff, then submit only the selected patch;
document-bound hunk/blame results are discarded when the active buffer changes.
`startGitJobInput` is limited to small patch payloads and closes stdin before
polling process completion.

## M10-003: Keep terminal selection in cell coordinates

Following Zed's terminal model, selection is represented as an anchor and
active `TerminalPoint`, not as a byte range in the rendered string. The screen
model resolves points against visible rows plus scrollback, normalizes reversed
dragging, and produces clipboard text with terminal line boundaries. The macOS
overlay remains non-editable so keyboard input continues to the PTY; pointer
selection is captured by the existing Metal view and copied through the normal
NimNUI clipboard contract. DEC alternate-screen state is saved separately so
full-screen terminal applications do not destroy the normal shell history.
PTY instances are kept in an ordered session list with an active index. The
idle callback polls every live session so an inactive shell cannot fill its
master pipe, while only the active session updates the overlay. Creating and
switching sessions changes presentation state without sharing screen buffers.

Task output uses a separate non-editable AppKit overlay rather than replacing
the PTY screen state. Completed `TaskResult.output` is retained in Nimculus,
and `toggle task output` presents it without taking keyboard focus from the
Metal view. The two overlays share panel geometry but are mutually exclusive,
so terminal input cannot accidentally be sent to a task log.

The VT implementation stores SGR state on each `TerminalCell` and keeps cursor
movement, scroll-region, insert/delete, alternate-screen, application-cursor,
and bracketed-paste modes on `TerminalScreen`. This mirrors Zed's separation
between terminal content and mode state. Rendering currently exposes the
plain-text overlay path; retained cell attributes are the contract for the
future GPU-native terminal renderer. Wide glyphs use explicit leading and
continuation cells, while mouse modes produce DEC reports at the PTY boundary.
Hyperlink/kitty extensions and attribute-aware GPU rendering remain separate
follow-up work rather than being silently flattened into the current overlay;
the current AppKit overlay receives retained cell attributes as copied runs.

## Reference: Zed GPUI Metal implementation

Zed was cloned at `references/zed` for local, ignored reference use. The
current reference revision is recorded by the clone itself; the directory is
not part of Nimculus source control.

The following patterns are relevant to future NimNUI milestones:

- Keep more than one drawable available when appropriate instead of assuming a
  single-buffer swapchain (`gpui_macos/src/metal_renderer.rs`).
- Prefer build-time Metal shader compilation and packaged metallib data for
  production builds, with runtime shader compilation reserved for development.
- Use reusable instance-buffer pools for batched GPU primitives rather than
  allocating a new buffer for every rectangle.
- Drive frame requests from display timing (`gpui_macos/src/display_link.rs`)
  and treat display-link teardown as a lifecycle problem.
- Keep Cocoa window/event handling separate from the Metal renderer
  (`gpui_macos/src/window.rs` and `metal_renderer.rs`).

## M2-001: Transfer PaintList commands through a small native ABI

The first generalized rendering slice transfers `PaintList` rectangle commands
as a by-value C array to the macOS renderer. The platform layer owns a copied
command buffer, so Nim temporary sequences do not cross the callback boundary.
The ABI carries bounds and clip data from the start; the current Metal slice
renders rectangle bounds and uses clip regions as scissor rectangles. A
retained BGRA scene texture is updated with `MTLLoadActionLoad` and dirty
region background clears, then copied to the newly acquired `CAMetalDrawable`
with a blit pass. This is required because the drawable is a presentation
target, not the retained source surface. The first slice supports rectangle,
border, rounded rectangle, shadow, caret, selection, and scrollbar primitives;
text/image/clip/transform remain separate renderer work. This preserves a
direct path to batching without forcing Cocoa or Metal types into NimNUI's
core model.

## M2-002: Hit-test native pointer events before UI dispatch

The macOS callback converts native pointer coordinates into a `UiTree` target
before dispatch. Hover, active, and focus state transitions are applied at the
application boundary; the event retains native modifier flags and scroll
deltas so controls can consume them without another platform dependency.

## M2-003: Resolve clip regions in PaintList before crossing the ABI

PaintList owns a nested clip stack and intersects each command with both the
active clip and dirty regions. The native renderer receives the resulting clip
rectangle as a scissor region; it does not need to reproduce UI-tree clip
ownership or maintain a second stack.

Viewport activation checks both dimensions. A zero width or zero height is a
valid degenerate clip rather than an instruction to disable clipping; an
entirely zero-sized viewport remains the unset sentinel used by the current
layout API.

## M2-005: Preserve affine geometry across the native paint ABI

`PaintList` keeps both the transformed damage bounds and the original source
rectangle plus its cumulative affine transform. The macOS bridge receives all
of these values and applies the matrix to Metal vertices; it must not render a
rotated or reflected primitive as only its axis-aligned bounding box. Scissor
regions continue to use the transformed bounds as conservative damage clips,
matching Zed's separation of scene geometry from damage tracking.

## M2-004: Release focus when a focus path becomes disabled

Disabling a focused node or one of its ancestors clears the `UiTree.focused`
owner and the node's focused flag. This follows Zed's explicit focus-loss
model: a disabled view must not continue receiving keyboard routing merely
because it held focus before the state change. Pointer hit-testing and focus
traversal apply the same disabled-path rule.

## M1-003: Use an AppKit tracking area for pointer motion

`mouseMoved` is delivered only when the window accepts mouse-motion events and
the view has an active tracking area. The macOS bridge therefore owns an
`NSTrackingArea` with `InVisibleRect` and `ActiveInKeyWindow`, while drag
callbacks use the same input event ABI as ordinary pointer events.

## M3-001: Core Text for macOS shaping and atlas source

Core Text is the macOS-native shaping and font discovery boundary. Its line
and run metrics provide glyph counts and typographic bounds, while the first
atlas is rasterized into CPU memory and uploaded with `MTLTexture`'s
`replaceRegion` API. This keeps shaping/font fallback platform-native and
keeps Metal responsible for texture sampling and presentation.

Font availability is queried against Core Text's registered PostScript and
family name databases without invoking the shaping fallback constructor. An
unknown configured font must remain unavailable; fallback is applied only when
resolving a render run, following Zed's separation between font resolution and
glyph fallback.

The editor texture is rasterized in logical points under a CGContext scale
matching the current `backingScaleFactor`, then uploaded at pixel resolution.
This keeps Core Text coordinates stable while avoiding a low-resolution texture
being stretched on Retina displays.

The committed editor glyphs use a separate monochrome Metal atlas. Atlas keys
include the Core Text PostScript font name, backing scale, and glyph ID, so
fallback runs and Retina variants cannot alias one another. Glyph quads are
generated only for visible lines, while selection, caret, and marked text remain
in the transparent overlay texture. The atlas uses a bounded shelf allocator;
when the atlas is full, entries are discarded and visible glyphs are rebuilt,
which gives deterministic bounded memory rather than unbounded texture growth.

When a file has no registered grammar, the editor deliberately falls back to
plain text: the previous parser and highlight spans are released and the new
document is still sent to the native text surface. This prevents a tab switch
from retaining syntax colors or stale text from the previously parsed file.

The platform contract also includes a headless native atlas smoke check. It
uploads mixed Latin, Japanese, and emoji glyphs, then rebuilds the same visible
range and requires cache hits. This verifies the Metal/Core Text boundary
without claiming that GUI rendering or IME behavior has been manually
validated.

## M3-002: NSTextInputClient is the IME boundary

The custom `NSView` implements `NSTextInputClient`; marked text, committed text,
selection, and the candidate rectangle are forwarded through a C callback into
the Nim IME state. The editor buffer remains separate so composition does not
mutate committed text prematurely.

## M4-001: Piece Table for the first editor buffer

M4 uses an original/additions/pieces representation. Edits append to the
additions buffer and update piece boundaries, while line starts are rebuilt at
the edit boundary. Edit records store before/after text and both the
pre-transaction and post-transaction byte offset. This lets a multi-cursor
transaction undo against the shifted post-edit offsets and redo against the
original offsets even when earlier edits change UTF-8 byte length. UTF-8 byte
offsets remain the internal source of truth; grapheme and UTF-16 positions are
derived at API boundaries.

PieceTable validation and range extraction operate over piece descriptors.
They do not flatten the complete buffer for every edit, split, substring, or
line-index lookup. This preserves the intended 100MB-class editing path while
keeping byte-boundary validation explicit, matching Zed's offset-oriented text
storage contract.

## M5-001: Keep editor services independent of AppKit

File documents, tabs, splits, search/replace, session persistence, and recovery
are Nim services. AppKit only supplies the native menu and modal file panels;
file correctness and recovery remain testable without a GUI session.

M4 edit transactions validate all ranges and reject overlap before applying
any change. This preserves the atomicity contract for multi-cursor edits and
prevents a partially applied transaction from corrupting undo history.

M5 external-change detection treats deletion as a change, and session loading
accepts partial metadata so a damaged or older session file cannot crash
startup.

The native Save menu dispatches a semantic `save` command instead of opening a
panel unconditionally. Nim saves an existing document at its current path and
opens `NSSavePanel` only for an untitled document, keeping the platform menu
contract independent from document ownership.

Dirty state compares a saved content revision with the current content
revision, not the number of edit/undo operations. Undo and redo restore the
revision represented by their transaction, so returning to the saved content
clears the dirty indicator even though the operation counter has advanced.

## M5-002: Route native document actions through a narrow callback

The macOS delegate owns Cocoa menus and panels, but it reports only the
selected path and whether the action is opening or saving. Nimculus owns
`EditorSession`, document loading, and buffer mutation. This keeps AppKit
objects out of the editor core while making Open, Save, Finder `openFiles:`,
and IME committed text reach the active document.

## M6-001: Lazy workspace enumeration with cancellation

Workspace opening records the root and ignore rules without reading file
contents. Directory children and search are enumerated on demand and accept
a cancellation token. FSEvents is isolated behind a C callback bridge and
reports paths only; application policy decides how to refresh them.

## M7-001: Static, independently compiled Tree-sitter grammars

The initial six grammars are pinned as git submodules under `references/` and
compiled through a C ABI. Each generated parser is a separate translation
unit because generated symbols are not namespace-safe when concatenated.
This keeps grammar loading deterministic and avoids a runtime shared-library
trust boundary.

Both macOS and Windows CI checkout these submodules recursively before the
portable or release build. A local-only grammar checkout must not be required
for package smoke tests.

The Windows runner installs Nim through Chocolatey. The setup step locates the
installed `nimble.exe` under Chocolatey's tools directory (`C:\tools\Nim` on
the hosted runner) and appends that directory, plus the user Nimble bin
directory, to `GITHUB_PATH` because
Chocolatey's environment changes are not automatically visible to later GitHub
Actions steps.

The ConPTY C boundary declares the small Windows 10 API surface locally when
building with MinGW. The hosted runner's MinGW headers do not ship
`winconpty.h`, expose `HPCON`, or define the pseudoconsole thread attribute,
although the functions are exported by
`kernel32`; the declarations mirror Microsoft's `CreatePseudoConsole`,
`ClosePseudoConsole`, and `ResizePseudoConsole` contracts without requiring a
newer SDK header, and use the documented thread-attribute value.

Shutdown closes both application pipe handles before `ClosePseudoConsole`, then
waits for and terminates the child process. This follows Microsoft's warning
that leaving the output side open can make ConPTY shutdown wait indefinitely.
The child is stopped before release, and the release call runs on a worker with
a two-second wait bound because older Windows versions can still block the
close call while a console client disconnects.

The Windows ConPTY integration test waits for the initial `cmd.exe`
cursor-visible VT sequence before writing its first command. The prompt text is
not guaranteed to be present in the application pipe, so the VT readiness
sequence verifies the real input/output handshake without racing process
startup.
The test sends carriage return for Enter, matching the native Windows terminal
input contract.
After the readiness sequence it allows a bounded 250ms for `cmd.exe` to finish
installing its input reader before sending the first line.
The post-input poll is bounded to five seconds so slow hosted runners do not
turn normal ConPTY scheduling variance into a false negative.

## M6-002: Workspace operations stay path-confined

All create, delete, and rename operations resolve relative paths against the
primary workspace root and reject traversal outside it. Additional roots are
enumerated independently, while the primary root preserves relative paths for
stable editor and search identities.

## M5-003: Route native editing commands through the editor core

AppKit command selectors are converted into a small string command ABI. The
Nim application applies them to the active document, using UTF-8 codepoint
boundaries for cursor movement and deletion. This prevents Cocoa responder
objects from owning buffer mutation.

## M5-004: Keep New as an application command

The Cocoa File menu exposes `Cmd+N` but does not construct editor state
itself. It emits a narrow `newDocument` command; Nim creates a new
`FileDocument`, resets the view/syntax state, and keeps the document eligible
for the existing Save As path.

## M5-006: Convert pointer positions to editor grapheme boundaries in Nim

The native callback reports window coordinates, but the editor core owns UTF-8
byte offsets. Nim converts the bottom-origin AppKit Y coordinate to a logical
line and grapheme column, then resolves that column through the shared text
position helper. Pointer drag selection therefore cannot split a multibyte
character or grapheme cluster.

## M5-007: Route AppKit movement selectors instead of key-code guesses

The native text responder forwards `move*AndModifySelection:`, word movement,
and word deletion selectors to the editor command ABI. This preserves macOS's
keyboard-layout and modifier interpretation in AppKit while keeping UTF-8
boundary decisions in the editor core.

## M5-008: Keep document Find as a native prompt with a narrow command ABI

The Edit menu owns the short-lived AppKit query prompt and sends only the query
through `findDocument:`. Nim performs the search and selection against the
active document, so search semantics and byte ranges remain testable without
AppKit.

Replace All uses the same boundary with a Unit Separator between query and
replacement. The UI is intentionally a single transaction through
`FileDocument.replaceAll`, so undo/redo can treat the operation atomically.

## M5-005: Resolve external changes at the application boundary

The editor service remains responsible for comparing file stamps. The macOS
application polls that contract from its main-loop tick and presents a native
Alert. Reload replaces the active document; Keep Editing advances the external
baseline without mutating the unsaved buffer.

## M3-003: Synchronize the IME candidate rectangle from editor state

The native view receives the current logical cursor coordinates from Nim after
buffer mutations. `firstRectForCharacterRange:` converts the editor's top-origin
logical Y coordinate into the bottom-origin NSView coordinate and returns a
zero-width insertion rectangle. Candidate positioning therefore follows
editor state rather than the transient `NSTextInputClient` selection range,
which is necessary for UTF-8 and Japanese composition.

## M3-004: Render marked IME text in the native text surface

Marked text is kept separate from the committed editor buffer. The native
platform bridge stores it independently and redraws it at the cursor with a
underline, while committed text continues through the normal editor callback.
This prevents composition updates from corrupting Undo/Redo state.

## M3-005: Convert editor byte ranges at the Cocoa boundary

The editor keeps UTF-8 byte offsets internally. The native text-input client
receives UTF-16 ranges, so the bridge converts selection bounds before
returning `selectedRange` or `attributedSubstringForProposedRange`, and
provides a bounded character-index approximation for hit testing.

## M3-006: Draw selection and caret in the text surface

Selection is converted from synchronized UTF-16 ranges to per-line rectangles
before Core Text draws each line. The caret uses the editor's logical point
and is rendered after text and marked composition, keeping editor state in Nim
while leaving pixel composition in the native renderer.

The grapheme boundary helper explicitly handles emoji regional-indicator
pairs and CRLF, in addition to combining marks, modifiers, and ZWJ sequences.

## M3-013: Keep macOS selection synchronization one-way at the AppKit boundary

Zed's common `InputHandler` exposes `set_selected_text_range` as a reverse
platform contract, but its macOS `NSTextInputClient` registration implements
the AppKit protocol's `selectedRange` getter and does not register a
`setSelectedRange:` selector. AppKit's `NSTextInputClient` protocol likewise
does not define that setter. Nimculus therefore keeps selection synchronization
one-way at this boundary: Nim updates the native `selectedTextRange` through
`platformSetEditorSelection`, while AppKit-originated IME replacement ranges
come back through the selection callback. Adding an ad-hoc Objective-C setter
would not be a supported AppKit callback and could create feedback loops.

## M3-014: Invalidate AppKit IME coordinates after editor movement

Zed calls `NSTextInputContext.invalidateCharacterCoordinates` after the
focused editor's geometry changes. Nimculus mirrors that boundary notification
after synchronizing scroll, cursor, and selection state, so macOS can recompute
the candidate window position after cursor movement, scrolling, or navigation.
The call is a no-op when no input context is active.

## M3-015: Clear native marked text when the document changes

Resetting only the Nim composition payload is insufficient because AppKit
keeps `markedText` and `markedTextRange` on the `NSTextInputClient` object.
Document open, reload, and new-document transitions therefore clear both the
Nim IME state and the native marked-text properties, matching Zed's explicit
`unmark_text` path and preventing stale composition from being reported for
the next document.

## M3-016: Normalize NSTextInputClient point coordinates from screen space

AppKit passes `characterIndexForPoint:` and
`fractionOfDistanceThroughGlyphForPoint:` points in screen coordinates. The
native bridge now converts screen → window → view coordinates before invoking
the editor hit-test, following Zed's `screen_point_to_gpui_point` boundary.
`firstRectForCharacterRange:` continues to return screen coordinates as
required by the protocol.

The first-rect implementation also uses the requested UTF-16 range's start
offset to compute the line and Core Text glyph x-position, rather than always
returning the last synchronized cursor position.

All AppKit-provided UTF-16 ranges are bounded with subtraction-based length
clamping before `NSMaxRange` is evaluated. This avoids integer wraparound for
malformed or `NSNotFound`-style ranges at the native boundary.

The optional `attributedString` selector returns committed document text, not
the transient marked composition; this follows the AppKit protocol contract.

Editor Core Text paths use Menlo when available and fall back to the system
font through `CTFontCreateUIFontForLanguage`. This keeps measurement, hit-test,
and texture generation valid even when the preferred font is unavailable.

## M2-011: Keep interaction states orthogonal

Focus, hover, active, and disabled are stored as independent flags on each
`UiNode`. The legacy `state` field remains a visual-priority projection
(`disabled > active > focused > hovered > normal`) for existing render code.
This matches GPUI's separate focus/hover interaction lifecycle and prevents a
pointer move from erasing keyboard focus. Active pointer state is also cleared
on pointer-up even when the release occurs outside the original hit target.
Disabled nodes and descendants of disabled nodes are excluded from pointer
hit-testing, cannot acquire focus, and are skipped by keyboard focus traversal.

## M2-012: Resolve macOS shortcuts before AppKit text input fallback

`CommandRegistry` is connected to the native `keyDown` boundary through a
boolean shortcut callback. A registered shortcut is considered handled and is
not forwarded to `interpretKeyEvents:`/the IME; an unregistered shortcut keeps
the existing AppKit text-input path. This follows Zed's `handle_key_event`
contract, where a handled key event stops propagation while an unhandled event
continues through the native input context. The native menu remains the
key-equivalent owner for menu items, while the registry provides the same
semantic path for application-level shortcuts that do not have a menu item.

## M5-007: Start editor pointer selection only inside the editor viewport

Editor scrolling and pointer selection are gated by the top-origin editor
viewport rectangle. A pointer down outside that rectangle cannot move the
editor caret; after a valid down, the active drag continues outside the
rectangle until pointer-up. This mirrors GPUI's captured hitbox contract and
prevents toolbar, sidebar, and empty-window clicks from changing document
selection.

## M5-008: Normalize selections after document-size changes

Document-wide replacement can remove bytes beyond either endpoint, and a
replacement can end inside a previously selected grapheme cluster. The view
state therefore clamps both endpoints to the new UTF-8 length and floors them
to grapheme boundaries before native synchronization. This keeps editing,
status reporting, and `NSTextInputClient` ranges within one buffer snapshot.

## M1-004: Preserve precise macOS scroll deltas

The native input ABI carries AppKit's `hasPreciseScrollingDeltas` distinction.
Non-precise wheel events are interpreted as line units; precise trackpad events
are converted from pixels using the editor line height and accumulated until a
whole logical line is available. This follows Zed's `ScrollDelta::Pixels` /
`ScrollDelta::Lines` split and avoids dropping small trackpad movements.

## M3-017: Reset the native text surface when showing workspace previews

Workspace tree, search, and Quick Open reuse the editor's native text texture,
but are not the active document input handler. Each preview therefore clears
the native selection, caret position, scroll line, and marked composition before
uploading its text. This prevents a previous document's IME or selection state
from appearing in a different surface.

## M3-018: Keep Core Graphics text coordinates logical after Retina scaling

The editor texture allocates pixel dimensions (`logical size * scale`) and
then scales the CGContext by the backing scale. All baselines, selection
rectangles, marked text, and caret positions therefore use the logical editor
height, not the pixel texture height. This follows Zed's separation of logical
layout coordinates from scale-factor rasterization and keeps Retina text
inside the texture.

## M3-019: Pass editor text with an explicit UTF-8 byte length

The native editor surface receives `(pointer, byte length)` rather than a
NUL-terminated C string. A U+0000 byte is valid UTF-8 editor content and must
not truncate Core Text layout, hit-testing, or IME document coordinates. The
native side constructs `NSString` with `initWithBytes:length:encoding:` and
the platform contract includes a length-preservation test.

## M3-020: Verify the NSTextInputClient composition transaction at the native boundary

The macOS platform contract exercises the same composition sequence used by
AppKit: `setMarkedText:selectedRange:replacementRange:` receives a UTF-16
replacement range, forwards its UTF-8 byte bounds to Nim, and emits a composing
callback; `insertText:replacementRange:` forwards a committed callback and then
`unmarkText` emits the empty composing callback. The contract checks Japanese
text, UTF-16 marked-text length, UTF-8 byte ranges, and callback ordering without
requiring a physical IME on CI. This follows Zed's `InputHandler` separation of
marked text from committed buffer edits while keeping the AppKit marked-text
surface and editor document state independent. The smoke restores all global
callbacks and editor selection state before returning.

## M3-031: Return unhandled IME commands through AppKit selector dispatch

Zed's macOS window gives its input handler the first chance to consume keys
while composition is active or an IME input source owns a printable key. If the
handler does not consume the key, AppKit invokes `doCommandBySelector:` so it
can be resolved by the editor's normal keybinding path. Nimculus keeps the same
boundary: `NimculusMetalView` maps AppKit selectors to semantic editor commands
without committing or cancelling `markedText`. The native contract starts a
Japanese marked-text composition, checks left movement, backward deletion, and
cancel dispatch independently, then verifies that composition remains pending
until `unmarkText`. This makes IME fallback testable without claiming that a
physical Japanese input source has been exercised in CI.

## M12-034: Preserve the useful AppKit editing-selector set at the editor boundary

`NSStandardKeyBindingResponding` supplies selectors beyond simple arrow-key
movement.  In particular, AppKit defines forward word deletion, deletion to a
line boundary, and document-boundary movement with selection extension.  The
macOS bridge maps those selectors to semantic commands, and both primary and
secondary editor views apply them using UTF-8/grapheme-safe word boundaries and
the PieceTable line index.  This keeps Option-delete, Control-K/U-style line
deletion, and Command-Shift document selection in the same keymap/IME fallback
path as existing editor commands, without adding Cocoa APIs to the core.

## M10-024: Consume editor selectors while the integrated terminal owns input

The native Metal view remains the AppKit text-input client while the terminal
overlay is visible. Therefore an AppKit selector not explicitly handled by the
terminal used to fall through and edit the active source file. The terminal now
owns a pure semantic-command mapping: arrows, Home/End, page movement and
editing operations emit conventional VT/readline sequences; selection and
history-only editor commands are consumed with no bytes. The mapping is unit
tested separately from PTY I/O, so a visible terminal cannot mutate the editor
through an unhandled Option/Control selector. Option-left/right use readline's
`ESC b` / `ESC f` word-motion sequences, alongside the Option-delete mappings.

## M8-027: Apply accepted completion cursor state to the focused split pane

LSP completion requests already use the focused pane's cursor, but completion
acceptance previously advanced the primary editor view unconditionally. With a
shared document buffer this edits the correct bytes while leaving the focused
secondary pane's cursor stale. Completion acceptance now uses the existing
active-pane cursor helper, so replacement, cursor geometry, candidate rects,
and the next LSP request all remain in the pane that owned the request.

## M3-032: Keep cursor visibility local to each split-pane viewport

Primary and secondary editor panes share a PieceTable but not a viewport. A
completion, definition, or go-to-line operation in the secondary pane must
therefore adjust only that pane's scroll line. `ensureCursorVisible` now
combines grapheme-safe selection clamping with the line-index visibility rule,
and native synchronization applies it separately to both panes. This prevents
a valid secondary cursor from remaining outside its displayed viewport while
leaving the primary pane's reading position unchanged.

## M1-005: Initialize the Metal drawable on first window attachment

`viewDidMoveToWindow` calls the same backing-scale update used by layout and
Retina transitions. This guarantees `CAMetalLayer.contentsScale` and
`drawableSize` are initialized even if AppKit attaches the view before the
first layout callback.

## M2-013: Clear pointer capture on application deactivation

The macOS delegate reports `applicationDidResignActive` as a semantic
`windowFocusLost` event. Nimculus clears split dragging, editor selection
dragging, active state, and hover state together. This mirrors GPUI's pointer
capture lifecycle, where capture is released at the end of the interaction and
must not leak across a window-state transition.

## M6-005: Refresh the visible workspace tree independently of the editor

FSEvents changes refresh the workspace tree whenever the tree preview is the
active surface, even if an editor document remains open in the session. The
workspace view and the active buffer are separate state owners, matching Zed's
worktree entry updates and preventing stale tree contents after a root or
session transition.

## M5-008: Switch tabs without sharing editor transient state

The session owns tab buffers independently. Previous/next tab actions change
only `activeTab`, then reset the active editor's IME composition, view state,
syntax state, and native selection/caret synchronization. This follows Zed's
pane tab ownership: buffers remain intact while the active editor view is
rebound to the selected tab.

## M5-009: Persist editor view state per tab

Each `EditorTab` owns its selection, scroll line, and view preferences. Tab
activation saves the current view and restores the target view, while session
serialization stores the same state with bounds and grapheme clamping on load.
This follows Zed's item-owned selection/focus behavior and prevents changing
tabs from moving the cursor or viewport in an unrelated buffer.

## M5-010: Cmd-W closes the active tab before the window

The File menu's Cmd-W action requests an active-tab close. The native prompt
keeps Save / Don't Save / Cancel synchronous at the callback boundary; Nim
removes the tab only after a successful save or an explicit discard. An
untitled tab uses a Save Panel, while the title-bar close remains a window
close operation. This follows Zed's `Pane::close_active_item` contract and
avoids terminating a workspace when multiple tabs remain.

## M5-011: Cmd-Q resolves every dirty tab before termination

Application termination and the title-bar window close are intercepted before
AppKit exits. Nimculus reports whether any tab is dirty, then a native Save
All / Don't Save / Cancel prompt is used. Save All writes every dirty tab
(including sequential Save Panels for untitled tabs); termination is retried
only after all writes succeed. This prevents an inactive dirty buffer from
being lost when the active tab is clean.

## M6-004: Open folders through the existing file callback contract

The macOS open panel accepts both files and directories. The existing callback
passes the selected path unchanged; the application checks whether it is a
directory and opens a `Workspace`, while files continue through
`EditorSession`. This keeps Cocoa path selection out of the workspace service.

## M6-005: Poll search work from the main run loop

Workspace search is advanced in bounded batches by a 50ms Cocoa timer. Nim
receives only a command tick, polls `SearchJob`, and redraws the bounded result
view. This keeps search progress responsive without making the workspace
service depend on AppKit or a background-thread ownership model.

The Edit menu exposes cancellation as a separate command. Cancellation closes
the active stream, drops pending work, and leaves a cancelled status in the
search view instead of silently showing stale partial results.

## M6-006: Start and consume FSEvents with the Workspace lifecycle

Opening a folder stops the previous watcher, starts a new watcher for the
active root, and consumes coalesced changed paths from the same main-loop tick
used by search. The preview is refreshed only when no editor document is
active, so file notifications cannot overwrite an open document surface.

Each additional root owns its own ignore patterns and FSEvents stream. A
change in one root therefore cannot accidentally apply the primary root's
ignore rules or stop another root's watcher.

## M6-007: Route workspace mutations through relative-path commands

The macOS File menu exposes create-file, create-folder, rename, and delete
commands using workspace-relative paths. The application forwards these paths
to the existing root-confined Workspace API, so the UI bridge does not
duplicate path validation. Directory deletion intentionally uses the native
filesystem behavior and therefore requires an empty directory. Successful
mutations refresh the preview and restart the FSEvents watcher; failures are
reported through the editor status message.

The mutation API also rejects an empty relative path independently of the UI.
This prevents callers from treating the workspace root as a deletable or
movable entry while still allowing normalized descendants and rejecting paths
that escape the root.

## M5-009: Keep close confirmation in the native lifecycle

The application layer owns the authoritative dirty state and publishes it to
the AppKit bridge. `windowShouldClose:` and `applicationShouldTerminate:` use
the same native alert, while Save delegates the actual document write to Nim.
An existing path is saved directly; an untitled document uses `NSSavePanel`.
The bridge returns Cancel until the application layer explicitly reports a
successful save, so a failed save cannot silently close the document.

## M5-010: Persist session state in Application Support

The macOS application stores session metadata under
`~/Library/Application Support/Nimculus`. Startup restores existing tabs and
then restores the active recovery buffer when present. Untitled tabs serialize
their UTF-8 content, line-ending mode, dirty state, and view state directly in
the session file, so they are not silently lost on restart. A main-loop tick
writes the active dirty document to a separate recovery file, while a
successful save or an explicit Don't Save decision removes it. The recovery
file intentionally contains only the active buffer; the session file remains
the source of truth for tab paths, untitled content, and recent files.

Dirty named tabs also serialize their current buffer content and line-ending
mode. On restore, the file's current disk metadata is loaded first, then the
serialized dirty content is layered back over it without modifying the file.
This protects non-active dirty tabs if the process crashes before the normal
close confirmation can run.

If the named file has disappeared, become a directory, or cannot be read by the
time of restore, the serialized dirty buffer is still reconstructed with its
original path and marked dirty. This is the local equivalent of Zed's
`DiskState::Deleted`: the user's unsaved content remains available and a later
Save can recreate the path once the disk state is repaired.

External file presence is tracked independently from byte size. This preserves
Zed's distinction between a present zero-byte file and a deleted file, so
deletion alerts also work for empty documents.

Clipboard transfers use explicit UTF-8 byte lengths and a retained NSData
buffer for reads. Copy/Cut/Paste therefore preserve embedded U+0000 bytes
instead of passing document text through a NUL-terminated C string.

Core Text measurement exposes the same explicit UTF-8 byte-length boundary as
editor text upload. The legacy NUL-terminated wrapper remains for callers
whose input is guaranteed to be C-string text, while the editor-facing API
uses `nimculus_measure_text_utf8` so measurement cannot truncate a document.

Caret and selection changes rebuild only the Core Text overlay texture; text
changes, scrolling, scale changes, and syntax highlight changes rebuild the
glyph atlas as well. This keeps the Zed-style atlas cache out of high-frequency
cursor movement while ensuring retained-scene redraws never reuse stale caret
or selection pixels.

FSEvents watcher creation is transactional: allocation, path conversion,
stream creation, and stream start must all succeed before the watcher is
published. Failed starts release the stream and watcher immediately, matching
the ownership boundary used by Zed's filesystem event service.

Cross-axis `alignStretch` uses the available content extent before applying
the child's min/max constraints. A preferred cross-size must not silently turn
stretch into start alignment; this follows GPUI's flex layout contract.

The initial Tree-sitter outline service extracts declaration identifiers from
the declaration node's source range and retains the node kind separately. This
is a small local equivalent of Zed's grammar outline queries; the later LSP
document-symbol service can replace or enrich it without changing the
`OutlineItem` contract.

Committed editor glyphs use the Metal atlas as the primary text path. The
Core Text texture is kept as a transparent overlay for selection, marked IME
composition, and caret; it renders the full line only when atlas generation
is unavailable. This follows Zed's atlas-backed glyph rendering while keeping
a visible-text fallback for native-resource failures.

The explicit Don’t Save all-tabs exit path calls session persistence with
`preserveDirty = false`: dirty named tabs are recorded only by path and reopen
from disk, while dirty untitled tabs are omitted. This prevents a discard intent
from being reversed by the final `applicationWillTerminate` session write.

An explicit external-file Reload replaces the buffer but preserves the active
view's selection, cursor, scroll, and display settings, clamping only values
that no longer fit the new text. This matches Zed's reload behavior and avoids
turning an external edit into an unexpected navigation reset.

`recoverDocument` marks the reconstructed buffer dirty even though its text is
loaded as the original piece source. Recovery is therefore preserved until an
explicit save or discard decision, rather than being deleted as soon as the
first persistence tick runs.

## M5-011: Keep command palette actions on the existing command ABI

The initial macOS command palette is a native modal prompt rather than a new
overlay widget. It dispatches only commands already owned by the application
layer (new, save, find, workspace search, and cancellation), while Go to Line
uses a dedicated numeric command. This gives the palette real execution
semantics without duplicating editor behavior in AppKit.

## M5-012: Synchronize Open Recent as a copied native list

The Nim session owns recent-file ordering. The native bridge receives a copied
array whenever the session is restored or a file is opened, and presents it in
the standard File menu's Open Recent dialog. The bridge copies the UTF-8 paths
immediately, so the temporary Nim pointer array does not become retained
native state.

## M2-009: Use one layout result for native demo geometry

The demo UI sends the rectangle calculated by `UiTree.layoutNode` through the
PaintList and native UI rectangle bridge. The application entry point does not
override that geometry with a second hard-coded rectangle, preventing hit-test,
PaintList, and Metal output from diverging.

## M2-010: Exercise native paint kinds in the startup gallery

The startup gallery intentionally emits one retained PaintList containing the
basic native paint kinds and a nested clip region. The gallery geometry is
static for the initial 960x640 surface, while the platform layer remains
responsible for Retina scaling and drawable resizing. This gives the native
renderer one deterministic smoke scene without coupling the editor surface to
demo-only controls.

## M1-009: Rebuild UI geometry from AppKit resize metrics

The platform bridge reports changed point dimensions through the existing
command callback. NimNUI then rebuilds the demo tree and PaintList from those
dimensions, so hit-testing and native drawing share the same geometry. The
Metal layer remains responsible for pixel drawable resizing and Retina scale.

## M3-012: Share the editor viewport origin across native text paths

The editor stores a logical `scrollLine` in Nim. The native bridge receives
that line and renders only the corresponding bounded window of text, while
selection UTF-16 offsets and syntax byte spans remain document-relative. Nim
subtracts the same origin for cursor and IME coordinates and adds it for
pointer hit-testing, preventing viewport scrolling from changing document
positions.

## M6-008: Make the lazy workspace preview actionable

The initial workspace tree is rendered as a bounded text preview. Its visible
entries are retained separately from the rendered string and mapped from the
native bottom-origin pointer coordinate to the text line. Clicking a file uses
the existing document-open path; clicking a directory replaces the active
Workspace. Search output clears this mapping so stale preview rows cannot open
the wrong entry.

## M6-013: Add workspace roots through NSOpenPanel

Additional roots are selected with `NSOpenPanel` in directory-only,
multi-selection mode. Each selected absolute path is sent through the command
callback; Nim validates it as a directory, adds its own ignore configuration,
restarts the watcher set, and rebuilds the bounded preview. Root labels are
represented as actionable rows so the preview-to-path mapping remains exact.

## M6-014: Persist workspace roots with the editor session

Workspace roots are stored as absolute paths alongside tabs and recent files.
Only existing directories are restored, and the first valid root becomes the
active workspace while later roots are added before watcher startup. This
preserves the workspace topology without persisting transient file contents.

## M7-016: Derive Tree-sitter edits at the editor syntax boundary

The editor syntax service receives complete post-edit text but not an editor
transaction. It derives the smallest changed byte interval using common
prefix/suffix scanning, expands interval edges to UTF-8 boundaries, computes
Tree-sitter row/byte-column points, applies `TSInputEdit`, and parses with the
previous tree. This keeps the buffer API independent of Tree-sitter while
making the actual editor update path incremental.

## M7-018: Use the dedicated TSX grammar for `.tsx` documents

Zed registers TypeScript and TSX as separate languages, while sharing their
language-server context.  Nimculus follows that parser boundary: `.ts`, `.mts`,
and `.cts` select `typescript`, whereas `.tsx` selects the generated `tsx`
grammar.  The two generated grammars are compiled in independent C translation
units, so JSX parsing is available without weakening the plain-TypeScript
parser or introducing a runtime grammar loader.  The resulting grammar ID is
also the settings language ID, allowing a `languages.tsx` override to remain
separate from `languages.typescript`.

## M6-015: Use the bounded text surface for initial Quick Open

Quick Open sends its query through the native command callback and reuses the
Workspace fuzzy-search service. The bounded result list is stored as
`WorkspaceEntry` rows, so the same pointer-to-row mapping opens a selected file
or directory. This keeps the first vertical slice small while preserving the
search service's cancellation and root-aware path semantics.

Workspace search results use a separate row mapping because they carry a line
and column rather than a `WorkspaceEntry`. Clicking a result opens the
resolved file and moves the editor cursor to that byte position after the
document has loaded.

Workspace mutation boundaries use the canonical path of the existing target,
or the canonical parent plus basename for a new target. This closes the gap
where lexical `..` checks pass but a symlinked directory redirects create,
rename, or delete operations outside the workspace root.

The same logical editor bounds are also used for preview-row hit-testing, so
moving the text surface below a toolbar does not shift Workspace, Quick Open,
or search-result selection by the toolbar height.

## M6-003: Search yields cooperatively and streams file contents

The UI-facing `SearchJob` processes a bounded number of files and lines per
poll, preserves pending directory/file state between polls, and reads the
active file with `readLine` instead of loading the complete file. Cancellation
closes an active file immediately. The existing synchronous search functions
remain as convenience APIs, while application UI code must use the yielding
job for large workspaces.

## M3-017: Use Core Text offsets for editor cursor geometry

The native text surface converts editor UTF-8 byte offsets to UTF-16 indices,
then asks Core Text for the glyph offset with
`CTLineGetOffsetForStringIndex`. Selection rectangles use the same measured
offsets. This keeps cursor, selection, and IME geometry aligned for Japanese,
emoji, combining characters, and proportional fallback runs instead of
assuming a fixed eight-pixel character width.

The reverse path uses `CTLineGetStringIndexForPosition` and converts the
result back to UTF-8 bytes before the editor applies a pointer selection. The
same bridge is used by `NSTextInputClient` character-index queries, so native
IME services and editor pointer input share one text hit-test contract.

The native selection state is stored in UTF-16 units because Core Text and
`NSTextInputClient` consume NSString ranges. The Nim editor continues to own
UTF-8 byte ranges and the platform setter performs the conversion at the
boundary; this prevents astral characters and Japanese text from shifting
selection or composition positions.

## M3-018: Treat the editor rectangle as the text-surface contract

The text texture is sized from the current logical editor rectangle and
backing scale, then mapped to that same rectangle in the Metal pass. Nim sends
the rectangle after every layout, so window resize cannot leave text at a
fixed NDC position or stretch a stale 1024x256 surface over the editor.

All native text protocol coordinates are derived from the same editor
rectangle: cursor and text are local to the texture, while
`firstRectForCharacterRange:`, pointer hit-testing, and fraction queries add
or subtract the rectangle origin at the Cocoa boundary. This avoids an IME
candidate offset that only appears after the editor is placed below a toolbar.

## M2-011: Store flex and size constraints on UI nodes

Flex grow belongs to a child in Row or Column layout, not to the container's
layout specification. `UiNode` therefore stores flex grow plus preferred,
minimum, and maximum sizes. The layout pass first allocates preferred/minimum
extents, then distributes remaining space by flex weight and clamps the
result. A container with no child constraints retains equal distribution for
the initial gallery and existing callers.

The first split-pane vertical slice keeps the ratio in application state and
rebuilds geometry on pointer movement. The editor pointer path is suspended
while the split handle is active, preventing a drag from changing both the
split position and text selection.

## M2-012: Keep text and image resources separate from PaintList geometry

M2 keeps text and image commands lightweight: text remains a placeholder in
the generic PaintList because M3 owns Core Text and glyph-atlas rendering,
while images carry a stable `imageId`. The macOS backend accepts decoded RGBA8
pixels through `nimculus_platform_set_image_rgba`, owns the corresponding
Metal textures, and resolves the ID during rendering. Missing IDs retain a
deterministic placeholder, so layout and dirty-region behavior do not depend
on resource lifetime. This follows Zed's separation between scene geometry
and renderer-owned GPU resources. Affine transforms are applied in PaintList
before dirty filtering, keeping hit-test and repaint bounds in logical UI
space.

## M1-010: Keep a real Metal uniform binding in the first renderer

The initial rectangle shader receives a small `buffer(1)` uniform block. Its
opacity value is currently fixed at `1.0`, but the binding is real and is
consumed by the fragment color path. This preserves the uniform-buffer
contract for later transforms, scale, and opacity without pretending that a
vertex-only buffer satisfies the M1 requirement.

## M5-013: Route Cocoa editor selectors through byte-based editor commands

`NSTextInputClient` reports navigation selectors in NSString semantics, but
the editor owns UTF-8 byte offsets. The bridge therefore emits semantic
commands (`moveUp`, line boundaries, document boundaries, newline, and tab),
and Nim resolves them through the existing buffer position helpers. This
keeps Cocoa selector handling out of the editor buffer while preserving
Unicode-safe movement.

Save callbacks use the same rule: file I/O exceptions are caught inside Nim
before returning through the C function pointer, and the editor status reports
the failure. No CatchableError is allowed to cross the Cocoa callback ABI.

`FileDocument.save` writes through the same-directory atomic-write helper used
by session and recovery files, and commits the requested path only after the
rename succeeds. A failed Save As therefore cannot silently retarget the
document to a path that was never written, and an interrupted save does not
leave a partially written target.

Session and recovery files use a same-directory temporary file followed by
rename. The temporary name includes the process id, and failures remove only
that temporary file. This gives startup recovery a complete previous file or
a complete new file, rather than a partially serialized JSON/text file.

The Untitled-document close flow uses the same success boundary: the native
Save Panel starts with close disallowed, and Nim enables it only after the
atomic document save returns successfully. A failed Save As cannot therefore
close the window while the document is still dirty.

The atomic helper copies the existing target's Unix permission set to the
temporary file before the rename. Replacing a file must not silently remove
the executable bit or other user/group access modes.

## M5-016: Include file identity in the external-change stamp

`FileDocument` records the filesystem `device/file` identity from Nim's
`getFileInfo`, in addition to existence, size, and modification time. Zed's
filesystem metadata keeps identity alongside mtime and length; the same
contract is needed here because an atomic replacement can preserve the byte
length and can fall within a filesystem timestamp resolution window. A changed
identity therefore raises the external-change state even when the other two
values match. The identity remains an opaque string at the editor boundary so
the core does not depend on a platform-specific integer width.

The atomic temporary path also includes a process-local sequence number. This
keeps consecutive saves from reusing one pathname while retaining the
same-directory rename required for atomic replacement.

## M6-008: Treat lossy FSEvents notifications as a root rescan

Zed's filesystem watcher marks `notify::Event::need_rescan` events separately
from ordinary path events. Nimculus now applies the same boundary to Apple's
FSEvents flags: `MustScanSubDirs`, user/kernel drops, wrapped event IDs, and a
changed root all enqueue the watched root rather than forwarding an
incomplete path list. The existing lazy workspace invalidates that root's
cached entries and rebuilds the visible tree/search view on the next main-loop
poll. `HistoryDone` is informational and is not treated as data loss.

The native watcher owns a Core Foundation copy of the root path so the
rescan callback remains valid for the entire stream lifetime, including
non-ARC Objective-C compilation modes.

## M8-006: Enforce LSP request deadlines at the session boundary

The request tracker already records a monotonic generation and start time,
but calculating expiry without acting on it leaves an unresponsive language
server's requests in memory and can leave the UI waiting forever. Each
`LspSession.poll` now expires requests after a configurable 30-second default,
sends the protocol cancellation notification, and removes the request from
the tracker. A timed-out initialize request fails the session because no
usable protocol state exists; a feature request is discarded while the
initialized session remains available for later requests.

This keeps cancellation and stale-response rejection in one session boundary,
matching Zed's separation between request lifecycle and feature presentation.

LSP process shutdown uses the same bounded-lifecycle rule: after SIGTERM, the
process is waited on for at most one second before the hard-kill fallback. A
language server must not be able to block the Cocoa close/quit path forever.

Git jobs use the same one-second termination boundary. `GitJob.cancel` first
requests normal termination, then hard-kills a process that remains alive;
the UI never waits indefinitely for a Git subprocess that is blocked on
stdin, a hook, or an external credential helper.

The same rule applies to tasks and terminals. Task cancellation uses the
bounded `Process` lifecycle, while the macOS PTY child receives a short SIGTERM
grace period and is then force-reaped with SIGKILL. This prevents a shell or
task from keeping the Cocoa close/quit path blocked indefinitely.

## Reference audit: Zed `858d317`

Before changing text and macOS rendering contracts, the implementation was
checked against the ignored local reference at `references/zed`:

- `crates/text/src/text.rs`: rope storage keeps byte offsets and checks UTF-8
  character boundaries when splitting or normalizing text.
- `crates/editor/src/display_map.rs`: display traversal and text inspection use
  Unicode grapheme segmentation rather than treating every byte or codepoint
  as a visual cursor unit.
- `crates/gpui_macos/src/shaders.metal`: device coordinates are derived from a
  named viewport size, with the Y direction made explicit at the renderer
  boundary.
- `crates/gpui_macos/src/events.rs`: NSEvent modifier flags are normalized into
  platform-neutral control/alternate/shift/command state before command
  matching.

Nimculus therefore keeps PieceTable offsets byte-based, applies UTF-8
character-boundary validation in the storage layer, applies grapheme
boundaries in editor navigation/display using the Unicode TR29 `graphemes`
package (`graphemes >= 0.12.0`), and converts AppKit coordinates once at the
platform boundary.
AppKit modifier flags are likewise converted by
`macOSModifiers` before shortcut resolution. Zed is used as an implementation
reference, not as an API compatibility target.

The AppKit event bridge preserves event class before NimNUI routing: left,
right, and other mouse buttons carry a button id; dragged events remain
pointer moves; and `flagsChanged` remains a modifier-change event. This
matches Zed's `PlatformInput` classification and prevents AppKit NSEvent type
numbers from falling through to the generic command path.

For NSTextInputClient, `unmarkText` is a state transition rather than only a
native drawing operation. It therefore sends an empty composing callback to
Nim, matching Zed's `InputHandler::unmark_text` contract and preventing stale
composition state after IME cancellation.

`setMarkedText:selectedRange:replacementRange:` also forwards the replacement
range. AppKit reports that range in UTF-16 units, while the editor buffer uses
UTF-8 byte offsets, so the native bridge converts the document range before
updating Nim's selection. This follows Zed's
`replace_and_mark_text_in_range` contract and avoids replacing the wrong text
when an IME supplies a range different from the current caret selection.

The same replacement-range contract applies to `insertText:replacementRange:`.
Some input sources commit text with a replacement range without a preceding
marked-text update, so the native bridge forwards that range before forwarding
the committed text. UTF-16-to-UTF-8 conversion walks complete Unicode scalar
boundaries and clamps a malformed midpoint request before it can create an
unpaired surrogate. Native selection callbacks are then clamped to an editor
grapheme boundary before editing or deletion.

Untitled-document close is asynchronous at the Cocoa Save Panel boundary. The
initial close/terminate delegate callback must return cancellation while the
panel is open; after Nim reports a successful save, Cocoa explicitly retries
the window close. A failed or cancelled save never retries it.

Retina scale is also an independent lifecycle event from bounds resize. The
AppKit view handles `viewDidChangeBackingProperties` and updates
`CAMetalLayer.contentsScale`, drawable pixels, metrics, and the Core Text
texture there. This follows Zed's `view_did_change_backing_properties` path and
keeps a window moved between displays from retaining the previous monitor's
scale.

IME commits are event payloads, not an application history. Nimculus retains
only the latest committed string in `ImeState` and clears composition state on
document open, reload, and new-document transitions. This mirrors Zed's
InputHandler transaction boundary and prevents a long editing session from
retaining every committed IME string.

The AppKit tracking area also emits explicit enter/exit events. NimNUI keeps
those distinct from pointer motion so hover state is cleared when the pointer
leaves the view, matching Zed's separate mouse-exit platform event instead of
letting an exit event fall through to command routing.

Line navigation uses an exclusive byte offset immediately before the line
terminator. The editor buffer normalizes working text to LF, and the document
save layer restores CRLF only at serialization, so movement does not depend on
the on-disk line-ending format.

Option word movement classifies each extended grapheme as Unicode whitespace,
word text, or punctuation. It follows Zed's punctuation skip behavior while
keeping the storage and cursor offsets byte-based.

Workspace ripgrep integration uses NUL-delimited path/result records. A
colon-delimited parser is not a valid file-search protocol because both POSIX
paths and source text may contain colons.

The external search process is launched asynchronously on POSIX and its output
is redirected to a unique temporary file. Cancellation terminates the process
before the caller waits for completion, matching Zed's cancellable search-task
boundary.

Workspace ignore evaluation delegates Git-compatible pattern semantics to the
`gitignore` package's `IgnoreStack`, mirroring Zed's `ignore` crate. Each root
owns its own lazy stack so nested `.gitignore` files and negation precedence do
not leak between workspace roots.
Ignore-file FSEvents replace the affected stacks, matching Zed's update path
instead of retaining stale parsed patterns until restart.

Filesystem callbacks are treated as producer threads, not as UI state owners.
The workspace watcher appends under a lock, and the UI polling boundary drains
the queue under the same lock before applying a refresh. This prevents a
background FSEvents callback from racing with workspace rendering.

Editor navigation and deletion use the same `textPositions` boundary list as
layout and cursor conversion. UTF-8 codepoint boundaries are insufficient for
combining sequences and emoji ZWJ sequences, so Backspace/Delete and word
movement must never introduce a boundary inside one grapheme cluster.

Visible text ranges use that same boundary list. The renderer may still shape
each visible run independently, but it never starts or ends a run halfway
through a grapheme cluster.

The public editor line-column contract uses grapheme columns. Byte offsets are
kept for storage and are converted explicitly through `byteOffsetAtLineColumn`
or the private byte-column path used by UTF-16/LSP conversion. This prevents
vertical movement from passing a byte count as a grapheme column.

Following Zed's separation of rope byte offsets from Unicode segmentation,
PieceTable validates edit endpoints before mutation at UTF-8 char boundaries.
The UI cursor and deletion layer adds grapheme boundaries, while lower-level
buffer edits may represent a valid codepoint-level protocol edit. Replacement
text must always be valid UTF-8.

Pointer hit-testing follows the same viewport contract as painting: a node is
eligible only when the point is inside all of its ancestor bounds. This keeps
scroll-container content from receiving events after it has been clipped.

AppKit `NSView` input points are bottom-origin while NimNUI layout rectangles
are top-origin. The platform boundary converts the Y coordinate once before
UI hit-testing and event dispatch; editor text callbacks retain their own
native coordinate conversion because they also account for the editor rect
and scroll line.

Workspace paths are owned by an explicit root. This follows Zed's
`ProjectPath { worktree_id, path }` model: `WorkspaceEntry.rootPath` remains
the owning root and `relativePath` remains relative to that root, while
search results expose an absolute `path` for opening. Root-sensitive file
operations therefore use `createFileAt`, `createDirectoryAt`,
`deleteEntryAt`, and `renameEntryAt`; the older operations remain convenience
wrappers for the primary root. This prevents a secondary root from being
silently redirected to the primary workspace.

On macOS, a Files-panel removal is a move-to-Trash operation rather than an
irreversible `removeFile`/`removeDir` call. The Nim `Workspace` first resolves
the requested path within its owning root and rejects the root itself; only
then does the macOS platform adapter call `NSFileManager`'s
`trashItemAtURL`. This preserves the common validation boundary for UI,
menus, and shortcuts while using the platform's recoverable file lifecycle.

Focused-pane tab navigation follows Zed's `Pane` ownership: previous/next tab
updates only that leaf's selected item. The primary `EditorSession.activeTab`
is still the document-store bridge for the first pane, but it is never used as
the selection source for a focused secondary pane. This keeps tab navigation,
the secondary text overlay, IME context, and per-document secondary view state
on the same pane-local document.

## M6-016: Coalesce filesystem changes before UI invalidation

Zed's worktree scanner publishes an `UpdatedEntriesSet` after reconciling
filesystem events with a new snapshot; consumers do not process every raw
watcher callback independently. Nimculus keeps the lightweight FSEvents bridge,
but applies the same boundary in `Workspace.changedPaths`: callback paths are
drained under the existing lock, normalized, deduplicated in arrival order, and
only then consumed by the UI. This prevents an FSEvents burst from repeatedly
rebuilding the preview or restarting search for the same path.

## M6-017: Invalidate workspace search on filesystem changes

Zed associates search results with the current worktree state. Nimculus's
cooperative search job is therefore cancelled and restarted when the watcher
drain reports a change, including when the previous job has already completed
but its search view remains visible. Partial results are cleared before the
restart, so stale matches are never presented as current. Quick Open retains
its query and re-runs fuzzy matching on the updated workspace entries.

## M6-018: Make Quick Open cooperative

Zed's tab/file finders consume project candidates from asynchronous worktree
and fuzzy-search tasks rather than blocking the window while walking a project.
Nimculus now uses `FuzzySearchJob` for the macOS Quick Open path. Directory
enumeration and candidate matching are advanced in bounded timer polls, with a
cancel token on Workspace switches, document opens, new queries, and watcher
invalidations. The existing synchronous `fuzzyFileSearch` API remains as a
library convenience, while the application path uses the non-blocking job.

## M6-019: Cancel stale search jobs at every workspace-view transition

Zed's project search replaces the pending search task when the query changes
and does not let an older result stream update the current search view. Nimculus
applies the same ownership rule to the macOS application boundary: switching
workspace, switching between Workspace Search and Quick Open, and clearing a
query all cancel and clear the previous job before changing the active view.
This is required because `SearchJob` retains the `Workspace` it is traversing;
otherwise a result from a previous root could be rendered after a workspace
switch.

## M6-020: Preserve one ripgrep result per matching line

Zed's project search streams matches as independent result records. The
previous `--null-data` invocation changed ripgrep's line model and could merge
multiple matches from one file into one payload. Nimculus now uses `--null`
only, parses the path NUL and result-line newline separately, and keeps the
path/text colon-safe. A same-file multi-match test protects this contract.

## M13-001: Keep platform value contracts separate from OS backends

Zed exposes a platform trait boundary while keeping Cocoa, Win32, and Linux
implementations in separate backend crates. Nimculus now follows the same
direction for its by-value ABI records: metrics, input events, paint commands,
diagnostics, terminal runs, and callbacks live in
`src/nimnui/platform/contracts.nim`. The macOS wrapper re-exports these types,
so a future Windows backend can implement the same behavior contract without
importing Cocoa or forcing macOS concepts into the core.

The C backend also exposes `sizeof` probes for every by-value contract, and
the macOS contract test compares them with Nim's `sizeof` results. This keeps
alignment and pointer-size changes visible before another backend is added.

## M13-002: Select a portable fallback backend before adding native Windows code

Zed selects a platform implementation at application startup while keeping
the GPUI/application layer independent of Cocoa, Win32, and Linux APIs.
Nimculus now selects the macOS backend only when compiling for macOS and uses
an explicit contract-only headless backend otherwise. The fallback is not a
Windows implementation; it is a build boundary that prevents non-macOS
compilation from accidentally importing Cocoa and gives each future native
backend a complete API surface to replace.

## M13-003: Start Windows with Win32, per-monitor-v2 DPI, and Direct3D11

Zed keeps its Windows window/message handling and Direct3D renderer in the
Windows platform crate. Nimculus follows that boundary in
`src/nimnui/platform/windows`: the first native slice registers a Unicode
Win32 window, runs the Win32 message loop, handles `WM_DPICHANGED` and
`WM_SIZE`, creates a D3D11 device/swap chain/render target, clears and presents
frames, and forwards basic keyboard/pointer/text events through the shared ABI.
IME, clipboard, file dialogs, ConPTY, and the full PaintList renderer remain
separate follow-up work. The DPI manifest/API choice follows Microsoft's
per-monitor-v2 guidance; a future installer must embed the manifest rather
than relying only on runtime fallback.

## M13-004: Keep Windows text clipboard and dialogs at the platform boundary

Following Zed's `gpui_windows` platform services, Nimculus keeps system
clipboard and file-picker calls out of the application layer. The Windows
backend converts the editor's UTF-8 bytes to `CF_UNICODETEXT` and back, and
uses Unicode common dialogs with stable UTF-8 return buffers. The native
Windows implementation remains independent from the macOS pasteboard and
panel code; richer clipboard formats and modern COM file-dialog options are
separate follow-up work.

## M13-005: Route Windows IMM32 composition through the shared text callback

Zed's `gpui_windows` handles `WM_IME_STARTCOMPOSITION` and
`WM_IME_COMPOSITION`, positions both the composition and candidate windows, and
reads `GCS_COMPSTR` / `GCS_RESULTSTR` from the IMM32 context. Nimculus follows
that contract: `ImmGetCompositionStringW` is converted to UTF-8 at the Windows
boundary and delivered through the existing `TextCallback`, with `composing`
set only for marked composition text. The editor reports its logical caret
position through a small platform hook; the Windows backend applies the current
per-window DPI before calling `ImmSetCompositionWindow` and
`ImmSetCandidateWindow`. This keeps IME state and text editing in the application
layer while keeping HWND/HIMC lifetime and coordinate conversion native.

## M13-006: Keep Windows font discovery and file drops at the platform boundary

Zed's Windows platform owns OS font and drag/drop integration rather than
exposing Win32 handles to GPUI. Nimculus follows the same boundary with
`EnumFontFamiliesExW` and `WM_DROPFILES`: font names are converted to UTF-8 and
sent through the existing font callback, while each dropped Unicode path is
converted to UTF-8 and sent through `FileCallback`. The current application
contract is path-based, so this is intentionally a small vertical slice; richer
drag-over state and shell metadata can be added only when the contract requires
them.

## M13-007: Isolate ConPTY handles behind the existing TerminalPty contract

Microsoft's pseudoconsole flow requires creating synchronous pipes before
`CreatePseudoConsole`, attaching the `HPCON` through
`PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` during `CreateProcessW`, and using
`ResizePseudoConsole` for later dimensions. Zed's Windows packaging also treats
ConPTY as a Windows-native dependency. Nimculus keeps these handles and process
lifetime rules in `windows_pty.c`, exposing only create/write/read/resize/close
operations to `terminal.nim`. This makes the protocol parser reusable while
leaving the Windows native terminal surface as a separate integration step.

## M13-010: Preserve the shared event-number contract on Win32

The application-side `nativeEventKind` intentionally consumes AppKit-compatible
event numbers for the shared input ABI. The initial Win32 slice used private
numbers for key and pointer messages, which would classify keyboard input as a
pointer event. The backend now maps Win32 messages to the same numbers used by
the common contract (`10/11` keyboard, `1/2/3/4/25/26` buttons, `5/6/27`
motion/drag, `22` wheel, `12` modifier changes), and emits focus changes through
the existing command callback. This keeps platform translation at the backend
boundary and adds regression assertions in `test_ui_text.nim`.

The Windows runner also executes `tests/test_windows_terminal.nim` against
`cmd.exe`, checking output delivery through the screen parser, resize state, and
close cleanup. The macOS test run only compiles the portable skip path because
ConPTY is inherently Windows-native.

## M13-009: Keep Windows terminal manager separate from macOS AppKit state

The existing macOS terminal manager also owns AppKit overlay layout, Git, task,
and LSP state, so broadening that conditional block would leak platform-specific
assumptions into the Windows build. Nimculus instead adds
`windows_terminal.nim`: it owns one Windows `TerminalPty`, polls it through the
Win32 idle timer, forwards `WM_CHAR`/selected virtual-key input, and sends UTF-8
screen text to the Windows platform overlay. The current overlay is deliberately
a bootstrap GDI surface; the terminal protocol and process lifetime remain
independent of the eventual GPU renderer.

## M13-008: Make Windows packaging a reproducible CI-owned pipeline

Zed's Windows bundle script stages the executable and its runtime artifacts
before producing archives and an Inno Setup installer. Nimculus follows that
shape with a PowerShell script that builds into a clean stage directory,
produces a versioned x64 ZIP, and invokes the checked-in Inno Setup definition.
The GitHub Actions Windows runner installs both Nim and Inno Setup and uploads
the complete `dist/windows` tree. The installer itself is intentionally not
claimed as verified until the Windows runner produces and inspects the artifact.

## M13-011: Keep Win32 window-state restoration in the native backend

Zed's `gpui_windows` keeps fullscreen restore bounds and window style state
inside its Windows window implementation. Nimculus follows the same boundary:
fullscreen, minimize, maximize, and restore are exposed as small platform
commands, while style flags, extended style flags, monitor bounds, and D3D11
render-target refresh remain private to `windows_platform.c`. This avoids
leaking Win32 state into Nimculus or NimNUI and preserves the existing
platform-contract approach.

## M13-016: Reuse the PaintList ABI for the first Direct3D primitive batch

Zed's `directx_renderer` receives a retained scene, uploads primitive batches,
and applies viewport/scissor state before drawing. Nimculus keeps the existing
`NativePaintCommand` ABI and adds a Windows-only D3D11 path: commands are copied
at the platform boundary, opaque rectangle-like primitives and registered RGBA8
images are converted to dynamic six-vertex batches, and runtime-compiled
shaders draw them with per-command scissor rectangles. Image bytes are retained
on the CPU and re-uploaded after device recreation, matching Zed's resource
rebuild boundary. Text commands remain deferred until the DirectWrite/glyph
atlas path is implemented, so this slice does not claim a complete Windows
renderer.

## M13-036: Register Windows image resources as D3D11 shader views

The Windows image API mirrors macOS `platformSetImageRgba`: it validates the
RGBA8 byte length, retains a bounded set of image records, creates a
`ID3D11Texture2D` and shader-resource view, and draws image PaintCommands with
a linear clamp sampler. CPU copies survive device loss, while the views are
released and rebuilt with the D3D11 device. Missing image IDs remain omitted
instead of displaying a misleading placeholder.

## M13-017: Recreate the Windows D3D device after device removal

Zed's DirectX renderer treats device removal as a recoverable lifecycle event:
GPU resources are released, the device/swapchain is rebuilt, and the retained
scene is uploaded again. Nimculus now checks `Present` for device-removed,
device-reset, and driver-internal-error results, releases the D3D11 target and
quad pipeline, recreates them, and keeps the copied PaintList commands intact.
This prevents a transient GPU reset from permanently leaving the window blank.

## M13-018: Preserve surrogate pairs at the Win32 text boundary

Windows may deliver supplementary-plane input as two `WM_CHAR` UTF-16 code
units. Zed keeps character input separate from key events and decodes the
platform text stream before handing it to the input handler. Nimculus now
buffers a high surrogate, joins a following low surrogate, and converts the
pair as one UTF-8 callback value; `WM_UNICHAR` is accepted for direct Unicode
code-point delivery as well. This prevents emoji and other non-BMP text from
being silently dropped by the Windows editor input path.

## M13-019: Connect Windows editor text before the GPU glyph renderer

Zed separates the platform input handler from the renderer's text resources.
Nimculus follows that sequencing on Windows: workspace preview and opened
document text reach the platform text surface, while the same callback updates
the editor buffer and IME caret coordinates. The initial surface was a bounded
UTF-8-to-UTF-16 GDI bootstrap; it is now backed by DirectWrite text layout on
the D3D11 swap-chain surface, with GDI retained only when the Direct2D target
cannot be created.

## M13-037: Draw Windows visible editor lines through DirectWrite

Zed's Windows text system keeps DirectWrite shaping at the platform boundary
and uploads its glyph resources alongside the DirectX renderer. Nimculus first
uses the corresponding DirectWrite/D2D boundary for the visible editor lines:
the swap-chain back buffer is exposed as a DXGI surface, Direct2D owns a
DirectWrite text format, and only the visible UTF-16 lines are drawn before
`Present`. Selection and caret are drawn in the same clipped target, and a
device-loss or target failure releases the D2D resources so the existing GDI
surface can remain a fallback. A persistent glyph atlas with per-run syntax
color and subpixel positioning remain later Windows renderer steps. Per-run
syntax colors are applied from the UTF-8 highlight spans below.

## M13-038: Preserve Windows syntax spans at the DirectWrite boundary

The application produces UTF-8 byte-based `NativeHighlightSpan` values from
Tree-sitter and semantic tokens. Windows retains those spans at the platform
boundary, converts each visible span's UTF-8 range to a UTF-16
`DWRITE_TEXT_RANGE`, and applies a Direct2D brush as the text-layout drawing
effect. This keeps syntax coloring out of the editor buffer and follows Zed's
separation between text layout runs and document storage. Spans are clipped to
the visible line and invalid ranges are ignored.

## M13-039: Keep Windows IME composition separate from committed text

IMM32 composition callbacks remain transient input: composing text is stored
in a separate UTF-16 platform buffer and rendered at the editor caret through
the DirectWrite layout with an underline. It is cleared on commit, cancel, or
document/preview reset. This follows Zed's marked-text boundary and prevents
IME composition from mutating the PieceTable before `GCS_RESULTSTR` is
delivered.

## M13-040: Consume Windows terminal runs at the native overlay boundary

The terminal screen already emits cell-derived `NimculusTerminalRun` records,
but Windows previously rendered only the flattened text and silently discarded
the run and selection APIs. Windows now retains the UTF-8 text and run records,
maps indexed/RGB/default colors (including inverse and dim), selects bold/italic
run fonts, paints run backgrounds, underline/strike-through, and paints the selected cell rectangle
before the text. This keeps the terminal parser and cell ownership in Nim while
making the existing GDI bootstrap observe the same attribute contract. A
DirectWrite/GPU terminal atlas remains separate follow-up work.

## M13-041: Route Windows task output to the native output overlay

Task execution already produces an accumulated output string and visibility
state, but Windows previously inherited no-op task-output platform functions.
Windows now stores the bounded UTF-8 output as UTF-16 and renders it in the
same bottom output surface when the terminal is not visible. Terminal and task
output remain separate application states, while both use the platform-owned
overlay lifecycle and invalidation boundary.

## M13-042: Preserve terminal cell coordinates and display width across the native ABI

Zed's terminal rendering consumes a cell grid with an explicit point and
wide-character spacer state; it does not infer terminal columns from UTF-8
codepoint counts. `TerminalCell.width` is therefore exported as `row`,
`column`, and `cell_width` on `NimculusTerminalRun`. The macOS text view keeps
using byte ranges for attributed text, while the Windows native overlay uses
the explicit coordinates and width for glyph, background, and decoration
placement. This prevents CJK/emoji glyphs from shifting subsequent runs and
keeps selection geometry aligned with the terminal grid.

## M13-043: Do not flatten Windows ConPTY cells before native rendering

The Windows terminal manager previously sent only `gridText()` to the native
backend, which made the run ABI implementation unreachable for the actual
Windows terminal. Its synchronization now mirrors the macOS cell-to-run
boundary: each visible non-continuation cell carries its byte range, row,
column, display width, SGR flags, colors, and hyperlink pointer. The native
Windows overlay therefore receives the same cell metadata that the parser
owns, while the text remains a bounded UTF-8 snapshot.

## M13-044: Keep Windows terminal pointer selection in the cell-grid owner

Windows platform input already reports pointer coordinates in logical client
space, but the Windows terminal manager previously handled only keyboard
events. The manager now owns terminal overlay hit testing, cell-point mapping,
mouse-report forwarding, drag selection, selection synchronization, copy, and
select-all. The pointer mapper reads native terminal font metrics rather than
assuming a fixed cell size, so settings changes keep hit testing aligned with
the rendered overlay. This keeps terminal selection semantics with
`TerminalScreen`, as in Zed, instead of teaching the Win32 renderer a second
selection model.

## M13-012: Normalize Win32 keyboard events before shared shortcut routing

Zed's Windows backend separates accelerator handling from character input and
does not let a consumed shortcut fall through as text. Nimculus now applies
the same boundary: Win32 virtual-key values are converted to the existing
AppKit-compatible key-code contract, the Windows Ctrl modifier is normalized
to the command modifier for standard application shortcuts, and consumed
control-key events suppress `TranslateMessage`. `WM_CHAR` and IMM32 remain the
layout-aware text path, so shortcut routing does not replace Unicode text
input. The Windows terminal receives canonical arrow/letter codes after this
translation.

## M13-013: Normalize Win32 pointer coordinates at the message boundary

Zed treats button and motion `lParam` values as client coordinates, while wheel
messages carry screen coordinates and must be converted with `ScreenToClient`.
Nimculus now keeps those paths separate and divides physical coordinates by
the current per-monitor scale factor before emitting the shared input event.
This prevents window-origin offsets and DPI scaling from corrupting hit tests,
dragging, and scroll anchoring.

## M13-014: Preserve Win32 pointer capture across drags

Zed captures the window on pointer down and tracks `WM_MOUSELEAVE`, so a drag
continues to receive movement and release events even when the pointer crosses
the client boundary. Nimculus now uses `SetCapture`/`ReleaseCapture`,
`TrackMouseEvent`, and maps X buttons and leave into the shared pointer
contract. This keeps split-pane/editor selection state from remaining stuck
after an out-of-window drag.

## M13-015: Do not resize the D3D11 target while minimized

Zed ignores `WM_SIZE` with `SIZE_MINIMIZED` and recreates the drawable when
the window receives its restore size. Nimculus now follows that lifecycle:
metrics are recorded, but `resize_render_target` is skipped for a zero-sized
minimized window. The normal restore `WM_SIZE` path then recreates the target.

## M13-020: Convert Windows editor pointer input through logical text boundaries

Zed keeps hit testing inside the text layout: a logical mouse position is
converted to a valid text index before selection state changes, and scrolling
is handled by the editor viewport rather than by the native window backend.
Nimculus applies the same boundary to the Windows GDI text bootstrap. Win32
already emits logical client coordinates, so the application maps them to the
editor viewport, clamps the visible line, estimates a fixed-width column, and
then floors to a grapheme boundary before moving the cursor. Pointer capture
continues the selection outside the editor rectangle, and wheel input changes
the editor line scroll with a bounded viewport range. The constants are
bootstrap renderer parameters; they must be replaced by measured DirectWrite
or GPU text-layout metrics when the final Windows text renderer is added.

## M13-021: Keep the Windows bootstrap text surface viewport-consistent

Zed's editor does not let the native window independently decide which text
is visible: scroll state, text layout, cursor, and selection are updated from
the editor state and then painted in the same viewport. The initial Windows
surface now follows that contract even before DirectWrite/GPU glyph resources
exist. The Win32 backend receives scroll line, cursor byte/line, and selection
updates, renders individual logical lines with `DT_SINGLELINE` (avoiding
`DrawTextW` word-wrap divergence), clips to the editor viewport, and paints a
fixed-width bootstrap caret and selection background. UTF-8 is retained only
at this boundary to map selection byte ranges to bootstrap codepoint columns;
the editor's grapheme-aware byte range remains authoritative. This makes
pointer selection and wheel scrolling observable without pretending that the
bootstrap metrics are the final Windows text layout.

## M13-022: Treat Win32 close as an application decision

Zed's Windows event handler invokes a `should_close` callback for `WM_CLOSE`
and destroys the window only when the application accepts the request. The
previous Nimculus path called `DestroyWindow` directly, which could lose dirty
documents and skip ConPTY cleanup. The Win32 backend now sends `quitRequest`
to the application and waits for `platformSetCloseDecision`. Nimculus rejects
the request while dirty tabs remain, closes the Windows terminal on an
accepted clean/save/discard path, and only then destroys the HWND. This keeps
the OS window lifecycle separate from document policy and makes the boundary
testable without embedding save dialogs in the Win32 backend.

## M13-023: Restore Windows session state before entering the message loop

Zed restores workspace and buffer state as part of application startup rather
than treating the first native window frame as an empty workspace. Nimculus's
Windows branch previously opened the current directory directly and skipped
session/recovery restore and initial editor synchronization. It now establishes
the persistence paths, restores session/recovery, chooses the restored workspace
root when it still exists, lays out the window, and synchronizes the active
document before `platformRun`. The Windows idle callback also persists session
and recovery state on the same bounded cadence used by the macOS path. This
keeps the platform backend responsible for messages while session ownership
remains in the application layer.

## M13-024: Detect Windows external edits without silent reload

Zed keeps disk-state observation separate from buffer mutation and requires an
explicit reload decision when an on-disk file changes. Windows did not have the
macOS FSEvents/alert path, so the active document could change on disk without
any visible indication. The Windows idle callback now compares the document's
recorded size/mtime stamp, reports a reload-or-keep-editing action for changes
and deletion, and leaves the in-memory buffer untouched. The existing
`reloadExternal` and `keepExternal` commands remain the mutation boundary.

## M13-025: Use a joined ReadDirectoryChangesW worker for Windows workspaces

Zed's worktree watcher reports filesystem changes into the project layer and
lets that layer coalesce and invalidate search/tree state. Nimculus keeps the
same application contract as macOS FSEvents: a Windows watcher owns one
directory handle per workspace root, watches recursively for file/directory
name, size, and last-write changes, converts relative UTF-16 names to UTF-8,
and calls the existing callback. `Workspace.changedPaths` remains the only
consumer-facing queue and performs deduplication and ignore-rule refresh.
Stopping a workspace cancels the blocking read, joins the worker, closes the
directory handle, and only then releases the watcher context. The Windows CI
watcher integration test exercises the end-to-end event path.

## M13-026: Consume Windows workspace changes at the idle/UI boundary

`ReadDirectoryChangesW` notifications are consumed from the Windows native
idle callback through `Workspace.changedPaths()`. A changed workspace
invalidates active search and Quick Open jobs, or rebuilds the bounded tree
preview when it is visible. This follows Zed's watcher-to-worktree event
boundary: reaching a queue is not completion; the consumer must invalidate
derived state before presenting it again. The active document disk-stamp check
remains separate because it reports a user-facing reload decision rather than
a workspace tree update.

## M13-035: Verify recursive Windows watcher mutations

The Windows watcher integration tests cover the complete mutation path rather
than only a single file creation: nested directory/file creation and writes,
rename, delete, and repeated writes are observed through `changedPaths`. Each
mutation phase drains the prior queue before making the next assertion, so a
stale notification cannot satisfy a later check. The repeated-write case also
asserts that the normalized queue exposes one path, matching the production
deduplication contract.

## M13-029: Keep Windows font settings at the native platform boundary

Windows font names are validated with `EnumFontFamiliesExW` before replacing
the native editor or terminal font. Font size is clamped to the supported
bootstrap range and used by the Win32 text surface; the editor line-height
query is also used by Nim-side visible-line, hit-test, cursor, and IME
coordinate calculations. This preserves Zed's separation between application
font settings and platform text layout while avoiding a Windows-only no-op
settings path.

## M13-028: Render Windows opaque PaintList shapes in the D3D11 pixel shader

The Windows backend keeps the existing `NativePaintCommand` ABI and uploads a
per-command quad with local coordinates, pixel size, radius, and primitive
kind. The shader applies a rounded-rectangle signed-distance boundary,
one-pixel border edge, and shadow alpha before the existing per-command
scissor. This follows Zed's Windows renderer boundary, where shape semantics
are encoded in GPU primitives rather than approximated by a CPU overlay.
Text and image resources remain deliberately separate follow-up work because
they require DirectWrite/glyph atlas and texture lifetime contracts.

## M13-034: Enable alpha blending for Windows shape primitives

Rounded and border shaders produce coverage alpha, and shadows intentionally
use reduced alpha. The D3D11 shape pipeline therefore owns a standard
source-alpha/inverse-source-alpha blend state and binds it for each PaintList
frame. Without this state, shader coverage would not affect the RGB render
target and the shapes would appear as opaque rectangles.

## M13-027: Convert Windows editor hit testing from grapheme columns

The Windows GDI bootstrap uses a fixed cell width only to estimate a visual
column. That estimate is passed to `PieceTable.byteOffsetAtLineColumn`, which
performs the authoritative grapheme-column to UTF-8 byte conversion. It must
not be passed to a byte-oriented boundary helper: a multibyte character,
emoji, or combining sequence would otherwise make clicks land before the
intended visual column.

## M13-030: Apply Windows font settings during startup and reload

Native font setters are invoked from the Windows settings application path,
startup initialization, and idle-time settings reload. Adding platform
functions without these application call sites would leave the feature
effectively unimplemented; keeping the call sites next to the macOS settings
flow makes the live-reload contract explicit.

## M13-031: Load Windows workspace settings from the restored root

Windows startup resolves the restored session root before constructing the
`SettingsStore`, then loads `<root>/.nimculus/settings.json`. Loading from the
process current directory would silently ignore project settings whenever a
session reopened a workspace elsewhere, leaving font and other workspace
configuration inconsistent with the visible project.

## M12-033: Switch workspace settings with the active workspace

Changing the active workspace updates `SettingsStore.workspacePath`, forces a
reload of the workspace layer, and reapplies platform settings. This keeps
folder-open and session-restoration behavior consistent with the selected
project instead of retaining configuration from the previous root. The
global settings layer remains unchanged.
## M13-045: Connect Windows task execution to the native task output

The Windows task path must not remain inside the macOS-only task service block.
The command palette resolves `run task <command>` at the application boundary,
then starts `cmd.exe /C <command>` through the shared `TaskService`, polls its
bounded output on the Windows idle callback, and sends that output to the native
Windows task overlay. Cancellation is explicit and is also performed before
window close. This keeps process execution and problem matching shared while
leaving output presentation platform-specific, matching the existing terminal
boundary and Zed's separation between command dispatch and platform rendering.

## M13-057: Keep Windows glyph raster data CPU-owned and atlas uploads device-owned

Zed's DirectX atlas treats the GPU texture and atlas tiles as device-lifetime
resources, while glyph rasterization remains a separate cacheable operation. The
Windows backend follows that boundary: DirectWrite produces bounded grayscale
`R8` rasters in a CPU cache, and a lazy upload places each raster into a padded
`R8_UNORM` D3D11 shader-resource texture. Repeated requests reuse the same tile
without another `UpdateSubresource` upload. Releasing or recreating the D3D11
device releases the texture/SRV and invalidates tile coordinates, but preserves
CPU rasters so the next frame can rebuild the atlas without rerasterizing. This
is an upload/lifetime contract only; glyph vertex generation, sampling, and
subpixel positioning remain separate follow-up work.

The upload path is now called from the Windows frame boundary for the visible
editor range (ASCII glyphs only). DirectWrite/D2D remains the visible fallback
for complex, colored, and highlighted text; plain ASCII glyphs additionally use
the R8 atlas pixel shader and quad path. This keeps shaping behavior unchanged
while making atlas sampling part of the normal frame. Plain ASCII shaped-run
submission is now implemented through `IDWriteTextAnalyzer::GetGlyphs` and
`GetGlyphPlacements`, preserving glyph IDs and advance/offset data before atlas
upload. Colored glyphs remain unimplemented. Plain ASCII glyphs now
quantize their device-space x/y origin to the same 4-way subpixel variants used
by the DirectWrite baseline offsets and cache key. This preserves fractional
placement through rasterization, atlas lookup, and sprite placement.

The Windows CI now also runs `tests/test_windows_native_smoke.nim`. It starts
the real Win32/D3D11 platform loop, invokes the idle callback after device and
shader creation, validates atlas upload, subpixel variants, and DirectWrite
shaping, then requests a clean quit. This prevents the normal contract suite's
headless skip from being mistaken for GPU resource verification.

## M13-058: Resolve Windows BMP glyph fallback through DirectWrite

DirectWrite's system fallback mapping requires an `IDWriteTextAnalysisSource`,
so the Windows backend provides a synchronous COM source with the text,
Japanese locale, left-to-right direction, and null number substitution. It
calls `IDWriteFontFallback::MapCharacters` before rasterizing a code point that
is missing from the configured editor face. The mapped `IDWriteFontFace` is
retained by the glyph-raster cache, and the fallback scale returned by
DirectWrite is included in the raster size key. This avoids treating a glyph
ID as globally unique when two font faces provide different outlines.

The R8 atlas path now accepts BMP, non-control, non-surrogate code points for
single-code-point fallback runs. Complex fallback shaping, surrogate pairs,
color glyphs, and BiDi remain on the DirectWrite/D2D path until their glyph-run
and color-text contracts are implemented. The contract and native smoke tests
verify that Japanese `日` maps to a non-primary font face and produces a
non-empty raster.

## M13-059: Shape a homogeneous Windows fallback run before per-codepoint fallback

The atlas path first tries the configured face for plain ASCII. For a line that
is not ASCII, it asks DirectWrite system fallback for the complete line and
uses `GetGlyphs` plus `GetGlyphPlacements` when the mapping covers the whole
line with one fallback face. The returned glyph IDs, advances, and offsets are
then rasterized with that same face and submitted to the atlas. If the line
contains mixed primary/fallback fonts, surrogate pairs, or another unsupported
case, the existing per-codepoint BMP path or the DirectWrite/D2D text path
remains in effect. The fallback scale is used both for rasterization and glyph
advance calculation, preventing subsequent glyphs from drifting horizontally.

The contract and native smoke tests now exercise a two-character Japanese
fallback run in addition to the single-glyph mapping test.

The frame path extends the same rule to mixed lines: it advances through
`MapCharacters`'s `mappedLength`, shapes each primary or fallback font run, and
keeps the run's font face attached to every raster-cache lookup. This avoids
using a primary-font glyph cache entry for a fallback outline and avoids the
horizontal drift that would result from treating a mixed line as one font.

## M13-060: Keep Windows color glyphs on the color-capable DirectWrite path

The monochrome atlas is `R8_UNORM`, so color emoji must not be rasterized into
it. Following Zed's `TranslateColorGlyphRun` path, the Windows backend now
constructs a surrogate-pair glyph run for the emoji fallback face and asks
`IDWriteFactory2::TranslateColorGlyphRun` whether color layers are available.
The contract accepts `DWRITE_E_NOCOLOR` because the installed fallback font may
not contain a color face; when an enumerator is returned, it must be safely
enumerable. The visible editor remains on DirectWrite/D2D for that run, which
preserves color. Conversion of COLR/PNG/SVG layers into a dedicated RGBA GPU
atlas is still tracked separately rather than discarding color information in
the R8 atlas.

## M13-062: Verify the Windows installer lifecycle in CI

Generating a non-empty Inno Setup executable does not prove that the package
can be installed. The Windows workflow now installs the generated artifact
silently into a runner-temporary directory, checks the installed executable and
uninstaller, then silently uninstalls it and asserts that the directory is
gone. This keeps the packaging gate aligned with the roadmap's installability
condition while avoiding a GUI launch in the headless runner.

## M13-061: Do not overlay an LTR atlas over DirectWrite BiDi layout

The Windows atlas sprite path is intentionally disabled for RTL code point
ranges (Hebrew, Arabic, presentation forms, and the supplementary RTL blocks).
Those runs stay entirely on the DirectWrite/D2D layout path, which owns script
analysis, visual ordering, and caret placement. This is required because the
atlas shaping helper currently submits `isRightToLeft = FALSE`; allowing it to
run for RTL text would draw incorrectly ordered monochrome sprites over the
correct D2D result. Full BiDi glyph-run extraction for the GPU atlas remains a
separate implementation item.

## M13-063: Feed DirectWrite script analysis into Windows glyph shaping

`GetGlyphs` and `GetGlyphPlacements` require a `DWRITE_SCRIPT_ANALYSIS` result;
passing a zero-initialized structure is not a valid substitute for script
analysis. The Windows backend now supplies a COM `IDWriteTextAnalysisSink`,
calls `AnalyzeScript`, and uses the returned script when shaping ASCII and
homogeneous fallback runs. If one run spans inconsistent script analyses, the
atlas path declines it and the existing DirectWrite/D2D renderer remains the
authority instead of producing an incorrectly shaped sprite sequence.

## M13-064: Exercise Win32 input and resize through the native smoke window

The Windows native smoke test now installs an input callback and sends real
Win32 messages to the created window: focus, mouse move, left-button capture
and release, screen-coordinate wheel input, keyboard down/up, and a restored
resize. The native contract checks that the shared input counter advances, the
capture is released, and the drawable metrics remain valid. This validates the
message-to-NimNUI boundary in the same run that validates D3D11 text resources,
rather than treating window creation alone as GUI verification.

The same interaction smoke sends `WM_CHAR` for an ASCII character and a
surrogate pair, plus `WM_UNICHAR` for a supplementary code point, and checks
that the text callback receives all UTF-8 events and that `WM_UNICHAR` returns
the handled result.
This covers the Win32 UTF-16 boundary without depending on a physical
keyboard or IME being attached to the CI runner.

## M13-065: Verify visible Windows glyph sprites from editor text

The native smoke test now installs the mixed text `office 日本` before the
window loop starts. After D3D11 and the atlas are ready, it calls the same
visible glyph sprite routine used by `WM_PAINT` and requires at least one
sprite draw. This closes the gap between testing an isolated cached `A` tile
and testing editor text, run mapping, shaping, atlas upload, and sprite
submission together.

## M13-066: Keep COLR layers in a separate RGBA atlas

`IDWriteFactory2::TranslateColorGlyphRun` returns the legacy
`DWRITE_COLOR_GLYPH_RUN` structure, where each enumerated run is a colored
COLR layer. The Windows backend rasterizes each layer's alpha mask with
`CreateGlyphRunAnalysis`, composites the layer colors into a CPU straight-alpha
RGBA buffer, and uploads that buffer to a separate `R8G8B8A8_UNORM`
texture. The color sprite uses the image shader, while ordinary glyphs keep
using the R8 atlas. This follows Zed's separate color-glyph path and prevents
color emoji from being converted into monochrome coverage. The newer
`DWRITE_COLOR_GLYPH_RUN1` formats (PNG/SVG/advanced color) remain delegated to
DirectWrite/D2D until the Factory4 path is introduced.

The Windows native smoke test now includes an emoji and validates the color
atlas when the installed fallback exposes a COLR face. `DWRITE_E_NOCOLOR` is
accepted as a valid environment-dependent result, so the test remains useful
on runners whose installed emoji fallback is monochrome or non-COLR.

## M13-067: Classify Factory4 color formats before choosing a renderer

Zed's Windows renderer branches on `DWRITE_COLOR_GLYPH_RUN1` rather than
assuming that every color run is a COLR layer. The backend now optionally
queries `IDWriteFactory4` and requests COLR, SVG, PNG, JPEG, and
premultiplied BGRA32 formats. Each enumerated run is checked for exactly one
known image format. COLR continues through the dedicated RGBA atlas; PNG,
SVG, JPEG, and premultiplied bitmap runs remain on DirectWrite/D2D until their
bitmap/SVG raster upload path is implemented. If Factory4 is unavailable, the
Factory2 COLR path remains the compatibility path.

The native contract test exercises this classification with a surrogate emoji
and accepts `DWRITE_E_NOCOLOR`, while rejecting null enumerator runs, unknown
formats, and failed enumeration. This prevents a future advanced-color atlas
implementation from silently treating an image run as a monochrome outline.

## M13-068: Decode PNG and JPEG glyph images before GPU atlas upload

The Factory4 path can expose bitmap glyphs as PNG or JPEG data rather than
COLR layers. For that case the backend queries
`IDWriteFontFace4::GetGlyphImageData` at the requested pixels-per-em, scales
the intrinsic image size with WIC when the font returns a different native
size, converts it to straight-alpha
32-bit RGBA, and stores the image origin from `DWRITE_GLYPH_IMAGE_DATA` in the
same color-raster cache used by COLR. The existing image pixel shader then
uploads and draws the resulting texture tile. The glyph-image COM context is
released immediately after copying, and the WIC factory is released with the
Windows platform lifecycle.

SVG remains on DirectWrite/D2D because its vector semantics require a separate
renderer path. JPEG uses the same WIC decode and atlas path as PNG.
Premultiplied BGRA32 is returned as raw pixels, so the backend converts BGRA
premultiplied samples to straight-alpha RGBA before atlas upload and
un-premultiplies only when alpha is nonzero. Bitmap color rasters use the same
cache-hit contract as COLR rasters: a cached raster returns success without
re-decoding or allocating a second atlas tile. The shaped fallback path keeps
DirectWrite's UTF-16 cluster map and tests color candidates per glyph cluster,
so a line mixing ordinary text and emoji cannot suppress the ordinary glyphs.
`IDWriteFontFace2::IsColorFont` enables the full glyph-by-glyph probe for
COLR/CPAL fonts, while the Unicode candidate ranges retain SVG/PNG/JPEG
coverage because those formats are not implied by the COLR/CPAL flag.
RTL runs are left to DirectWrite/D2D, which owns bidi reordering. The native contract test treats
an absent PNG, JPEG, or premultiplied glyph as a valid environment-dependent
case, but validates decode/conversion, atlas upload, and tile metadata when the
corresponding fallback is present.

## M20-014: Classify AppKit smoke failures by execution boundary

The cold-start and soak gates are intentionally based on a real `.app`
bundle, a committed Metal frame, and normal application termination. A
sandboxed automation shell is not an equivalent macOS GUI environment:
launching `NSApplication` there can abort inside AppKit's
`_RegisterApplication` before Nimculus reaches its delegate or renderer. Such
an environment failure must be reproduced in a login GUI session or CI runner
before changing application code. The rendered-frame requirement remains
mandatory in both environments.

## M1-016 / M3-021: Verify native window states and mixed visible text

Fullscreen, minimization, and zoom remain AppKit window behaviors. Nimculus
sets the production window's fullscreen collection behavior and keeps the
standard responder actions in the Window/View menus; the renderer does not
simulate those transitions. The native contract also checks the active
monitor bounds and Retina drawable after resize.

The text-assets contract uses one mixed Japanese/symbol/emoji sample through
the Core Text texture and the glyph-atlas path. Color emoji continues through
the RGBA fallback while ordinary glyphs use the monochrome atlas. The actual
Metal frame gate remains the cold-start/soak smoke; manual IME, mixed-text
display, and physical multi-display checks remain environment-specific
acceptance work.

## M2-022: Make overlays behavioral controls, not enum placeholders

`ControlKind.contextMenu`, `popup`, and `tooltip` previously identified no
behavior beyond their enum values. The NimNUI overlay model now owns the
anchor rectangle, viewport-clamped bounds, requested placement with a
vertical flip, menu items, disabled/separator filtering, keyboard selection,
activation, and dismissal. Menus grab input and close on an outside click;
tooltips remain passive and close when the pointer leaves their anchor.

This follows Zed/GPUI's separation between anchored popup geometry and input
grab policy. The first implementation stays in-window and OS-independent;
AppKit-native popup windows are not required for the M2 contract. `PaintList`
receives the overlay background, border, selection, separator, and text
commands, while the platform renderer remains responsible for text shaping.

## M3-022: Split ordinary glyphs from color emoji in mixed lines

The previous macOS path returned from atlas generation as soon as a document
contained one color-emoji scalar. That made a mixed Japanese/ASCII/emoji line
fall back as one complete Core Text texture and did not exercise the intended
GPU split. The atlas path now inspects Core Text glyph-run string indices,
skips only glyphs backed by color-emoji scalars, and retains ordinary glyphs
in the R8 atlas. The RGBA texture masks non-emoji foreground glyphs when the
atlas is available, leaving the color-emoji runs as the fallback layer.

This follows Zed's separation of monochrome glyph atlases and color-glyph
resources while keeping Core Text responsible for macOS fallback shaping.
The native contract requires both assets for one mixed sample; actual frame
presentation and visual Retina/IME acceptance remain separate gates.

## M3-023: Classify macOS color glyphs by the resolved Core Text font

Unicode ranges alone do not classify every emoji sequence. In particular,
keycaps combine an ASCII digit or symbol with Variation Selector-16 and
`U+20E3`, and joined sequences may be represented by one color-font run. Zed's
macOS text system marks a shaped glyph as emoji from the resolved
`AppleColorEmoji` or `.AppleColorEmojiUI` font rather than from a scalar list.

Nimculus now uses that same Core Text run boundary for the main decision:
ordinary runs are rasterized into the R8 atlas, while color-font runs remain
in the RGBA Core Text fallback texture. The previous Unicode scalar classifier
is retained only as a defensive fallback when filtering individual atlas
glyphs. The native mixed-text contract includes a ZWJ sequence, a supplementary
emoji, and a keycap, and requires both rendering assets.

## M1-017: Treat a new Metal target as a full retained-scene rebuild

The macOS renderer keeps a scene texture and applies damage rectangles to it
before copying the result into each `CAMetalDrawable`. A damage list is valid
only when that scene already contains a complete previous frame. When the
drawable size changes, the Metal device changes, or the first frame is being
rendered, the target is new; clearing only the damage rectangles and replaying
only those commands would leave the rest of the frame blank.

The renderer now resets the retained-scene state for size/device changes and
uses a single `sceneNeedsFullRebuild` decision for the background, PaintList,
glyph atlas, and Core Text overlay passes. Partial scissor rendering remains
available only for an initialized scene with a non-empty damage list. This
matches Zed's boundary between a reusable render target and a newly allocated
target, and the native contract covers all four initialization/damage
combinations.

## M1-018 / M3-024: Fail closed for a GUI-capable macOS runner

Zed's visual-test platform combines real Metal rendering with deterministic
test execution, rather than treating a headless unit test as evidence of a
native frame. Nimculus keeps the portable tests permissive for terminal-only
development environments, but its GUI self-hosted workflow explicitly sets
`NIMCULUS_REQUIRE_NATIVE_GUI=1`. In that mode the Cocoa window lifecycle,
clipboard, Metal device, glyph atlas, and mixed Japanese/emoji text-asset
contracts must succeed; they cannot silently downgrade to a skip.

The requirement is deliberately limited to the interactive self-hosted
workflow. GitHub-hosted runners continue to run the same broad test suite and
cold-start/soak frame gates, while the GUI runner supplies the stronger
AppKit-session evidence without executing untrusted pull-request code.

## M3-025: Build the glyph pipeline for native text-asset validation

The color-emoji fallback contract must prove that an R8 glyph atlas and an
RGBA Core Text texture coexist. The production glyph pipeline is normally
created during `applicationDidFinishLaunching`, but C-ABI platform tests
intentionally exercise text assets without leaving an application window
running. Without a pipeline, the test only exercised the all-Core-Text
fallback and could be silently skipped.

The glyph pipeline descriptor is now shared between application startup and a
native validation helper. The helper compiles the same Metal glyph shader only
when no production pipeline exists, then validates the ordinary-glyph atlas
and color-emoji texture together. This follows Zed's separate monochrome and
color-glyph resources while keeping the test independent of a persistent GUI
process.

## M3-026: Validate the complete NSTextInputClient composition boundary

Zed forwards marked-text replacement ranges, committed text, unmark events,
and character bounds through one InputHandler boundary. Nimculus validates the
same macOS contract with a Japanese document: marked text selects the correct
UTF-8 byte range from a UTF-16 replacement range; commit sends text before an
empty composition update; and cancellation sends an empty composing update
without manufacturing a committed edit.

The candidate-window rectangle is tested on an attached temporary NSWindow,
not a detached view, because `firstRectForCharacterRange:` must return screen
coordinates. The fixture restores text, selection, scroll, editor bounds, and
metrics after AppKit has detached the temporary view, so candidate validation
cannot contaminate subsequent Core Text hit-testing.

## M3-027: Rebuild and own text assets across Retina scale transitions

Following Zed's scale-factor update boundary, Nimculus validates a 1x → 2x →
1x transition with ordinary Japanese glyphs and color emoji. The RGBA Core
Text texture must double its device-pixel dimensions at 2x, the monochrome
glyph atlas must be recreated for the new raster scale, and a second 2x frame
must reuse its atlas entries instead of rerasterizing them.

The macOS backend is compiled with manual Objective-C ownership in this
environment. Replacing a `newTexture` result or a glyph-atlas dictionary must
therefore release the prior global resource and retain the replacement. This
prevents an autorelease-pool dangling atlas after a scale change and prevents
unbounded texture retention during repeated text updates.

## M1-019: Bound retained scene textures during drawable-size changes

The retained Metal scene target is created with `newTextureWithDescriptor:`
and therefore has explicit ownership under the macOS backend's manual
Objective-C memory management. Dropping the global pointer on a resize without
releasing it retains one GPU texture for every drawable-size transition.

The scene-target replacement path now releases its prior texture before
creating the replacement, while retaining identical-size targets for reuse.
The native Metal contract exercises same-size reuse and two size transitions.
This is consistent with Zed's renderer and atlas lifecycle: stale offscreen
resources are returned or deallocated before replacement rather than being
left reachable only through Metal's allocation lifetime.

## M20-004: Centralize ownership for long-lived macOS UI state

Nimculus' macOS backend uses globals for the state shared by the Nim bridge,
AppKit overlays, and the Metal renderer. Under manual Objective-C ownership,
assigning a newly allocated string, array, clipboard payload, or texture into
one of those globals without releasing its predecessor leaks once per update.
This is especially visible for editor text, terminal output, hover/completion
updates, themes, image previews, and clipboard activity.

All long-lived Objective-C state now uses explicit replacement helpers that
retain/copy the new value before releasing the old one. Image textures are
owned by their dictionary after insertion, so the temporary `newTexture`
ownership is released immediately. The dictionary itself is explicitly owned
rather than autoreleased. This mirrors Zed's ownership-bound render-target and
atlas lifecycle and keeps steady-state resource use bounded by current UI
state rather than update history.

## M20-005: Release Core Text staging objects on every frame path

Core Text bridges require temporary attributed strings for glyph atlas shaping,
fallback text, soft wrapping, IME composition, completion/hover popups, hit
testing, and terminal styling. In a manual-reference-counted Objective-C
backend, these objects are not reclaimed merely because their associated
`CTLine`, `CTFrame`, or `CTTypesetter` has been released.

Each staging `NSAttributedString` and `NSMutableAttributedString` is now
released immediately after its Core Text or AppKit consumer has copied the
data. The change covers both normal and soft-wrap text paths and the terminal
overlay, avoiding allocation growth proportional to frame count or text
navigation. Native GUI contracts continue to exercise the corresponding Metal,
Core Text, IME, clipboard, and terminal paths.

## M20-006: Return autoreleased Cocoa values from UI callback boundaries

The `NSTextInputClient` attributed-text methods and workspace modal helpers are
called by AppKit and do not follow the Objective-C create/copy ownership
convention. Their returned or event-scoped controls must therefore be
autoreleased, even though the implementation internally uses `alloc/init`.

The backend now returns autoreleased attributed strings and creates transient
alerts, accessory views, rows, and picker controls as autoreleased objects.
AppKit retains them for the modal interaction; the event autorelease pool then
returns their ownership after the interaction. This bounds repeated command
palette, search, workspace, and settings UI use without changing their
interaction contracts.

## M20-007: Explicitly tear down the macOS renderer on application exit

The macOS backend owns Metal pipelines, command queues, retained render
targets, text/atlas/image textures, CPU-side paint and glyph buffers, and
bridge-side Objective-C state. Process exit eventually reclaims these, but an
explicit termination boundary is required to avoid leaving GPU work or timers
live while AppKit tears down windows and layers.

`applicationWillTerminate:` now first saves the session, invalidates the
workspace timer, and then releases Metal resources before freeing CPU buffers
and retained bridge state. Pipeline descriptors, shader functions, and
libraries created during startup are released once their pipeline state has
been created. This follows Zed's ownership model in which dropping the
renderer releases its render targets and atlas resources together.

The native platform contract runs this teardown as its final test and verifies
that every retained renderer object and CPU backing buffer has been cleared.

## M20-008: Make idle memory growth a soak-test failure

M20 requires that resident memory does not grow indefinitely while the app is
idle. Recording samples alone cannot enforce that requirement, so the soak
runner now compares the first and last resident-memory and live-allocation
samples. It requires at least one completed rendered sample and fails when
growth exceeds configurable limits (128MiB resident and 50,000 live blocks by
default). The limits remain environment-configurable for intentionally larger
profiling runs, while the self-hosted GUI smoke uses the same gate.

## M5-012: Keep the renderer gallery out of the normal editor surface

The M2 PaintList gallery is valuable for renderer inspection but its placeholder
rectangle, text, and image commands are not application chrome. Rendering that
gallery during normal startup obscured the editor's Core Text surface and made
an empty document appear as a blue demo canvas.

Normal startup now emits only the editor border and scrollbar from the retained
PaintList; text, line numbers, outline, cursor, and status remain the native
editor surfaces. The complete M2 gallery is preserved behind
`NIMCULUS_UI_GALLERY=1` for explicit renderer inspection. Indent guides now
render only for the indentation present on visible lines rather than drawing a
full-height guide at every possible column in an empty document.

## M3-010: Normalize Core Text glyph atlas rows for Metal sampling

The macOS text renderer uses a monochrome Metal glyph atlas for normal text
and a Core Text RGBA texture for caret, selection, IME composition, and color
emoji. The atlas initially used Core Graphics' bitmap-row order directly while
sampling it with Metal texture coordinates in the opposite order. On a real
file open this sampled the atlas padding rather than glyph pixels, leaving line
numbers but no visible source text.

The atlas payload is now normalized to Metal's row order once when a glyph is
inserted, and the glyph positions remain in logical points after Retina
subpixel quantization. Per-draw Metal buffers are released immediately after
encoding; the command buffer retains them until GPU completion. This matches
Zed's separation of monochrome atlas sprites and independent overlay
primitives without retaining transient buffers across frames.

## M3-011: Rebuild visible glyph quads after atlas eviction

A glyph-atlas eviction replaces the texture allocation map, so every UV emitted
before that eviction becomes invalid. Keeping the earlier quads would render
old glyphs from unrelated new atlas tiles (or transparent padding) when a
visible document contains enough distinct glyphs.

The macOS renderer now detects an eviction while building visible glyphs and
rebuilds the full batch once against the new atlas. If the rebuilt visible
batch itself exceeds the atlas capacity, it clears the batch and uses the
existing Core Text full-text fallback rather than mixing atlas generations.
The native platform contract forces the shelf-full path and verifies a valid
rebuilt batch.

## M5-017: Present external-file changes as asynchronous macOS sheets

External-change polling runs on the AppKit idle path. Calling `NSAlert`'s
synchronous `runModal` from that callback suspends frame presentation and can
leave the Metal editor surface blank behind a blocked modal loop.

The notification now uses `beginSheetModalForWindow:completionHandler:` on the
active Nimculus window. The callback dispatches Reload or Keep Editing only
after the user responds, while Cocoa keeps the event loop and Metal drawable
alive. This follows Zed's macOS prompt lifecycle, which begins a sheet and
returns the answer asynchronously rather than nesting a modal event loop.

The native GUI contract creates a temporary Cocoa window, verifies that the
sheet attaches without nesting the run loop, programmatically completes its
Reload response, and checks that the command callback fires afterward.

## M2-023: Verify Command shortcut routing at the AppKit view boundary

Zed separates AppKit menu key equivalents from ordinary `keyDown:` delivery
and prevents a key equivalent from being processed a second time as a key-down
event. Nimculus likewise lets the native macOS menu own standard equivalents,
while its application command registry receives unclaimed shortcuts through
`NimculusMetalView.keyDown:`.

The platform contract now synthesizes `Command-Shift-P` and sends it to the
Metal view. It verifies normalized modifier flags at the shortcut callback,
that the shortcut is consumed exactly once, and that it is not forwarded to
ordinary input or text interpretation. This tests the live Cocoa
dispatch boundary rather than only the menu metadata or a Nim-only registry.

## M5-018: Use asynchronous sheets for application-owned Open Panels

The File menu's Open action and workspace-folder picker previously used
`runModal`. That works functionally but nests an AppKit modal loop while a
Metal-backed application window is active. Zed creates macOS path prompts
with completion handlers instead, allowing the foreground event loop to keep
running.

Nimculus now starts `NSOpenPanel` with `beginSheetModalForWindow:` for its
main window. Open and Add Workspace Folder deliver file or root callbacks
only after an accepted response; cancellation leaves application state
untouched. The native GUI contract attaches the actual File/Open action to a
temporary Cocoa window, verifies the `NSOpenPanel` sheet, dismisses it, and
checks that the sheet detaches without a nested modal loop.

## M5-019: Route untitled-document Save through an asynchronous sheet

The ordinary `save` command used a synchronous `NSSavePanel` for an untitled
document even after the File/Open path had become asynchronous. That reentered
the AppKit modal loop and duplicated part of the document-save flow on the Nim
side.

The macOS save command now opens a window-attached `NSSavePanel` and returns
immediately. Its accepted path reaches the existing native file callback, so
the same document write, tab-title update, session persistence, and close
decision handling serve every panel-based save. Save-after-close and
save-before-window-close also continue their deferred close only after that
callback reports a successful write.

AppKit delays teardown of sheet transform animations beyond the response
callback. The Save Panel contract therefore runs in its own test process; this
prevents a temporary test window's deferred animation state from contaminating
unrelated alert contracts in the same process. Both the isolated Save Panel
contract and the ordinary macOS platform contract are required in local and
self-hosted macOS CI.

## M5-020: Queue Save All and Quit across asynchronous Save Panels

Save All and Quit can encounter more than one untitled tab. A synchronous
loop used to prompt for each path serially with `runModal`, but a direct
replacement with one asynchronous panel would either abandon later tabs or
attempt to terminate before all writes completed.

The macOS path now records the next tab index and advances it after every
accepted panel callback. Named documents save immediately; each untitled tab
becomes active only while its own Save Panel is shown. Completion saves any
remaining tabs, applies a pending update, closes native terminals, and then
confirms the deferred application termination. Cancellation emits
`savePanelCancelled`, clears the pending index, and keeps the application
open, so a later ordinary Save cannot accidentally resume an abandoned quit.

## M5-021: Keep unsaved close and quit confirmation out of nested modal loops

The unsaved-tab close confirmation and the application quit confirmation still
used synchronous `NSAlert.runModal` after file prompts had moved to sheets.
That nested AppKit's event loop over the Metal editor, and the close action
could only inspect a Save Panel result synchronously.

Both confirmations now use window-attached completion-handler sheets. Choosing
Save starts the existing asynchronous save-and-close or Save All queue;
choosing Don't Save performs the existing discard action. The close sheet does
not emit `closeTabConfirmed` until the subsequent Save Panel callback reports
success. The quit sheet confirms termination immediately only for a synchronous
discard or an all-named Save All; an untitled Save All is confirmed by the
queue's final completion. A dedicated macOS GUI contract verifies the actual
unsaved-close sheet attaches and detaches without nesting a modal loop.

## M5-022: Keep every application-owned macOS alert on the sheet lifecycle

After file and unsaved-change prompts moved to asynchronous sheets, utility
alerts (find, replace, Go to Line, command palette, settings, recent files,
and workspace create/rename/delete actions) still used `NSAlert.runModal`.
Those paths can be opened while the Metal view is presenting, so a remaining
nested loop is just as disruptive as a synchronous file panel.

Zed's `gpui_macos` platform presents both path prompts and confirmation
alerts with `beginSheetModalForWindow:` and receives the response in a
completion handler. Nimculus now has one AppDelegate alert presenter that
uses the active window's sheet lifecycle (with AppKit's non-window fallback
only during teardown). Every application-owned alert dispatches its Nim
command from that completion handler. The obsolete synchronous file-panel ABI
now returns an empty selection on macOS rather than starting a nested loop.

The native GUI contract opens the real Find in Document alert, verifies that
it attaches to a Cocoa window, dismisses it programmatically, and verifies
that `findDocument:` is dispatched only afterwards. It runs in its own test
process because AppKit sheet transform teardown can outlive a response
callback.

## M5-023: Make Save As an explicit asynchronous macOS command

The initial macOS File menu exposed Save but did not expose the roadmap's
required Save As operation. Reusing the synchronous compatibility ABI would
also reintroduce a nested AppKit run loop.

File > Save As… and Command-Shift-S now dispatch a dedicated `saveAs`
command. Nimculus supplies the active file name (or Untitled tab title) as an
`NSSavePanel` suggested name; the accepted path returns through the existing
save callback, which performs the atomic write, changes the document path,
updates the tab title, and persists the session. The native panel contract
checks that this is a window-attached sheet and that a Japanese suggested name
reaches the actual AppKit panel. The main-menu contract verifies the standard
Command-Shift-S key equivalent.

## M5-024: Preserve the standard macOS Redo key equivalent

The menu-wide shortcut normalization assigned Command to every Edit menu item
after it was created. That inadvertently replaced Redo's required
Command-Shift-Z modifier mask. Redo now has an explicit lowercase `z` key
equivalent with Command and Shift, and the normalization loop leaves that
explicit binding intact. The native menu contract verifies both modifier flags
and key equivalent so later menu additions cannot silently regress it.

## M5-025: Route CLI startup paths through the macOS file-open boundary

Zed collects startup open paths independently of its macOS URL callback and
then routes both through the same workspace open operation. Nimculus accepted
Finder and URL Apple Events but ignored positional command-line paths, which
made direct terminal launch inconsistent and prevented an automated Japanese
path smoke test.

`startupOpenPaths` now filters editor flags, resolves existing files and
directories to absolute paths, de-duplicates them, and honors `--` for a
path beginning with a hyphen. After Cocoa callbacks are installed, main feeds
each path through `receiveNativeFile`, exactly like Finder/Open With. The
editor service test covers a Japanese/emoji file name, directory path,
duplicate suppression, flag rejection, and the `--` escape boundary.

The self-hosted Cocoa/Metal cold-start smoke additionally creates a Japanese
and emoji-named fixture and supplies it through `NIMCULUS_COLD_START_PATH`.
The benchmark forwards that optional path only after validating that it
exists. This proves the actual bundled application reaches a rendered Metal
frame after CLI open-path routing, rather than proving only the pure path
filter.

The normal M5 open/search/replace/save integration test also uses a Japanese
and emoji-named path and keeps Japanese/emoji content through CRLF conversion,
atomic replacement, and existing-permission preservation. This covers the
same storage boundary used by a completed Save Panel callback without
pretending that an Accessibility-driven panel click was performed.

## M5-026: De-duplicate repeated macOS file-open events by document path

Zed de-duplicates open path sets before routing them to panes. Nimculus had a
single callback for Finder, Open With, URL, and CLI opens, but always appended
a new tab. Repeated Apple Events for the same absolute path could therefore
create divergent views of one buffer.

`EditorSession.tabIndexForPath` now identifies an existing named document.
The file callback saves the current view, activates the existing tab, restores
its view state, clears stale IME/syntax state, refreshes native text and
syntax, updates recent files, and persists the session. A Japanese/emoji path
test covers the identity lookup and missing-path behavior. Before that lookup,
all existing open-event paths pass through `expandFilename`, which follows
symlinks and makes `/tmp`/`/private/tmp`-style aliases one document identity.

The macOS AppDelegate contract also invokes one `openFiles:` event containing
two paths (Japanese and emoji names) and verifies both callbacks arrive before
testing the URL route. This keeps the Finder/Open With batch boundary covered
separately from the editor's tab de-duplication policy.

## M5-027: Preserve document identity across Save As, symlinks, and recovery

Zed identifies singleton project items before opening or activating them, so a
pane never holds independent editable views for the same project entry.
Nimculus initially applied that policy only to open events. A Save As callback
could target a file already represented by another tab; it would overwrite the
file and leave two divergent buffers. It also kept the raw Save Panel pathname,
allowing a subsequent Finder event through a symlink or macOS `/tmp` alias to
miss the existing tab.

Every opened and saved named document now stores `canonicalOpenPath`: an
existing leaf is resolved with `expandFilename`, while a deleted leaf resolves
its parent first so crash recovery retains the same `/private/tmp` identity.
Save As checks that canonical destination before writing and rejects it if a
different tab already owns the document. Successful Save As updates Open
Recent and the persisted session from the canonical path.

The same asynchronous Save Panel is used while Save All and Quit assigns a
path to an untitled tab. A conflicting destination cancels that pending queue
and the deferred termination decision, rather than allowing a later ordinary
Save callback to resume a stale quit operation.

Atomic replacement resolves an existing symlink before it creates the
temporary replacement. This writes the linked target and keeps the symlink
itself intact; replacing the link pathname would be a destructive surprise for
an editor. The editor test suite covers Japanese/emoji Save As identities,
already-open destination detection, and macOS symlink preservation, including
the deleted-file session-recovery case.

`tabIndexForPath` owns the normalization rather than trusting each caller to
perform it. LSP workspace edits and definition navigation therefore update or
activate the existing symlink-backed tab, instead of reading a second buffer
and applying an edit only to that temporary copy.

The lookup rejects an empty path so an invalid file-bearing request can never
select an Untitled tab. The session loader applies the same canonicalization to
old dirty/deleted recovery entries; this migrates pre-normalization `/tmp`
paths without requiring a schema version or risking the user's unsaved text.

## M10-009: Close macOS PTYs by process group

Zed treats a terminal session as the owner of the spawned process tree, rather
than only the initial shell. Nimculus previously sent `SIGTERM` only to that
shell. A shell command such as `yes x` could therefore outlive the terminal
test or application close and retain the PTY resources.

The `forkpty` child now establishes a dedicated process group before it
executes the configured shell. Terminal close signals the group and the leader
for compatibility with the platform session setup, waits for the direct child,
then sends `SIGKILL` to the same scope only if bounded reaping expires. The
macOS integration test starts a pipeline command, closes the PTY, and verifies
that its process group no longer exists. This keeps Cocoa termination bounded
without leaving shell descendants running.

## M0-008: Keep the default verification path macOS-only while Windows is frozen

The project target order makes macOS completion the immediate goal; Windows is
important for later WSL support but must not receive speculative work while the
macOS milestones remain unverified. The previous default `nimble test` and
macOS CI compiled or ran Windows-only contracts, making ordinary macOS work
depend on a platform outside the active scope.

`nimble test` now contains only portable and macOS-relevant verification. The
Windows-only terminal, platform, and native smoke tests are grouped under
`nimble testWindows` for a future Windows runner, and the macOS workflow no
longer cross-compiles Linux or Windows. This preserves the existing Windows
sources without treating them as part of macOS acceptance.

## M10-010: Release a macOS PTY after natural shell exit

Zed's terminal task lifetime ends when its process completes; retaining an
idle terminal transport after its shell has gone away wastes polling work and
can leave a dead session selected in the UI. Nimculus previously reclaimed a
PTY only through an explicit application close.

The macOS transport now keeps the master readable through the shell's final
output, then treats EOF or a non-retryable read error together with a reaped
child as terminal completion. It also handles macOS's short post-exit `EAGAIN`
window only after both the direct child and its PTY-owned process group have
gone away. It closes the master, drops pending input, and marks the session
closed without blocking the Cocoa idle callback. The integration test execs a
finite `printf`, verifies its final line is delivered, then verifies the closed
state, rejected input, and absent process group.

## M10-011: Cancel macOS tasks by their verified process group

Zed's Unix process wrapper creates a group for each owned process so stopping
a task also stops its descendants. Nimculus previously called `terminate` on
only the shell spawned for `run task`; a build child could survive after the
task panel reported cancellation.

Nimculus now asks Nim's POSIX spawn path to set the child's process group before
`exec`, then records that group only after `getpgid` verifies it. Cancellation
sends TERM, then bounded-wait KILL, to the verified group; a failed setup
safely falls back to terminating only the direct process rather than risking
the editor's group. Partial output is drained and retained before the process
closes. The macOS test starts a shell with a background child, cancels it, and
verifies the whole group disappears.

## M8-012: Stop macOS Language Servers by verified process group

Language Servers commonly launch helper processes (for example Node workers or
indexers). Zed's Unix process wrapper owns process groups specifically so an
editor restart or shutdown cannot leave those helpers alive. Nimculus stopped
only the direct server process, which was insufficient for that lifecycle.

The LSP launcher now uses the same child-side POSIX spawn group boundary as
macOS tasks, records it only after `getpgid` verification, and sends TERM then
bounded-wait KILL to the group on stop. Restart creates and verifies a fresh
group. The macOS protocol test starts a shell server with a background child
and verifies the entire group disappears after stop.

## M8-013: Release LSP handles after natural server exit

A Language Server can stop on its own due to configuration failure or an
update. Merely changing its visible state leaves the stdout pipe and process
handle owned by the editor until a later restart, which is both a resource leak
and an ambiguous lifecycle boundary.

Every LSP exit path now uses one release operation: it closes the process,
clears transport streams and the process-group ID, and preserves only the
configuration required for a future restart. The protocol test runs a server
that exits normally and verifies it reaches stopped/non-running state without
an explicit stop call.

## M9-008: Cancel macOS Git hooks and helpers by verified process group

Git commands can start hooks, credential helpers, and external diff tools. As
with Zed's Unix process wrapper, GitJob must own that whole descendant tree;
terminating only the Git leader can leave a hook running after the editor says
that cancellation completed.

Git jobs now request Nim's child-side POSIX spawn process-group setup and store
the group ID only after `getpgid` verifies it. Cancellation sends TERM, then
after a one-second bounded wait sends KILL, to that verified group. If setup
cannot be verified, it falls back to the direct Git process so it can never
signal the editor's group. The macOS regression test places a background child
behind a fake Git command and verifies that the entire group is absent after
cancellation.

## M11-015: Bound update helper lifetime to a verified macOS process group

Update download, signature verification, and DMG installation cross an
external-tool boundary (`curl`, `codesign`, `hdiutil`, and `rsync`). A timeout
or application quit must not leave a helper child running after the direct
tool has been terminated. Following Zed's Unix process ownership model, these
tools now receive a child-side POSIX process group and that group is retained
only after `getpgid` verification. Timeout and cancellation send TERM, then
bounded-wait KILL, to the verified group, with direct-process fallback if the
group cannot be verified. The macOS update test starts a fake curl with a
background child and verifies the group is gone after cancellation.

## M13-010: Keep Windows CI dormant during the macOS-first phase

The project currently accepts macOS behavior, packaging, and GUI gates before
resuming M13. Running the Windows workflow on every main push contradicts that
order and creates Windows trial-and-error work without advancing the active
target. The workflow is therefore manual-dispatch only until the documented
macOS completion gates allow the Windows milestone to resume.

## M10-012: Stop every macOS-owned service after quit is accepted

The Cocoa quit sheet can be cancelled, so process cleanup must happen only
after the user has accepted quit (or after Save All succeeds). Previously that
path closed PTYs but left the separately owned Task, Git, LSP, and update
download lifecycles to process termination. Their process groups reduce the
damage, but relying on application exit leaves a window where helpers can
outlive the UI.

`shutdownNativeServices` now cancels active update, diff/status/action Git
jobs, and task jobs; stops the LSP bridge; and then closes all PTYs. Every
accepted macOS quit route invokes it before applying an already-verified update,
so no editor-owned helper remains during DMG installation. A cancelled
unsaved-changes sheet does not cancel a pending update or other active work.

The quit-only LSP bridge shutdown deliberately does not emit `didClose` or
`$/cancelRequest`: those are normal document-lifecycle writes, but they can
block if a failed Language Server no longer drains stdin. It stops the verified
server process group directly and drops bridge state. The macOS regression test
uses an unresponsive shell server with a background child and verifies the
whole group is gone.

The same accepted-quit boundary cancels incremental workspace/Quick Open jobs
and stops every FSEvents watcher before dropping the active workspace. Workspace
replacement already used this order; applying it to termination prevents an
asynchronous watcher callback from observing partially released editor state.
It snapshots the workspace roots into the editor session first, because the
AppKit termination callback persists that session after services are released.

## M11-016: Defer Developer ID approval without blocking macOS functionality

Developer ID certificates and App Store Connect credentials are external
release approvals, not prerequisites for editor, UI, text, terminal, or
workspace functionality. Waiting for those credentials must not turn the
macOS-first plan into an implementation pause.

The packaging pipeline remains fail-closed when strict notarization is
requested, and its ad-hoc package, DMG, mounted-app, and cold-start checks
remain part of macOS CI. The Developer ID/notarization release gate is recorded
as pending until the credentials are available; meanwhile work continues only
on the documented macOS functionality and its tests. This does not authorize
Windows, WSL, or Linux work ahead of their milestones.

## M7-017: Release the final Tree-sitter state on macOS quit

Tree-sitter parsers and trees are C allocations, not ARC-managed Nim memory.
Document switches already close the replaced syntax state, but an editor which
quits while its final supported document remains open previously left that
parser/tree pair to process teardown.

The accepted macOS quit boundary now closes and clears `syntaxState` after
stopping process-backed services. This is deliberately part of the same
idempotent shutdown path so every confirmed quit route has identical ownership
semantics. The editor-syntax regression test asserts that closing a state
clears both underlying C handles.

## M5-019: Coalesce legacy duplicate named tabs during session restore

The active editor prevents duplicate named tabs at every live open boundary,
but older session files can still contain repeated paths. Restoring each entry
blindly reintroduced duplicate tabs and could preserve a stale clean buffer
beside the actual dirty recovery content.

Session restore now applies the same canonical path identity as normal opens.
It keeps one named tab per path, prefers dirty content over clean content, and
then prefers the originally active entry between otherwise equivalent choices.
The persisted active index is remapped to the surviving tab. Untitled tabs
remain independent, because they have no on-disk identity. The regression test
uses a Japanese/emoji path and a clean plus dirty duplicate to prove both data
preservation and single-tab persistence. Session writing applies the same
selection rule, so an in-memory legacy duplicate cannot be serialized again.

## M6-011: Canonicalize persisted workspace roots and recent paths

Workspace roots previously used absolute-string comparison. A symlink alias
therefore survived session restore as a second root and could allocate another
ignore stack and FSEvents watcher for the same directory. Recent files had the
same stale-path duplication risk in the Open Recent menu.

Existing persisted paths now use the canonical path boundary already used for
documents: recent paths are retained even when their leaf is gone, workspace
roots are retained only when they are existing directories, and both lists are
deduplicated on load and save. `Workspace.open/addRoot` use the same canonical
root identity, so Finder, shell, and session aliases share exactly one watcher.
The regression test covers a Japanese/emoji directory and a symlink alias.

## M10-013: Keep terminal cells scalar and intern shared presentation data

Zed's terminal delegates its compact cell-grid representation to Alacritty:
the grid records a glyph and attributes by value/reference, while larger data
is owned outside each cell. Nimculus had instead retained UTF-8 strings, color
objects, booleans, and hyperlink strings in every visible and scrollback cell.
That multiplied ARC allocations and retained roughly 184 MiB of resident memory
while parsing the standard 1 MB M20 terminal-output fixture.

`TerminalCell` now stores only scalar glyph, combining-glyph, hyperlink, and
style identifiers plus display width. `TerminalScreen` interns styles,
hyperlinks, and combining sequences and reconstructs text/presentation at the
native-overlay boundary. The same benchmark now shows about 4.5 MiB resident
growth for that fixture, while preserving SGR, OSC 8, UTF-8, combining glyph,
wide-cell, selection, and native attributed-run behavior. A compact-cell size
regression test prevents future variable-length data from being reintroduced;
an additional overwrite test clears a stale wide-glyph continuation cell.

## M10-014: Bound terminal metadata by retained grid lifetime

The scalar terminal-cell design moves hyperlink URIs, combining sequences, and
styles into screen-level intern tables. Without an explicit lifetime policy,
discarding old scrollback rows would leave their unique OSC 8 URIs and styles
allocated indefinitely. This was a second-order retention leak despite compact
cells.

Following Zed's separation between the retained Alacritty grid and the
rendering snapshot, Nimculus now compacts intern tables whenever scrollback is
discarded. It remaps every visible, scrollback, and saved-alternate cell and
keeps only values still reachable from those cells or the active hyperlink.
OSC collection is limited to 8 KiB and a retained OSC 8 URI to 2 KiB; malformed
or oversized links are dropped rather than allowing a stale previous link to
label later output. The M20 metadata benchmark sends 1,024 distinct links and
reports retained counts and bytes; it retained 166 links / 4,838 bytes with no
resident-memory increase, matching the live grid rather than total history.

## M10-015: Never block Cocoa quit in the final PTY reap fallback

The PTY close path already sent TERM and then KILL to the terminal-owned process
group. Its final `waitpid(..., 0)` still made the Cocoa thread wait without a
deadline if a malformed session failed to reap after KILL. The full macOS test
suite reproduced that wait, contradicting the terminal shutdown requirement.

Both TERM and KILL phases now poll `waitpid(..., WNOHANG)` for a one-second
bounded grace interval. The PTY master is then released regardless, so quitting
the editor never waits indefinitely in the kernel. The process-group signal and
direct-child fallback remain unchanged. A macOS regression starts a shell that
ignores TERM, proves `close` finishes within three seconds, and verifies its
process group no longer exists.

## M10-016: Index terminal presentation intern tables without extending their lifetime

Zed's terminal stores its cell payload in Alacritty's compact grid and uses
separate shared ownership for hyperlink metadata. Nimculus likewise keeps the
cell's style, link, and combining data as numeric IDs, but its initial intern
lookup walked the retained sequence linearly. A terminal command that emits a
distinct truecolor SGR value or OSC 8 URI per line would consequently turn
parsing into quadratic work even though scrollback compaction bounded memory.

`TerminalScreen` now maintains private hash indexes from each presentation
value to its existing scalar ID. The ordered sequences remain the sole ID
storage used by cells, so this changes lookup cost without changing the compact
cell ABI or retention policy. Every scrollback compaction first drops
unreachable values, then rebuilds the indexes from the newly retained
sequences. A regression emits 512 unique RGB/link pairs, forces compaction, and
verifies that the final active attributes still resolve without growing the
retained tables. The M20 metadata fixture also varies RGB styles alongside its
1,024 distinct OSC 8 links.

## M3-011: Build native editor line indexes at committed-text boundaries

The macOS Core Text renderer receives committed document text at the platform
boundary. It previously called `componentsSeparatedByString:` and re-summed
line prefixes for every scroll, atlas rebuild, text-overlay update, cursor
placement, and hit-test. That made a deep scroll through a 10,000-line file do
work proportional to the entire document before shaping even the visible rows.

Nimculus now builds an owned line array plus UTF-8-byte and UTF-16 offsets when
committed editor text changes. The visible renderer, glyph atlas, line-number
and indent overlays, cursor placement, Core Text hit-testing, and IME-facing
position paths share those indexes. Temporary validation strings retain the
safe local fallback, while normal editor updates avoid document-wide splitting
and prefix scans. The index is released with the renderer's other persistent
resources.

## M20-015: Keep a deep native text-position measurement in the standard benchmark

The pure-Nim Unicode position benchmark does not cover the macOS boundary where
Core Text hit-testing, the editor's UTF-8 model, and `NSTextInputClient`'s
UTF-16 coordinates meet. A regression in the native line index could therefore
pass the generic benchmark while making deep scrolling slow or incorrect.

M20 now sets a 10,000-line document, scrolls to its final line, and performs
1,000 native byte/UTF-16 hit-tests. It emits both resolved offsets as well as
elapsed time. On Apple Silicon this returned offset 19,998 for both coordinate
systems in 0.014 seconds, providing a repeatable guard for the visible-text
and IME position path without launching a persistent application window.

## M20-006: Measure PieceTable edits without materializing the document

The M20 editor-edit loop used `toString().len` only to obtain the logical
document length. For a large file that allocates and copies the complete piece
table before every edit, making the benchmark primarily measure accidental
string reconstruction rather than PieceTable editing.

`contentLength` is now a public, non-materializing logical-size query and M20
uses it for edit offsets. The editor-buffer regression verifies its value across
a Unicode replacement. The standard Apple Silicon M20 edit workload completes
100 edits in 0.375 seconds without those full-document copies.

## M5-028: Treat split geometry as session state, not a completed split editor

The old `EditorSession.split` flag and the UI divider's process-global ratio
could disagree after a relaunch. More importantly, the flag was not evidence
of a usable multi-pane editor: the native renderer still owns one editor
rectangle and one selection/scroll state.

Zed's `PaneGroup` creates a new pane, retains pane-local item state, and places
both panes into a split tree. Nimculus now at least stores the current divider
ratio with the split direction in the session, clamps it to leave both sides
usable, restores legacy sessions to an even split, and persists a drag
immediately. The roadmap deliberately keeps actual independent panes, native
rendering, input routing, and pane-local view state unchecked until that
vertical slice exists; a divider alone must not be represented as completed
split display.

## M5-029: Give a cloned split its own persisted view state

Pane-local cursor, selection, scroll position, and display preferences cannot
be stored on a shared document tab: moving in one clone would otherwise move
the other. Zed keeps item state in each `Pane`, while the document remains a
separate shared item.

Nimculus now preserves that separation for its initial two-pane model. The
document tab remains the shared buffer; the second pane receives a copied
`EditorViewState` when created and serializes independently with the split
direction, ratio, and active-pane index. Legacy sessions get the default view
and an even divider. Native dual-pane rendering and input routing remain the
next required vertical slice, so this state model is intentionally not marked
as completed split display.

## M5-030: Establish disjoint native pane geometry before dual rendering

The existing macOS text and IME API assumes one editor rectangle. Before two
Core Text/Metal render states can be attached, pointer routing must have an
unambiguous native answer for which pane owns a coordinate. Zed's pane group
likewise resolves a pane from geometry before forwarding an item event.

Nimculus now keeps primary and optional secondary editor rectangles separately
and exposes a half-open hit-test (`[origin, origin + size)`) that returns pane
0, pane 1, or no pane. The native regression covers left/top inclusion and
right-edge exclusion, including the divider gap. Drawing and editing the
secondary pane remain the next required vertical slice.

## M5-031: Start a split from the divider without misrouting secondary input

The existing divider had no session effect, and its hit region could only
adjust a global ratio. A real split must make that gesture create split state
and must never send a secondary-pane coordinate through the primary Core Text
hit-test while dual rendering is still incomplete.

Dragging the divider now creates the vertical split state on first use, lays
out primary and secondary rectangles from the persisted ratio, and registers
both with the macOS platform. A click in the secondary rectangle activates its
pane state but suppresses primary-editor editing until the secondary renderer
and pane-local text input path are available. This preserves user data while
the remaining rendering slice is implemented.

## M5-032: Keep secondary Core Text state independent of the active input client

Zed's `PaneGroup::pane_at_pixel_position` selects a pane before its editor
converts the point into an anchor.  Applying that boundary to Nimculus means a
secondary pane cannot borrow the primary viewport while calculating a byte
offset or drawing a selection.

The macOS platform now stores a secondary rectangle, scroll line, cursor, and
UTF-16 selection separately.  Rebuilding the secondary Core Text texture
temporarily installs only that state, then restores the primary
`NSTextInputClient` state.  Pointer hit testing selects the pane before byte
offset conversion; secondary drag selection and wheel scrolling mutate the
persisted secondary `EditorViewState`.  The native contract checks that the
same screen point resolves using the secondary scroll offset.

The shared document buffer remains intentional.  Keyboard editing and IME
composition still target the primary input client until focus can atomically
switch the full text-input bridge, including the candidate rectangle.  This
keeps the remaining gap explicit instead of presenting partial input routing
as a finished split editor.

## M5-033: Switch one NSTextInputClient to the focused split pane

AppKit owns one first responder for the window, so creating a second native
text-input client would split focus and IME state unnecessarily.  Instead,
Nimculus keeps the Metal view as the sole `NSTextInputClient` and explicitly
selects its input pane when `PaneGroup` geometry activates a split pane.

The selected pane supplies the UTF-16 selection for `setMarkedText:`, the
viewport and rectangle used by `firstRectForCharacterRange:`, and the
coordinate conversion used by `characterIndexForPoint:`.  Marked-text
rendering rebuilds only the selected pane's Core Text texture.  Nim routes
committed text, selection callbacks, navigation, deletion, clipboard, and
undo/redo selectors through that pane's `EditorViewState`; the document buffer
remains deliberately shared.  This follows Zed's focused-editor input model
without duplicating Cocoa responders.

## M5-034: Expose the initial split lifecycle through macOS commands

The first two-pane editor must be reversible; a divider that can only create
state leaves the user with a persistent layout accident.  Zed's pane group
also treats pane creation and removal as workspace actions rather than hidden
pointer-only behavior.

Nimculus therefore exposes `Split Editor` and `Close Split` in the Window menu
and accepts the same operations from the Command Palette.  Creating a split
clones the active document's view into the secondary pane; closing it removes
only the secondary view and geometry, never the shared document or the
primary view.  Both operations rebuild native geometry, resynchronize the
active text-input pane, and persist the resulting session immediately.

## M5-035: Make both split view states tab-owned

Each split pane shares the active document buffer, but each document needs a
separate primary and secondary viewport. Keeping `secondaryView` only on the
session leaked its cursor and scroll position after a tab switch; the old UI
then also reset the newly loaded primary view to a blank state.

`EditorTab` now owns `view` and `secondaryView`. Switching, selecting,
opening, closing, saving, and restoring a tab save/load both views, while only
transient UI state (IME remainder and derived symbols) is reset. The session
stores `splitView` per tab and imports the old root-level
`splitSecondaryView` into the active tab for backward compatibility.

## M5-036: Route position-based commands through the focused split view

Zed resolves commands from the active pane/editor rather than from a global
primary editor.  In Nimculus, ordinary Cocoa editing selectors already use the
focused split view, but LSP requests, Git hunk actions, definition navigation,
and replacement cleanup still read the primary cursor or selection.

Nimculus now exposes a small focused-view boundary for cursor movement and
selection lookup. LSP completion, definition, references, rename, signature
help, code-action/inlay ranges, definition navigation, and Git hunk actions
use that boundary. A whole-document replace clamps both persisted views after
the shared buffer changes. This keeps OS-independent command semantics at the
editor layer while leaving Cocoa-specific rendering and IME integration in the
macOS platform layer.

## M5-037: Keep transient LSP UI owned by one split-pane texture

Zed maps pointer input to the pane under the pointer before asking the active
editor for semantic information. The same rule applies to hover: the UTF-16
position must use the viewport and layout of the pane being pointed at. Because
each Nimculus pane is rendered into an independent Metal texture, its popup
coordinates must remain local to that texture.

Nimculus therefore tracks the hovered pane without changing keyboard focus and
uses that pane for the text hit-test supplied to LSP. The macOS renderer tags
each texture rebuild as primary or secondary: hover is emitted only into the
hovered pane, while IME marked text, completion, and caret are emitted only
into the focused input pane. Signature help uses the focused pane's local
cursor position. This prevents duplicate overlays and keeps every transient
surface aligned in either pane.

## M3-028: Keep native text validation on the committed-text cache boundary

The macOS renderer deliberately caches committed document lines and their
UTF-8/UTF-16 offsets. Native validators that assign a temporary string without
rebuilding that cache silently measure the old document: this made IME
candidate rectangles collapse to one position and made the Retina validation
shape an empty line after earlier tests.

Temporary native validation now rebuilds the same line index used by normal
`set_editor_text` updates both after installing and after restoring its test
document. `editorFont` also supplies the standard Menlo/14-point fallback
after renderer teardown. This makes the GUI-required candidate-rectangle and
1x/2x glyph-atlas checks independent of test order, while preserving the
production committed-text boundary.

## M3-029: Verify candidate rectangles for both focused split panes

One `NSTextInputClient` serves both Nimculus split panes. A primary-only
candidate-rectangle test could therefore pass while the focused secondary pane
still returned coordinates for the wrong text surface.

The native IME contract now creates distinct primary and secondary editor
rectangles, switches the input pane, and verifies the UTF-16 range's screen
rectangle moves into the secondary pane. The temporary state restores both
pane geometry, scroll state, and input focus afterwards.

## M3-030: Cancel marked text before split-pane focus changes

Zed assigns its platform input handler to the focused editor, so marked text
never survives as state owned by a previously focused editor. Nimculus keeps a
single AppKit responder for both split panes; without an explicit boundary, a
click could move the native input pane while the Nim composition still
described the old view.

Before activating a different split pane, Nimculus now clears both the Nim IME
state and the native `markedText`/`markedTextRange`. The shared document is not
edited or discarded: only uncommitted composition is cancelled, matching the
normal focus-change behavior of a macOS text input client.

## M5-038: Keep workspace-search navigation in the focused split pane

Zed models navigation as an operation on the active pane. Nimculus already
used that boundary for LSP definition navigation, but the click handler for a
workspace-search result directly changed the primary view. Selecting a result
while editing in the secondary pane therefore opened the right document but
left the secondary cursor at its prior position.

Workspace-search navigation now uses the same focused-view cursor operation as
definition navigation. The shared document and tab activation behavior stay
unchanged; only the target view receives the search match position. The
editor-layer test covers the invariant that a focused secondary pane moves
without changing the primary cursor.

## M8-028: Reap the macOS LSP process group before releasing its transport

Zed terminates a non-Windows child with `killpg` so a language server cannot
leave helper processes behind. Nimculus likewise signals the verified POSIX
group through that native API and then reaps the direct server process before
releasing the transport.

macOS can retain an already-dead orphan as a zombie until `launchd` reaps it;
`killpg(group, 0)` therefore cannot distinguish a live helper from a dead
zombie. The native tests instead use a child TERM trap to verify that the group
signal reached a real descendant, while keeping application shutdown bounded.

## M7-012: Collect syntax spans for both visible split-pane ranges

Zed gives each editor pane its own visible display range. Nimculus renders a
secondary Metal text texture with an independent scroll position, but the
syntax bridge originally submitted spans only for the primary viewport. A
secondary pane scrolled far from the primary therefore rendered unstyled text.

The syntax layer now accepts and merges disjoint half-open byte ranges. macOS
submits the primary range and, when split, the secondary range. Overlapping
ranges are merged while distant ranges remain separate, preserving viewport
bounded highlighting for large files. The editor-syntax test verifies that no
spans are pulled from the gap between two split viewports.

## M10-018: Separate terminal visibility from keyboard ownership

Zed associates terminal input with the terminal's focus handle, not merely
with whether its panel is visible. Nimculus previously routed committed text
and Cocoa editing selectors to any visible terminal. Clicking an editor pane
while the terminal stayed open therefore still typed into the shell.

The macOS integration now tracks terminal input focus independently. Opening,
switching, or clicking a terminal gives it ownership; any pointer-down outside
the terminal returns ownership to the editor. The pure terminal contract test
captures this visibility-versus-focus boundary, while existing command mapping
tests continue to verify that a focused terminal never falls through to editor
selectors.

## M10-019: Clear terminal presentation state during service shutdown

Closing PTY sessions releases their process groups, but the macOS presentation
state is owned separately by the AppKit overlay. Leaving its visibility or
keyboard-ownership flags set while clearing the active session could make a
subsequent lifecycle callback observe a terminal that no longer exists.

The terminal shutdown boundary now clears the active session, visibility, and
focus together, and explicitly hides the native overlay. This keeps the
terminal's session and focus lifecycles aligned, as in Zed where a panel's
focus handle cannot outlive the panel it belongs to.

## M10-020: Share terminal cell metrics between drawing and pointer input

Zed derives terminal mouse coordinates from the same `cell_width` and
`line_height` used to lay out its terminal grid. Nimculus previously rendered
the configured AppKit terminal font but converted pointer coordinates with
fixed 7.2/18-point constants, so a terminal font-size change made selection
and mouse reporting address the wrong cells.

The macOS bridge now resolves a fixed-pitch terminal font, disables NSTextView
soft wrapping so PTY rows remain rows, and exposes its cell advance, line
height, and text inset to Nim. Pointer conversion uses those exact values.
The native platform contract verifies that increasing the terminal font size
also increases the exported grid metrics.

## M10-021: Resize PTYs only when the metric-derived grid changes

Zed derives a terminal's dimensions from its viewport, cell width, line height,
and insets, then avoids forwarding pixel-only changes to the PTY. Nimculus
still used fixed constants for this separate resize path, and a terminal font
setting update changed rendering without changing the PTY grid.

Nimculus now calculates rows and columns from the same native metrics used by
terminal drawing and pointer input. Applying terminal settings and resizing the
window recompute that grid; a PTY resize is emitted only when rows or columns
actually change. The terminal-core test covers normal and degenerate viewport
calculations.

## M12-035: Keep terminal font configuration independent in the macOS settings UI

Zed exposes terminal `font_family` independently from the editor font. Nimculus
already modeled and validated `terminal.fontFamily`, but its macOS settings
panel offered one ambiguous font-family field and only saved it to the editor.

The settings panel now presents separate editor and terminal font-family fields
and carries both values through its native command payload into the global
settings file. This preserves the existing layered settings model and lets the
terminal's fixed-pitch safety boundary choose from the user's terminal setting.

## M8-029: Do not classify a pre-reap stdout EOF as an LSP failure

On macOS, an LSP stdout pipe can report EOF just before the direct child is
reapable through `waitpid`. Nimculus immediately released the transport using
the temporary `peekExitCode == -1`, converting a clean `exit 0` into
`lspFailed` and making restart readiness nondeterministic.

The LSP reader now retains an EOF transport until `peekExitCode` yields a real
exit status on a subsequent idle poll. It remains non-blocking and never waits
in the UI path; the existing exited-server test verifies it converges to
`lspStopped`.

## M10-022: Keep terminal scrollback navigation out of the editor scroll path

Zed keeps a terminal-local scroll position and sends wheel input to the PTY
only while a terminal application has enabled mouse reporting. Nimculus stored
scrollback rows but always rendered the live grid; ordinary terminal wheel
events therefore fell through to the editor.

The macOS terminal overlay now renders a bounded scrollback viewport using
absolute screen rows. Ordinary wheel input moves that viewport while mouse
reporting remains routed to the PTY. Pointer selection is translated between
viewport-local and absolute rows, so copy continues to include scrollback.
New output preserves an existing scrollback position rather than snapping the
reader to the bottom. Terminal-core tests cover viewport and offset bounds.

## M10-023: Verify terminal cells at the macOS presentation boundary

The terminal core test suite verifies VT parsing and cell selection, but the
macOS overlay previously had only a clear-state contract. That did not prove
that UTF-8 run offsets, wide-cell coordinates, terminal decorations, links,
and row/column selections survived the conversion into AppKit attributes.

The native contract now creates representative terminal runs and validates the
attributed text boundary directly: bold text, an underlined OSC-8 link on a
two-cell Japanese glyph, inverse/strikethrough styling, and a cross-row cell
selection. This follows Zed's separation of terminal-grid state from native
text presentation while testing the conversion boundary rather than either
side in isolation.

## M10-024: Preserve a bounded scrollback reader position during compaction

Scrollback length is not a reliable measure of new terminal output: once the
history limit is reached, batch compaction can leave it unchanged or shorter
even though one or more new normal-screen rows displaced the reader's view.
Using length deltas consequently caused a scrolled-up terminal to drift toward
the live bottom under sustained output.

`TerminalScreen` now records a monotonic normal-screen history serial whenever
a row enters scrollback. The macOS presentation layer uses its delta to advance
the local offset before clamping to the current bounded history. This matches
Zed's display-offset ownership: the reader remains on the same logical output
until retention necessarily evicts it. The terminal-core test covers the
compaction case where history length is not monotonic.

## M10-025: Rebase terminal selections after scrollback retention evicts rows

Terminal selections are stored in absolute rows across history and the live
grid. When bounded retention removes front rows, leaving those coordinates
unchanged silently retargets a selected range to later output. That makes a
subsequent copy return unrelated text while the reader is looking at the same
viewport.

The screen now exposes a monotonic discard serial in addition to its append
serial. On each PTY poll, the macOS terminal presentation rebases its active
selection by the discarded count before mapping it to viewport-local AppKit
coordinates. A selection crossing the retention boundary keeps its surviving
suffix; one entirely evicted is cleared. The terminal-core tests cover both
the retention counter and selection behavior.

## M10-026: Keep all terminal grids structurally valid across resize

The active screen, scrollback, and the normal screen saved for DEC 1049 are
all cell grids. Resizing only the visible rows leaves the saved grid at its old
column count; restoring it later violates the terminal's column contract.
Shrinking an active row can also cut off the continuation cell of a wide glyph.

Nimculus now resizes and normalizes every retained grid. A dangling wide lead
at the new right edge becomes a one-cell fallback, orphan continuations become
blank cells, and valid wide pairs retain shared style/link metadata. This
follows the grid-invariant discipline used by Zed's Alacritty terminal state.
Terminal tests cover both CJK truncation and alternate-screen restoration.

## M10-027: Exercise grid invariants across representative VT transitions

Single-feature parser tests cannot expose a malformed grid introduced only by
the interaction of cursor motion, scroll regions, alternate screens, OSC/SGR
metadata, partial escape sequences, and repeated resize. Zed delegates this
state machine to Alacritty, whose presentation assumes every row remains a
well-formed cell grid.

Nimculus adds a deterministic representative VT trace that performs those
transitions repeatedly. After each input and resize it validates line widths,
cursor and scroll-region bounds, and the two-cell lead/continuation invariant
for wide glyphs. This is deterministic rather than a nondiagnosable random
fuzzer, so a failure identifies the exact protocol trace while covering the
state combinations most likely to cause a terminal crash.

The trace exposed a one-column resize edge case: a double-width glyph was
correctly wrapped but then still wrote a nonexistent continuation cell. A
one-column grid now renders such glyphs as a one-cell fallback, and the
dedicated regression test prevents this crash from returning.

It also exposed two alternate-screen resize omissions: newly added active rows
used the old width when both dimensions changed together, and a saved normal
screen retained its old height while DEC 1049 was active. Resize now sets the
new column count before allocating rows and resizes/trims the saved normal
grid alongside the active one. Cursor validation permits the conventional
wrap-pending position one cell past the right margin.

## M10-028: Preserve wide-cell invariants during CSI line editing

Zed's terminal renderer explicitly skips Alacritty's wide-character spacer
cells. That representation assumes every spacer immediately follows a
double-width leading cell. Nimculus previously normalized rows on resize but
CSI erase-character, insert-character, and delete-character could address or
shift only one half of a wide glyph.

`clearCell` now clears both halves when either cell of a valid pair is
addressed. After CSI insert/delete shifts a row, Nimculus normalizes it before
returning to the parser. This preserves a valid compact cell grid even when a
cursor lands on a CJK/emoji continuation column. Terminal regressions exercise
erase, insert, and delete at that boundary.

## M1-020: Forward AppKit's canonical trackpad scroll deltas

Zed's macOS event adapter distinguishes line and pixel scrolling using
`hasPreciseScrollingDeltas`. Apple documents `scrollingDeltaX/Y` as the
preferred values for scroll-wheel events: coarse devices are interpreted in
line units, while precise devices provide pixel deltas. Nimculus previously
read `deltaX/Y`, which are generic mouse/drag/swipe properties and are not the
recommended scroll input surface.

The macOS adapter now forwards `scrollingDeltaX/Y` with the existing precision
flag, preserving the current NimNUI residual line conversion without a
platform-wide ABI change. The native contract captures the callback payload
from a pixel scroll event and verifies both delta values and its precision flag
against the originating `NSEvent`.

## M10-029: Normalize local terminal scrollback as pixel or line input

Zed's terminal scrollback converts `ScrollDelta::Pixels` using its terminal
line height, but applies `ScrollDelta::Lines` directly. Nimculus's local
terminal scrollback previously divided every event by the terminal line height
and used the opposite sign from the editor path. Consequently an ordinary
mouse wheel could require many ticks to move one history row.

`terminalScrollLineDelta` now shares the same signed residual model as editor
scrolling: precise trackpad pixels accumulate against the terminal font line
height; ordinary wheel values are immediate logical rows. The terminal pointer
path uses this helper before updating its bounded scrollback offset, and unit
tests cover both device classes.

## M10-030: Verify the configured macOS login shell, not just sh compatibility

Zed models the selected shell as an explicit program with shell-specific launch
arguments and tests those semantics. Nimculus likewise defaults its macOS PTY
to `/bin/zsh` and launches it as a login shell, but its integration coverage
previously only exercised `/bin/sh`. That did not prove the user-facing default
shell or its requested working directory was usable.

The macOS PTY integration suite now opens the default shell in `/tmp`, sends a
small zsh command followed by the terminal Enter byte (`CR`) through the PTY,
and waits (with a bounded readiness window) for both the zsh-only
`$ZSH_VERSION` marker and `pwd` output. This keeps the test independent of
prompt formatting while verifying the actual default launch contract and the
same Enter encoding used by the terminal UI.

## M12-035: Apply system themes from AppKit appearance notifications

Zed connects `viewDidChangeEffectiveAppearance` to its window appearance
observers rather than waiting for a settings-file change. Nimculus previously
read `effectiveAppearance` only while applying settings, so `theme: "system"`
did not repaint after macOS changed Light/Dark mode.

The Metal view now emits an `appearanceChanged` command from AppKit's native
appearance notification. The settings layer resolves system Light/Dark colors
as a pure operation, with unit coverage for both appearances and explicit
background overrides. A native platform contract invokes the AppKit view
override and verifies that it dispatches that exact command without replacing
the application's existing callback. The app reapplies only a system theme
when that command arrives; explicit light, dark, and user background choices
remain unchanged.

`bestMatchFromAppearancesWithNames:` returns an appearance-name `NSString`,
not an `NSAppearance`. The platform boundary stores that exact return type and
compares it directly, preventing a cold-start crash caused by sending `name` to
an NSString.

## M12-036: Re-resolve language settings when the active document changes

Zed resolves language settings for each buffer and refreshes the applicable
snapshot when the active language changes. Nimculus already had language-layer
merging, but its application kept the settings store's `languageId` at its
initial value. Language blocks were therefore a loader feature rather than an
active-editor feature.

The active document now maps through the supported Tree-sitter grammar IDs and
selects a fresh validated settings snapshot whenever that ID changes. Theme and
icon registries are rebuilt at the same boundary, so a removed language overlay
cannot retain stale values. Tests switch Nim → Rust → plain text without a
settings-file change and verify every effective value.

## M8-030: Send TSX documents to TypeScript LSPs as `typescriptreact`

Zed keeps TSX as a distinct grammar and maps it to the standard
`typescriptreact` language ID for both its TypeScript Language Server and
vtsls adapters. Nimculus now follows the same protocol boundary: `.tsx` sends
`typescriptreact`, while `.ts`, `.mts`, and `.cts` send `typescript`. This
keeps JSX-aware semantic analysis aligned with Tree-sitter's grammar selection
without conflating user settings IDs (`tsx`) with LSP wire IDs
(`typescriptreact`).

## M20-018: Aggregate manual macOS checks into a release-candidate E2E pass

Individual fullscreen, trackpad, multi-monitor, and IME interactions are poor
per-milestone gates: they require hardware or a selected macOS input source,
while the editor surface is still changing. Nimculus therefore uses unit and
integration tests, native Cocoa/Metal contracts, and self-hosted macOS CI as
the implementation gates for M0 through M12.

After M12 and the M20 automated cold-start, soak, and benchmark criteria are
available, a release candidate runs one macOS E2E acceptance pass. That pass
exercises the integrated editor, split panes, IME, workspace, Tree-sitter,
LSP, Git, terminal/tasks, settings, and available hardware variants in a
single realistic session. Failures are turned into issues and automated
regressions rather than multiplying isolated manual checklists.

## M20-019: Make the release-candidate macOS E2E gate reproducible

The E2E policy needs an executable baseline before an operator adds the
physical-hardware and real-IME portion. `nimble macosE2E` therefore runs the
same release-candidate evidence in one ordered log: build, native contracts,
unit/integration tests, benchmarks, repeated cold starts, soak, and a mounted
adhoc-signed DMG cold start. The manual self-hosted E2E workflow runs this
single command only after checkout and dependency installation.

The short soak default keeps the gate usable for a release candidate. The same
command accepts a 8-hour soak duration for formal acceptance, and its
temporary package/native caches are removed unless artifact retention is
explicitly requested.

## M6/M9-021: Keep project navigation and Git history outside the editor buffer

Zed's Project Panel is a dedicated dock, not a temporary document. The prior
Nimculus workspace preview rendered a bounded file list by replacing the
active editor text, so opening a folder could hide a document and made the
filer unsuitable for normal editing.

The existing macOS sidebar overlay now has explicit modes for document
outline, workspace files, and Git history. Every workspace root is a
first-class expandable row; its children are emitted immediately below it in a
bounded lazy traversal, so multiple roots never merge into an ambiguous flat
list. The native text view lives in an `NSScrollView`, so bounded large file
trees and the 100-entry Git history remain browseable rather than being clipped
to the sidebar height. File and commit rows dispatch a small indexed command
back to Nim; file rows open the selected document and a commit row
asynchronously loads its `git show --stat` details into the output panel. The editor text texture,
selection, IME state, and split panes are not modified by either sidebar mode.
This is deliberately a macOS presentation boundary; a future platform only
shares the sidebar behaviour contract after it needs the same interaction.

## M20-020: Treat a self-hosted E2E run as evidence, not hardware acceptance

The release-candidate workflow now has a successful Apple Silicon GUI-runner
record for commit `a3b1d1c`: build, native Cocoa/Metal contracts, all tests,
benchmarks, three cold starts, a short soak, and mounted adhoc-DMG launch all
completed in one execution. Recording that immutable workflow URL in the
roadmap and acceptance guide makes the automated baseline auditable.

The result must not be inflated into a claim about physical Japanese IME,
trackpad, multi-monitor behavior, real-LSP interaction, multi-hour stability,
or Developer ID notarization. Those require their respective available
hardware, tools, duration, or credentials and are recorded as separate
release-acceptance coverage.

## M20-021: Give formal soaks an explicit job budget and live evidence

The release-candidate workflow originally inherited GitHub Actions' 360-minute
job default, which cannot prove the roadmap's eight-hour stability target.
The self-hosted runner's documented execution limit is five days, so the
manual-only E2E job now sets a nine-hour budget: eight hours for the soak and
enough bounded time for build, package verification, and cleanup.

The soak wrapper previously buffered every heartbeat until the process exited.
It now tees the child output to a temporary log while retaining that log for
the completion and memory-growth checks. This makes a long run observable in
the Actions log without retaining cache or package artifacts after the run.

## M9-022: Show a commit patch without delegating to repository diff drivers

Zed treats commit metadata and the loaded commit diff as explicit Git-panel
data, rather than opening a shell-owned viewer. A Nimculus Git History entry
now asks Git for fuller metadata, statistics, and the patch in the existing
bounded asynchronous job, then presents that text through the output panel.

The command includes `--no-ext-diff`. Repository configuration can otherwise
redirect `git show` to an arbitrary external diff program, which is unsuitable
for an editor action and would weaken the cancellation/process-group boundary.
The service-level operation rejects empty revisions and has a regression test
covering metadata and both sides of a changed line.

## M9-023: Switch only validated local branches and retain dirty editor state

Zed's branch picker separates list loading from the switch action and lets Git
enforce worktree safety. Nimculus adds the corresponding minimum vertical
slice: `git branches` loads local branches in a stable, uncolored format, and
`git switch <branch>` invokes `git switch --no-guess` through the existing
bounded asynchronous process boundary.

Before a synchronous service switch, Git validates the ref with
`check-ref-format --branch`; the UI also rejects option-looking/control input.
`--no-guess` prevents a command-palette typo from implicitly creating or
tracking a remote branch. After a successful switch Nimculus reloads only
clean documents inside that repository and preserves dirty buffers, so editor
state remains user-owned while Git itself refuses an unsafe worktree switch.

## M9-024: Resolve Git from the document before giving up on a workspace root

Zed resolves a repository for each buffer path and selects the most specific
matching worktree. A Nimculus restored session could have an active workspace
whose roots did not include a subsequently opened document; the previous
lookup returned `nil` immediately in that case, making Git commands unavailable
even though the document lived inside a repository.

Git lookup now falls back to `git rev-parse --show-toplevel` from the
document's parent directory. The matching relative path uses the same fallback
instead of returning an empty path. A nested-file regression test confirms the
resolved root is the enclosing repository.

## M9-025: Keep amend explicit and message-bearing

Zed's commit modal separates normal commit from its amend mode instead of
silently changing the meaning of the primary commit action. Nimculus follows
that behavioral contract in its command palette: `git commit <message>` and
`git commit --amend <message>` are separate commands, and both require a
non-empty explicit message. The service keeps the message as one process
argument, while the existing bounded asynchronous Git job owns execution and
cancellation.

This avoids an accidental amend caused by implicit state or a reused editor
field. A successful amend simply replaces the existing commit through Git's
normal safety checks; history can then be refreshed through the existing Git
History command.

## M20-022: Preserve E2E harness failures through the workflow boundary

The soak wrapper correctly rejects an early process exit without
`soak_complete`, but invoking it as a Nimble task on the self-hosted runner
reported the task exception while returning a successful workflow step. The
release-candidate workflow now invokes `scripts/test_macos_e2e.sh` directly
under `bash` with `set -euo pipefail`. A failed completion or memory contract
therefore produces a failed Actions job.

This is a measurement-harness correction, not an implementation gate: a
long-soak result is stability evidence and does not block macOS editor feature
development.

## M9-026: Refresh history after a Git write without blocking the editor

Zed refreshes its Git panel after commit operations, so the current HEAD and
changed-file state do not remain stale. Nimculus now chains a successful
`commit` or explicit `amend` to its existing asynchronous history job. The
write first updates the active document's hunk markers, then the bounded Git
log job redraws the sidebar.

The chain deliberately avoids a synchronous `git log` in the main event loop.
It remains cancellable, uses the same 100-entry history bound, and records
whether the refresh follows a normal commit or an amend in the final status.

## M9-027: Use a pathspec-separated command for file history

Zed's commit view can filter changed files to the selected path. Nimculus adds
the corresponding lightweight editor command: `git file history` renders the
active document's bounded history in the existing native Git sidebar. The Git
command inserts `--` before the workspace-relative path, so a path is never
parsed as a revision or option.

The implementation reuses the history renderer and commit-detail click path;
it does not create a second Git view or block the editor while loading history.

## M9-028: Preserve a file-history filter when opening a commit

Zed keeps the selected-file filter when it opens a commit view. Nimculus keeps
the same small context beside its history sidebar: a repository history has no
path filter, while `git file history` records the workspace-relative path.
Selecting a commit then appends that path after Git's `--` separator.

The result is a focused patch for the requested file without changing the
revision's parsing or allowing repository-configured external diff tools.

## M9-029: Render bounded line blame without altering editor state

Zed presents blame as an editor decoration and status item. Nimculus uses its
existing native output panel for the same information until a dedicated gutter
annotation layout is warranted: `git blame` lists line number, short hash,
author, and source text, while retaining the cursor-line summary in the status
bar.

The list is capped at 500 lines. This preserves a useful whole-file view for
ordinary sources without turning a large generated file into a blocking native
text update.

## M9-030: Separate conflicted Git status entries before ordinary changes

Zed gives unresolved conflicts their own section and avoids sweeping them into
bulk staging operations. Nimculus' `git status` now renders a bounded output
list with conflicts first and a `CONFLICT` marker; renamed paths retain their
old-to-new relationship. It remains display-only, so status inspection cannot
silently resolve an unmerged file.

The list is capped at 1,000 entries to preserve responsiveness in large
workspaces, while the status bar retains total change and conflict counts.

## M9-031: Make bounded Git status entries navigable in the native sidebar

Status inspection needs a path back to editing. The bounded conflict-first
status list is now also rendered through the existing scrollable macOS
sidebar. Selecting an entry opens the corresponding existing regular file;
deleted and unavailable paths report their state rather than creating an
untitled replacement.

Before opening, Nimculus canonicalizes both repository root and candidate path
and rejects a path outside that root. The native sidebar uses a new mode value
but retains its established indexed callback contract, so no OS-specific
interaction abstraction enters the editor core.

## M9-032: Reuse the native sidebar as the local branch picker

Zed separates branch listing from the switch operation. Nimculus renders the
same machine-oriented local branch list in its existing sidebar; selecting a
non-current entry invokes `git switch --no-guess` through the established
asynchronous job boundary. The list itself comes from Git, and the current
branch is intentionally inert.

This keeps the existing clean-tab reload and Git worktree safety behavior
while providing a discoverable macOS interaction instead of requiring users
to type a branch name into the command palette.

## M6-018: Reveal the active file by expanding only its ancestor chain

Zed's Project Panel reveals the active file rather than forcing users to
manually expand every directory. Nimculus adds the same command-palette
behavior for workspace files: it finds the owning root, expands that root and
the document's directory ancestors, then refreshes the existing bounded lazy
tree.

No full workspace traversal is introduced. Files outside all configured roots
remain unopened in the tree and produce a clear status message instead.

## M6-019: Prioritize a revealed file within the bounded lazy tree

The project tree intentionally caps visible entries, but a simple lexical walk
could exhaust that cap in an earlier root or sibling directory before reaching
the active file. When Reveal Active File is used, Nimculus now orders the
owning root and each ancestor child ahead of unrelated entries. The existing
cap and lazy directory loading remain in force.

This guarantees that the requested path receives traversal budget without
turning reveal into an eager workspace scan.

## M10-013: Close a single terminal session through its PTY process group

Zed's terminal panel closes an individual terminal without tearing down the
whole panel. Nimculus now exposes the same behavior as `Close Terminal`: it
closes the active `TerminalPty`, removes only that session, and selects the
next remaining session. The existing POSIX close path terminates the child
process group before reclaiming PTY resources.

If the final session is closed, the native terminal overlay and focus state are
cleared. This avoids both orphaned shell descendants and a stale overlay that
appears to accept input without an owning PTY.

## M20-023: Record current-head E2E evidence separately from release credentials

The self-hosted Apple Silicon GUI E2E for commit `7083934` succeeded after the
integrated Git sidebar, workspace reveal, and terminal-session changes. It
ran the full test suite, native Cocoa/Metal contracts, benchmarks, three cold
starts, a short soak, and an adhoc DMG mount-and-launch in one execution.

This is evidence that the macOS implementation is integrated and runnable at
the current head. It does not assert physical IME/trackpad/multi-display
coverage, an eight-hour soak, real LSP interaction, or Developer ID
notarization; those remain separately recorded release coverage rather than
blocking feature implementation.

## UI-002: Own workspace layout as application state before rendering it

Zed's `Workspace` owns docks, pane groups, active items, focus, and transient
layers; individual panels render from that state. Nimculus previously exposed
Files, Outline, Git history, status, and branches through one serialized
native-sidebar string. That representation cannot preserve panel identity,
dock sizing, focus, or direct manipulation.

`workspace_ui` therefore introduces a platform-independent `WorkspaceUiState`
with independent left and bottom docks, a pane tree, focus region, and
geometry calculation. During the migration `EditorSession` remains the owner
of documents, while panes reference its tab indices. This keeps document and
editing behavior stable while moving visual composition and interaction toward
one GPU UI owner. Cocoa is retained for platform services, not as a parallel
workspace layout system.

## UI-003: Persist workspace composition as scalar session state

Dock ownership stays in `WorkspaceUiState`, but session serialization should
not depend on renderer or platform types. `EditorSession` therefore stores
only the left/bottom dock visibility, size, and selected panel ordinal. On
startup `workspace_ui` validates those scalars and reconstructs the layout;
sessions written before this addition retain the default Files dock because a
zero persisted dock size is treated as absent state.

This keeps a user-selected Files, Outline, Git, Terminal, or Task arrangement
across relaunches without introducing Cocoa state into the editor core or
coupling session JSON to the recursive pane implementation.

## UI-004: PaneTree is the canonical pane-geometry owner

**Context.** The original editor split was represented by `EditorSession.split`
and a primary/secondary rectangle in `main.nim`. That made a second view visible,
but it could not grow into Zed's recursive `PaneGroup`: the layout path, pointer
hit testing, focus, and split divider were separate sources of truth.

**Decision.** `WorkspaceUiState.center: PaneTree` owns pane geometry, split
ratios, and focused-pane identity. Its recursive layout result will be consumed
by both Metal chrome and the macOS text presenter. `EditorSession` remains the
authoritative document store during the migration, while each Pane stores its
selection of session items and each native presenter receives an explicit pane
context.

**Evidence.** Zed's `PaneGroup` recursively renders `Member::Pane` and
`Member::Axis`, retaining each pane's active state and bounding boxes. Apple's
Metal guidance keeps AppKit layout in logical points and converts only the
`CAMetalLayer` drawable to backing pixels; AppKit text input requires the active
text surface to answer IME geometry. The relevant source and documentation are
recorded in `docs/ZED_UI_ARCHITECTURE_RESEARCH.md`.

**Consequences.** A split must not be implemented as a decorative duplicate of
the active editor. The first implementation supports the existing two native
presenters while preserving pane-local focus, selection, scrolling, and document
context. Arbitrary-depth splitting follows only after this two-pane contract is
verified. No macOS-specific view or coordinate type enters `workspace_ui`.

## UI-005: One focused pane defines the complete macOS IME document context

**Context.** Once two panes can select different documents, switching only the
draw rectangle or cursor is insufficient. `NSTextInputClient` asks for document
text, UTF-16 selection and marked ranges, a candidate rectangle, and a character
index for a screen point. If any of those methods read the primary document while
the secondary pane is focused, IME replacement and candidate positioning become
incorrect whenever the two files differ.

**Decision.** The active input pane selects one complete native document context:
text, UTF-16/UTF-8 line indexes, rectangle, scroll position, soft-wrap setting,
cursor, and selection. The bridge may temporarily swap the text/index portion to
reuse Core Text helpers, but it must restore it before returning. Cocoa ranges are
converted against that context before crossing into Nim's UTF-8 editor core.

**Evidence.** Zed exposes its `InputHandler` as a one-to-one implementation of
the complete `NSTextInputClient` contract, and `Pane::activate_item` changes the
active item and focus together. Apple documents UTF-16 document ranges for text
replacement and screen-coordinate candidate and character-index methods. The
API-by-API audit is recorded in `docs/ZED_UI_ARCHITECTURE_RESEARCH.md`.

**Consequences.** Native split-pane tests must use intentionally different
primary and secondary UTF-8 documents, including newlines and a surrogate pair.
Tests that give both panes the same text cannot detect the class of failures this
decision prevents.

## UI-006: Dock list selection is application state, not a text-overlay side effect

**Context.** The first macOS workspace presenter serializes file and Git entries
into an `NSTextView` overlay. It can map a clicked row to an action, but it does
not represent selected rows, keyboard navigation, or persistent focus. Zed's
Project Panel and Git Panel instead own selection and dispatch open/navigation
actions from it.

**Decision.** `WorkspaceUiState` owns independent list selection state for each
left-dock panel. Item refreshes accept stable keys and retain the selected key
when possible. The Cocoa text surface is a temporary presenter only: it sends
select/open/navigation intents and receives the selected row to render. Files,
Git history, Git status, and branches share list-selection mechanics while
retaining domain-specific open actions.

**Evidence.** Zed's `ProjectPanel` holds selection, visible entries and focus,
then uses `open_internal` to distinguish opening a file from toggling a
directory. Its Git panel similarly exposes selection navigation as actions.
Nimculus' current Metal text paint is intentionally a placeholder, so replacing
the native text presenter before GPU text rendering exists would regress the
usable macOS UI. The source audit is in `docs/ZED_UI_ARCHITECTURE_RESEARCH.md`.

**Consequences.** A click selects first; double-click or Enter activates the
selected entry. Up, Down, Home, and End operate through the same state and show
selection feedback. A future GPU text renderer can replace Cocoa rendering
without changing workspace behavior.

## UI-007: Files Dock opens into the focused pane

**Context.** `receiveNativeFile` is the shared callback for Finder, Open panels,
and workspace UI. Its historical behavior activates `EditorSession.activeTab`,
which is correct for an application open event but wrong when the secondary pane
has keyboard focus and the user activates a Project Panel file.

**Decision.** Keep platform file-open events on the primary session path, and
introduce a Files-Dock-specific action that selects the target tab in
`WorkspaceUiState.focusedPane`. Reusing an existing document does not duplicate
its buffer; adding a new document preserves the primary active tab when the
target is secondary.

**Evidence.** Zed's Project Panel turns an entry selection into a Pane-targeted
open or split event rather than directly changing a global active editor. The
source-path audit is recorded in `docs/ZED_UI_ARCHITECTURE_RESEARCH.md`.

**Consequences.** Opening a file from Files while the secondary pane is focused
changes that pane's document, viewport, selection, and IME context without
silently replacing the primary editor.

## UI-008: Tab presentation and activation are pane-local

**Context.** A single macOS tab overlay could only render the primary session's
active tab. It contradicted PaneTree's independent selection and made a
secondary document impossible to discover or switch through the UI.

**Decision.** Native tab presenters are explicit primary and secondary surfaces.
Their callbacks identify both pane and tab. `WorkspaceUiState` remains the
selection authority; activating a primary tab additionally updates
`EditorSession.activeTab`, while activating a secondary tab does not.

**Evidence.** Zed's `Pane::render_tab_bar` renders and activates items from one
Pane's own item list. The implementation audit is in
`docs/ZED_UI_ARCHITECTURE_RESEARCH.md`.

**Consequences.** A split presents two independently highlighted tab bars.
Files Dock open, tab click, text rendering, selection, and IME all resolve the
same Pane document.

## UI-009: Close requests resolve through the focused Pane

**Context.** The initial close command always removed `EditorSession.activeTab`.
That is the primary Pane's document, even when the keyboard focus and visible
tab were in the secondary Pane. Closing a secondary tab could therefore remove
the wrong document.

**Decision.** Resolve a close request from the focused Pane's active tab index,
then remove that document from `EditorSession` and every mirrored `PaneTree`
tab list in one operation. Each Pane keeps its own selected item whenever
possible. The asynchronous native save/discard sheet retains the resolved tab
and pane target until it completes, including a subsequent Save As panel.

**Evidence.** Zed implements `Pane::close_active_item` against the Pane's
`active_item_index`, rather than a workspace-global active editor. Its Pane
owns item focus while the Workspace coordinates lifecycle. The relevant source
audit is recorded in `docs/ZED_UI_ARCHITECTURE_RESEARCH.md`.

**Consequences.** Cmd+W cannot silently close the primary document while the
secondary Pane has focus. Clean secondary tabs close immediately; dirty tabs
receive the standard Save / Don’t Save / Cancel sheet against the same focused
document. Focus changes while a sheet is visible cannot redirect its result to
another tab.

The active native tab also exposes the same close action directly. An inactive
tab's right edge still selects it, preventing an ambiguous one-click close of a
document the user was not viewing.

## UI-010: Empty editor panes expose a native welcome surface

**Context.** A clean launch with no restored document presented an empty dark
editor rectangle and a scrollbar. File and workspace actions existed in the
menu bar, but the central workspace—the user's primary entry point—gave no
indication of how to begin.

**Decision.** Render a centered welcome surface only while no editor document
is active. It offers New File, Open File, Open Folder, and Open Recent through
the same AppKit actions already used by the main menu. The surface is a native
overlay during the GPU-text migration; the interaction contract is independent
of that presenter.

**Evidence.** Zed enables `Pane::should_display_welcome_page` for the center
pane and renders a WelcomePage when no worktree/item exists. The inspected
source path is documented in `docs/ZED_UI_ARCHITECTURE_RESEARCH.md`.

**Consequences.** An empty macOS launch has visible, discoverable next actions.
While it is visible, document-only chrome (focus border, scrollbar, line
numbers, indent guides, and caret) is suppressed so the center is unambiguously
an entry surface. Opening or creating a document hides the surface immediately,
leaving the normal editor and workspace layout untouched.

The primary project-opening action is visually distinct from secondary
file/recent actions. Every action uses a fixed-width, 34pt control rather than
an intrinsic text-width button, preserving a clear click target and hierarchy
at both Retina and non-Retina scales.

LaunchServices does not supply a meaningful project working directory for an
app bundle. Therefore only a restored workspace or an explicit Finder/Open
path opens a project; an empty launch never treats `/` as the workspace root.

## UI-011: Git panel resolves workspace context without an open document

**Context.** The initial Git history/status implementation derived its
repository only from the active file. That made the Git panel unavailable in a
newly opened project, a welcome workspace, or an untitled editor even though a
repository was already known to the workspace.

**Decision.** Resolve Git actions for a pathless/no active document from the
first Git-backed workspace root, in workspace order. A concrete document keeps
precedence and resolves its own enclosing worktree, including a restored file
outside configured roots.

**Evidence.** Zed's `GitPanel` initializes `active_repository` from the
Project rather than an editor buffer (`crates/git_ui/src/git_panel.rs`).

**Consequences.** Files, status, history, and branches can be used from the
project UI before opening a file. Multi-root behavior remains deterministic;
the first Git-backed root is selected until an explicit document provides a
more specific worktree.

## M5-011: Preserve Finder open events during application startup

**Context.** LaunchServices can invoke `application:openFiles:` before Nim's
file callback has been installed. Dropping that event leaves a Finder-opened
folder on the welcome page, despite the app having received the request.

**Decision.** The Cocoa bridge queues file URLs received before callback
registration and flushes them in delivery order when Nim installs the callback.
The queue is copied before delivery to make a callback-triggered nested open
safe, and is released with the other platform-owned resources.

**Consequences.** Finder/Open With, `open -a Nimculus <path>`, and cold-start
file associations retain their original path—including Unicode paths—without
requiring a retry. The registered callback remains the single routing boundary
for files and directories.

## UI-012: Shared native sidebar keeps panel-level visual hierarchy

**Context.** Files, outline, and Git history had correct interaction routing
but were all presented as editor-sized plain text. This hid panel headings,
directory disclosure, status, and commit identity in the same visual weight as
file content.

**Decision.** Keep the shared `NSTextView` presenter while applying attributed
panel typography: a compact title, subdued divider, 13pt rows, accented project
disclosures, explicit Git status prefixes, and short commit hashes. Rows remain
single-line so the existing selection/index contract stays exact.

**Evidence.** Zed's Project/Git panels distinguish headers, tree affordances,
and status/commit anchors while retaining keyboard-selectable logical entries.

**Consequences.** The core file and Git workflows become legible as panels
without introducing a second selection implementation or changing panel item
identity semantics.

## UI-013: Files panel owns contextual workspace actions

**Context.** Workspace create, rename, delete, and Finder reveal already had
safe backend commands and menu-bar entry points, but a user working in Files
had to leave the selected row to invoke them.

**Decision.** A right click on a Files row first preserves the normal panel
selection, then opens a native context menu for that exact workspace entry.
It exposes Open (files), Reveal in Finder, New File, New Folder, Rename, and
Delete. The Cocoa presenter owns only the selected absolute path and prompts.
Each asynchronous prompt snapshots that path when it opens, so a later
right-click cannot redirect its mutation. All mutation commands continue
through the Nim workspace path-validation boundary.

**Evidence.** Zed's Project Panel deploys a context menu from a selected entry
and keeps the panel focus/selection as the action context.

**Consequences.** File management is reachable at the point of use while
preserving keyboard routing and the existing symlink/workspace-root safety
checks. Directories remain subject to the current empty-directory deletion
rule.

## UI-014: Git navigation is visible in the sidebar

**Context.** Git status, commit history, and branch checkout already used the
same cancellable Git-job boundary, but switching between them required a
command-palette command. That makes the primary Git workflow undiscoverable
inside the panel where the results appear.

**Decision.** When the native sidebar presents a Git mode, show a macOS
segmented control for Changes, History, and Branches above its scrollable
rows. Each segment dispatches the existing status/log/branches command; it
does not duplicate Git state, process ownership, or cancellation logic.

**Evidence.** Zed's Git Panel exposes Changes and History as persistent panel
tabs and opens a selected history entry through the panel action boundary.

**Consequences.** Users can see and switch the three Nimculus Git workflows
at their point of use, while history selection still opens the existing safe
`git show --no-ext-diff` detail job.

## UI-015: Files creation is visible at the point of use

**Context.** Files already supported creation through the menu bar and a row
context menu, but neither made the primary project-creation workflow visible
when the Files panel was open.

**Decision.** Show native `New File` and `New Folder` controls at the top of
the Files sidebar. They invoke the existing AppKit sheets, then route through
the Nim `Workspace` path-validation and refresh boundary.

**Evidence.** Zed's Project Panel registers New File and New Directory as
panel actions and exposes them with the selected project context.

**Consequences.** File creation is now a discoverable panel action without
creating a second mutation implementation or weakening workspace checks.

## UI-016: Git status rows own safe stage actions

**Context.** The Git status sidebar could open a file, but staging required a
command-palette action even though the changed row already establishes the
file context.

**Decision.** A Git status row's context menu provides Open plus Stage and/or
Unstage when its porcelain state permits the action. Conflict rows provide no
automatic stage action. Mutations use `git add -- <path>` or `git reset HEAD
-- <path>` through the existing cancellable Git-job boundary and refresh
status on completion.

**Evidence.** Zed derives stage intent from the entry and its section, and
keeps conflicted entries outside bulk staging operations.

**Consequences.** Git changes are actionable where they are displayed while
conflict resolution remains explicit and the panel never retains stale state.

## UI-017: Git history exposes commit-level actions

**Context.** Selecting a history row opened its detail, but users could not
copy the full revision identifier from the history surface.

**Decision.** A Git history row context menu exposes Open Commit and Copy
Commit SHA. Open reuses the bounded `git show --no-ext-diff` path; copy uses
the shared macOS clipboard contract.

**Evidence.** Zed's Git Panel commit context menu exposes Copy SHA alongside
the commit view action.

**Consequences.** A commit row now provides both common commit-level actions
without introducing a Git graph dependency or a separate clipboard path.

## UI-018: Command Palette presents discoverable primary actions

**Context.** The native Command Palette accepted arbitrary text but advertised
only a small, stale subset of the commands it could execute. This made a
large portion of the editor, workspace, Git, terminal, and LSP workflow
effectively undiscoverable.

**Decision.** Use a native completing combo box with the primary action names
as visible candidates, while retaining exact free-form commands for commands
that require an argument.

**Evidence.** Zed initializes an action registry and normalizes action names
for its Command Palette rather than requiring users to remember raw commands.

**Consequences.** The palette now provides a useful first-level action
surface without changing the existing command-dispatch ABI.

## UI-019: Terminal sessions are explicit panel controls

**Context.** Nimculus could create, switch, and close PTY sessions through
shortcuts and the Command Palette, but the terminal surface itself gave no
visible indication that sessions existed or how to operate them.

**Decision.** Add a native macOS terminal session bar above the terminal
grid. A popup lists every session, and persistent `+` and close controls send
commands through the existing Nim terminal manager. Task output deliberately
hides this bar because it is not a PTY session.

**Evidence.** Zed's `TerminalPanel::apply_tab_bar_buttons` places terminal
creation and pane operations directly in the terminal tab bar.

**Consequences.** Terminal session state remains owned by Nim and PTYs remain
independent, while the primary multi-session workflow is visible and usable
without opening a palette.

## UI-020: Commit details use an identified, dismissible inspector

**Context.** A Git history row asynchronously loaded commit metadata and a
patch, but rendered it as anonymous task-output text. That made it unclear
whether the panel represented a task, a Git commit, or an LSP result, and
provided no direct way to dismiss it.

**Decision.** The shared lower inspector has a native title bar and close
control. Git commit details set the title to `Git Commit`; task and LSP
surfaces use the same presenter with their own titles. The body remains a
bounded native text view rather than a second editor implementation, but is
read-only selectable and scrollable so a diff can be inspected and copied.

**Evidence.** Zed opens a dedicated `CommitView` after independently loading
commit details and file diffs, giving the result an explicit presentation
identity rather than treating it as terminal output.

**Consequences.** Nimculus retains one cancellable output boundary while Git
history now leads to a recognizable, dismissible commit inspector.

## UI-021: Every document tab exposes its close target

**Context.** Only the active Nimculus tab drew a close glyph. Background tabs
were visually indistinguishable from tabs that could not be closed, although
the underlying close path already handles selection, unsaved confirmation,
and session persistence safely.

**Decision.** Draw a muted close glyph on every tab and retain the brighter
active-tab treatment. Clicking any close target routes through the existing
`closePaneTab` → `closeTabRequest` flow rather than bypassing unsaved work.

**Evidence.** Zed renders a close target for each closable pane item (visible
on hover by default) and delegates closure to `CloseActiveItem`.

**Consequences.** The document lifecycle is visible at the point of use,
while Nimculus retains the same safe confirmation semantics for every tab.

## UI-022: An empty Files panel starts a workspace

**Context.** The Files sidebar showed creation controls even when no workspace
existed. Those actions lacked a meaningful root and made the primary first
step—choosing a project—harder to discover.

**Decision.** Files presents `Open Folder…` as its only panel action without
a workspace. The empty row and toolbar route to the existing non-blocking
macOS directory panel; after selection, the normal workspace preview replaces
the action with `New File` and `New Folder`.

**Evidence.** Zed's empty Project Panel makes opening or cloning a project
the primary action instead of offering file-tree mutations with no project.

**Consequences.** The file explorer is useful before and after a workspace is
open, with no separate folder-selection or workspace-creation implementation.

## UI-023: Git has an explicit no-repository state

**Context.** Opening Git outside a repository only changed the status bar,
leaving a stale sidebar behind. The user could not tell whether Git had opened
or what action would make it useful.

**Decision.** Render a Git sidebar placeholder with the normal Git tabs, a
`No repository found` message, and an `Open Folder…` row. That row uses the
same macOS folder picker and workspace-open path as Files.

**Evidence.** Zed's Git Panel renders a `No repository found` placeholder
when its active repository is absent.

**Consequences.** Git navigation remains a coherent UI state before a
repository exists, without inventing a special Git workspace loader.

## UI-024: The workspace header contains real navigation

**Context.** The editor layout reserved a top chrome band above document tabs,
but the band was empty. It consumed vertical space without providing an
editor, Files, Git, or terminal workflow.

**Decision.** Put native Files, Outline, Git, and Terminal controls in that
workspace header. They dispatch existing commands and do not own duplicate
panel, Git, or PTY state.

**Evidence.** Zed configures persistent tab-bar buttons as part of the Pane
chrome and lets panel-specific code add workspace actions there.

**Consequences.** The previously blank region now anchors primary navigation,
while all functional ownership stays in the existing workspace command paths.

## UI-025: Persistent workspace navigation shows its active destination

**Context.** The workspace header had working Files, Outline, Git, and
Terminal controls, but every control used the same idle appearance. Once focus
moved into the editor, there was no visible indication of the sidebar mode or
whether the terminal panel was open.

**Decision.** Resolve the selected state from the existing sidebar mode and
terminal visibility each layout pass. The matching native button receives the
theme accent and an accessibility tooltip; it does not store presentation
state or dispatch a new command.

**Evidence.** Zed's persistent Pane tab-bar actions retain an active visual
state while the focused editor item changes.

**Consequences.** Workspace context remains visible in the primary chrome,
without duplicating workspace, Git, or terminal ownership in AppKit.

## UI-026: Git Changes exposes a native commit entry point

**Context.** Nimculus could commit safely through the command palette, but
the Git sidebar exposed only status, history, and branch navigation. A normal
source-control workflow therefore required discovering a typed command before
the existing Git service became usable.

**Decision.** Place `Commit…` beside the Changes/History/Branches selector.
It opens a non-blocking macOS sheet, validates that the message is non-empty,
then dispatches the existing `git commit <message>` command. The Nim Git
service remains the sole owner of repository resolution, argument-array
construction, asynchronous execution, cancellation, and output rendering.

**Evidence.** Zed's Git Panel keeps its commit editor and commit action within
the Changes workflow, while `commit_changes` remains owned by its repository
layer.

**Consequences.** Commit is discoverable where users review changes, without
adding a second Git execution path or allowing a native UI control to mutate
the repository directly.

## UI-027: A left activity bar owns persistent workspace destinations

**Context.** Nimculus had top workspace navigation, but the left dock lacked
the persistent edge navigation that makes Files, Outline, Git, and Terminal
quickly discoverable in a Zed-style editor layout.

**Decision.** Add a compact SF Symbol activity bar at the left edge of the
workspace dock. Each button dispatches the existing workspace command and
derives its accent state from sidebar mode or terminal visibility. Inactive
controls receive an explicit muted theme foreground rather than AppKit's
default accent, so the selected destination is visually unambiguous. The
tree, Git tabs, and Files actions shift right by the fixed rail width; no
panel state is stored by the rail.

**Evidence.** Zed keeps workspace destinations in persistent dock/tab-bar
controls, separate from the project tree and focused editor item.

**Consequences.** The layout now has a stable, icon-first navigation edge
without shrinking the editor or creating a competing navigation model.

## UI-028: Pane chrome exposes the current split action

**Context.** The editor supported split panes through menus, shortcuts, and a
divider interaction, but no visible action in pane chrome exposed that
capability. Users could not discover a central editor workflow from the place
where it takes effect.

**Decision.** Add a workspace-header control that dispatches `splitEditor`
when one pane is visible and `closeSplit` when the native secondary editor is
visible. Its label and tooltip are derived from the existing native pane
visibility contract; it owns no editor-session state.

**Evidence.** Zed renders a Split Pane icon in pane chrome and changes the
available action according to whether a pane can be split or joined.

**Consequences.** Split and unsplit become discoverable at the editor's point
of use, while the existing editor session keeps all pane geometry, focus, and
persistence ownership.

## UI-029: Git panel resolves its branch asynchronously

**Context.** The editor's background Git-status refresh used `currentBranch`
after porcelain status completed. That helper synchronously launches Git, so
an idle callback could still wait on filesystem or repository state while the
panel and editor should remain responsive.

**Decision.** Start a separate cancellable `symbolic-ref --quiet --short
HEAD` GitJob whenever status is refreshed. The Changes title initially renders
without a branch if necessary, then rerenders only the visible status panel
when the branch result arrives. Branch and status carry the same monotonically
increasing snapshot generation, so a late result can update only the matching
Changes list. Detached HEAD is an explicit presentation state.

**Evidence.** Zed keeps repository state and panel presentation in separate
asynchronous update paths; a panel does not synchronously query Git while
rendering or handling input.

**Consequences.** Git status and branch can arrive in either order without
blocking input, and document/workspace changes cancel stale branch work with
the rest of the Git lifecycle; a late branch result cannot relabel an older
status list.

## UI-030: Workspace navigation owns explicit contrast

**Context.** A real dark-theme review showed that AppKit's textured buttons
and default template-symbol tint left Files, Outline, Git, Terminal, and Split
labels too dark, while inactive activity icons could resemble the active
accent. The controls were functional but their state was not legible.

**Decision.** Style workspace-header and activity-bar buttons with explicit
theme foregrounds, accent/muted backgrounds, and an active accent border.
They remain native buttons and retain their existing accessibility labels and
command dispatch; the appearance no longer depends on AppKit's default bezel
or template-image tint choices.

**Evidence.** Zed assigns foreground, active background, and border tokens to
its pane and dock controls rather than relying on platform-default button
colors.

**Consequences.** Navigation labels and selected state remain visible under
the configured dark theme, making the UI pathway itself usable rather than
merely present.

## UI-031: Git navigation uses explicit native button states

**Context.** The Changes/History/Branches switcher was the remaining
`NSSegmentedControl` in the workspace navigation path. Its textured selected
state was delegated to AppKit, producing a different and lower-contrast dark
appearance from the workspace header and activity bar.

**Decision.** Implement the switcher as three compact native `NSButton`
controls, reusing the workspace navigation theme contract for foreground,
active background, and border. It keeps the same asynchronous Git commands,
tooltips, keyboard-accessible native controls, and panel layout.

**Consequences.** Git history is a visible, stateful primary surface rather
than an otherwise-functional feature hidden behind an ambiguous platform
bezel.

## UI-032: Background file refresh never replaces the active panel

**Context.** A real Git-panel interaction showed that a workspace-preview
refresh could reset the visible sidebar to Files after Git status completed.
The Git result still existed, but its selected state and navigation surface
were replaced by unrelated watcher-driven presentation work.

**Decision.** Workspace refreshes always update the Files panel model, but
publish it to the native sidebar only when Files is the active left-dock
panel. Git, Outline, and other active panels retain ownership of the visible
sidebar during background filesystem changes.

**Consequences.** The control that a user selected remains selected through
asynchronous work, and workspace watching cannot make Git history appear to
fail or disappear.

## UI-033: Git controls preserve labels at narrow dock widths

**Context.** After Git selection ownership was fixed, real macOS review showed
that a narrow left dock truncated Changes and Branches because the full
`Commit…` label competed for the same single toolbar row.

**Decision.** Keep all three Git navigation labels visible by compacting only
the secondary commit control to a checkmark button below the dock-width
threshold. The button keeps its full tooltip and accessibility label and
expands to `Commit…` when the dock is wide enough.

**Consequences.** The primary Git navigation remains scannable at practical
sidebar sizes without removing commit from the UI or forcing users into the
command palette.

## UI-034: Git status has one primary presentation

**Context.** macOS visual review showed that status refresh rendered the same
Git Status list in both the left panel and the output overlay. The duplicate
overlay covered the editor despite the sidebar already providing scrolling,
selection, opening, and stage/unstage context actions.

**Decision.** Render Git Status only in the Git sidebar. Keep the output
panel for user-requested details: commit patches, blame, task output, and LSP
results.

**Consequences.** A status refresh preserves document context and leaves the
Git panel as the unambiguous place to review and act on changes.

## UI-035: Git tab selection maps behavior, not enum order

**Context.** The command-layer sidebar modes are ordered History, Status, and
Branches, while the user-facing Git navigation is Changes, History, and
Branches. Deriving the selected tab from the enum ordinal made Git Status
visibly select History during real macOS review.

**Decision.** Use an explicit behavior-to-presentation mapping: Status maps
to Changes, History maps to History, and Branches maps to Branches.

**Consequences.** The selected Git tab now truthfully identifies the content
being shown, independent of internal enum declaration order.

## UI-036: Document tabs never paint past the editor edge

**Context.** Real macOS review with several restored documents showed the
fixed minimum tab width extending the tab strip beyond the editor viewport.

**Decision.** Divide the visible tab strip across its current documents and
truncate titles within each allocation. Preserve the right-side close target
where a tab has enough width to render it.

**Consequences.** Every open document remains reachable in the current editor
surface without painting chrome outside its bounds.

## UI-037: Files creation actions use explicit dark-theme contrast

**Context.** New File, New Folder, and Open Folder were reachable in the
Files panel but still used AppKit's textured button appearance, making the
primary file-creation path weak against the dark workspace chrome.

**Decision.** Reuse the native workspace navigation styling for Files actions;
the leading New File/Open Folder action receives the active accent treatment,
while the secondary creation action remains readable and subdued.

**Consequences.** Opening or creating a project file is visually discoverable
at the point where users browse the workspace.

## UI-038: Many document tabs retain readable labels

**Context.** Fitting every restored tab into the editor width made each tab
unreadably narrow in a real session.

**Decision.** Present a bounded, active-tab-centered window of 120pt tabs and
show a small range indicator when documents exist outside that window. Tab
keyboard navigation and the Window menu move the active tab and therefore its
visible window.

**Consequences.** The current document and nearby documents remain readable
and closable without chrome overflow or meaningless one-character labels.

## UI-039: Status messages and cursor position are distinct fields

**Context.** The status bar concatenated transient messages directly with the
cursor position, producing unreadable text such as `Soft wrap disabledLn 1`.

**Decision.** Separate a nonempty transient message from line/column metadata
with a fixed bullet delimiter before rendering the single native status field.

**Consequences.** Editor feedback and document position remain scannable
without changing the status bar's compact one-line layout.

## UI-040: Split panes own independent syntax buffers

**Context.** A split pane can select a different document from the primary
pane. Reusing the primary Tree-sitter ranges in the secondary Core Text texture
applies byte offsets from the wrong buffer and produces incorrect coloring.

**Decision.** Maintain a second `EditorSyntaxState` for the secondary pane and
send its visible spans through a distinct macOS highlight buffer. The platform
selects that buffer only while rebuilding the secondary texture. Diagnostics
and Git hunks use matching per-pane buffers and URI/path-specific async
sources; inlay hints remain attached to the primary overlay until they obtain
the same per-document request ownership.

**Consequences.** Two different languages or source lengths can be displayed
side-by-side without syntax-span aliasing or stale primary diagnostics/diff
markers, while the remaining primary-only inlay-hint scope stays explicit.

## UI-041: Persist the secondary pane item separately from the primary tab

**Context.** `EditorSession.activeTab` denotes the primary Pane. Once the
secondary Pane can select a different shared document, restoring only the
split geometry and per-document viewport loses which document was visible
there after relaunch.

**Decision.** Store `splitSecondaryTab` beside `activeTab` in the session
format. Serialization maps both indices through deduplication; restoration
uses the mapped secondary item to restore its cursor/scroll view. The legacy
`switchTab` helper retains its old mirrored-viewport behavior, while workspace
commands keep their pane-local selection.

**Consequences.** A primary and secondary document survive session recovery as
the same two-pane workspace rather than collapsing into a duplicate primary
document.

The restored `splitActivePane` also restores `WorkspaceUiState.focusedPane`.
Without that final focus handoff, the native input responder could target the
secondary pane while Files-panel opens and pane-local commands still target the
primary pane.

## UI-042: Keep LSP document lifetimes and diagnostic buffers pane-local

**Context.** The LSP transport already stores diagnostics by URI, but the
editor bridge closed the previous document whenever focus changed. A secondary
pane therefore either lost its server state or received primary-document byte
offsets.

**Decision.** Retain each synchronized document's `didOpen` state, text
snapshot, and version in the bridge. Selecting the primary document only
changes the target for request-producing features such as completion and
hover; synchronizing the secondary document leaves that target unchanged.
Metal receives a separate diagnostic span buffer for the secondary editor,
selected while its Core Text texture is rebuilt.

**Consequences.** Split panes can render URI-correct diagnostics and update
their own document versions without a focus switch sending `didClose` for the
other visible buffer. Interactive LSP requests remain deliberately scoped to
the focused primary bridge until per-pane request ownership is introduced.

## UI-043: Expose both supported split axes through the macOS UI

**Context.** `PaneTree`, session restoration, and the native primary/secondary
presenters already support vertical and horizontal two-pane geometry. The
visible toolbar and Window menu, however, only created a vertical split, while
the divider drag calculation always used the x coordinate.

**Decision.** Keep the compact toolbar action as the common vertical split and
add an explicit `Window > Split Editor Horizontally` command and Command
Palette aliases. Divider dragging derives its ratio from the `PaneTree` axis:
x/width for vertical splits and y/height for horizontal splits.

**Consequences.** The supported two-pane model has no hidden orientation that
can only be restored from a session. Geometry, hit testing, focus, and drag
resizing remain derived from the same `PaneTree` layout.

## UI-044: Render Git hunks from each visible pane's document

**Context.** Git hunk ranges are line-based and belong to a specific file.
Suppressing primary hunks in the secondary pane avoided stale markers, but
left an independently selected secondary document without diff feedback.

**Decision.** Give the secondary pane its own cancellable `git diff` job,
path guard, and Metal hunk buffer. Completion applies only if that same path
is still visible in the secondary pane; closing the split or removing its
document clears the buffer. Its gutter hit test also converts the click using
that pane's bounds and scroll state before starting stage/unstage.

**Consequences.** Two files can display correct independent diff decorations
and hunk actions without coupling the Git sidebar/status job to
secondary-pane presentation.

## UI-045: Bind native Save Panels to their initiating tab

**Context.** AppKit save panels complete asynchronously. A split editor can
change focus while a panel is open, so resolving the callback from the current
primary tab can save the wrong document.

**Decision.** Record the initiating tab index before showing an NSSavePanel or
Save As panel. The completion callback uses that stored tab after close-flow
requests have taken precedence, then clears the pending target on success,
failure, cancellation, or destination conflict.

**Consequences.** Cmd+S and Save As work for an untitled secondary-pane
document without changing which pane owns keyboard focus or overloading the
native panel API with pane-specific state.

## UI-046: Keep Git history bound to its source repository

**Context.** A history sidebar remains visible while users open documents from
other workspace roots. Looking up the active document when a commit is
selected can therefore show the SHA from a different repository.

**Decision.** Use the repository retained by the asynchronous history job for
both row activation and its context-menu detail action.

**Consequences.** Commit metadata and patches stay attached to the history
list's original project even as editor focus changes.

## UI-047: Make changed-file diffs visible from the Git panel

**Context.** The Changes sidebar exposed opening and staging actions, but did
not offer an in-app way to inspect the selected file's patch. This made Git
state visible without making its consequences reviewable.

**Decision.** Add `View Diff` to the changed-file context menu. For tracked
files, render `git diff HEAD` so staged and unstaged edits appear together;
for untracked files, use the standard `/dev/null` no-index diff and accept
Git's exit code 1 as the expected "differences found" result.

**Consequences.** The native read-only output panel becomes a safe review
surface for every normal status entry without spawning an external diff tool
or changing the user's editor document.

## UI-048: Enter file history from the file tree

**Context.** Zed exposes file history from a project entry's context menu.
Nimculus only offered that history after first opening the file and invoking a
palette command, which made a common repository-navigation action indirect.

**Decision.** Add `View History` to the macOS file-tree context menu. The
command resolves the selected path's enclosing repository and passes a
repository-relative path to the existing cancellable `git log -- <path>`
workflow.

**Consequences.** History remains available without changing the active editor
or treating a workspace-relative path as trusted input to Git.

## UI-049: Copy a file-tree entry path without opening it

**Context.** File navigation regularly needs a path for shell commands, test
fixtures, and issue reports. Requiring a Finder reveal or opening the file to
obtain it makes the file tree less useful as a primary workspace surface.

**Decision.** Add `Copy Path` to the macOS workspace-entry context menu and
route it through Nimculus' existing clipboard boundary.

**Consequences.** The copy operation preserves the selected tree entry and
works identically for files and directories without introducing a Cocoa-only
clipboard path into workspace code.

## UI-050: Navigation commands follow the focused split pane

**Context.** Files, workspace search, Git status, and LSP definition commands
all open a path and optionally position a cursor. Sending any one of these
through the primary document path makes a two-pane editor appear to ignore the
user's active pane.

**Decision.** Treat these operations as pane-local navigation: open the target
through the focused-pane file activation boundary, then resolve the target
document and cursor from that same pane. Generic editor commands also derive
their document from the focused pane.

**Consequences.** Split panes retain their independent tab, selection, and
navigation state across Files, search, Git, and LSP workflows.

## UI-051: Make Git change actions follow their rendered section

**Context.** A partially staged path has both index and worktree changes. It
appears under both `Staged` and `Unstaged`, so a generic toggle can apply the
opposite operation from the one the user selected.

**Decision.** Retain a projection for every rendered Changes row. `Staged`
rows show `✓` and unstage on their leading control; `Unstaged` rows show `○`
and stage. Context menus expose the matching staged or unstaged diff. Conflict
rows expose no stage toggle or implicit resolution.

**Consequences.** The native sidebar line mapping and Git action state remain
aligned when one path occurs twice. The isolated GUI E2E performs Stage All
then Unstage All and verifies the resulting Git index and worktree state;
the native contract verifies row-control dispatch.

## UI-052: Keep Quick Open out of the editor document surface

**Context.** Quick Open previously replaced the native editor text with search
results. That made the active document, caret, and second split pane appear to
disappear until a result was selected.

**Decision.** On macOS, render Quick Open into the existing Files sidebar and
retain its normal list-selection and activation path. Keep the editor text
presentation untouched; the Windows fallback retains its current independent
surface until it has an equivalent native project panel.

**Consequences.** File discovery behaves as workspace navigation rather than a
temporary document. The GUI E2E opens File > Quick Open, enters a query, and
asserts that its title appears in the sidebar accessibility text area.

## UI-053: Give workspace search its own navigation panel

**Context.** Full-text workspace search used the same editor-replacement
surface as the former Quick Open implementation. It obscured the current file
and lacked a persistent activity-bar destination while results streamed.

**Decision.** Add a persisted-safe `panelSearch` value at the end of the
workspace panel enum and expose it through macOS Search activity-bar and
toolbar controls. Render path, line, column, and text results into this native
sidebar; activating a row opens the result in the focused editor pane and
moves its cursor to the matched position.

**Consequences.** Search, Files, Outline, and Git are distinct UI states with
their own stable selection keys. Workspace search no longer mutates document
presentation, and GUI E2E verifies `Find in Workspace…` produces a `Search:`
sidebar result.

## UI-055: Bound navigation lists at the presentation boundary

**Context.** Quick Open displayed ten entries while exposing up to one hundred
to native sidebar selection; Workspace Search displayed one hundred while its
panel state retained up to 256. Keyboard navigation could therefore select a
row that had no visual counterpart.

**Decision.** Apply a shared presentation boundary per surface: the native
sidebar text, item count, and panel selection keys all use the same first 100
entries. Search jobs may retain additional source results for later refreshes,
but they are not selectable until rendered.

**Consequences.** Visible rows and activation indices remain one-to-one for
mouse, keyboard, and accessibility clients. The bound also limits native text
layout work while background search remains streaming and cancellable.

## UI-054: Open an integrated terminal from a project entry

**Context.** The Project Panel exposed navigation and file operations, but a
developer who wanted a shell in a selected subdirectory had to open a terminal
at the workspace root and change directory manually.

**Decision.** Add `Open in Terminal` to the native Files context menu. The
editor canonicalizes the selected path, uses a directory itself or a file's
parent, verifies it is beneath a configured workspace root, then starts a new
Nimculus PTY in that directory. It never launches Terminal.app.

**Consequences.** File navigation and terminal work form one in-app workflow.
The context-menu native contract verifies its explicit command payload, while
the existing PTY suite verifies working-directory creation and bounded
shutdown behavior.

## UI-056: Scope folder search through the workspace path resolver

**Context.** `Find in Folder…` needs to search the selected directory without
duplicating traversal logic or accidentally scanning sibling directories. Raw
prefix matching is unsafe for symlink aliases and multi-root workspaces.

**Decision.** Extend the cooperative `SearchJob` with an optional scope path.
It resolves that path through `Workspace.splitWorkspacePath`, then initializes
the existing lazy directory queue with exactly its registered root and relative
directory. The macOS context menu sends the directory and query as a structured
payload; the editor verifies the directory remains inside the workspace.

**Consequences.** Folder search shares all ignore rules, cancellation,
streaming limits, and canonical-path rules with global search. A workspace
test proves that a scoped job returns the selected subtree while excluding a
sibling with the same match.

## UI-057: Never signal a shared process group from a UI cancellation action

**Context.** Nimculus is normally launched from Terminal or a Codex session.
Process-group cancellation can therefore terminate the interactive launcher
when a child inherits or races a group boundary. The GUI E2E previously also
used a group-level cleanup path.

**Decision.** Git, task, LSP, updater, PTY, and GUI E2E cancellation address
only the direct process each subsystem created. PTY shutdown additionally uses
`waitpid(WNOHANG)` immediately before a signal, proving that its PID is still
an unreaped child and cannot be a reused PID. Background descendants are not
treated as authority to signal a broader group.

**Consequences.** A cancelled helper cannot terminate Codex, Terminal, or a
shared launcher. Cancellation remains bounded for the direct child; external
tools that deliberately detach descendants are responsible for their own
lifecycle rather than inheriting broad signal authority from the editor.

## UI-058: Keep GUI acceptance independent of terminal-session hangups

**Context.** The GUI acceptance workflow opened the integrated Terminal only to
assert that its activity-bar control dispatched.  That creates and then closes
a PTY during cleanup.  On macOS, closing a PTY master may deliver `SIGHUP` to
processes in its terminal session; that is an unacceptable risk in an
environment where Codex or a developer shell can be active.

**Decision.** The Accessibility GUI workflow covers Files, Search, editor
splits, and Git, but never opens the integrated Terminal.  Terminal behavior
is verified by isolated integration tests that spawn only temporary fixture
processes.  The GUI workflow's cleanup continues to signal only its exact,
separately launched Nimculus PID.

**Consequences.** The integrated E2E still validates the terminal subsystem,
but the interactive acceptance layer cannot create or disconnect a terminal
session.  A dedicated disposable GUI host may add terminal UI acceptance in
the future only after proving it cannot share a developer's terminal session.

## M8-035: Keep LSP shutdown and its test at the direct-child boundary

**Context.** LSP shutdown is deliberately limited to the server process
created by Nimculus.  An old bridge test nevertheless started a TERM-ignoring
shell plus a background helper and asserted group-wide termination.  After the
application correctly stopped sending process-group signals, that test left
the helper's parent shell orphaned under `launchd`.

**Decision.** The bridge regression fixture is now one TERM-ignoring direct
server process.  Shutdown proves the bridge releases that direct process
within its bounded fallback path; it creates no background helper and makes no
claim of descendant ownership.

**Consequences.** The test cannot leave a process behind and cannot exercise
a cancellation boundary broader than the one granted to the application.
Detached language-server helpers remain external-process lifecycle
responsibility, as specified by UI-057.

## UI-060: Invert resize coordinates for the macOS right Project dock

**Context.** Zed presents the Project dock on the right on macOS. Nimculus
already maps the logical left dock to that presentation for layout and paint,
but its drag handler still used the pointer x-coordinate as if the dock were
on the left. The right-side divider therefore could not set the intended
width.

**Decision.** Keep dock ownership platform-neutral in `WorkspaceUiState` and
add explicit forward/inverse coordinate helpers. For a right-presented dock,
the divider is `window width - dock width` and a drag requests `window width -
pointer x`.

**Consequences.** The macOS Project dock now resizes from its visible edge,
while Windows/Linux can retain left-side presentation without inheriting a
macOS-specific layout abstraction. Double-clicking the resize handle restores
the Zed-like default width. Unit coverage verifies the round trip and reset.

## UI-059: Keep workspace-search controls inside the Search panel

**Context.** The Search activity-bar item could open a query sheet, but once
results were visible there was no panel-local way to begin another search or
cancel a streaming search. Users had to rediscover the command palette or the
Edit menu.

**Decision.** Reserve a compact Search header in sidebar mode `panelSearch`.
It provides icon-first, fully accessible `New workspace search` and `Cancel
workspace search` controls. Both route through the established command
boundary, so cancellation remains a harmless no-op after completion.

**Consequences.** Workspace search is a self-contained navigation surface:
the active document remains visible while a user can refine, restart, or stop
search directly from its results. Native contract and GUI E2E cover the two
controls.

## UI-059: Model Git History as explicit loading, error, and loaded states

**Context.** Zed's Git Panel renders `Loading Commit History…`, a failure
placeholder, or an empty-history message while repository data changes. The
Nimculus History tab waited for `git log` to complete, leaving a stale Files or
Changes panel visible in the meantime; refreshing file history could also
silently change to the currently focused document.

**Decision.** Render a zero-item History sidebar immediately before every
history job, replace it with a failure placeholder on a non-zero result, and
then render commit rows only after a successful result. Preserve the history
path and repository across Refresh so File History always refreshes the file
that created the list.

**Consequences.** The Git panel's visible state accurately represents the
asynchronous operation, has no stale clickable rows during loading or failure,
and file-history refresh remains stable even when editor focus changes.

## UI-060: Make Files-panel tree navigation continuously reachable

**Context.** Zed's Project Panel exposes both fast hierarchy reset and
selection-oriented navigation. Nimculus had `Reveal Active File` internally,
but it was only discoverable through the command palette, while a deeply
expanded tree had no single reset action.

**Decision.** Add icon-first `Reveal Active File` and `Collapse All` actions
to the Files header next to New File/New Folder. Reveal expands only the
active file's ancestors. Collapse clears the expanded-directory state without
traversing files or reloading their contents; workspace roots remain visible.

**Consequences.** The file manager stays usable after navigating large trees,
and all common navigation actions are visible at the point of use. Native
contract and GUI E2E invoke the commands through the public buttons.

## UI-061: Keep editor-tab actions at the tab that invoked them

**Context.** Zed exposes tab actions from the tab itself. In a split editor,
Nimculus already kept a pane-local click and close target, but users had to
activate a tab before using file-oriented actions elsewhere. That made it too
easy for a context action to apply to the active tab rather than the tab that
the user selected.

**Decision.** A secondary click on a macOS editor tab dispatches its pane and
tab index to a native menu containing Close Tab, Copy File Path, and Reveal in
Finder. The action payload retains both indices. Close reuses
`closePaneTab` and therefore the existing Save / Don't Save / Cancel flow;
copy and reveal are no-ops with an explanatory status for an untitled tab.

**Consequences.** File-oriented tab actions are available at their point of
use without bypassing unsaved-work protection or changing selection merely to
run an action. Native contracts cover both hit testing and action payload
dispatch.

## UI-062: Branch context actions are non-destructive by default

**Context.** Zed provides a copy-branch-name action alongside branch
management. Nimculus rendered the local-branch list and supported a safe
primary-click checkout, but a secondary click was deliberately ignored. That
removed a common non-destructive Git action from the point where the branch
name is visible.

**Decision.** Branch sidebar rows now expose Copy Branch Name in a native
context menu. The command retains the row index, verifies that the Branches
panel is still current, and copies only the branch value returned by Git.
Checkout remains the primary-click action and uses `git switch --no-guess`.

**Consequences.** Users can reuse a branch name without changing the
worktree. The sidebar's context-menu contract covers Branches as well as
Files, History, and Changes.

## UI-063: Pinning is tab order, not a transient decoration

**Context.** Zed models pinned tabs as a contiguous prefix in each pane. A
purely visual pin in Nimculus would still let a narrow tab strip hide the
important document, and would lose meaning at relaunch. The current editor
session remains the shared document store for both split panes, so moving an
item also has to preserve both pane selections.

**Decision.** `EditorTab` owns persisted `pinned` state. Pinning moves the
tab to the end of the pinned prefix; unpinning moves it after that prefix.
The editor session remaps primary and secondary tab indices as it moves an
item. The native strip draws a pin marker and its context menu offers Pin /
Unpin and Unpin All. The bridge rebinds both pane selections after a move.

**Consequences.** Fixed tabs stay first in overflow and after session restore,
while a pin action in one split pane cannot silently change the document shown
by its sibling. Unit, session-round-trip, and native context-action contracts
cover the state boundary.

## UI-064: Reopen closed tabs from paths, never discarded buffers

**Context.** Zed's Reopen Closed Item is navigation-history based and skips
items without reopenable paths. Retaining full `PieceTable` values for a local
closed-tab stack would make closing a large file fail to release memory. It
would also allow a `Don't Save` decision to be silently undone.

**Decision.** Keep a bounded LIFO history of 32 clean, named closed tabs with
their path, title, pin state, and pane-local view states. Reopen loads the
current file content from disk, skips unavailable paths, and never records
untitled or dirty/discarded buffers. File > Reopen Closed Tab and the Command
Palette both use the same command.

**Consequences.** Reopen remains useful after a close while respecting an
explicit discard, reflects external file changes, and does not retain closed
large-file buffers in memory. The restored tab preserves pin/view metadata
and rebinds split-pane selections.

## UI-065: Drag reordering does not implicitly change a pin

**Context.** Zed supports tab dragging and treats the pinned prefix as a
separate tab group. A compact strip must not turn a drag near the group
boundary into an accidental unpin or pin, and its visible close target must
not start a drag.

**Decision.** The macOS tab strip records a non-close mouse-down tab and
reorders on mouse-up over another visible tab. The command carries pane,
source, and destination indices. Nimculus clamps a pinned source to the
pinned prefix and an unpinned source after it, then uses the shared index
remapping helper and rebinds both split-pane selections.

**Consequences.** Reordering is available without compromising pin intent,
close actions, overflow navigation, or per-pane document identity. The native
tab contract and editor-core remapping test cover the dispatch and state
boundaries.

## M20-007: Debounce session persistence without weakening recovery

**Context.** The macOS workspace timer and native idle callback each triggered
full session serialization on the same shared tick counter. In an active AppKit
event loop that repeatedly writes `session.json`, including every buffer's
state, even when neither document nor workspace state changed.

**Decision.** Explicit durable transitions (save, tab/workspace layout
changes, close, and quit) still call `persistSession` immediately. Ordinary
editor edits instead schedule a trailing persistence write one second after
the last event, capped at five seconds from the first pending edit. Both the
macOS workspace timer and Windows/native idle path only flush a due request.

**Consequences.** Continuous editing retains bounded crash-recovery latency
without serializing unchanged sessions at timer/frame cadence, reducing CPU,
I/O, and allocation churn on large open files.

## M20-008: Make native status updates state-driven

**Context.** The macOS timer polls asynchronous workspace services every
50 ms. Its idle callback replaced the same `NSTextField` string twice per
poll even when no status changed, causing needless Objective-C allocation and
layout activity in an otherwise idle editor.

**Decision.** Track the last status sent from the editor core and update the
native overlay only when the visible value differs. The Objective-C boundary
also compares its owned status string, making direct callers idempotent.
This follows Zed/GPUI's notification-driven refresh model while retaining the
existing polling cadence for terminal, Git, LSP, and workspace jobs.

**Consequences.** Background services still become visible at the same time,
but an idle editor no longer mutates AppKit chrome at 20 Hz. Text shaping and
glyph rasterization now also use the shared content viewport, avoiding rows
that the right/bottom chrome clip would discard.

## M20-009: Keep workspace polling responsive only while work is active

**Context.** FSEvents already queues changed paths asynchronously, but the
macOS fallback timer still acquired the workspace change lock and called
`stat` for every open document every 50 ms even when no search, quick-open,
or filesystem change was pending.

**Decision.** A small deterministic scheduler preserves the 50 ms cadence
while an incremental search or quick-open job is active. With no active job,
workspace maintenance runs at most every 500 ms. Session persistence retains
its own deadline check and is not delayed by this cadence.

**Consequences.** Search streams remain interactive, while an idle editor
does substantially less lock, allocation, and filesystem work. FSEvents and
external-change notices remain bounded to half a second when idle.

## M12-037: Keep keyboard and activity-bar workspace navigation equivalent

**Context.** Files, Outline, and Git were reachable from the Nimculus
activity bar and command palette, but the default shortcut registry omitted
the corresponding Zed macOS bindings. This left the visible UI incomplete for
keyboard-first development despite the underlying panel implementations.

**Decision.** Register Zed-compatible defaults: `Cmd+Shift+E` for Files,
`Cmd+Shift+B` for Outline, and `Control+Shift+G` for Git. Each forwards to
the existing command-palette command rather than duplicating panel state
transitions. The named registry entries remain configurable through
`settings.json`.

**Consequences.** Activity-bar and keyboard actions share one dispatch path,
and custom keymaps can override every default without Cocoa-specific logic.

## M12-038: Workspace panel shortcuts toggle focus, not visibility

**Context.** Zed binds Files, Outline, and Git to `ToggleFocus`: a second
shortcut returns to the editor while retaining the panel and its layout. The
first Nimculus shortcut implementation used the older visibility toggle,
which closed the dock and created unnecessary layout changes.

**Decision.** Model panel focus separately from dock visibility. A focused
panel shortcut returns native first responder ownership to the Metal editor;
an unfocused or hidden panel activates its dock and makes the native sidebar
the first responder. The default keeps the panel open, matching Zed's normal
`close_panel_on_toggle = false` behavior.

**Consequences.** Keyboard navigation works immediately after opening a
panel, a second invocation returns typing to the editor, and panel selection
survives the round trip.

## M10-025: Make the terminal toggle focus-aware

**Context.** Zed's macOS default keymap binds `Ctrl+\`` to
`terminal_panel::Toggle`. Its panel contract focuses a visible but unfocused
terminal before closing it. Nimculus had no default binding and closed an
otherwise visible terminal immediately.

**Decision.** Register `Ctrl+\`` as the configurable `toggleTerminal`
command. If the terminal is visible but does not own input, the command moves
focus to it; only an already-focused terminal is hidden. The native Metal view
remains the first responder, because it owns both editor IME handling and PTY
input routing.

**Consequences.** The shortcut has predictable two-step behavior, terminal
input is not stolen by the sidebar's native text view, and the existing PTY
process remains untouched when merely changing focus.

## M6-023: Give every native workspace sidebar an editor-focus exit

**Context.** The Files and Git sidebar uses an AppKit text overlay so it can
receive arrows and Enter. It lacked the familiar `Tab`, `Shift+Tab`, and
`Escape` route back to the editor, forcing a pointer click before editing.

**Decision.** Dispatch Tab and Escape from the shared sidebar overlay as
`sidebarFocusEditor`. The Nimculus core updates workspace focus state and
restores the Metal editor as the native first responder. This applies equally
to Files, Outline, Search, Git status, history, and branch lists.

**Consequences.** Sidebar navigation always has a keyboard exit and no panel
is hidden merely to return to editing. The native dispatch contract exercises
both keys without depending on a user window.

## M9-021: Preserve Space semantics for Files and Git Changes

**Context.** Zed uses Space as an open action in the project panel and as the
stage/unstage toggle in its Changes list. Nimculus only exposed these actions
through pointer activation or context menus, despite already tracking a stable
selected sidebar item.

**Decision.** The native sidebar dispatches Space to `sidebarOpenSelected` for
Files, Outline, Search, Git history, and branches. In Git status mode it emits
`sidebarStageToggleSelected`, which resolves the selected Git projection and
reuses the existing stage/unstage safety checks.

**Consequences.** Keyboard actions retain the same conflict, staged, and
unstaged rules as pointer actions; no Git command is created until a real
selectable change is focused.

## M7-019: Use one flat LSP-symbol projection for the Outline sidebar

**Context.** LSP returns hierarchical document symbols, while native sidebar
selection requires a stable linear row index. Nimculus flattened symbols for
the command palette but recursively rendered that flattened list in Outline,
which could duplicate child rows and left sidebar selection unregistered.

**Decision.** Retain the flattened symbol sequence together with each row's
tree depth. Outline rendering, native line count, workspace panel selection,
and navigation all use this same projection. A stable key combines name and
LSP range so refreshes retain selection across overloaded symbol names.

**Consequences.** Every visible Outline row maps to exactly one LSP range;
click, Enter, and Space move the editor cursor to that range and return focus
to the editor without duplicating nested symbols.

## M6-024: Give Files tree expansion explicit keyboard actions

**Context.** The Files panel already retained directory expansion state, but
only pointer activation could change it. Zed's project panel reserves Right
for expanding and Left for collapsing the selected directory.

**Decision.** Dispatch left/right arrow keys from the native sidebar to
`sidebarCollapseSelected` and `sidebarExpandSelected`. Right expands a closed
directory or advances into an open directory's first visible child. Left
collapses an open directory; for a closed directory or file it selects the
visible parent. The core changes only existing expansion state, then refreshes
the bounded workspace projection.

**Consequences.** Tree exploration is keyboard complete without triggering
file loads or a broad workspace rescan. Repeated Right descends through the
visible tree and repeated Left returns toward the root.

## M6-025: Route Files-panel Rename directly to the existing sheet

**Context.** The native context menu already had a Rename sheet that retains
the selected path across asynchronous completion, and the core already
validates same-root renames. The Zed-compatible F2 entry point was absent.

**Decision.** F2 dispatches `sidebarRenameSelected`; the core resolves the
selected Files row and invokes the existing native Rename sheet with that
exact path. Workspace root rows are refused because a multi-root workspace
does not own their parent names.

**Consequences.** Rename does not depend on pointer context menus, retains
the established validation and FSEvents refresh path, and cannot accidentally
rename a workspace root.

## M9-022: Make Git Changes and History keyboard-addressable

**Context.** The macOS Git sidebar renders Zed-like Changes, History, and
Branches tabs. Only pointer tab clicks reached the existing asynchronous Git
commands, while Zed reserves `Cmd+1` and `Cmd+2` for Changes and History.

**Decision.** When a Git sidebar mode owns first responder, dispatch
`Cmd+1` to the existing `git status` command and `Cmd+2` to `git log`. These
remain commands rather than a native-only selected-tab mutation, so loading,
cancellation, stale-job handling, and focus remain identical to pointer use.

**Consequences.** Git history has a keyboard entry point without duplicate
repository state. The native sidebar contract verifies both command bindings.

## UI-061: Keep document search and navigation inside the editor surface

**Context.** Find, Replace, and Go to Line were presented as `NSAlert` sheets.
They suspended the user's editing flow and made an accidental shortcut look
like a blocked application. Zed's `BufferSearchBar` instead lives in pane
chrome, takes focus when deployed, updates search without closing the editor,
and dismisses back to the active pane.

**Decision.** Use one native `NimculusDocumentSearchOverlay` above the active
Metal editor rectangle. Find updates the existing document-search command as
the query changes; Replace exposes a second field and uses the existing
atomic replace-all command; Go to Line uses the same overlay. The overlay is
not an `NSWindow` or `NSAlert`, so it never attaches a blocking sheet. Closing
it returns first responder status to `NimculusMetalView`.

**Consequences.** Cmd+F, Replace, and Cmd+L remain keyboard-first while the
document stays visible and responsive. The native contract proves the three
modes, live command routing, lack of an attached sheet, and focus restoration.

## UI-062: Present the command palette as editor chrome, not an alert

**Context.** The old `NSAlert` command palette blocked the app behind a sheet.
Zed's `CommandPalette` uses a focused picker with command completion, runs the
selected action after dismissal, and restores the previous editor focus.

**Decision.** Place a native `NSComboBox` command palette over the active
editor rectangle. Its curated, command-dispatch-compatible entries are
completion candidates; typed commands retain the existing `commandPalette:`
boundary. Input uses ordered subsequence matching (with prefix and substring
matches ranked first), so abbreviated discovery remains useful rather than
requiring an exact command string. Enter hides the palette before dispatching
and Esc restores the Metal editor first responder. No `NSAlert` or attached
sheet is used.

**Consequences.** Shift+Cmd+P no longer strands a document behind a dialog,
while keyboard completion and exact command input remain available. The native
overlay contract verifies visibility, Enter dispatch, absence of a sheet, and
Esc focus restoration.

## UI-063: Start workspace search without a blocking prompt

**Context.** Project Search in Zed retains the document and displays results
in a dedicated search surface. Nimculus already has a Search sidebar and a
cancelable background search job, but its entry action required an `NSAlert`
before that surface could be reached.

**Decision.** Reuse the editor search overlay for a Workspace Search mode.
It dispatches the existing `workspaceSearch:` command only on explicit Enter,
which avoids starting ripgrep for every keystroke. The existing result renderer
then selects the Search sidebar and streams results there; Esc simply restores
editor focus without changing the current search job.

**Consequences.** Cmd+Shift+F and the Search activity action retain a visible,
non-modal query entry point. Search remains cancellable from the persistent
Search sidebar, and document content is never replaced by search output.

## UI-064: Edit a Git commit message in the Changes surface

**Context.** Nimculus had a Commit button in its Zed-like Changes panel but
opened an `NSAlert` to collect the message. Zed keeps a commit editor in the
Git panel, so committing does not replace the workspace with a blocking prompt.

**Decision.** Place a compact native message editor beside the active Git
sidebar. Commit validates the existing non-empty message contract, hides the
editor before dispatching `commandPalette:git commit <message>`, and Esc
returns focus to the Metal editor. The existing asynchronous Git job remains
the only path that performs a commit.

**Consequences.** The primary Changes-panel operation stays visible and
keyboard-complete without weakening Git validation or creating a second commit
implementation. The native overlay contract verifies Enter, Esc, and command
routing without an attached sheet.

## UI-065: Keep Quick Open inside the editor workflow

**Context.** Quick Open already streamed fuzzy file results into the Files
sidebar, but its query was collected through an `NSAlert`. That interrupted
the editor before the result UI was even visible.

**Decision.** Add a Quick Open mode to the shared non-modal query overlay.
Enter dispatches the existing `quickOpen:` command, which retains its bounded,
cancelable fuzzy-search job and Files-sidebar result projection. The mode does
not run a filesystem search for every keystroke.

**Consequences.** File navigation has the same non-modal, editor-preserving
entry behavior as document and workspace search. The native overlay contract
verifies query dispatch and focus restoration without an attached sheet.

## UI-066: Edit supported settings without blocking the workspace

**Context.** The initial settings UI used an `NSAlert` with six controls. It
blocked the document despite settings already having an explicit validation,
persistence, and live-reload command boundary.

**Decision.** Render the supported global settings as a centered native form
above the active editor: appearance, editor and terminal font sizes, font
families, and terminal shell. Apply serializes the same six fields into the
existing `settingsApply:` command; Esc and Close leave the persisted settings
unchanged and return focus to the editor.

**Consequences.** Cmd+, is a usable editing surface rather than a blocking
prompt. The native contract covers populated values, Apply dispatch, absence
of a sheet, and Esc focus restoration; Nim remains responsible for validation
and atomic settings-file updates.

## UI-067: Constrain native editor overlays to their owning pane

**Context.** The Metal document surface clips text to its content viewport,
but native search, command-palette, commit, and settings overlays previously
kept visual minimum sizes. In a narrow split pane this could put an overlay or
one of its controls beyond the right or bottom edge of its owner.

**Decision.** Clamp every native overlay frame to the active editor pane (or
the Git sidebar for the commit editor), including height as well as width.
Each overlay clips its child controls to its own bounds. Usability at normal
window sizes retains the preferred dimensions; constrained panes shrink the
overlay rather than drawing into adjacent UI.

**Consequences.** Native chrome now follows the same four-sided containment
rule as Metal text. The GUI contract exercises a 148pt × 78pt pane and proves
that each overlay frame and its children remain contained.

## UI-068: Preserve usable workspace and pane minimum sizes

**Context.** Zed prevents normal windows from shrinking below 360pt × 240pt
and keeps side-by-side panes at least 80pt wide and stacked panes at least
100pt high when space permits. Nimculus previously stored a split ratio only,
so a divider could collapse a pane despite enough available space.

**Decision.** Apply Zed's normal-window 360pt × 240pt content minimum through
AppKit. In the platform-independent PaneTree, clamp each divider against a
recursive 80pt width / 100pt height minimum extent. If a window is already
smaller than the aggregate minimum, retain the requested ratio and never
produce a negative rectangle. Divider drags persist that same constrained
ratio, rather than merely applying the floor during paint.

**Consequences.** Split views retain a practical text-input surface during
dragging, while the layout stays well-defined even under externally imposed
small sizes. The workspace and native window contracts verify both limits.

## QA-014: Give GUI E2E authority over one exact process only

**Context.** A GUI harness must close its own temporary app after the
workflow, but command-line matching can accidentally select a developer's
interactive Nimculus, Terminal, or Codex process. This is especially unsafe
on a logged-in macOS development desktop.

**Decision.** Record the PID and full command prefix of the one direct child
started by the GUI workflow. Cleanup verifies that exact PID before sending a
signal; it never enumerates and signals matching processes. Any unexpected
descendant is reported rather than terminated. The workflow also resizes its
own window below the supported floor and verifies AppKit keeps it at least
360pt × 240pt before running Files, Search, split-pane, and Git interactions.

**Consequences.** Consolidated GUI E2E covers functional layout limits without
becoming an authority over the developer session. The acceptance fixture's
Files, Search, split, Git Changes/History, and Stage/Unstage paths are tested
in one app run while unrelated processes remain outside its lifecycle scope.

## UI-069: Convert logical top-origin frames at the AppKit boundary

**Context.** NimNUI and the Metal scene use top-origin logical coordinates,
while the macOS root `NSView` remains bottom-origin. Several native child
views (tabs, line numbers, sidebar controls, welcome content, and editor
overlays) had their logical `y` coordinate assigned directly to an AppKit
frame. A child declaring `isFlipped` changes its internal drawing coordinates,
not the coordinate system in which its parent places that frame.

**Decision.** Keep the root Metal view bottom-origin for the existing
`NSTextInputClient` screen/caret conversion and input bridge. Add one
`appKitFrameForLogicalTopRect` boundary conversion and apply it to every
logical workspace child frame. Convert legacy toolbar/header offsets into
top-origin expressions at the same time: tabs and breadcrumbs precede the
text viewport; Find and Command Palette begin at its top; Git controls precede
their scrollable list. The Metal text viewport, native overlay bounds, and
AppKit child frames now describe the same visible pane. The status and terminal
panel retain their explicit bottom-origin placement because they already
convert from logical workspace coordinates at their own boundary.

**Consequences.** Native chrome is no longer vertically mirrored relative to
the Metal editor. Pane-local containment is structural for both renderer and
native controls, including narrow split panes. The existing native overlay
contract now compares converted AppKit frames against converted pane bounds and
locks the top-edge placement of tab/header and non-modal search controls.

## UI-070: Let a narrowed workspace collapse native sidebar presentation

**Context.** The logical workspace protects the editor minimum width by
shrinking its side dock when a macOS window becomes narrow. The AppKit bridge
then reintroduced a fixed 140pt sidebar width, so Files, Git, and the activity
bar could extend beyond the window's right edge even though the logical dock
had already collapsed.

**Decision.** Derive both Metal workspace composition and native sidebar
presentation from the actual post-layout dock width. A sidebar is shown only
when there is room for its 124pt content area, 38pt activity bar, and outer
spacing. Until then its logical open state remains unchanged, but the dock as
a whole is absent from the visual composition and its width returns to the
editor. Once space returns, the same panel reappears without changing workspace
state. When presented, its width is the available dock width rather than a
visual minimum that can exceed the AppKit root.

**Consequences.** Window resize cannot create right-edge native overflow.
The native contract checks both a collapsed 520pt window and a widened window,
proving that Files/Git presentation is hidden in the former and fully bounded
in the latter. Pointer region and divider hit-testing consume the same
projected dock width, so a retired dock cannot steal editor focus or begin an
invisible resize drag.

## UI-071: Do not reserve a second macOS titlebar in workspace content

**Context.** Zed uses a transparent custom macOS titlebar and lays its
workspace chrome continuously below it. Nimculus keeps AppKit's native
titlebar, but its content layout also reserved an additional empty 24pt strip
above the breadcrumb and tab bar. The Project dock inherited the document
inset, leaving an even larger blank header before Files or Git actions.

**Decision.** Keep the native titlebar, but use the content view's top edge
for the 28pt breadcrumb and 28pt tab strip: editor text starts at 56pt. The
native workspace sidebar is positioned from the workspace top and spans the
same vertical extent as the breadcrumb, tabs, and editor surface; it no longer
inherits the document-only top inset.

**Consequences.** The editor gains 24pt of usable height and Project/Git
controls are immediately discoverable at the top of their panel. Pane-local
overlays retain their existing top-edge containment. The non-modal native
overlay contract exercises the revised sidebar and commit-editor bounds.

## UI-072: External file changes must not block the editor window

**Context.** External-change detection used an asynchronous `NSAlert` sheet.
Although it did not enter a nested modal run loop, AppKit still disabled the
parent document window while the sheet was present. A formatter, Git operation,
or another editor could therefore interrupt typing and leave the application
apparently stopped.

**Decision.** Present one compact floating child notification with explicit
`Reload` and `Keep Editing` actions instead of an attached sheet. It remains
visible until one action is chosen, but the document window stays interactive:
the user can continue editing, save, navigate, or switch tabs. The notification
tracks the single pending external-change decision already maintained by the
editor core, so coalesced FSEvents cannot stack prompts.

**Consequences.** External modifications remain explicit and never overwrite an
in-memory buffer automatically, while they no longer block normal work. The
native contract verifies that no sheet is attached, the parent retains first
responder input, and the Reload action dismisses the notification and reaches
the editor command callback.

## UI-073: An open workspace replaces the launch welcome surface

**Context.** Starting Nimculus with a project path correctly populated the
Files tree, but the final no-document startup branch re-enabled the welcome
surface. The project was therefore open but visually covered, making the
primary project interactions appear unavailable.

**Decision.** Treat the welcome page as a no-workspace launch surface, not as
an empty-editor surface. Opening a workspace explicitly hides it. Cursor and
native editor synchronisation retain that rule while no document is selected;
the welcome page returns only when neither a document nor a workspace exists.

**Consequences.** Folder launches, restored workspaces, and the Files panel
all enter directly into the project view. Empty workspaces retain a clean
editor canvas and the visible project tree instead of competing calls to
action.

## LSP-074: Route inlay hints by document, not focused pane

**Context.** A split editor can display two documents while sharing one LSP
session. A single inlay-hint result stored against the focused pane is unsafe:
the response may arrive after focus changes, or a secondary document may be
shown while the primary document remains the bridge's active request target.

**Decision.** Keep an inlay-hint cache keyed by file URI and attach every
request to its document path and document version. On a text change, invalidate
only that document's cache and discard a response from an older version. The
macOS native backend receives separate primary and secondary annotation
buffers, text ownership arrays, overlays, and viewport clipping. This follows
Zed's buffer-local inlay-hint cache boundary while preserving Nimculus's
platform-specific Cocoa/Metal rendering contract.

**Consequences.** Switching focus or changing the split layout cannot move
annotations into the wrong editor. Empty responses clear the requesting
document's visible annotations, and a stale response cannot replace a newer
snapshot. The native contract checks pointer, count, and owned-string
separation for both panes.

## UI-075: Keep split-pane viewport calculations local

**Context.** The primary and secondary macOS editor panes can display different
documents and have different heights in a horizontal split. Reusing the
primary document's line count or visible-line budget for secondary scrolling
allowed the secondary pane to overscroll, clip syntax ranges against the wrong
buffer, and position its cursor using the wrong viewport.

**Decision.** Derive the visible-line budget from each pane's actual native
editor bounds. Route scroll clamping, trackpad fractional remainder, cursor
visibility, and syntax visible ranges through the focused pane's document and
view state. Keep the primary and secondary scroll remainders separate, just as
Zed keeps scroll state and viewport queries on the owning editor/pane.

**Consequences.** A horizontal split remains bounded when its documents have
different line counts, and resizing one pane does not change the other pane's
scroll behavior. The shared UI/editor contracts continue to own interaction
semantics while the macOS platform layer supplies pane-specific geometry.

## UI-076: Make multi-selection a user-visible editor feature

**Context.** The editor buffer already supported atomic `applyEdits`, but the
application exposed only one selection and one caret. That made the M4
"multiple cursors" capability an internal API property rather than a usable
macOS editor feature. Zed's editor keeps a collection of selections and routes
text edits through all non-overlapping ranges in one transaction.

**Decision.** Keep the existing primary `Selection` field as the compatibility
boundary and add pane-owned `additionalSelections`. Normalize ranges in
document order before editing, reject duplicates/overlaps at the view boundary,
and apply insertion, deletion, cut, and paste through `PieceTable.applyEdits`.
Expose macOS entry points matching the reference interaction model:
Option-click, Cmd+D, Cmd+Shift+L, and Option+Shift+Up/Down. Persist additional
selections with the tab view state.

The Cocoa/Metal boundary receives a bounded array of UTF-8 byte ranges and
caret positions for each pane. Core Text renders every selection inside the
same four-sided text clip and paints additional carets after the text overlay.
The existing single-selection setter remains valid for native contracts and
compatibility callers.

**Consequences.** Multi-selection is now visible, editable, undoable, and
restorable in the macOS application, while the editor core remains independent
of Cocoa. Movement commands collapse additional selections as in a normal
single-caret navigation, so the behavior is predictable when leaving a
multi-selection operation. The native array is capped at 256 entries to keep
per-frame ABI work bounded.

## UI-077: Synchronize the selected tab at the session/UI composition boundary

**Context.** `EditorSession.activeTab` is updated when a startup path, Finder
open event, or Files-panel activation selects a document. The macOS workspace
also keeps a pane-local tab index. If a restored single-pane index remained
valid after a new document was activated, the editor could render one document
while highlighting a different tab.

**Decision.** For a non-split editor, synchronize the first pane's tab index
from `EditorSession.activeTab` whenever the session tab collection is refreshed.
Split panes retain independent pane-local selections. This keeps the document,
breadcrumb, caret/IME target, and highlighted tab on one activation boundary,
including direct startup paths and Finder/Open With.

**Consequences.** A file opened from the command line or Finder is immediately
represented by the selected tab, and the tab label cannot drift from the
document shown in the editor. Split-pane tab ownership remains unchanged.

## UI-078: Keep the native Files selection row readable while inactive

**Context.** The macOS Files panel uses an `NSTextView` so keyboard navigation,
selection, and accessibility stay native, while NimNUI supplies the full-width
theme selection background. AppKit paints an inactive selection after the text
view's own attributes. Painting the theme row afterward therefore covered the
selected filename, and the two coordinate systems also differed by half of the
fixed row height.

**Decision.** Keep AppKit's semantic selected range, position the custom row
background using the fixed 18pt line fragment's half-line correction, and
redraw the selected glyph range after the theme background. The native text
selection remains available to keyboard/accessibility consumers, while the
visible row uses NimNUI's selection color and retains readable foreground text.

**Consequences.** Files, Git, and Outline selections share one readable native
presentation even when the editor owns first responder. Stable row alignment is
preserved across workspace refreshes without a one-row visual drift or a pale
inactive strip hiding the selected path.

## UI-079: Keep Outline useful before LSP symbols arrive

**Context.** Tree-sitter already parsed the active document, but the macOS
Outline panel was populated only by asynchronous LSP document symbols. A plain
local project, a language server that was still starting, or a server that did
not implement document symbols therefore showed an empty panel even though the
editor had enough syntax information to provide useful declarations.

**Decision.** Project Tree-sitter outline items into the same native Outline
contract as LSP symbols whenever the active document has no valid LSP symbol
snapshot. Use the buffer's explicit UTF-16 position conversion when creating
the ranges, because the editor's grapheme columns are not an LSP protocol
position. Prefer the LSP snapshot once it arrives, and keep symbol activation
on the same UTF-16 range in either mode.

**Consequences.** Outline is immediately actionable during local editing and
does not depend on a language-server process for its basic navigation. LSP
hierarchy and richer symbol kinds still replace the flat local fallback when
available. Nim declaration nodes (`proc_declaration`, `template_declaration`,
and type declarations) now extract their declared identifier rather than a
later enum member or raw node kind.

## UI-080: Expose syntax selection expansion through the macOS editor

**Context.** The Tree-sitter layer already exposed syntax-node selection
expansion, but it was only a library operation. Users could not invoke the
feature from the editor, so the M7 selection-expansion capability was not a
functional macOS feature.

**Decision.** Follow Zed's macOS keymap and bind `Cmd+Ctrl+Right` and
`Cmd+Ctrl+Left` to expand and shrink the active selection. Select the smallest
strictly larger syntax node for expansion, and the largest child node that
contains the focused cursor for shrinking. Route both operations through the
focused pane's existing cursor/selection boundary, refresh syntax and native
IME state, and persist the resulting view state.

**Consequences.** Syntax-aware selection is now reachable from both the
keyboard and command palette (`expand selection` / `shrink selection`) without
adding Cocoa types to the editor core. The operation stops at the parsed
syntax-tree leaf and reports that state instead of silently changing an
unrelated range.

## UI-081: Reconstruct syntax siblings from Tree-sitter ranges

Zed's `SelectNextSyntaxNode` and `SelectPreviousSyntaxNode` operate on syntax
siblings, and climb to a parent when the current node has no sibling. The
Nimculus Tree-sitter bridge intentionally exposes a flat, immutable node stream
rather than leaking Tree-sitter cursor types into the editor layer.

The syntax service therefore reconstructs immediate children from strict range
containment, selects the adjacent child, and repeats the search at the parent
when necessary. `Cmd+Ctrl+Up/Down` and the command palette use this service
through the focused editor selection boundary. This keeps the macOS interaction
contract aligned with Zed while keeping the platform-independent syntax module
free of Cocoa and editor-session state.

## UI-082: Keep syntax folding as an item-owned display map

Zed folds syntax ranges in a display map while preserving the underlying buffer
and anchor positions. Nimculus follows the same boundary: `EditorViewState`
owns byte-anchored `FoldRange` values, Tree-sitter derives candidates, and the
macOS backend receives only a derived source-line range. The native renderer
skips folded body lines in text, glyph atlas, line numbers, indentation guides,
and hit testing; it never rewrites the document string or LSP byte offsets.

`Cmd+Option+[` and `Cmd+Option+]` follow Zed's macOS fold/unfold bindings. The
command palette additionally exposes current, all, toggle, and unfold actions.
Entering a folded body automatically removes the containing fold so keyboard,
mouse, and IME positions remain reachable. Primary and secondary panes retain
independent fold maps.

**Consequences.** Folding stays local to a view and invalid ranges are ignored.
Syntax highlighting, diagnostics, Git annotations, and text input continue to
address the original UTF-8 document; only their native display projection is
compressed.

## UI-083: Derive structural brackets from the syntax snapshot

Zed's enclosing-bracket navigation uses language-aware bracket ranges rather
than scanning every delimiter in the raw buffer. Nimculus keeps the compact
Tree-sitter bridge, but derives exclusion ranges for string and comment nodes
before scanning structural delimiters. The Zed selection bias is preserved:
the smallest enclosing pair is preferred, a bracket directly under the cursor
gets priority, and moving from a closing bracket lands on the matching
opening bracket.

The raw-string overload remains available for documents without a parsed
grammar. The macOS editor uses the syntax-aware overload whenever the active
Tree-sitter snapshot is valid, so brackets in comments and literals cannot
change cursor navigation or fold structure.

## UI-084: Keep fold commands semantically separate

Zed distinguishes `Fold`, `UnfoldLines`, `ToggleFold`, recursive folding, and
fold-at-level actions. Nimculus therefore keeps a focused-pane fold map but
does not implement `Fold` as an accidental toggle: repeated Fold/Unfold
commands are idempotent, while ToggleFold alone removes an existing range.
Recursive commands operate on the smallest enclosing syntax range and its
contained ranges. Fold-at-level commands derive nesting depth from the
deduplicated Tree-sitter ranges and expose levels 1 through 9 through the macOS
command palette.

All operations update only the display projection, then resynchronize native
line visibility, hit testing, syntax overlays, and persisted view state.

## UI-085: Keep Files panel creation and trash actions at the selection boundary

Zed's macOS Project Panel makes the selected row the target for `Cmd+N` (new
file), `Cmd+Option+N` (new directory), and Backspace/Delete (move to Trash).
Nimculus now dispatches those shortcuts from the native Files overlay to the
selected workspace entry. The macOS delegate owns the alert sheet and captures
the selected path before the asynchronous response; Nim owns path validation,
workspace-root protection, filesystem mutation, refresh, and editor-tab
updates. New files and folders resolve a selected file to its parent directory,
matching the existing context-menu behavior, while deleting a workspace root is
rejected before a destructive sheet can appear.

This keeps keyboard activation and the existing right-click menu on one native
path without adding Cocoa state to the workspace model.

## UI-086: Make implemented editor services discoverable from Command Palette

Zed treats the command palette as a primary action surface, not a short list of
the most common shortcuts. Nimculus had already implemented LSP, syntax, Git,
workspace, terminal, task, and settings dispatch, but its native palette only
listed a small subset of those actions. The palette now exposes the complete
macOS no-argument action set, including replace/go-to-line/quick-open,
Tree-sitter selection and folding, Git hunk operations, terminal/task control,
LSP navigation/actions/signature/inlay/semantic/formatting, update checks, and
settings.

Actions that need user data retain their explicit command syntax (`rename
<new-name>`, `run task <command>`, `apply code action <number>`). Bare `git
commit` opens the existing commit editor instead of creating an implicit empty
commit. Replace, go-to-line, and quick-open use AppKit overlay entry points so
they remain non-modal and return focus to the editor consistently with the
existing menu actions.

The native combo box can retain the user's fuzzy spelling in `stringValue` even
when the first visible result is the selected candidate. Confirmation therefore
resolves the selected/result command before dispatching; otherwise typing `sav`
would close the palette and send an unknown `sav` command. Explicit argument
forms are detected before this resolution so task, rename, LSP, and Git
commands continue to carry their user-provided suffix.

## UI-087: Clip every editor overlay in the same local text viewport

Metal text and Core Text already share a four-sided content viewport, but
AppKit child overlays have their own draw coordinates. The line-number and
indent-guide overlays therefore clip locally to the pane's text viewport,
including the top and bottom insets, instead of using the complete editor
pane. Split-pane annotation drawing also selects the matching secondary
annotation buffer before converting document positions. This keeps scrollbar,
tab/status chrome, and the adjacent split pane outside every text decoration.

## UI-088: Route macOS View menu actions through the existing command boundary

Zed exposes workspace docks and editor presentation controls from its native
macOS View menu. Nimculus therefore adds Files, Outline, Git, Terminal, and
Soft Wrap entries to the AppKit View menu, but keeps the menu layer free of
workspace or editor mutation logic. Each item carries the same command string
used by the activity bar and command palette and dispatches through the existing
`g_command_callback` boundary.

This preserves one source of truth for focus, panel visibility, terminal
lifecycle, and soft-wrap state. The native menu only owns labels and standard
key equivalents; Nim owns state transitions and persistence. The native menu
contract invokes every new item and verifies the exact command payload, so a
visible menu item cannot silently become a presentation-only affordance.

## UI-089: Synchronize editor horizontal scrolling before retained paint

The native editor measurement is authoritative for the widest visible line,
but retained Nim paint commands must be built only after the current pane
rectangle and soft-wrap mode have crossed the platform boundary. Each render /
sync turn therefore clamps primary and secondary `scrollX` through the shared
editor geometry contract, mirrors the native result back to the view state, and
forces zero in soft-wrap mode. The same turn emits the horizontal thumb when
the measured content overflows.

Scrollbar paint remains on the semantic kind-10 path, but its Metal scissor is
the owning editor pane rather than the text-only viewport. This preserves the
bottom chrome band where the horizontal thumb lives while retaining the
existing command and dirty-region flow. `NIMCULUS_SCROLL_DEBUG=1` provides a
single native diagnostic with widest width, viewport, offset, track, and thumb
geometry for live macOS verification.

## M17-089: Keep extensions manifest-driven and permissioned

Zed's extension host separates discovery, manifest metadata, host registration,
and executable extension processes. Nimculus adopts that boundary for macOS:
`extension_service.nim` discovers `extension.json` files in global and
workspace roots and registers language, Tree-sitter grammar, LSP, theme, icon,
snippet, task, and command metadata without loading code into the editor.
External processes require an explicit `process` permission in the manifest.
There is no Node.js runtime, VSCode API compatibility layer, or direct native
shared-library loading. WASM and a versioned extension API remain follow-up
work after the data-backed contract is stable. The registry now negotiates
API version 1 and validates the WebAssembly magic/version header and root-safe
module path before registration. It still does not execute a module until an
explicit WASM runtime and host API are selected.

## M18-090: Own CLI agent processes per session

Zed's agent thread owns its process, working directory, worktree identity,
output, and lifecycle independently of the editor buffer. Nimculus follows the
same ownership model in `agent_service.nim`: each session has bounded UTF-8
output, prompt input, Git change snapshots, diff/review operations, and a
bounded stop/kill/reap path. `AgentManager` supports concurrent sessions and
active-session selection. The UI only dispatches commands and renders output;
it never embeds an agent runtime or assumes a vendor-specific protocol.

## M18-098: Resolve supported CLI agents at the process boundary

The initial macOS agent targets are Codex CLI, Claude Code, and OpenCode, but
Nimculus must not embed a vendor SDK or silently weaken a provider's approval
policy. `agent_service.nim` resolves an explicit `NIMCULUS_AGENT_COMMAND`
first, then an explicit `NIMCULUS_AGENT_PROVIDER`, and finally probes the
documented provider priority (`codex`, `claude`, `opencode`) with `findExe`.
The Command Palette and Agent menu expose each provider explicitly as well as
an Auto entry. Provider-specific arguments are limited to display/transport-
safe options (`codex --no-alt-screen`); no dangerous approval or sandbox
bypass flag is inserted. The resolved executable path and provider label are
retained in the session UI, while the existing bounded stdin/stdout,
worktree, diff-review, and direct-child cleanup boundary remains unchanged.

## M19-091: Keep DAP framing and debugger state separate from UI

Zed's DAP implementation uses a framed transport, monotonic request sequence,
pending-request tracking, and a session-owned adapter process. Nimculus mirrors
those responsibilities in `dap.nim`: Content-Length framing is byte-accurate
and bounded, partial/multiple frames are retained safely, stale requests are
discarded, and adapter termination is bounded. The macOS UI projects protocol
events into the existing Task output panel and Debug menu. Reverse adapter
requests are answered without blocking the event loop. `runInTerminal` starts
the requested direct child through the bounded task service and returns its
PID; unsupported reverse requests receive an explicit bounded failure response
instead of leaving an adapter waiting forever. Response sequences are allocated
from the same client sequence space without polluting pending request state.

## M18-092 / M19-093: Keep worktree and remote-debug routing explicit

An agent session assigned to a Git worktree must execute in that worktree; a
metadata-only assignment would let the CLI mutate the wrong checkout. The
agent manager therefore uses the selected worktree as the child process cwd,
keeps it as the diff/review root, and exposes bounded next/previous session
selection. Patch application is an explicit command and is checked with
`git apply --check` before mutation.

For DAP, launch and attach are separate protocol requests. A local adapter is
started directly, while a remote adapter uses the macOS `nc` byte-stream bridge
when `NIMCULUS_DAP_HOST`/`NIMCULUS_DAP_PORT` are configured. Both routes use the
same DAP decoder, request tracker, event projection, and bounded shutdown path;
the UI never creates a second transport implementation.

Responses are consumed through `acceptResponse`, which removes the pending
entry and rejects cancelled, expired, or unknown request sequences before the
UI sees them. Adapter exit also calls the session stop path to close the
process handle rather than merely dropping the Nim reference.

## M19-094: Project DAP state into a dedicated macOS Debug panel

Zed's debugger UI keeps session navigation and inspection separate from its
console output. Nimculus now mirrors that boundary: DAP protocol output remains
in the bounded bottom Task Output surface, while Threads, Stack Frames, Scopes,
Variables, and Watches are projected into the macOS Debug sidebar. Each visible
row is assigned a stable panel item and the AppKit line map excludes section
headers from activation. Enter/Space selects a thread or frame, requests the
selected scope, and expands/collapses variables through their
`variablesReference`. Activating a frame also opens its absolute source path in
the focused pane, moves the pane cursor to the adapter's zero-based line, and
keeps the line visible. The Debug activity-bar command opens the panel without
moving first responder away from the editor. This keeps the current
text-backed native surface compatible with a future richer tree renderer while
already providing the user-visible debugger actions.

## M19-097: Own DAP runInTerminal children through the task boundary

Zed responds to DAP reverse requests through the transport rather than logging
and abandoning them. Nimculus handles `runInTerminal` on the macOS idle path by
validating the adapter-provided command, cwd, and string environment entries,
starting the direct child with `TaskJob`, and returning both `processId` and
`shellProcessId`. The job is polled without blocking AppKit and is cancelled
before DAP/session shutdown. `startDebugging` now creates a separate child
adapter session. The parent transport remains selected in the Debug panel
while the child owns an independent request tracker and lifecycle.

## M19-099: Keep DAP reverse child sessions independent

Zed's `handle_start_debugging_request` creates a new session from the parent
adapter configuration, registers it separately, and does not replace the
parent session selected by the debugger panel. Nimculus follows that boundary
for macOS: a `startDebugging` reverse request validates the `launch`/`attach`
kind and object configuration, starts a separate local or remote
`DapSession`, performs its own `initialize` then launch/attach request, and
acknowledges the parent request after the child transport exists. Child
sessions are polled on the idle path, shown in a Debug sidebar Child Sessions
section, and stopped during parent failure, explicit stop, and application
shutdown. Unsupported reverse requests from a child receive a bounded
negative response. Real target acceptance remains subject to the same macOS
debugserver permissions as the parent.

## M17-095: Install extensions through an explicit macOS sheet

Zed's extension store and host keep installation, manifest discovery, and WASM
execution as separate boundaries. Nimculus now exposes an explicit
`Install Extension…` action in the Extensions menu and Command Palette. The
AppKit sheet returns a local directory to Nim, where `extension_service.nim`
validates the manifest, safe directory id, WASM container/root boundary, and
symlink-free tree before copying into `~/.nimculus/extensions/<id>` through a
temporary directory and same-volume rename. Existing installations are not
silently overwritten. Since no Wasmtime-compatible runtime is bundled yet,
the UI reports validation/registration only and never presents header
validation as WASM execution.

## M17-100: Keep the first WASM host behind a direct Wasmtime argv boundary

Zed's extension host uses Wasmtime's Component Model and WASI linker rather
than treating a WASM file as an arbitrary executable. Nimculus now separates
the same concerns in `wasm_runtime.nim`: manifest validation happens before a
`WasmExecutionPlan` is created, Wasmtime is resolved from the explicit
`NIMCULUS_WASMTIME` override or the well-known `PATH` binary, and execution
uses direct argv with no shell interpolation. The plan preopens only the
extension root as `/extension` and passes the extension id/API version as
explicit guest environment values. The task boundary owns output, cancellation,
and direct-child cleanup. Both core-module and Component Model headers are
recognized. `wasmEntrypoint` is optional and is passed through `--invoke` only
when declared by the manifest; Component Model entries use Wasmtime's explicit
Wave call syntax such as `run()`. This is an executable macOS
WASM slice, not a claim that the full Zed WIT host API has been implemented;
the first in-process Component Model linker is now present, while the full
capability-specific WIT surface remains an explicit follow-up
work.

## M19-096: Resolve Apple's DAP adapter without an environment-only gate

Apple's `lldb-dap` requires `pathFormat` during `initialize`; a direct
protocol probe on the available Xcode adapter rejected the old request and
accepted the corrected one. Nimculus now sends `pathFormat: "path"` and
resolves the adapter in this order: `NIMCULUS_DAP_COMMAND`, the standard Xcode
bundle locations, then `xcrun --find lldb-dap` so `DEVELOPER_DIR` remains
respected. The existing command/argument/program environment variables remain
available for non-LLDB adapters and project-specific launch configurations.
The 2026-08-02 direct probe accepted `initialize` but macOS debugserver denied
launching `/bin/sleep` with `Not allowed to attach to process`. Nimculus treats
that as an adapter failure, stops lldb-dap, cancels any `runInTerminal` children,
and leaves the Debug panel in a clean no-session state; it is not converted into
a false launch-success result.

## M19-101: Preserve standard and Apple DAP attach argument names

Apple's `lldb-dap` does not consume the generic DAP `processId` field for an
attach request; it requires the adapter-specific `pid` field. The macOS client
therefore sends both `processId` and `pid` from the shared `attachArguments`
helper. Standard adapters can continue to consume `processId`, while Apple's
adapter receives the field it actually implements. A real C target is compiled
inside the macOS DAP integration test and verifies launch through a breakpoint
to stack/scopes/variables as well as attach to a running process with
`stopOnEntry`. This keeps the compatibility decision at the protocol boundary
instead of hiding it in UI-only launch paths.

## M17-101: Keep the optional Component host dynamically resolved and bounded

Zed's `WasmHost` compiles a Component with Wasmtime's Component Model linker,
adds WASI, and exposes extension capabilities through an explicit host boundary.
Nimculus now has a macOS-only first slice of that boundary in
`wasm_component_host.c`. It resolves the official Wasmtime C API with
`dlopen`/`dlsym` instead of linking to Homebrew or requiring development
headers, and rejects a missing or incompatible library by retaining the CLI
fallback. The host enables the Component Model and fuel, limits store memory
and instance resources, provides only the extension root as `/extension`
(read-only unless `filesystem-write` is declared), and passes the extension id
and API version as explicit WASI values. Manifest/container validation occurs
before the C call, and every owned Wasmtime object is released on both success
and failure paths.

The current C boundary intentionally calls only an explicit no-argument export
(`init-extension` by default, or the manifest entrypoint with a trailing `()`
removed). It is not yet the full Zed WIT host API. The export runs on a native
worker, is polled from the macOS idle callback, and uses Wasmtime epoch
interruption for cancellation; the Cocoa thread never enters Wasmtime. Core
modules continue through the existing responsive CLI task path. Versioned WIT
bindings and capability-specific host functions remain the next M17 slices;
permission presentation is implemented as an asynchronous macOS Allow/Deny
sheet.

## M17-102: Make the first host contract explicit and permissioned

The local Zed WIT review shows that an extension world is more than a WASI
filesystem: it imports platform, process, HTTP, and worktree resources and
exports versioned extension callbacks. Nimculus does not claim compatibility
with that whole world until each import has a real macOS implementation.
Instead, API version 1 publishes the small capability contract that is
actually granted today: `filesystem-read` and optional `filesystem-write`.
The contract is passed as `NIMCULUS_EXTENSION_HOST_API_VERSION` and
`NIMCULUS_EXTENSION_CAPABILITIES` to both the direct CLI and Component host.
Manifest permission names are allow-listed, unsupported host capabilities are
rejected before execution, and no capability is inferred from a declaration.

Additional permissions are an application interaction. A local extension
install or WASM run that requests `filesystem-write`, `process`, or `network`
uses an asynchronous AppKit Allow/Deny sheet; the Cocoa thread remains usable
while the decision is pending. The next WIT slice must add one capability,
tests, and a user-visible action together, using Zed's corresponding WIT and
host implementation as the reference.

## M17-103: Keep catalog synchronization separate from extension installation

The catalog boundary follows Zed's separation between extension metadata and
the host that installs and runs an extension. `extension_catalog.nim` accepts
only version-1 JSON with bounded entry count, safe IDs, HTTPS archive URLs, and
SHA-256 digests. `extensions catalog` fetches this metadata through a direct,
bounded curl task; it does not mutate the extension directory. `extensions
install <id>` downloads the verified archive asynchronously, inspects its
manifest, presents the same macOS permission sheet as local installation, and
only then extracts the ZIP in a temporary directory. The existing registry
performs symlink rejection and atomic destination creation. This makes an
untrusted catalog unable to grant itself a permission or overwrite an
installed extension.

## M17-104: Add the Zed platform WIT capability before the rest of the world

Zed's generated Component linker adds the versioned extension world to a
Wasmtime linker. Its first platform contract is
`zed:extension/platform.current-platform`, which returns the operating system
and architecture as WIT enums. Nimculus now mirrors that exact import name and
tuple shape in the macOS native linker and returns `mac` plus `aarch64` on the
Apple Silicon build. A checked-in WIT fixture is generated into a test
component and used to validate the import/export boundary when an
architecture-compatible Wasmtime C library is installed.

The rest of Zed's imports are not silently treated as available. Wasmtime's
`define_unknown_imports_as_traps` API resolves them to deterministic traps, so
an extension cannot infer process, network, or other capabilities from a
declaration alone. Each future WIT capability must add its host implementation,
permission contract, user-visible action, and runtime test together. The C
library is resolved through stable Homebrew `opt` paths and rejected when its
architecture cannot be loaded by the arm64 process; the direct Wasmtime CLI
remains the fallback for core modules and Component execution stays optional.

## QA-015: Make the macOS GUI workflow exercise user command boundaries

**Context.** The earlier macOS GUI smoke proved that a packaged Nimculus
window appeared in WindowServer, but it did not prove that Files, the editor,
Git History, and the integrated terminal were connected as one user-visible
workflow. Zed's visual test runner opens the Project Panel and a document
before moving to the next surface, so the same ordering is useful here.

**Decision.** Add an opt-in asynchronous workflow to the packaged application.
The harness opens Files, opens the first workspace file, invokes Git History,
opens a new terminal, and closes it. Git and terminal actions must enter through
the same `commandPalette:*` dispatch used by the visible macOS commands; raw
internal dispatch labels are not accepted as proof. The result is written to a
temporary file, and cleanup signals only the exact app PID started by the
harness.

**Consequences.** `scripts/test_macos_gui_workflows.sh` now validates the
Files-to-editor-to-Git-to-terminal path in one run without depending on flaky
Accessibility scripting. This is functional integration evidence, not proof of
physical IME behavior, pixel-perfect rendering, eight-hour stability, or signed
notarized distribution.

## UX-016: Make the macOS titlebar part of the Nimculus workspace

**Context.** A screenshot comparison with Zed showed that Nimculus used an
AppKit-owned white titlebar above a dark editor surface. The visual boundary
was inconsistent with the rest of the workspace and exposed no workspace
context in the window chrome.

**Decision.** Use `NSFullSizeContentView` and a transparent AppKit titlebar.
AppKit continues to own the traffic-light controls, while a Nimculus root
content view draws the dark titlebar, workspace name, and current Git branch.
The document breadcrumb remains in the editor header as the single document
location display. The branch badge is an accessible native button and a real
Git entry point: clicking it opens the existing branch panel. The Metal editor
remains in a child frame below the 30pt titlebar so existing content metrics,
IME coordinates, and editor clipping remain unchanged. Titlebar dragging and
double-click zoom are handled by the application-owned titlebar view.

**Consequences.** The macOS window now presents one continuous Zed-like
workspace surface and keeps the titlebar as a visible UX entry point. Any
future titlebar controls must be added to the same root view and must preserve
the traffic-light hit regions.

## UX-017: Treat footer, tabs, and context menus as first-class feature entry points

**Context.** Static extraction from Zed's `StatusBar`, `Pane`, `Tab`, and
context-menu builders showed that the previous Nimculus UI compressed several
independent controls into one status string and omitted editor-text context
menus. A screenshot could therefore look complete while user actions were
still unavailable.

**Decision.** Keep the footer as structured tab-separated items with separate
layout and hit testing. It exposes active file, cursor position, indentation,
encoding, line ending, language, and LSP state. Add native editor-text context
menus and complete tab context actions, plus explicit tab-bar new-item and
split menus. Bulk tab operations close clean tabs only; dirty tabs remain for
the existing confirmation flow.

**Consequences.** Footer and tab controls are now visible interaction surfaces,
not decorative text. The mechanical inventory in
`docs/ZED_UI_ELEMENT_INVENTORY.md` and `tools/extract_zed_ui_inventory.sh`
must be rerun when Zed reference UI code or Nimculus workspace chrome changes.

## UX-018: Use a semantic palette derived from Zed theme roles

**Context.** The previous theme boundary exposed only background, foreground,
accent, selection, and border. That made the titlebar, editor, panels, tabs,
footer, terminal, and Git states drift toward hard-coded colors and made a
theme change incomplete from the user's perspective.

**Decision.** Model theme colors by semantic role and initialize the built-in
dark and light palettes from Zed's One Dark and One Light definitions. Nimculus
serializes the resolved palette once at the Nim/AppKit boundary; Metal and
AppKit resolve the same role names for surfaces, text hierarchy, selection,
focused states, tabs, status surfaces, scrollbars, terminal, and Git status.
Custom themes may override individual roles and inherit the remaining roles.

**Consequences.** A palette update now repaints the whole workspace rather than
only the editor background. New UI surfaces must consume a semantic role or
add one to `ThemeColors`, instead of introducing a local calibrated color.

## UX-019: Make workspace chrome boundaries explicit

**Context.** A visual audit of the packaged macOS window found that the
logical Metal layout and the AppKit presenters used different outer dock
insets. The result was an 8pt gap between the editor and Files panel and an
additional 8pt gap at the right edge. The editor also reserved an obsolete
8pt strip above the status bar.

**Decision.** The macOS left dock owns the full rectangle beginning at the
window's left edge and ending at the editor's left edge. The activity bar is
the outermost 34pt slot and the Files/Git scroll container begins immediately
inside it, with a 4pt internal gap. The editor owns x=28pt for its
line-number/content gutter, its tab strip and breadcrumb each occupy 28pt
above the pane, and its text ends directly at the 22pt logical status bar. The
native titlebar remains a separate 28pt AppKit region above the Metal content
view.

**Consequences.** The native sidebar contract now verifies editor-to-sidebar
and sidebar-to-activity-bar adjacency as well as root containment. Future
workspace chrome changes must distinguish an intentional component inset
(text, gutter, activity-button padding) from an outer layout gap.

## UX-020: Derive editor text placement from font metrics

**Context.** The first and last visible editor rows were being clipped even
though the pane rectangle and Metal scissor were technically contained. The
previous renderer positioned rows from a fixed baseline and submitted a
partially visible final row.

**Decision.** Follow Zed's text-system rule: calculate the baseline from font
ascent, descent, line-height, and top padding, then apply a small glyph safety
inset. Hit testing, cursor placement, caret geometry, Core Text fallback, and
glyph-atlas placement use the same line-box origin. The visible-row budget is
floored so a partial final glyph is never submitted.

**Consequences.** The editor may show one fewer row at the bottom, but every
visible glyph is complete and remains inside the content viewport. Text
layout changes must update the shared line-box helpers rather than adding a
renderer-specific y offset.

## UX-021: Adopt Zed's left workspace dock and two-row document chrome

**Context.** The macOS presentation had a right-side dock, a breadcrumb above
the tabs, and a tab strip that reserved a fixed navigation band. Those choices
made the workspace geometry diverge from the logical left-dock model and from
Zed's default affordance order.

**Decision.** Present the activity bar at the outer left edge and the Files,
Search, and Git panels immediately inside it. Keep the titlebar as the native
AppKit row, followed by a 28pt tab row and a 28pt breadcrumb row. Branches are
light text buttons beside the workspace name. The shared workspace model keeps
OS-free dock ownership and hit-test contracts; only the macOS presenter maps
those contracts to AppKit views.

**Consequences.** Existing right-dock contract tests remain valid for explicit
right-side projections, while the macOS default is now left-side. Editor text
continues to begin below both rows, and the titlebar remains outside the Metal
content coordinate system.

## UX-022: Use measured tabs and native tab-bar controls

**Context.** Fixed-width tabs, a 160pt reserved navigation block, a painted
`2/41` counter, and hand-drawn control glyphs made tab labels and actions
ambiguous and did not provide native hover, tooltip, or accessibility behavior.

**Decision.** Measure each tab label with AppKit font metrics, cap its content
width, and expose a content-width scrolling window around the active tab. Draw
the close affordance only for the active or hovered tab, retaining the dirty
bullet in the label. Use native SF Symbol `NSButton` controls for previous,
next, open-tabs, new, split, and zoom actions, routing each through the
existing command boundary.

**Consequences.** Tab hit testing uses the same measured widths as painting,
so selection, close, context, and drag reorder stay aligned. The tab presenter
owns only AppKit UI state (hover and button views); document ownership and
commands remain in Nimculus core.

## UX-023: Centralize chrome tokens and semantic light/dark roles

**Context.** Workspace chrome mixed hard-coded spacing and calibrated colors,
which made panel boundaries and theme changes inconsistent.

**Decision.** Keep `space1`, `space2`, `space3`, `rowHeight`, and
`controlHit` in the macOS presentation layer and resolve chrome colors through
`themeRoleColor` using the semantic roles `chromeBg`, `tabBar`, `tabActive`,
`border`, `fgPrimary`, `fgMuted`, and `accent`. Custom palettes continue to
override these roles through the existing theme bridge, with light and dark
fallbacks for missing roles.

**Consequences.** New macOS chrome must consume a token or semantic role
instead of adding a local literal. Theme updates restyle native controls and
repaint the same surfaces without changing the NimNUI/core dependency
direction.

## UX-024: Keep panel titles and actions in one Zed-aligned header row

**Context.** The macOS Files and Search actions were rendered in a detached
toolbar above the panel title. Git placed its Changes actions in a second
toolbar row, so panel controls were visually separated from the title they
modified.

**Decision.** Add a native `NimculusSidebarHeader` `NSStackView` for every
sidebar. Its title is left-aligned and its action stack is right-aligned in a
single `rowHeight` row. Files, Search, and Git Changes actions remain native
24pt buttons with their existing tooltips, accessibility labels, and command
identifiers. Git's Changes/History/Branches navigation remains in the row
below the header. The source sidebar text still owns its two-line title
contract, but the presenter removes those lines from the scrollable content
and translates row mappings so selection, keyboard navigation, and context
actions keep their existing item indices.

Reveal Active File uses `location.magnifyingglass` instead of `scope`, and
sidebar/activity icons use a shared SF Symbol point-size token. Header and
activity boundaries use the existing semantic theme roles so the layout keeps
its contrast in both light and dark themes.

**Consequences.** Panel chrome now matches Zed's single-row title/action
hierarchy without adding a new command or blocking work on the UI thread.
Future panel actions must be added to the header action stack and sized from
`space1`, `space2`, `space3`, `rowHeight`, and `controlHit` rather than by
positioning a detached toolbar.

## UX-025: Use ghost chrome controls and a raised active tab

**Context.** A visual comparison with Zed showed that the tab-bar controls and
sidebar-header actions carried a permanent low-alpha box, while the active tab
was only a faint tint. The result made quiet workspace chrome look heavier than
Zed and made the selected document difficult to identify, especially in the
light theme.

**Decision.** Make workspace navigation buttons native `NimculusChromeButton`
instances with tracking areas. Inactive controls remain borderless and
transparent until pointer hover, when the semantic `elementHover` surface is
shown at a restrained alpha and the existing `space1` radius is applied.
Active navigation keeps the accent state, while tooltips, AX labels, and
existing command targets remain unchanged. Paint the active document tab with
the light `tabActive` or dark `elementActive` surface and a 2pt semantic accent
bar at its top edge; tab measurement, close-glyph placement, and hit testing do
not change.

**Consequences.** Both light and dark macOS themes have quieter controls and a
more legible selected tab without adding a renderer/core dependency or a new
interaction path. Hover state is owned by the AppKit control, so it does not
block the UI thread or alter the Metal editor contract.

## PERF-026: Pace live macOS redraws with a dirty-gated ProMotion display link

**Context.** Synchronous redraws for every editor, terminal, pointer, and
state-reflection update can submit more work than a ProMotion display can
present, especially during trackpad scrolling. An always-running display link
would fix pacing but would also change the existing idle and frame-diagnostic
contract.

**Decision.** On macOS 14 and later, `NimculusMetalView` owns an AppKit
view-bound `CADisplayLink`, configured with a `CAFrameRateRange` from 60Hz up
to the current screen's maximum, capped at 120Hz. The link starts only while
the window is visible and unoccluded, stops for miniaturization, occlusion,
close, and teardown, and coalesces redraw requests through a single dirty
flag. An idle link does not call `drawFrame`.

Every interactive/state-reflection caller now invokes `requestRedraw`. While
the link is running, that method only sets the dirty flag; otherwise—including
headless/contract tests, startup before the link begins, and hidden windows—it
calls `drawFrame` synchronously. This fallback is intentional: a frame remains
defined as a successfully presented drawable, so `presentDrawable`, frame timing
samples, `frame_count`, input-to-frame diagnostics, and the cold-start first
frame retain their existing semantics. Initialization and validation therefore
remain synchronous whenever no live display link is available.

**Consequences.** Live GUI rendering is paced at the display cadence without
idle frames or duplicate synchronous submissions. The renderer's existing
present, timing, frame-count, and damage/dirty-region logic is unchanged, and
non-macOS/headless backends require no display-link knowledge.

## UI-079: Use a continuous macOS editor scroll position

**Context.** Precise trackpad deltas were accumulated into an integer line, so
the editor jumped by a full line even though the input was pixel-based.

**Decision.** Store continuous logical scroll pixels and derive the legacy line
index plus sub-line fraction for the platform boundary. macOS applies that
fraction to text, line numbers, cursors, selections, Git gutter, diagnostics,
hit testing, and IME candidate coordinates. Scrolling still invalidates through
the existing `requestRedraw` path. In unwrapped mode, the paint list emits a
horizontal thumb when the widest visible line exceeds the viewport, using the
theme scrollbar role for both light and dark themes and reserving the lower
right corner when both thumbs are present.

**Consequences.** Integer `scrollLine` callers and old sessions remain valid
through compatibility reconciliation. Non-macOS rendering and frame,
display-link, and damage semantics are unchanged.

## UI-080: Keep wheel scrolling independent from cursor visibility

**Context.** A precise wheel or trackpad event updates the editor's continuous
scroll position, but the redraw synchronization also ran `ensureCursorVisible`.
That made every scroll event immediately re-clamp the viewport around the
cursor, preventing the cursor from scrolling out of view.

**Decision.** Treat wheel/trackpad scrolling as a viewport-only update. The
handler preserves the continuous pixel position, reconciles its compatibility
line and fraction, sends both values to the platform, and redraws without
running cursor visibility correction. Cursor visibility correction remains the
default for cursor movement, editing, clicking, navigation, completion, and
definition actions, including each split pane's own cursor-driven updates.

**Consequences.** Scrolling now moves freely like Zed while retaining smooth
sub-line motion, horizontal scrolling, native scrollbars, and independent
split-pane state. A subsequent cursor movement restores the cursor to the
visible viewport when needed.

## UI-082: Clone Zed's Project Panel presentation in the native Files dock

**Context.** The Files tree already owned selection, expansion, keyboard
navigation, context menus, reveal, and drag dispatch, but its presentation
used plain text markers, hid ignored entries, applied a heavy accent selection,
and kept all header actions visible. Zed's vendored Project Panel and One theme
are the source of truth for this surface.

**Decision.** Keep the existing row-index bridge and attach four style bits to
each macOS Files line: ignored, added, modified, and deleted. The asynchronous
Git porcelain result is reused for status colors, with Zed's precedence of
deleted, modified, added, then ignored. Files requests ignored entries from the
existing workspace ignore stack, while search and enumeration retain their
previous filtered behavior. The native presenter renders folder/file SF
Symbols, strips textual indentation into 20pt paragraph indents, paints
`border.variant` guide lines, and uses a 24pt comfortable row rhythm. Selected
and hovered rows use `element.selected` and `element.hover`; file status colors
and `ignored` use the One Light/Dark semantic values.

The header uses the project root name with a folder icon. Its existing actions
remain available, but are revealed only while the Files header is hovered.
The workspace UI keeps its 240pt default dock size so the interaction boundary
and persisted resize behavior remain unchanged.

**Evidence.** Values and behavior were read from
`references/zed/crates/project_panel/src/project_panel.rs`,
`references/zed/crates/project_panel/src/project_panel_settings.rs`,
`references/zed/assets/settings/default.json`,
`references/zed/assets/themes/one/one.json`,
`references/zed/crates/theme/src/icon_theme.rs`, and the vendored
`references/zed/assets/icons/file_icons/` set. Nimble format, lint, test, and
build gates are required before the native launch smoke check.

## UI-090: Port Zed's status-bar order and summaries

**Context.** The footer already had native ghost buttons and preserved the
existing command routes, but its left cluster began with diagnostics and Git,
its right cluster began with the cursor, and the cursor used the bespoke
`Ln 1, Col 1` spelling. Zed registers project search, LSP, diagnostics, and
the active file on the left, then places encoding, language, line ending, and
cursor position on the right when unsupported items are omitted.

**Decision.** Keep the tab-separated Nim-to-AppKit payload and its existing
tooltips, accessibility labels, right-click Status Bar menu, and command
destinations. Add a far-left magnifying-glass Search Project ghost button
using the existing `commandPalette:workspace search` route. Render the left
cluster as search, LSP, diagnostics, active file, and Git; Git remains the
existing status-panel entry because Nimculus has no separate blame/conflict
status item. Render the right cluster as UTF-8 encoding, language, line
ending, and the cursor position, omitting Zed's unsupported toolchain and
other items as well as the non-Zed indentation entry.

Diagnostics follow Zed's `DiagnosticIndicator`: clean state is a Check icon
alone; non-clean state uses XCircle plus an error count and/or Warning plus a
warning count, with the existing diagnostics command shared by each summary
segment. The cursor is calculated from Nimculus's grapheme-aware line/column
mapping and displayed one-based as `line:character`, with a selection count
when multiple selections are active. Semantic theme roles keep the treatment
valid in both light and dark appearances.

**Evidence.** The ordering comes from
`references/zed/crates/zed/src/zed.rs` lines 635-649, the diagnostic rendering
from `references/zed/crates/diagnostics/src/items.rs`, and cursor formatting
from `references/zed/crates/go_to_line/src/cursor_position.rs`. Required
Nimble format, lint, test, build, and native launch/crash-report checks remain
the acceptance gate.

## UI-091: Use one Zed-style picker surface for Command Palette and Quick Open

**Context.** Nimculus's command palette was an `NSComboBox` attached to the
editor edge, while Quick Open used a search field plus the Files sidebar. That
split presentation did not provide Zed's centered elevated picker, inset rows,
fuzzy-match emphasis, or trailing keybinding treatment.

**Decision.** Replace the command palette's combo-box presentation with a
shared native picker list. The card uses the One theme's `elevated` role (the
Nimculus transport for Zed's `elevated_surface.background`), `border`, an 8pt
`rounded_lg`-equivalent radius, and the four-layer modal shadow from Zed's
elevation model. Rows follow `ListItem::new(ix).inset(true).spacing(Sparse)`:
8pt outer inset, 34pt sparse rhythm, rounded selected/hover fills from
`element.selected` and `element.hover`, fuzzy subsequence highlighting in
`text.accent`, and right-aligned keybinding labels when a binding exists.

Quick Open mounts the same card/list implementation and continues to consume
Nimculus's asynchronous workspace result stream and existing
`sidebarSelect`/`sidebarOpenSelected` activation route. Picker rows expose
menu-item accessibility roles, labels, and selected state; Esc still returns
focus to the editor, while arrows and Enter retain their existing dispatch
contract.

**Evidence.** The geometry and picker behavior come from
`references/zed/crates/picker/src/picker.rs` and `shape.rs` (`34rem` default
width, `24rem` maximum height), the row contract from
`references/zed/crates/ui/src/components/list/list_item.rs`, the command row
composition from `references/zed/crates/command_palette/src/command_palette.rs`,
the elevation/shadow treatment from `references/zed/crates/ui/src/traits/styled_ext.rs`
and `styles/elevation.rs`, and the light/dark role values from
`references/zed/assets/themes/one/one.json`.

## UI-092: Port Zed's option-aware search bars and project filters

**Context.** Nimculus's native find overlay previously exposed only a literal
query and Replace All, while workspace search used a case-sensitive substring
scan with no replacement or path filters. Zed keeps these controls in the
search bar: Case Sensitive, Whole Word, Regex, previous/next navigation with
the active match count, Replace with Replace Next/Replace All, and project
include/exclude filters plus Include Ignored.

**Decision.** Add a shared option-aware matcher at the Nimculus search boundary
and pass the same options through document and workspace searches. The native
AppKit overlay retains the existing command callback and focus paths, but adds
SF Symbol ghost buttons, explicit accessibility labels, `n of m` state, and
theme-role styling; active toggles use the accent role in both appearances.
Workspace jobs carry include/exclude globs and Include Ignored through their
bounded traversal, and project replacement reuses the same matcher before
writing files. Invalid regular expressions stay visible as search errors.

**Evidence.** Layout, action names, option labels, replacement actions, and
filter placement were read from the vendored Zed sources
`references/zed/crates/search/src/buffer_search.rs`,
`references/zed/crates/search/src/project_search.rs`, and
`references/zed/crates/search/src/search_bar.rs`; semantic colors follow
`assets/themes/one/one.json` and Nimculus's existing theme-role bridge.

## UI-094: Snap editor rows and wrap width to Zed's pixel contract

**Context.** The macOS editor resolved the comfortable buffer line height as
the fractional value `15 * 1.618 = 24.27`, and soft wrapping used the full
post-gutter viewport. Against the same One Light document this produced a
systematic vertical drift and different paragraph breaks.

**Decision.** Match Zed's `TextStyle::line_height_in_pixels` by rounding the
resolved comfortable line height to a whole device pixel before sharing it
with Core Text, the atlas, scrolling, hit testing, cursor placement, and IME
coordinates. Match `EditorElement`'s editor-width calculation by reserving
two typographic `em` widths after the gutter; the scrollbar remains an
overlay. Use the same reduced width for the Core Text soft-wrap frame so line
breaks and painted continuation rows use one boundary.

The footer keeps the existing native commands and accessibility labels but
now presents the compact Zed-like shape observed for this acceptance case:
the left side contains only the icon cluster, while the right side starts
with cursor position and language (`25:53` / `Markdown` for the reference
document), followed by encoding and line-ending controls. Active-file and Git
summary text remain available through the breadcrumb and source-control
surfaces rather than widening the footer's left cluster.

**Evidence.** The rounding rule is from
`references/zed/crates/gpui/src/style.rs` (`line_height_in_pixels`), and the
two-em reservation is from
`references/zed/crates/editor/src/element.rs` (`editor_width` and
`calculate_wrap_width`).
## UI-093: Make Git Changes rows native checkbox controls with a pinned commit footer

**Context.** The existing Git sidebar already had section-aware stage/unstage
dispatch and bulk actions, but its rows were plain text. The leading gesture
was only a hit-test convention, so the control was not visible or exposed as
an accessibility checkbox. Commit entry was also a transient editor overlay
instead of the persistent lower surface used by Zed's Changes workflow.

**Decision.** Keep the shared, scrollable native sidebar and add one AppKit
checkbox per staged/unstaged row. Each checkbox keeps the existing
`sidebarStageToggle:<index>` route, uses an accessible Stage/Unstage label, and
does not appear for conflicts. Render each row as basename, muted repository
directory, and a final status token. Added, modified, deleted, and conflict
tokens resolve through the existing semantic `added`, `modified`, `deleted`,
and `conflict` theme roles, whose values are sourced from Zed's
`references/zed/assets/themes/one/one.json` mapping for
`version_control.added`, `version_control.modified`,
`version_control.deleted`, and `conflict`. Reserve the bottom 46pt of Changes
for the existing commit editor and route its button through the established
`commandPalette:git commit ...` job boundary.

**Consequences.** Partial staging remains unambiguous because a path rendered
under Staged receives a checked checkbox and unstages, while its Unstaged
projection receives an unchecked checkbox and stages. Existing keyboard
navigation, context menus, async Git refresh, and status-list selection remain
unchanged. The native controls inherit light/dark theme roles and remain
inspectable by macOS accessibility tooling.
## M20-XXX: Match Zed's breadcrumb hierarchy and text metrics

The macOS editor breadcrumb now carries the complete Markdown ATX heading
ancestor chain at the cursor and uses Zed's `›` separator. The AppKit presenter
renders heading markers in the muted role and heading titles in a bold copy of
the configured buffer font, rather than using the proportional chrome font.
Its text origin is explicitly lowered within the 28pt row to match the measured
Zed capture. Nim emits a plain UTF-8 breadcrumb payload and the macOS layer
owns font, color, and baseline styling. The native editor-context contract in
`tests/test_platform_contract.nim` covers the complete hierarchy, separator,
font, and marker/title styling.

## M20-XXX: Resolve chrome text through Zed's UI scale

The breadcrumb, tab labels, footer status items, panel headers, and panel rows
must use the configured buffer font family without inheriting the buffer font
size. Zed's `text_ui(cx)` uses the UI text scale, whose default is 14px, while
the editor buffer in this acceptance case is 15px. The macOS native chrome now
shares one UI-font helper for those paths; its 13.6pt AppKit request is the
Retina raster calibration that produces Zed's 14px columns. Editor and terminal
content retain their independent configured sizes. Tab content measurement uses
the same font as painting, and the tab label origin remains lowered to preserve
the measured row baseline.

Evidence: `references/zed/crates/breadcrumbs/src/breadcrumbs.rs` applies
`.text_ui(cx)`, `references/zed/crates/editor/src/items.rs` supplies the buffer
font family, and `references/zed/crates/ui/src/styles/typography.rs` defines
`TextSize::Default` from 14px.

## UI-101: Port Zed's accessibility tree through NimNUI and NSAccessibility

対応マイルストーンは ROADMAP.md の M1〜M6（macOS window/NimNUI/text/workspace）に
またがる UI テスト基盤である。完了条件は、実起動した Nimculus の AX tree から Window
の Role / Title / Value / Identifier / Children / Parent を取得でき、主要なタブ、
ツールバー操作、ステータス項目、Project Panel 行、`editor.content` を identifier で
解決できること、さらに XCUITest が `app.buttons["toolbar.save"].click()` の形で
操作できることである。Metal の editor surface は framework が synthetic TextRun
children と byte 単位の selection を生成して公開する。

Zed との層対応は次のとおりとする。

| 層 | Zed のファイル:行と構造名 | Nimculus のファイル:行と構造名 | 概念の対応 |
| --- | --- | --- | --- |
| element（app） | `crates/gpui/src/element.rs:112` `Element::a11y_role`、`:120` `write_a11y_info`、`:131` `a11y_synthetic_children`、`:228` `GlobalElementId::accesskit_node_id` | `src/nimnui/ui_tree.nim` の `UiNode` accessibility fields、`src/nimnui/controls.nim` の `makeControl` | 各コントロールが role と title/value/identifier を申告する。role が `none`、または identifier が空の node は公開しない。Node ID と generation から安定 ID を得る |
| framework | `crates/gpui/src/window/a11y.rs:166` `A11y`、`:300` `A11ySubtreeBuilder`、`:386` `A11yNodeBuilder` | `src/nimnui/accessibility.nim` の `AccessibilityTree`、`AccessibilityBuilder`、`addSyntheticChild` | UI tree の申告を親子関係つきの値型へ集約し、root/focus/selection と synthetic TextRun を作る。ここには AppKit 型を入れない |
| platform | `crates/gpui_macos/src/window.rs:535` `SubclassingAdapter`、`:1881` `a11y_tree_update`、`:1902` `ActivationHandler`、`:1908` `A11yActionHandler` | `src/nimnui/platform/contracts.nim` / `contracts.h` の C ABI、`src/nimnui/platform/macos/macos_platform.m` の `NimculusAXNode` と `NimculusMetalView` accessibility bridge | framework の flat update を保持し、NSAccessibility の Role/Title/Value/Identifier/Children/Parent と press action を公開する。platform は UI 構造を判断せず、受け取った tree と action command を OS 表現へ変換する |

AccessKit は Rust crate で Nim に等価物がないため、`accesskit_macos` 相当の
NSAccessibility adapter は platform 層に直接実装する。これは OS 依存型を NimNUI core
へ漏らさず、Zed の element → framework → platform の依存方向を保つための選択である。
候補だった AccessKit の C/Rust bridge 追加は、今回の最小縦切りに新しい runtime と
ownership 境界を持ち込むため採用しない。AppKit の既存 native overlays を置き換える
ことも、描画・入力の回帰範囲を広げるので採用しない。

Identifier は Web の `data-testid` 相当の安定した公開 API として、ドット区切りの
小文字 namespace を使う。主要な値は `toolbar.new`、`toolbar.open`、`toolbar.save`、
`sidebar.projects`、`sidebar.projects.row.<stable-id>`、`editor.content`、
`editor.tab.<stable-id>`、`statusbar.<item>`、`dialog.confirm.ok` とする。表示文言や
行番号を identifier に使わず、タブ・行の stable Node ID を suffix に使う。

Zed の `a11y_role() == None` と同じく role が無い element は tree に入れない。ただし
window root は platform が必要とする固定の Window node として framework が生成する。
TextRun は `editor.content` の synthetic child とし、本文の UTF-8 byte range、caret、
selection を親の属性へコピーする。これで Metal renderer に NSView の子を追加せずに
XCUITest と assistive technology の双方から本文構造を取得できる。
