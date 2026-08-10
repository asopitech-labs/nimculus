# Zed の構成と、Nim での再現方式

この文書は Zed のコード構成を層ごとに整理し、各メカニズムを Nim でどう再現するかを決めるためのもの。
**個別の差分を追いかける前に、ここを見る。**

2026-08-10 に 10 のエージェントで Zed と Nimculus を並行して読み、突き合わせて作った。
行番号は実測。読んでいないものは `不明` と記す。

## 規模

| | Zed | Nimculus |
| --- | --- | --- |
| 総行数 | **1,484,084** | 43,424（Nim 24,706 + ObjC 18,718）|
| 単位 | 239 crate | 2 パッケージ |
| フレームワーク | gpui 73,213 | nimnui 2,700 |
| デザインシステム | ui 27,996 | **無い** |
| エディタ | editor 158,936 | main.nim の一部 |

**34 倍。全部は移植できない。** 何を移植し何を移植しないかを先に決めるための文書がこれ。

## メカニズムの移植状況

| 層 | 計 | 済 | 一部 | 無 |
| --- | ---: | ---: | ---: | ---: |
| プラットフォーム層（OS 境界） | 26 | 3 | 10 | 13 |
| フレームワーク: 中核 | 13 | 0 | 7 | 6 |
| フレームワーク: テキストと描画 | 17 | 3 | 7 | 7 |
| フレームワーク: 入力とアクション | 17 | 2 | 8 | 7 |
| デザインシステム層 | 16 | 0 | 9 | 7 |
| ワークスペース層 | 19 | 3 | 12 | 4 |
| エディタ: モデル | 19 | 1 | 11 | 7 |
| エディタ: レイアウトと描画 | 24 | 2 | 13 | 8 |
| プロジェクト層（サービス） | 16 | 2 | 9 | 4 |
| 機能 crate 群 | 23 | 3 | 13 | 6 |
| **合計** | **190** | **19** | **99** | **69** |

**過半数（99 件、52%）が「一部のみ」。**
移植済みが 19 件しかない一方、着手した痕跡があるものが 99 件ある。
「一部のみ」は動いているように見えて条件を変えると壊れる。実際、
2026-08-09〜10 の作業で見つけた不具合はほぼ全部この層にあった。


## プラットフォーム層（OS 境界）

状態: **一部のみ**

### Zed のファイル

| ファイル | 行 | 役割 |
| --- | ---: | --- |
| `crates/gpui_macos/src/window.rs` | 3228 | MacWindow: runtime synthesis of the NSView and NSWindow/NSPanel subclasses (:131-475), MacWindowState (:490-748), window open (:755-1103), the PlatformWindow impl (:1205-1897), and |
| `crates/gpui_macos/src/metal_renderer.rs` | 1799 | MetalRenderer: device/CAMetalLayer setup (:150-176), instance-buffer pool (:56-109), the eight render pipeline states (:111-140), drawable-size and path intermediate textures (:381 |
| `crates/gpui_macos/src/platform.rs` | 1514 | MacPlatform: NSApplication/app-delegate class synthesis (:70-163), the whole Platform trait impl (:475-1193), menu-bar construction (:241-460), open/save panels (:744, :794), keych |
| `crates/gpui_macos/src/keyboard.rs` | 1502 | MacKeyboardLayout (TIS input-source id/name) and MacKeyboardMapper, a per-layout table of key-equivalent character substitutions (:13-50 plus the large layout tables). |
| `crates/gpui_macos/src/text_system.rs` | 904 | MacTextSystem: CoreText font loading/matching (:276-419), CoreGraphics glyph rasterization including subpixel positioning and dilation (:421-530), and CTLine-based single-line shap |
| `crates/gpui_macos/src/events.rs` | 574 | Translates NSEvent into gpui PlatformInput (scroll phase/precise deltas at :258-286) and maps gpui key names to native key equivalents (:29). |
| `crates/gpui_macos/src/pasteboard.rs` | 531 | Pasteboard wrapper for general/find/unique boards with text, file-URL and typed image (UTType) read/write (:22-333). |
| `crates/gpui_macos/src/display_link.rs` | 461 | Frame pacing: an immortal per-display CVDisplayLink registry (:65-226) plus WindowFrameSource, a per-window GCD data-add source that coalesces vsync ticks onto the main queue (:231 |
| `crates/gpui_macos/src/metal_atlas.rs` | 379 | MetalAtlas: shelf-packed (etagere) sprite atlas keyed by AtlasKey, with texture growth (:121) and refcounted tile removal (:62, :250). |
| `crates/gpui_macos/src/screen_capture.rs` | 344 | ScreenCaptureKit source enumeration behind the screen-capture feature. |
| `crates/gpui_macos/src/open_type.rs` | 191 | Applies OpenType feature settings and the font fallback cascade list to a CTFont descriptor (:34, :102, :155). |
| `crates/gpui_macos/src/dispatcher.rs` | 175 | MacDispatcher: maps GPUI task priorities onto GCD global/main queues (:31-79) and sets mach thread policy for realtime audio threads (:81-164). |

### Nimculus の対応物

| ファイル | 行 | 何を担っているか |
| --- | ---: | --- |
| `/Users/yoshinori/work/nimculus/src/nimnui/platform/macos/macos_platform.m` | 17976 | Everything: NSApp bootstrap and delegate, the NSWindow, NimculusMetalView with Metal layer + CADisplayLink + NSTextInputClient, the glyph atlas and Metal draw p |
| `/Users/yoshinori/work/nimculus/src/nimnui/text.nim` | 467 | The framework side of shaping: LineLayoutCache (:119), layoutLineByHash (:332), layoutWrappedLineByHash (:367) — the analogue of gpui's line layout cache, sitti |
| `/Users/yoshinori/work/nimculus/src/nimnui/platform/macos/platform.nim` | 356 | The importc declarations for platform.h. Predominantly the validate_* self-test entry points (:23-94) rather than platform operations. |
| `/Users/yoshinori/work/nimculus/src/nimnui/platform/macos/platform.h` | 290 | The declared macOS boundary. Roughly 200 entry points, of which only a handful (run, layout_line, clipboard, get_metrics, the four dispatch calls via contracts. |
| `/Users/yoshinori/work/nimculus/src/nimnui/platform/contracts.h` | 240 | The genuinely portable contracts: PlatformMetrics, InputEvent, the text-shaping structs (:72-90) with an explicit note that the framework owns rows/wrapping/cac |
| `/Users/yoshinori/work/nimculus/src/nimnui/platform/contracts.nim` | 128 | Nim mirrors of the contracts.h structs and the PlatformDispatcher record type. |
| `/Users/yoshinori/work/nimculus/src/nimnui/platform/dispatcher.nim` | 107 | Zed's MacDispatcher, as a record of closures plus GC_ref'd runnable boxes; also a portable in-process dispatcher for tests that has no Zed counterpart. |
| `/Users/yoshinori/work/nimculus/src/nimnui/platform/macos/text_platform.h` | 19 | A second, older text boundary: font availability, font enumeration, and whole-string measurement — parallel to and separate from the layout_line contract in con |

### メカニズム

#### NSApplication bootstrap and app-delegate callbacks — 一部

Zed: `crates/gpui_macos/src/platform.rs:70 (build_classes), :488 (Platform::run), :1227 (did_finish_launching)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:12384 (nimculus_platform_run), :11036 NimculusAppDelegate, :11048-12229 its implementation`

Synthesizes GPUIApplication and GPUIApplicationDelegate at load time, stashes a MacPlatform back-pointer in an ivar, runs [NSApp run], and routes reopen/terminate/openURLs/keyboard-layout-change/thermal/wake notifications into stored Rust closures. A headless branch skips AppKit and calls CFRunLoopRun (:493).

**Nim での再現:** Already reproduced with a compile-time @interface rather than runtime ClassDecl, which is the right choice for Nim: Nim has no ObjC runtime binding, so classes must be declared in the .m. The missing part is the back-pointer discipline. Zed stores `*mut MacPlatform` in an ivar so several platforms/windows can coexist; Nimculus uses file-scope globals (g_active_view, g_command_callback...). In Nim the equivalent of Zed's ivar is a `ptr PlatformState` handed to the ObjC side once at startup and passed back through every callback's first argument — the same trick contracts.h already uses for dispatch (`void *context`). No headless CFRunLoopRun path exists.

#### The Platform trait as the OS boundary — 無

Zed: `crates/gpui_macos/src/platform.rs:475 (impl Platform for MacPlatform)`  
Nimculus: `src/nimnui/platform/contracts.h (240 lines, dispatcher only) vs src/nimnui/platform/macos/platform.h (290 lines, ~200 app-specific entry points)`

One trait of ~60 methods is the entire surface between gpui and macOS: executors, text system, displays, windows, clipboard, menus, panels, cursor, credentials. Everything above it is OS-agnostic.

**Nim での再現:** Nim has no traits, but it has three usable encodings and the codebase already picked one for the dispatcher: a record of closures (`PlatformDispatcher` with mainThread/background/mainQueue/delayed fields, src/nimnui/platform/dispatcher.nim:39-46). That is the correct Nim analogue of a Rust trait object and should be extended to a `Platform` object with fields for openWindow, textSystem, displays, clipboard, setMenus, promptForPaths, setCursorStyle. A `concept` would also work but gives worse error messages and no dynamic dispatch across the headless/macos/windows backends that already exist as sibling directories. The blocker is not the language: platform.h currently declares editor-domain functions (set_editor_git_hunks, set_editor_sidebar, show_git_status_context), so there is no boundary to encode.

#### Per-window state behind a handle stored in an ObjC ivar — 無

Zed: `crates/gpui_macos/src/window.rs:77 (WINDOW_STATE_IVAR), :490 (MacWindowState), :1959 (get_window_state), :1969 (drop_window_state)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m uses file-scope globals throughout (g_editor_text, g_editor_rect, g_editor_scroll_line, g_active_view, ...)`

Every NSWindow and NSView carries an `Arc<Mutex<MacWindowState>>` in an ivar. Callbacks recover it, take the lock, and — crucially — `take()` the callback closure out of the state and drop the lock before invoking it (:2664, :2676, :2875), so re-entrant AppKit callbacks cannot deadlock or double-borrow.

**Nim での再現:** Reproducible and worth reproducing. `Arc<Mutex<T>>` becomes a Nim `ref object` pinned with GC_ref and handed to ObjC as `void *` — dispatcher.nim:30-33 already does exactly this with RunnableBox. Nim has no borrow checker, so the take-callback-then-unlock dance is not forced on you, but the underlying hazard (an AppKit callback re-entering while state is mutated) is real in Nim too; the discipline must be adopted by convention. The concrete cost of not having it is visible today: firstRectForCharacterRange (macos_platform.m:10935) has to save and restore eight globals and call swapEditorTextState twice just to answer a question about the secondary pane.

#### Runtime NSView/NSWindow subclass synthesis with a fixed selector set — 一部

Zed: `crates/gpui_macos/src/window.rs:131-303 (VIEW_CLASS), :365-474 (build_window_class)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:4110 (@interface NimculusMetalView : NSView <NSTextInputClient>), :9515-11034 implementation; window delegate methods at :11060-11095`

Declares exactly which selectors the view answers (36 of them: keyDown, performKeyEquivalent, all mouse variants, makeBackingLayer, displayLayer, the eight NSTextInputClient methods, _opaqueRectForWindowMoveWhenInTitlebar) and which the window answers (windowDidResize, occlusion, fullscreen, drag, tab commands).

**Nim での再現:** Compile-time @interface is the right Nim-side answer — Nim cannot call objc_allocateClassPair usefully, and there is no reason to. Missing selectors relative to Zed: performKeyEquivalent:, resetCursorRects, magnifyWithEvent:, swipeWithEvent:, pressureChangeWithEvent:, acceptsFirstMouse:, _opaqueRectForWindowMoveWhenInTitlebar, and the drag-and-drop family (draggingEntered/Updated/Exited/performDragOperation). Each is a method to add to NimculusMetalView plus one callback slot in contracts.h.

#### Traffic-light repositioning for an app-drawn titlebar — 無

Zed: `crates/gpui_macos/src/window.rs:541 (move_traffic_light), :601 (capture_traffic_light_frames), :638 (restore_traffic_light)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:12120 sets titlebarAppearsTransparent/titleVisibility only; NimculusTitlebarView (:4140, :4152) draws its own titlebar but never touches standardWindowButton`

Captures the original frames of the close/minimize/zoom buttons and their container, then re-lays them out at a caller-specified point, resizes the titlebar container to button_height + 2*y, and calls updateTrackingAreas on all four. Restores originals on fullscreen. Re-run on every resize and screen change because AppKit recreates the buttons.

**Nim での再現:** Straightforward: three [window standardWindowButton:] calls plus setFrameOrigin, in the .m, driven by a `traffic_light_x/y` pair added to the window-open contract. Nothing in Nim itself is involved. This is a direct, measurable UI-parity gap — Zed's traffic lights sit at a configured offset inside its own titlebar, Nimculus takes AppKit's default position.

#### Display-link frame pacing — 一部

Zed: `crates/gpui_macos/src/display_link.rs:65-226 (immortal per-display CVDisplayLink registry), :231 (WindowFrameSource), crates/gpui_macos/src/window.rs:659 (start_display_link), :2689 (step callback)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:9519 (displayLinkDidFire:), :9545 (startDisplayLinkIfNeeded), :9569 (stopDisplayLink), :9576 (restartDisplayLinkIfNeeded), :9529 (requestRedraw)`

One never-released CVDisplayLink per CGDirectDisplayID; each window subscribes with its own GCD data-add source. The link's io thread calls merge_data, which coalesces ticks onto the main queue and invokes step(view), which calls the window's request_frame callback. Links run iff they have subscribers. The header comment (:1-51) documents two shipped crash classes that this design exists to avoid: CVDisplayLinkStop does not wait for the last output callback, so releasing either the link or the dispatch source races it.

**Nim での再現:** Nimculus uses macOS 14+ CADisplayLink per view (:9550-9565), which sidesteps the teardown race entirely — invalidate is safe — and adds preferredFrameRateRange clamped to 60..120. That is a legitimate simplification, not a gap, and needs no Nim work. Two real differences remain: (a) Zed's link is shared per display so N windows on one screen tick once; Nimculus is per-view but is also single-window today; (b) Nimculus falls back to a synchronous drawFrame when the link cannot run (:9541), which Zed never does. If a pre-14 target is ever needed, the CVDisplayLink registry has to be ported wholesale, including the immortality rule.

#### presents-with-transaction during synchronous redraw — 無

Zed: `crates/gpui_macos/src/window.rs:2673 (display_layer), crates/gpui_macos/src/metal_renderer.rs:374 (set_presents_with_transaction), :492-499 (commit/wait_until_scheduled/present)`  
Nimculus: `not found in src/nimnui/platform/macos/macos_platform.m (drawFrame at :10441 always uses presentDrawable at :10724)`

When AppKit drives the frame (displayLayer:, i.e. live resize), the renderer switches the CAMetalLayer to presentsWithTransaction, stops the display link, draws synchronously, then switches back and restarts the link. Without this, resize tears because the drawable presents out of band with the layer transaction.

**Nim での再現:** Pure .m work: set metalLayer.presentsWithTransaction = YES, replace [command presentDrawable:] with commit + waitUntilScheduled + [drawable present]. No Nim involvement. Worth testing during live resize before deciding it matters.

#### Metal renderer: pipeline states per primitive kind and a pooled instance buffer — 一部

Zed: `crates/gpui_macos/src/metal_renderer.rs:111-140 (MetalRenderer fields), :56-109 (InstanceBufferPool), :446 (draw), :1047-1568 (draw_shadows/quads/paths/underlines/mono+poly sprites/surfaces)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:1285-1289 (g_pipeline, g_text_pipeline, g_glyph_pipeline, g_polychrome_glyph_pipeline, g_image_pipeline), drawFrame :10441-10735`

Eight prebuilt MTLRenderPipelineStates, one per scene primitive kind. Each frame acquires a pooled instance buffer, writes all primitives into it, and on out-of-space doubles the pool's buffer size and retries (:502-518). The buffer is returned to the pool from the command buffer's completion handler (:484-490). Paths are rasterized to a 4x-MSAA intermediate texture first (:397, :961).

**Nim での再現:** Five pipelines vs Zed's eight; no shadow, underline or path/MSAA pipeline. The structural divergence is bigger than the count: Nimculus keeps a *retained scene texture* and re-encodes only dirty regions into it, then blits scene->drawable (:10719-10723). Zed re-encodes the whole scene into the drawable every frame. Nimculus's approach is a damage-tracking optimization Zed does not have, and the code is honest about the cases where it must fall back to a full rebuild (:10453-10461). Reproducing Zed's instance-buffer pool in Nim is not applicable — the buffers live in ObjC. What could move to Nim is the *scene* description (a seq of typed primitive records), leaving the .m as a dumb encoder; today the .m computes the primitives itself.

#### Sprite atlas with shelf packing and keyed tiles — 一部

Zed: `crates/gpui_macos/src/metal_atlas.rs:13 (MetalAtlas), :40 (get_or_insert_with), :96 (allocate), :121 (push_texture), :62/:250 (remove + refcount)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:1294-1308 (g_glyph_atlas_texture, g_glyph_atlas_next_x/next_y/row_height, hit/miss/eviction counters), :1376 (g_glyph_atlas_cache hash table), :3429-3462 (rebuild on scale change)`

Keyed by AtlasKey (glyph params, image id, path); on miss the caller's closure produces bytes, etagere shelf-allocates a tile in the current texture, and a new texture is pushed when full. Tiles are refcounted so removal frees shelf space for reuse.

**Nim での再現:** Nimculus has a hand-rolled shelf allocator (next_x/next_y/row_height) and an open-addressed hash cache, plus hit/miss/eviction instrumentation Zed lacks. Two gaps: it holds exactly one monochrome and one color texture (no push_texture growth — on full it rebuilds, :3444-3452), and there is no per-tile refcount so nothing is reclaimed selectively. If the atlas ever moved to Nim, a `Table[GlyphKey, AtlasTile]` plus a seq of shelves is a direct translation; the etagere crate has no Nim equivalent, so the shelf allocator stays hand-written either way.

#### Single-line text shaping (CTLine) as the platform's only text job — 済

Zed: `crates/gpui_macos/src/text_system.rs:532 (layout_line)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:3279 (nimculus_platform_layout_line), contract in src/nimnui/platform/contracts.h:72-90, Nim-side cache at src/nimnui/text.nim:119 (LineLayoutCache), :332 (layoutLineByHash), :367 (layoutWrappedLineByHash)`

Builds a CFMutableAttributedString from per-run fonts, converts UTF-8 to UTF-16 offsets, creates a CTLine, then walks CTRuns emitting ShapedGlyph{id, position, utf8 index, is_emoji} and merging adjacent runs with the same font. Ascent/descent come from font metrics, width from CTLine typographic bounds. Note the deliberate ligature-breaking hack at :559-571 (alternating font_size by one ULP per run).

**Nim での再現:** This is the one place where the layering matches Zed exactly, and the comment at contracts.h:69-71 says so explicitly: the platform resolves a font and returns a glyph stream, the framework owns rows, wrapping and cache keys. The Nim side is a real LineLayoutCache keyed by text hash, which is the analogue of gpui's LineLayoutCache. The ULP ligature trick is absent from the .m; if ligature behaviour ever diverges visually, that is where to look.

#### Glyph rasterization with subpixel variants and dilation — 無

Zed: `crates/gpui_macos/src/text_system.rs:421 (raster_bounds, dilated by 1px), :436 (rasterize_glyph)`  
Nimculus: `not exposed in src/nimnui/platform/contracts.h; rasterization happens privately inside macos_platform.m's atlas path`

Rasterizes one glyph into a CGBitmapContext — gray/alpha-only for text, RGBA premultiplied for emoji (then swizzled to BGRA straight alpha, :521-526). Subpixel positioning is on and quantization is off (:497-500); the subpixel_variant shifts the draw origin by a fraction of a pixel and grows the bitmap by 1px in that axis (:446-451). `dilation` fakes stem darkening by drawing at a gray luminance with font smoothing on (:502-508).

**Nim での再現:** The contract has no rasterize_glyph, so the framework cannot own glyph cache keys the way gpui does. Adding it is mechanical (bounds + bytes out through a caller-provided buffer, mirroring layout_line's shape). Whether it should be added depends on whether Nim ever needs to own the atlas. The subpixel-variant and dilation parameters are the part that actually shows up as a visual difference and neither appears in Nimculus.

#### Font fallback cascade and OpenType features — 無

Zed: `crates/gpui_macos/src/open_type.rs:34 (apply_features_and_fallbacks), :102 (generate_fallback_array), :155 (append_system_fallbacks)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:2859-2877 creates a CTFont with a descriptor; contracts.h:92 declares NimculusEditorFontFeature but platform.h exposes no function taking it`

Builds a CTFontDescriptor carrying the requested feature settings and an explicit cascade list (user fallbacks first, then CTFontCopyDefaultCascadeListForLanguages), so a missing glyph resolves deterministically instead of per-call.

**Nim での再現:** The struct exists in the contract but is unused — a half-built mechanism. Completing it is .m work (CTFontCreateCopyWithAttributes with kCTFontCascadeListAttribute); the Nim side needs a font-features field on whatever carries font config.

#### Task dispatcher over GCD — 済

Zed: `crates/gpui_macos/src/dispatcher.rs:31-79 (PlatformDispatcher impl), :166 (trampoline)`  
Nimculus: `src/nimnui/platform/contracts.h:220-238, src/nimnui/platform/macos/macos_platform.m:69-91, src/nimnui/platform/dispatcher.nim:35-46, src/nimnui/platform/macos/platform.nim:18-20`

Three priorities onto global queues, a main-queue path, and dispatch_after. The runnable is passed as a raw context pointer through a C trampoline that reconstitutes it and runs it.

**Nim での再現:** Fully and faithfully ported, and it is the model for how the rest of this layer should look. Rust's `Runnable::into_raw`/`from_raw` becomes GC_ref on a `RunnableBox ref object` and GC_unref in a `finally` (dispatcher.nim:22-33) — Nim's GC makes this safer than the Rust version, not harder. There is also a portable non-GCD dispatcher (dispatcher.nim:71-107) for tests, which Zed's mac crate has no equivalent of. Missing: Priority::RealtimeAudio and the mach thread_policy_set block (dispatcher.rs:81-164), which is audio-only.

#### IME arbitration: who sees a key first, the keybinding matcher or the input context — 一部

Zed: `crates/gpui_macos/src/window.rs:2121 (handle_key_event), :2094 (is_ime_input_source_active), :2848 (do_command_by_selector)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:10737 (keyDown: -> interpretKeyEvents: unconditionally), :10897 (doCommandBySelector:, mapping 30 selectors to string commands), :4101-4104 (shortcut callback consulted inside logInput before the input callback)`

The single hardest piece of this layer. A key goes to the IME first if composing, or if the current TIS source is a non-ASCII-capable keyboard *input mode* and the input handler wants printable keys, or if it is a non-printing key without control/fn/cmd. Otherwise keybindings match first. When the IME declines, it calls doCommandBySelector:, which re-dispatches the stashed keystroke as a KeyDown and records whether it was handled (:2851-2862). The 28-line comment at :2057-2083 enumerates the layouts this must be tested against.

**Nim での再現:** Nimculus sends every keyDown to interpretKeyEvents: after giving g_shortcut_callback a veto. That is a different arbitration order: the shortcut callback runs on the raw NSEvent before AppKit's input context, whereas Zed decides per-key which of the two goes first. The consequence Zed documents — multi-stroke bindings like `jj` stealing keys the Japanese IME should compose, and the converse — is not addressed. Reproducing this in Nim is feasible: is_ime_input_source_active is a TIS call that belongs in the .m, and the decision function is pure boolean logic over (composing, key_char printable, modifiers, ime_source_active) that could live in Nim and be called back through contracts.h. doCommandBySelector's re-dispatch and its handled/not-handled return value is the part that needs a new contract entry — today it fires a fire-and-forget string command with no return.

#### Key-equivalent vs key-down de-duplication — 無

Zed: `crates/gpui_macos/src/window.rs:2045 (handle_key_equivalent), :2149-2153 (last_key_equivalent), :2243 (don't forward modified key equivalents)`  
Nimculus: `NimculusMetalView implements no performKeyEquivalent: (checked across src/nimnui/platform/macos/macos_platform.m)`

macOS dispatches performKeyEquivalent: before keyDown: for some keystrokes. GPUI treats both as one event, so it remembers the last key-equivalent and drops the matching key-down. It also refuses to hand modified key equivalents to the IME so cmd-` keeps working.

**Nim での再現:** Cheap to add and only becomes necessary once a menu or a cmd-binding collides with an editor binding. One BOOL field plus a stored last keystroke on the view; no Nim change.

#### Keyboard layout identity and per-layout key-equivalent remapping — 無

Zed: `crates/gpui_macos/src/keyboard.rs:13 (MacKeyboardLayout), :18 (MacKeyboardMapper), :30-50 (map_key_equivalent), plus ~1400 lines of per-layout character tables`  
Nimculus: `no TIS call in src/nimnui/platform/macos/macos_platform.m`

Reads the TIS input source id/name, and for non-US layouts substitutes the character a binding should display and match against (e.g. on Finnish, '[' is typed as 'ö'). The layout is re-read on NSTextInputContextKeyboardSelectionDidChange (platform.rs:1301).

**Nim での再現:** The tables are pure data and translate to a Nim `const` of `Table[string, seq[(char, char)]]` verbatim — this is one of the few pieces of gpui_macos that is more natural in Nim than in Rust. The TIS lookup itself stays in the .m. Only matters once keybindings are user-configurable and non-US layouts are supported.

#### NSEvent to portable input event translation — 一部

Zed: `crates/gpui_macos/src/events.rs:258-286 (scroll phase and precise vs line deltas), :288-300 (button numbers incl. Navigate back/forward), crates/gpui_macos/src/window.rs:319 (convert_mouse_position, y-flip)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:4058 (logInput), contract struct at src/nimnui/platform/contracts.h:18-35`

Turns NSEvent into a typed enum: ScrollDelta::Pixels vs Lines depending on hasPreciseScrollingDeltas, TouchPhase from NSEventPhase, MouseButton including the two navigation buttons, and a bottom-left to top-left y flip against window height.

**Nim での再現:** NimculusInputEvent carries the same fields (precise_scrolling, phase, delta_x/y) and logInput guards the AppKit properties that throw when read on the wrong event type (:4067-4082) — that guard is a real hardening Zed gets for free from its typed match. The divergence is that `type` is passed through as the raw NSEventType integer and `modifiers` as raw NSEventModifierFlags, so the classification Zed does at the boundary happens somewhere above instead. In Nim the natural encoding of Zed's PlatformInput enum is an object variant (`case kind: InputKind`), which src/nimnui/events.nim would be the place for; the flat struct is the thing to replace.

#### Pasteboard read/write with typed content — 一部

Zed: `crates/gpui_macos/src/pasteboard.rs:22 (Pasteboard), :50 (read), :92 (read_image), :165 (write), :264-333 (UTType mapping for png/jpeg/gif/webp/bmp/svg/ico/tiff/pnm)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:17921 (clipboardTextFromPasteboard), :17933 (nimculus_clipboard_set), :17945/:17952 (read back)`

Separate general/find/unique boards; reads text, external file paths, or an image in one of nine formats; writes text as data plus GPUI's own metadata type.

**Nim での再現:** Text only, general board only. Nimculus already copies Zed's important detail — writing NSPasteboardTypeString as *data* rather than via setString, so embedded NULs and non-ASCII survive (comment at :17923-17926). Adding the find pasteboard is two globals; images need the UTType table, which is mechanical. No Nim-language obstacle.

#### Display enumeration and coordinate space — 無

Zed: `crates/gpui_macos/src/display.rs:16 (MacDisplay), :28 (primary), :48 (all), :79 (uuid), :108 (bounds), :121 (visible_bounds)`  
Nimculus: `no display enumeration in src/nimnui/platform/macos/macos_platform.m; the window is created and [window center]'d at :12109-12159`

Enumerates CGDirectDisplayIDs, gives each a stable UUID for persisted window placement, and converts AppKit's bottom-left screen rects into GPUI's top-left space. MacWindow::open uses it to place a window on a requested display (window.rs:823-848).

**Nim での再現:** Needed the moment window geometry is persisted across sessions or multi-monitor is supported. Pure .m plus a small struct in contracts.h; the Nim side just needs a `seq[Display]`. The y-flip convention (macOS bottom-left, UI top-left) is the part to copy carefully — Zed documents it in gpui_macos.rs:4-5 and applies it in both display.rs:108 and window.rs:707-729.

#### Cursor style ownership — 無

Zed: `crates/gpui_macos/src/window.rs:334 (set_active_window_cursor_style), :1994 (reset_cursor_rects), crates/gpui_macos/src/platform.rs:1039, :1045 (hide_cursor_until_mouse_moves)`  
Nimculus: `no resetCursorRects or NSCursor use found in src/nimnui/platform/macos/macos_platform.m`

The platform stores the desired CursorStyle on the active window's state and invalidates its cursor rects; AppKit then calls resetCursorRects, where the style is actually applied. Cursor visibility is mirrored in an AtomicBool because AppKit does not expose setHiddenUntilMouseMoves state (platform.rs:190-191).

**Nim での再現:** Small and self-contained: one enum in contracts.h, a setter, and a resetCursorRects override on NimculusMetalView. It matters for UI parity anywhere the pointer should become an I-beam over text or a resize cursor over a splitter — Nimculus has splitters (the divider double-click at :10748-10756) but no cursor feedback on them.

#### Menu bar construction from a declarative menu tree with keystrokes from the keymap — 一部

Zed: `crates/gpui_macos/src/platform.rs:241 (create_menu_bar), :305 (create_menu_item), :1387 (handle_menu_item), :1404 (validate_menu_item)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:12140 (setupMainMenu), items carry representedObject strings dispatched via dispatchCommand: (see :10782-10786 for the same pattern in the editor context menu)`

Builds NSMenu from a Vec<Menu>, and for each action looks up its binding in the keymap to set the key equivalent and modifier mask. Actions are stored in a Vec and the index is the NSMenuItem tag, so the callback is a Vec lookup. validateMenuItem: asks the app whether the action is currently enabled; menuWillOpen: lets the app refresh state first.

**Nim での再現:** Nimculus dispatches by string command instead of by tag index into an action table, which is a reasonable Nim-side simplification (Nim has no `dyn Action`; the analogue would be an object variant or just the string). What is missing is validateMenuItem: — without it, menu items cannot grey out when unavailable, which is visible chrome. Also missing: the menu tree is built in the .m, so the app cannot declare its menus from Nim.

#### Accessibility tree — 一部

Zed: `crates/gpui_macos/src/window.rs:1862 (a11y_init), :1881 (a11y_tree_update), :1893 (a11y_update_window_bounds), :535 (accesskit_macos::SubclassingAdapter field), :1898-1911 (activation and action handlers)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:95-205 (NimculusAXNode, a hand-written NSAccessibility element), contract at src/nimnui/platform/contracts.h:189-209, entry point nimculus_platform_set_accessibility_tree (platform.h:20), Nim side src/nimnui/accessibility.nim (114 lines)`

Delegates entirely to accesskit: gpui pushes a TreeUpdate, and accesskit's SubclassingAdapter synthesizes the NSAccessibility element hierarchy on the real NSView. Action requests come back through a handler.

**Nim での再現:** The shape is right — a flat node array plus a child-index array pushed from the framework, which is structurally the same as accesskit's TreeUpdate — but the implementation is hand-rolled against the old NSAccessibility informal protocol (attributeNames/accessibilityAttributeValue, :153-185) rather than the modern NSAccessibilityElement protocol. There is no accesskit for Nim and writing one is not proportionate; the practical path is to keep the hand-rolled adapter and grow its role/attribute coverage (12 roles today, :113-124). Per MEMORY.md this layer is the stated prerequisite for XCTest/XCUIAutomation, so it is load-bearing.

#### External file drag-and-drop onto the window — 無

Zed: `crates/gpui_macos/src/window.rs:2931 (dragging_entered), :2943 (dragging_updated), :2958 (perform_drag_operation), :2964 (external_paths_from_event), :3011 (send_file_drop_event)`  
Nimculus: `no registerForDraggedTypes or draggingEntered: found in src/nimnui/platform/macos/macos_platform.m`

The window registers for NSFilenamesPboardType (window.rs:870-874) and translates the four drag callbacks into FileDrop input events carrying the paths and the drag position.

**Nim での再現:** Mechanical: register the type on the window, implement four delegate methods, add a file-drop callback alongside the existing NimculusFileCallback (contracts.h:215). No Nim-language issue.

#### Backing scale and drawable resize — 済

Zed: `crates/gpui_macos/src/window.rs:2630 (view_did_change_backing_properties), :2635 (set_frame_size), :2479 (update_window_scale_factor), :1933 (get_scale_factor), crates/gpui_macos/src/metal_renderer.rs:381 (update_drawable_size)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:10431 (updateBackingScale from viewDidChangeBackingProperties), :10809 (also on viewDidMoveToWindow)`

On resize, compares old and new size, forwards to super, converts to device pixels with the current scale factor, resizes the Metal drawable and the path intermediate textures, then invokes the resize callback with the lock released.

**Nim での再現:** Present and correctly hooked in both places. Note Nimculus also has to guard against a zero drawable size the same way Zed does (metal_renderer.rs:397-405 documents a SIGABRT from zero-sized textures); worth confirming the retained scene texture path at :10451 has the same guard.

#### Window blur / vibrancy background — 無

Zed: `crates/gpui_macos/src/window.rs:304 (BLURRED_VIEW_CLASS on NSVisualEffectView), :1525 (set_background_appearance), :3082 (blurred_view_update_layer), :3092 (remove_layer_background), :123 (CGSSetWindowBackgroundBlurRadius)`  
Nimculus: `not present in src/nimnui/platform/macos/macos_platform.m`

Three background modes (Opaque, Transparent, Blurred). Blurred inserts an NSVisualEffectView subview whose layer background is stripped, and may use the private CGSSetWindowBackgroundBlurRadius.

**Nim での再現:** Only relevant if a theme ever asks for a translucent window. Pure .m. The private CGS call should be skipped.

#### Native window tabs — 無

Zed: `crates/gpui_macos/src/window.rs:448-471 (tab selectors), :1052-1080 (addTabbedWindow at open), :1141 (get_user_tabbing_preference), :1238-1294, :1707-1761`  
Nimculus: `single window created at src/nimnui/platform/macos/macos_platform.m:12111; NimculusTabBarOverlay (:4460, :6638) is an app-drawn document tab bar, not NSWindow tabs`

Honours the AppleWindowTabbingMode user default, adds new windows as tabs of the main window, and surfaces merge-all/move-to-new-window/select-next/prev/toggle-tab-bar as callbacks.

**Nim での再現:** Requires multi-window first, which requires the per-window state mechanism above. Not reachable while window state is process-global.

### 層としての所見

The layering diverges in one decisive way, and it is not the one the brief anticipated.\n\nZed's split is gpui_macos (OS) -> gpui (framework) -> workspace/editor/project (app). Nimculus's split is macos_platform.m (OS + framework + half the app) -> nimnui (a thin framework) -> src/nimculus/main.nim (9845 lines). The 17976-line .m is the bigger layering problem than main.nim is. Compare the two boundary files: gpui_macos/src/platform.rs:475 declares a Platform impl whose every method is domain-free, whereas src/nimnui/platform/macos/platform.h declares nimculus_platform_set_editor_git_hunks, nimculus_platform_set_editor_sidebar_line_items, nimculus_platform_show_git_status_context and nimculus_platform_set_terminal_runs. Git hunks, sidebar rows and terminal runs are project/editor concepts; in Zed they never reach gpui_macos, let alone cross into Objective-C. The .m contains ~40 @interface declarations (macos_platform.m:4311-4586) for AppKit widgets — tab bar, sidebar, footer, command palette, settings, git panels — that in Zed are gpui elements built in the ui and workspace crates.\n\nThe consequence is concrete, not stylistic. Because editor state lives in the .m as globals, answering an NSTextInputClient question about the non-focused pane requires saving and restoring eight globals around a swapEditorTextState() pair (macos_platform.m:10935-10965 and again at :10967-10996). In Zed the same question is `with_input_handler(this, |h| h.bounds_for_range(range))` (window.rs:2728-2756) because the input handler is a per-window value, not a global. The same root cause blocks multi-window entirely: Zed keys everything off an Arc<Mutex<MacWindowState>> in a WINDOW_STATE_IVAR (window.rs:77, :490, :1959); Nimculus has one g_active_view.\n\nWhat belongs where, if this is ever untangled: the .m should keep NSApp/NSWindow/NSView lifecycle, the Metal device/layer/queue and encoding, CADisplayLink, CoreText shaping and glyph rasterization, the pasteboard, TIS/IME plumbing, NSAccessibility element synthesis, and NSMenu/NSPanel construction. It should not decide what a gutter looks like, where a sidebar row is, or which git hunk is which. nimnui should own the scene (a typed primitive list the .m only encodes), input classification as an object variant, focus, hit-testing, and the element tree — src/nimnui/ui_tree.nim, layout.nim, render.nim exist but are 293/289/170 lines against the .m's 17976, so they are not yet load-bearing. The application layer should own buffers, git, LSP and workspace; much of it already does, in src/nimculus (21308 lines across ~30 modules, which is better factored than main.nim's size suggests).\n\nOn the Rust-to-Nim question specifically: the two mechanisms that look hardest are actually the easiest. A Rust trait becomes a record of closures — dispatcher.nim:35-46 already proves the pattern works and reads well. Rust's Arc<Mutex<T>>-in-an-ivar becomes a GC_ref'd ref object handed over as void* — dispatcher.nim:22-33 already proves that too. Nim's GC makes the second safer than Rust's, not harder. What Nim genuinely cannot reproduce is the borrow discipline that makes Zed's take-callback-then-drop-lock idiom (window.rs:2664-2669) mandatory rather than merely advisable; that has to become a convention with a comment. And accesskit has no Nim equivalent, so the hand-rolled NimculusAXNode (macos_platform.m:95-205) is the permanent answer there, not a stopgap.\n\nTwo places where Nimculus is ahead of Zed and should not be "fixed" toward it: the retained scene texture with dirty-region re-encode (macos_platform.m:10441-10723, versus Zed re-encoding the full scene every frame at metal_renderer.rs:446), and macOS 14 CADisplayLink (macos_platform.m:9550) which sidesteps the entire CVDisplayLink teardown race that display_link.rs:1-51 exists to document and work around.\n\nMarked unknown rather than guessed: I did not read events.rs's platform_input_from_native in full, keyboard.rs's layout tables beyond the two I sampled, screen_capture.rs, or window.rs:1376-1460 (prompt) and :1857-1897 (render_to_image / a11y) beyond their signatures. On the Nimculus side I did not read src/nimculus/main.nim, so claims about which application concerns live there rest on the C boundary in platform.h, not on the Nim source.


## フレームワーク: 中核

状態: **一部のみ**

### Zed のファイル

| ファイル | 行 | 役割 |
| --- | ---: | --- |
| `crates/gpui/src/window.rs` | 6551 | Owns one window: the two-Frame (rendered/next) retained draw state, the WindowInvalidator/DrawPhase state machine, the request_layout->prepaint->paint->focus->present pipeline, hit |
| `crates/gpui/src/geometry.rs` | 4008 | The typed geometry primitives: Pixels/ScaledPixels/DevicePixels/Rems, Point/Size/Bounds/Edges/Corners, and the length enums (AbsoluteLength, DefiniteLength, Length). |
| `crates/gpui/src/app.rs` | 2903 | Owns the process-global App state: the entity map, the window slot map, globals, the effect queue, subscriber sets, and the update/flush_effects re-entrancy discipline. |
| `crates/gpui/src/app/context.rs` | 0 | Context<'a,T> - an App plus a WeakEntity<T>, giving entity-scoped notify/emit/observe/spawn. Cited line numbers are real; total line count not measured. |
| `crates/gpui/src/app/entity_map.rs` | 0 | EntityMap: slot-keyed type-erased storage with reserve/insert/lease/end_lease/read, plus Entity<T>/WeakEntity<T> handles. Cited line numbers are real; total line count not measured |

### Nimculus の対応物

| ファイル | 行 | 何を担っているか |
| --- | ---: | --- |
| `/Users/yoshinori/work/nimculus/src/nimculus/main.nim` | 9845 | Everything App and Window own in Zed, plus workspace/editor/project. setupDemoUi (main.nim:334-655) is the entire frame - rebuild tree, layout, compose paint li |
| `/Users/yoshinori/work/nimculus/src/nimnui/ui_tree.nim` | 293 | Retained node tree: ids+generations (approx EntityId handles), per-node dirty bits (approx WindowInvalidator but per node), hitTest (approx Frame::hit_test), fo |
| `/Users/yoshinori/work/nimculus/src/nimnui/layout.nim` | 289 | The whole layout phase: flexbox main/cross sizing, absolute positioning, clip propagation. Stands in for request_layout + compute_layout + Taffy, as one recursi |
| `/Users/yoshinori/work/nimculus/src/nimnui/context.nim` | 196 | KeyContext / KeyBindingContextPredicate - keymap contexts. Despite the filename this is NOT Zed's Context<'a,T>, which has no counterpart anywhere in the tree. |
| `/Users/yoshinori/work/nimculus/src/nimnui/render.nim` | 170 | PaintList: command seq, dirty-region merge, clip/transform stacks. Stands in for Scene + with_content_mask/with_element_offset. Single-buffered: no rendered/nex |
| `/Users/yoshinori/work/nimculus/src/nimnui/layout_types.nim` | 87 | LayoutSpec: direction/position/inset/size/margin/padding/gap/flexGrow/alignItems/justifyContent/overflow/scrollOffset/viewport, plus Length/LengthEdges. Covers  |
| `/Users/yoshinori/work/nimculus/src/nimnui/geometry.nim` | 84 | Pixels (distinct float32), Point/Size/Rect/EdgeInsets, Transform2D. A subset of geometry.rs: no ScaledPixels/DevicePixels/Rems, no Corners, no generics over uni |
| `/Users/yoshinori/work/nimculus/src/nimnui/executor.nim` | 75 | BackgroundExecutor/ForegroundExecutor/Task[T]=Future[T] - the app.rs:1795-1843 executor+spawn surface. The one gpui-core mechanism ported deliberately and named |

### メカニズム

#### Entity handle + type-erased entity store (lease discipline) — 無

Zed: `crates/gpui/src/app/entity_map.rs:414 (Entity<T>), :114 reserve, :120 insert, :134 lease, :151 end_lease, :156 read`  
Nimculus: `src/nimculus/main.nim - state is ~120 module-level vars (main.nim:142 demoTree, :256 imeState, :257 editorSession, :911 activeWorkspace)`

State lives in one central map keyed by EntityId; a handle is a refcounted id, not a pointer. update_entity (app.rs:2591) removes the box from the map onto the stack for the duration of the closure, then puts it back - that is how Rust gets &mut T and &mut App at once without aliasing. A second lease of the same entity panics (double_lease_panic).

**Nim での再現:** Directly reproducible and cheaper in Nim, because the borrow checker is what forced the lease trick. Entity[T] = object id: EntityId; generation: uint32, plus EntityMap = object slots: seq[EntitySlot] where EntitySlot = object gen: uint32; data: RootRef. update[T](app: var App, e: Entity[T], body: proc(state: var T, cx: var Context[T])) can index the seq directly - Nim's var T aliasing is unchecked, so no lease/unlease dance is needed; keep take/put-back only if you want the crash-on-reentrancy guarantee (one bool on the slot). Generation counters give WeakEntity for free - ui_tree.nim:12 NodeHandle already uses exactly this idiom, just not for app state.

#### Context<'a,T> - entity-scoped view of App — 無

Zed: `crates/gpui/src/app/context.rs:20 (struct), :50 entity(), :229 notify(), :765 emit()`  

A &mut App plus the WeakEntity of the entity being updated, with Deref to App. Every cx.notify() inside a method therefore knows which entity dirtied without the caller passing an id.

**Nim での再現:** Context[T] = object app: ptr App; entity: Entity[T], with template forwarders replacing Deref (Nim has no Deref, so either write cx.app.foo explicitly or generate template forwarders per App proc). Name collision to resolve: nimnui/context.nim already owns the name Context for keymap contexts (KeyContext), so the entity context needs a different module and name.

#### Effect queue + flush_effects re-entrancy guard — 無

Zed: `crates/gpui/src/app.rs:1516 push_effect, :1531 flush_effects, :1029 App::update, :1036 start_update, :1040 finish_update`  

Notifications, emits, defers, refreshes and entity-created callbacks are queued as Effect rather than delivered inline, and drained once at the end of the outermost update (pending_updates==1). Notify effects are deduplicated via pending_notifications before queueing, so N notifies of one entity collapse to one observer run. flush_effects loops until empty, since effects enqueue effects.

**Nim での再現:** A seq[Effect] where Effect is an object variant (case kind: EffectKind of efNotify: emitter: EntityId; of efEmit: ...; of efDefer: cb: proc()). Nim object variants are the natural replacement for Rust payload enums, and closures replace Box<dyn FnOnce>. pendingUpdates: int and flushingEffects: bool are plain fields; dedup is a HashSet[EntityId]. Nothing here needs a language feature Nim lacks.

#### WindowInvalidator + DrawPhase state machine — 一部

Zed: `crates/gpui/src/window.rs:117 WindowInvalidatorInner, :140 impl, :153 invalidate_view, :180 set_phase, :1197 enum DrawPhase, :1891 Window::refresh`  
Nimculus: `src/nimnui/ui_tree.nim:28-29 (layoutDirty/paintDirty per node), :192 markLayoutDirty (walks to root), :200 markPaintClean`

Single source of truth for whether a window needs a frame. invalidate_view records the dirty entity and only marks the window dirty when draw_phase==None, so an invalidation raised during a draw does not restart the frame. debug_assert_prepaint/debug_assert_paint (window.rs:212-233) enforce that insert_hitbox is prepaint-only and paint_quad is paint-only.

**Nim での再現:** Nimculus has per-node dirty bits but no window-level phase. Add DrawPhase* = enum dpNone, dpPrepaint, dpPaint, dpFocus and WindowInvalidator = object dirty: bool; phase: DrawPhase; dirtyViews: HashSet[NodeId]. The debug_assert_* guards become one template assertPrepaint() wrapping when defined(debug): doAssert win.phase == dpPrepaint, called at the top of each phase-restricted proc. Highest-value item in the layer: without it, every state change in main.nim must call setupDemoUi() by hand, which it does from 42 call sites.

#### Double-buffered Frame with element-state carryover — 無

Zed: `crates/gpui/src/window.rs:824 struct Frame, :867 Frame::new, :884 Frame::clear, :965 Frame::finish, :1015-1016 rendered_frame/next_frame fields, :2737-2741 mem::swap in draw`  
Nimculus: `src/nimnui/render.nim:34 PaintList (single buffer, no previous frame, no element state)`

Each frame is built into next_frame; at the end of draw Frame::finish migrates only the element_states that were accessed this frame from the old frame, then the two frames are swapped and next_frame cleared. Anything not accessed is dropped - the automatic GC for per-element state.

**Nim での再現:** Frame = object commands: seq[PaintCommand]; hitboxes: seq[Hitbox]; elementStates: Table[ElementKey, ElementState]; accessed: seq[ElementKey], with system.swap(win.renderedFrame, win.nextFrame) as the exact mem::swap equivalent. The type-erased ElementStateBox (Box<dyn Any> + downcast) has no direct Nim equivalent: use ref RootObj with of-based type tests, or an object variant over the state types Nimculus actually keeps. The TypeId::of::<S>() half of the key becomes a compile-time type name string or a macro-assigned per-type integer.

#### Three-phase element pipeline: request_layout -> prepaint -> paint — 一部

Zed: `crates/gpui/src/window.rs:2853 draw_roots (Prepaint at :2854, root request_layout :2884, stretch_auto_size_to_fill :2885, prepaint_as_root :2889, Paint at :2923, root paint :2924), :4252 request_layout, :4301 compute_layout, :4318 layout_bounds, :3039 prepaint_deferred_draws, :3109 paint_deferred_draws`  
Nimculus: `src/nimnui/layout.nim:113 layoutNodeRecursive, :277 layoutNode; paint emitted separately in src/nimculus/main.nim:498-596`

Layout is requested bottom-up into a Taffy tree (request_layout returns a LayoutId), the root is stretched to the viewport, prepaint then resolves bounds and registers hitboxes/tooltips/deferred draws, and only then does paint emit primitives. Deferred draws let an element paint above later siblings - how overlays and menus escape their subtree.

**Nim での再現:** Nimculus has layout and paint but no prepaint and no layout-id indirection: layoutNode writes bounds straight into UiNode.bounds and main.nim reads them. Defensible as a simplification (single-pass flexbox, not Taffy) but it costs three things: no measured layout (Zed's request_measured_layout, window.rs:3186, is how text sizes itself), no deferred-draw layer, and no place to register hitboxes at resolved bounds. In Nim: keep the recursive layout, add prepaint(tree: var UiTree, win: var Window) between layout and paint that fills win.nextFrame.hitboxes and runs measure callbacks stored on the node as proc(known: Size, avail: AvailableSpace): Size {.closure.}. Deferred draws become a seq[DeferredDraw] drained after the main paint walk.

#### Hitbox list + topmost hit testing with blocking behaviors — 一部

Zed: `crates/gpui/src/window.rs:678 struct Hitbox, :724 enum HitboxBehavior, :4338 insert_hitbox, :935 Frame::hit_test, :2919 (per-frame cache)`  
Nimculus: `src/nimnui/ui_tree.nim:143 hitTest`

Hit testing runs against the painted hitbox list in reverse paint order, intersected with each hitbox's content mask, stopping at a BlockMouse hitbox. hover_hitbox_count separates what blocks hover from what blocks clicks (BlockMouseExceptScroll). Computed once per frame and cached.

**Nim での再現:** Nimculus hit-tests the node tree in reverse node order and re-derives clipping by walking ancestors for every candidate (ui_tree.nim:151-176), with the O(n) nodeIndex (ui_tree.nim:60) called inside that loop. Porting Zed's model means recording a flat seq[Hitbox] of already-clipped rects during paint and testing that instead; the ancestor walk disappears because the content mask is baked in at insert time. HitboxBehavior is a plain Nim enum. This also removes the nested linear scan, which should become a Table[NodeId, int] regardless.

#### Content mask stack and element offset stack — 一部

Zed: `crates/gpui/src/window.rs:1793 ContentMask, :3323 with_content_mask, :3341 with_element_offset, :3360 with_absolute_element_offset, :3473 element_offset, :4325-4327 (layout_bounds applies snapped offset)`  
Nimculus: `src/nimnui/render.nim:37-38 clipStack/transformStack, :110 pushClip, :118 popClip, :120 pushTransform, :124 popTransform; layout-side clipping at src/nimnui/layout.nim:24 clipRect, :39 childClipBounds, :120-133`

Clipping and scroll translation are ambient stacks on Window, not parameters. layout_bounds adds the current pixel-snapped element offset to every returned rect, which is how scrolling works without any element knowing it is scrolled.

**Nim での再現:** Structurally present, and pushClip already intersects with the parent (render.nim:114-116) exactly as Zed does. The divergence: Nimculus clips twice - once in layout (writing clipBounds onto the node) and once in the paint list - and applies scroll in layout (content.origin.x - spec.scrollOffset, layout.nim:213) rather than as an ambient paint-time offset. Zed's with_* closures map to Nim templates (template withClip(paint, rect, body)) which push/pop around body with the same scope safety as a Rust closure and no allocation. Pick one clipping owner; the paint list is Zed's answer.

#### Per-element retained state keyed by GlobalElementId — 無

Zed: `crates/gpui/src/window.rs:3562 with_element_state, :3517 use_keyed_state, :3546 use_state, :3505 with_element_namespace, :6157 enum ElementId`  

Elements are rebuilt every frame but retain state (scroll position, open/closed, hover animation) under a stable path of ElementIds. use_state derives the key from the caller's source Location. Access marks the key live for the frame; unaccessed keys are dropped at Frame::finish.

**Nim での再現:** ElementId is a Rust enum over usize/str/Uuid/EntityId/Location - in Nim an object variant, or a plain string/Hash if you accept losing type discrimination. use_state's #[track_caller] maps cleanly onto Nim's instantiationInfo() inside a template, which yields (filename, line) at the call site; this is the one spot where Nim is exactly as capable as Rust. The Box<dyn Any> downcast has no safe equivalent: use ref RootObj plus of type tests, checked at runtime the same way.

#### Typed pixel units and the scale-factor ladder — 一部

Zed: `crates/gpui/src/geometry.rs:2677 Pixels, :2781 impl (floor/round/ceil/scale/pow/abs), :2829 Pixels::scale, :2982 DevicePixels, :3075 ScaledPixels, :3131 ScaledPixels->DevicePixels, :3238 Rems, :3298 AbsoluteLength, :3460 DefiniteLength, :3611 Length, :3736 px()`  
Nimculus: `src/nimnui/geometry.nim:2 Pixels (distinct float32), :17 px, :19-24 arithmetic`

Three distinct units so a logical coordinate can never be silently handed to the GPU: Pixels.scale(factor)->ScaledPixels->DevicePixels. Rems plus AbsoluteLength are how rem_size scales the whole UI (window.rs:2466 rem_size, with an override stack for with_rem_size).

**Nim での再現:** distinct float32 is exactly Rust's newtype, so Pixels ported cleanly. Missing are the other two units and rems: add ScaledPixels* = distinct float32, DevicePixels* = distinct int32, Rems* = distinct float32 and proc scale(p: Pixels, f: float32): ScaledPixels. Nim's {.borrow.} pragma supplies the arithmetic operators without hand-writing them (geometry.nim:19-24 writes each by hand). Note a real defect: Nimculus defines / as Pixels/Pixels -> Pixels (geometry.nim:22) whereas Zed's Div for Pixels returns bare f32 (geometry.rs:2679); the Nim version makes dimensionally wrong expressions such as remaining / px(2) (layout.nim:109) compile silently. Length/DefiniteLength/AbsoluteLength are Rust payload enums -> Nim object variants; layout_types.nim:31-38 already does this for a two-case Length, so the pattern exists but is far narrower.

#### Bounds / Point / Size / Edges / Corners generic over unit — 一部

Zed: `crates/gpui/src/geometry.rs:85 Point<T>, :396 Size<T>, :723 Bounds<T>, :1750 Edges<T>, :2258 Corners<T>, :43 trait Along, :25 enum Axis, :1694 Bounds<Pixels>::scale, :1707 to_device_pixels`  
Nimculus: `src/nimnui/geometry.nim:4 Point, :7 Size, :10 Rect, :14 EdgeInsets`

One geometry family parameterised by unit, so Bounds<Pixels> and Bounds<DevicePixels> are different types. Along/Axis let layout code be written once and applied to either axis.

**Nim での再現:** Nimculus's types are monomorphic in Pixels and Corners is absent entirely (render.nim:26 carries a single scalar radius, so per-corner radii - which Zed uses for tab shapes and rounded selections - cannot be expressed). Nim generics handle this directly: Point*[T] = object x*, y*: T, and Rect should be aliased to Bounds for vocabulary parity. The Along trait is the one place Nim's lack of traits bites mildly: use a concept, or more pragmatically proc along*[T](p: Point[T], axis: Axis): T with a case - a plain proc replaces the trait because there is only one implementation per type. layout.nim already hand-rolls the axis switch with rowDirection booleans (layout.nim:164 and ~15 subsequent if rowDirection: branches); an Along-style accessor collapses those.

#### Frame profiling: dirty-timestamp accumulation and present — 一部

Zed: `crates/gpui/src/window.rs:126 FrameDirtyAccumulator, :2681 take_frame_dirty, :2789 record_frame_timing, :2827 present, :2841 present_if_needed`  
Nimculus: `src/nimculus/main.nim:96-116 (soak sampling reads platformGetFrameTimingStats / platformGetInputLatencyStats), main.nim:50 receiveNativeFrame`

Records when the frame first became dirty and how many invalidations coalesced into it, so frame time is measured from first invalidation to draw_end rather than from draw start. present() hands the finished scene to the platform window and clears needs_present.

**Nim での再現:** Nimculus measures frame time on the native side and reads it back through the platform contract, which measures draw-to-draw, not dirty-to-drawn. To match Zed's number the invalidation timestamp must exist Nim-side: add dirtyAt: Option[float64] and invalidations: int to the invalidator, stamped in markLayoutDirty/markPaintDirty via epochTime(), drained where the frame is composed. This matters for the project's own acceptance measurements, because the two definitions of frame time are not comparable.

#### Window/App split: root view, viewport, scale factor, refresh — 無

Zed: `crates/gpui/src/window.rs:989 struct Window (root :1006, viewport_size :1004, layout_engine :1005, scale_factor :1029), :2347 viewport_size(), :2460 scale_factor(), :2466 rem_size(), app.rs:711 windows SlotMap, app.rs:1217 open_window, app.rs:1728 update_window_id`  
Nimculus: `src/nimculus/main.nim - one implicit window; viewport read from platformGetMetrics at main.nim:378-383; scale factor never enters the Nim layer`

App holds N windows in a slot map; each Window owns its own layout engine, frames, focus, text system and platform window. update_window_id takes the window out of its slot for the duration of the callback - the same lease trick as entities, and the reason a window cannot re-enter itself.

**Nim での再現:** A Window = ref object holding tree, frames, invalidator, viewportSize, scaleFactor, remSize, plus App = object windows: seq[Window], is straightforward Nim; the lease trick is unnecessary for the reason given under the Entity mechanism. The concrete gap that will bite first is scale factor: it is never surfaced Nim-side, so pixel snapping (window.rs:4326 pixel_snap_point) cannot be done in Nim and all Retina-dependent geometry parity is decided by the Metal backend alone.

### 層としての所見

Layering divergence, concretely.

1. There is no App and no Window object anywhere in the Nim layer. Zed's App (app.rs:679) and Window (window.rs:989) are ~130 fields of framework state; in Nimculus that state is ~120 module-level vars in main.nim (main.nim:142-160, :256-259, :911-987). The consequence is not stylistic: because nothing owns "this window is dirty", every state change must manually call setupDemoUi(), and it does so from 42 separate call sites. Zed's equivalent is one cx.notify() per entity and one window.draw() per frame. This is the largest structural gap in the layer, and most of the others follow from it.

2. Nimculus has no frame loop in Nim. receiveNativeFrame (main.nim:50) does one thing - pollAsyncDispatchTick(). Frames are driven by the platform display link, and the Nim side only ever pushes a fully composed paint list across the FFI (platformSetPaintCommands, main.nim:630). Zed's draw (window.rs:2679) is Rust-side and owns the whole pipeline. So the layer boundary sits in a different place: Zed's Window/present is Nimculus's Objective-C/Metal layer, which leaves the Prepaint/Paint/Focus phase discipline, the double-buffered Frame, and dirty-to-drawn frame timing with nowhere to live.

3. The retained-vs-immediate split is inverted. Zed rebuilds the element tree every frame and retains only element state keyed by ElementId (window.rs:3562). Nimculus retains the node tree (ui_tree.nim UiTree) with dirty bits, then throws it away and rebuilds from scratch on every setupDemoUi (demoTree = newUiTree(), main.nim:341) - paying the cost of a retained tree while getting the invalidation semantics of an immediate one. The generation counters at ui_tree.nim:33 that would let handles survive a rebuild are reset with the tree.

4. Where the Nim layering is genuinely good: executor.nim maps Task/BackgroundExecutor/ForegroundExecutor onto Nim's Future with the thread-ownership rule stated in the module doc, and it is a smaller, clearer surface than app.rs:1795-1843. The single-pass flexbox in layout.nim is also a defensible substitute for Taffy at this scale.

5. Two measurable defects noticed while reading this layer. (a) nodeIndex (ui_tree.nim:60) is a linear scan called inside the hit-test ancestor walk (ui_tree.nim:155, :160) and inside layout's child loops (layout.nim:145, :174, :190, :207, :231), making layout quadratic in child count. (b) proc `/`(a, b: Pixels): Pixels (geometry.nim:22) returns Pixels where Zed's Div for Pixels returns f32 (geometry.rs:2679), so dimensionally wrong expressions such as remaining / px(2) (layout.nim:109) compile silently.

If this layer is built out, the split should be: Pixels/ScaledPixels/DevicePixels/Rems/Bounds/Edges/Corners in nimnui/geometry.nim; Entity/EntityMap/Context/effect queue in a new nimnui/app.nim; Window/WindowInvalidator/DrawPhase/Frame/hitboxes/element state in a new nimnui/window.nim. Everything in main.nim from setupDemoUi's tree construction and paint composition onward is Zed's workspace crate, not gpui, and should not migrate into the framework layer with it.


## フレームワーク: テキストと描画

状態: **一部のみ**

### Zed のファイル

| ファイル | 行 | 役割 |
| --- | ---: | --- |
| `crates/gpui/src/window.rs` | 6551 | The paint_* boundary that converts logical Pixels into ScaledPixels scene primitives: paint_quad, paint_path, paint_underline, paint_strikethrough, paint_glyph, paint_emoji, paint_ |
| `crates/gpui/src/text_system/line_wrapper.rs` | 1577 | The pooled LineWrapper used for soft-wrap boundary search independent of a shaped layout; obtained via TextSystem::line_wrapper (text_system.rs:307). I read only its declaration su |
| `crates/gpui/src/style.rs` | 1525 | Style/StyleRefinement and TextStyle/TextStyleRefinement/HighlightStyle, plus UnderlineStyle, StrikethroughStyle, Fill, and Style::paint which emits shadows/quads for an element. |
| `crates/gpui/src/text_system.rs` | 1206 | Owns the process-wide TextSystem: font id interning, font metrics cache, glyph raster-bounds cache, the line-wrapper pool, and the per-window WindowTextSystem that fronts the line  |
| `crates/gpui/src/text_system/line_layout.rs` | 1078 | Defines LineLayout/ShapedRun/ShapedGlyph/WrappedLineLayout, the index<->x geometry queries, wrap-boundary computation, and the two-frame LineLayoutCache (including the hash-keyed,  |
| `crates/gpui/src/color.rs` | 1070 | Rgba and Hsla (with alpha/opacity/fade_out/blend/grayscale), and Background — the tagged solid/linear-gradient/pattern fill that quads and paths carry to the shader. |
| `crates/gpui/src/text_system/line.rs` | 1015 | ShapedLine/WrappedLine: pairs a cached LineLayout with DecorationRuns and turns them into paint calls (glyph/emoji sprites, underline/strikethrough runs, per-run background quads), |
| `crates/gpui/src/scene.rs` | 915 | The Scene: per-kind primitive vectors, layer stack + BoundsTree draw order assignment, insert/replay/finish (sort by order), and the BatchIterator that merges the eight sorted stre |
| `crates/gpui/src/text_system/font_features.rs` | 154 | FontFeatures, part of the Font identity used as the font-id cache key. |
| `crates/gpui/src/text_system/font_fallbacks.rs` | 21 | FontFallbacks, also part of Font identity. |

### Nimculus の対応物

| ファイル | 行 | 何を担っているか |
| --- | ---: | --- |
| `/Users/yoshinori/work/nimculus/src/nimnui/platform/macos/macos_platform.m` | 17976 | The whole rendering half of this layer: RenderGlyphParams-equivalent atlas key and 4x1 subpixel quantization, mono/polychrome sprite structs and their Metal pip |
| `/Users/yoshinori/work/nimculus/src/nimculus/main.nim` | 9845 | Not read for this layer; noted only because it is where the application-level style and colour decisions that Zed puts in TextStyle/theme would have to live tod |
| `/Users/yoshinori/work/nimculus/src/nimnui/text.nim` | 467 | LineLayout/ShapedRun/ShapedGlyph/WrappedLineLayout types, the two-frame hash-keyed LineLayoutCache with steal-from-previous and finishFrame swap, computeWrapBou |
| `/Users/yoshinori/work/nimculus/src/nimculus/editor_text_layout.nim` | 230 | The app-side half of shape_text: font-run construction from syntax decorations (the analogue of the FontRun coalescing in text_system.rs:556-567), wrapped-row e |
| `/Users/yoshinori/work/nimculus/src/nimnui/render.nim` | 170 | The paint-command list that stands in for Zed's Scene: a single PaintCommand object with a semantic kind enum, dirty-rect merging, a clip stack and a transform  |

### メカニズム

#### Font identity and FontId interning — 一部

Zed: `crates/gpui/src/text_system.rs:1051 (Font), :107 (font_id), :148 (resolve_font)`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimnui/text.nim:42 (FontRun.fontId: uint32); /Users/yoshinori/work/nimculus/src/nimnui/platform/macos/macos_platform.m:1355-1368 (font_id in the raster key)`

Font is (family, features, fallbacks, weight, style) and is hashable; TextSystem interns it to an opaque FontId through a RwLock<FxHashMap<Font, Result<FontId>>>, and resolve_font falls back down a hard-coded stack (text_system.rs:71-84) so a missing family never fails a frame.

**Nim での再現:** Nimculus already uses a bare uint32 font id, but there is no Font record and no interning table: the id is minted app-side as decoration.kind+1 (editor_text_layout.nim:78), so it encodes a syntax category, not a typeface. Reproducible as a Nim `object` Font with `hash`/`==` overloads plus a `Table[Font, uint32]` in a `FontSystem` ref object; resolve_font becomes a plain proc returning the first id that the Objective-C side resolves. No trait is needed — the platform text system is already a single .m file, so it can stay a set of importc procs rather than a `dyn PlatformTextSystem`.

#### Font metrics cache and the em_width / em_advance / ch_width / ch_advance distinction — 一部

Zed: `crates/gpui/src/text_system.rs:226-249, :292 (read_metrics), :1104 (FontMetrics), :1137-1177`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimnui/platform/macos/macos_platform.m:2164-2165, :2187-2189 (editorGlyphAdvance), :2212-2215, :3068 (emWidth via typographic width of 'm')`

FontMetrics holds units_per_em, ascent, descent, line_gap, underline_position/thickness, cap_height, x_height, bounding_box in font units; every accessor scales by font_size/units_per_em. em_width is the *typographic bounds* width of 'm', em_advance is the *advance* of 'm', ch_width the bounds width of '0', ch_advance the advance of '0'. Metrics are memoized per FontId behind an upgradable RwLock.

**Nim での再現:** The four-way distinction is honoured on the macOS side — editorGlyphTypographicWidth vs editorGlyphAdvance are separate procs, and the gutter uses ch_width for padding but ch_advance for line-number width (macos_platform.m:2220-2229) — but it lives in Objective-C, is computed per call from CTFont, and is not memoized or exposed to Nim. In Nim this is a `FontMetrics` object plus `Table[uint32, FontMetrics]` in the same FontSystem ref object; the accessors are trivial procs. Rust's RwLock/upgradable-read is unnecessary because Nimculus paints on one thread — a plain Table suffices, which is a simplification, not a loss.

#### Two-frame line layout cache with hash keys — 済

Zed: `crates/gpui/src/text_system/line_layout.rs:392 (LineLayoutCache), :398 (FrameCache), :497 (finish_frame), :577 (layout_line), :638/:694 (by-hash variants)`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimnui/text.nim:119 (LineLayoutCache), :115 (FrameCache), :332 (layoutLineByHash), :367 (layoutWrappedLineByHash), :409 (finishFrame)`

Keeps current_frame and previous_frame maps; a lookup checks current, then steals the entry out of previous, else shapes via the platform. finish_frame swaps the two and clears the new current, so anything not touched this frame is dropped exactly one frame later. The by-hash maps let a caller probe without materializing a contiguous string.

**Nim での再現:** Already done, and done well: `swap(cache.previousFrame, cache.currentFrame)` at text.nim:410 is the exact analogue of the mem::swap at line_layout.rs:500, and the steal-from-previous path is at text.nim:341-348. Rust's Arc<LineLayout> becomes Nim `ref LineLayout` under ARC, which gives the same shared-ownership semantics without the borrow discipline. Two divergences: Nimculus keys *only* by hash (there is no text-keyed map — CacheKey at text.nim:79 stores textHash, not the text), so a hash collision silently returns the wrong layout where Zed would compare the actual &str at line_layout.rs:936; and there is no layout_index/reuse_layouts/truncate_layouts (line_layout.rs:434-495), the mechanism that lets an element subtree reuse a previous frame's layouts wholesale.

#### Line geometry queries (index_for_x, x_for_index, position_for_index) — 一部

Zed: `crates/gpui/src/text_system/line_layout.rs:58, :75, :105, :117, :283-362`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/editor_text_layout.nim:97 (xAt), :92 (glyphByteAt)`

Maps between byte index and x within a shaped line, and between byte index and (x,y) within a wrapped line, by walking the glyph stream. This is what cursor placement and click-to-position are built on.

**Nim での再現:** Nimculus has only the index→x direction, and it lives in the app module rather than next to LineLayout. The remaining four (index_for_x, closest_index_for_x, font_id_for_index, position_for_index with its wrap-boundary walk) are straightforward nested-loop procs over `layout.runs[].glyphs[]` and belong in nimnui/text.nim beside the LineLayout type.

#### Wrap boundary computation on the already-shaped glyph stream — 済

Zed: `crates/gpui/src/text_system/line_layout.rs:128 (compute_wrap_boundaries), :212 (WrappedLineLayout), :225 (WrapBoundary)`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimnui/text.nim:272 (computeWrapBoundaries), :70 (WrapBoundary), :73 (WrappedLineLayout)`

Walks the shaped glyphs once, tracking the last word-start candidate, and emits WrapBoundary{run_ix, glyph_ix} whenever the accumulated width from the last boundary exceeds wrap_width — without re-shaping any candidate prefix. max_lines clamps the count.

**Nim での再現:** Already a direct port, and the comment at text.nim:274 says so. The Nim version differs in its word-character predicate (text.nim:176 isWordChar hard-codes Unicode ranges) where Zed defers to LineWrapper; that is a fidelity risk for CJK and for the punctuation set, not a structural one.

#### The pooled LineWrapper — 無

Zed: `crates/gpui/src/text_system.rs:307 (line_wrapper), :56 (wrapper_pool), :850 (LineWrapperHandle), crates/gpui/src/text_system/line_wrapper.rs`  

A reusable per-(font,size) wrapper object handed out through an RAII handle that returns it to the pool on Drop; used for soft-wrap decisions that are independent of a shaped line.

**Nim での再現:** Nimculus wraps only via computeWrapBoundaries on a shaped layout, so there is no second wrapper at all. If one is needed, the pool is a `seq[LineWrapper]` in a table keyed by (fontId, fontSize); Rust's Drop-based return becomes either an explicit `release` proc or Nim's `=destroy` hook on a distinct handle type. I read only the declarations of line_wrapper.rs, not its wrapping algorithm, so I cannot say what behaviour would have to be reproduced inside it.

#### DecorationRun coalescing (style runs separated from font runs) — 一部

Zed: `crates/gpui/src/text_system.rs:409-427 (shape_line), :537-567 (shape_text), crates/gpui/src/text_system/line.rs:24 (DecorationRun)`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimnui/text.nim:47 (TextRun), :79 (CacheKey comment); /Users/yoshinori/work/nimculus/src/nimculus/editor_text_layout.nim:45 (fontRunsForLine), :60 (appendRun)`

TextRuns carry both font identity and colour/underline/strikethrough/background. shape_line splits them: adjacent runs with identical decoration merge into one DecorationRun, and adjacent runs with the same FontId merge into one FontRun. Only the FontRuns enter the cache key, so a colour change never invalidates a shaped line.

**Nim での再現:** The key insight is preserved — text.nim:80-81 explicitly notes colour is outside CacheKey, and fontRunsForLine coalesces adjacent same-font runs. What is missing is the DecorationRun half: Nimculus has no type carrying (len, color, background, underline, strikethrough), so there is nothing to coalesce and nothing to hand to a painter. In Nim this is an `object` with `Option[UnderlineStyle]` fields (Nim has `std/options`) and a merge loop identical to the Rust one; no trait or generic is involved.

#### paint_line: turning a layout plus decorations into primitives — 一部

Zed: `crates/gpui/src/text_system/line.rs:334-578, background variant at :580`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimnui/platform/macos/macos_platform.m:2904-2919 (editorTextBaselineFromMetrics), :3736 (appendEditorGlyphSprite), :3795-3830 (per-row glyph walk)`

Walks glyphs advancing a pen by position deltas, opens/closes underline and strikethrough spans as DecorationRuns change or a wrap boundary is crossed, culls glyphs against the content mask, and calls paint_glyph or paint_emoji. It fixes the baseline as padding_top + ascent where padding_top = (line_height - ascent - descent)/2 (line.rs:353), places the underline at baseline + descent*0.618 (line.rs:458) and the strikethrough at ((ascent*0.5)+baseline)*0.5 (line.rs:477).

**Nim での再現:** The baseline formula is reproduced exactly — macos_platform.m:2906 computes (lineHeight - ascent - descent)/2 and adds ascent, matching line.rs:353. The glyph walk and content-mask cull are there too. Absent: the decoration state machine. There is no underline or strikethrough emission for text (the only underline in the codebase is the diagnostic squiggle at macos_platform.m:2571), so the 0.618-descent and 0.5-ascent placements have no counterpart. In Nim this whole loop should move out of the .m file into a Nim proc over LineLayout + seq[DecorationRun] that emits typed primitives, leaving Objective-C only the rasterize-and-upload step; the Rust `Option<(Point, UnderlineStyle)>` running state becomes `Option[tuple[origin: Point, style: UnderlineStyle]]`, a direct translation.

#### Glyph rasterization key and subpixel quantization — 済

Zed: `crates/gpui/src/text_system.rs:44-48 (SUBPIXEL_VARIANTS_X/Y), :1023 (RenderGlyphParams), :324 (raster_bounds), :336 (rasterize_glyph); crates/gpui/src/window.rs:3954-3976`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimnui/platform/macos/macos_platform.m:1309-1310, :1355-1368 (NimculusRenderGlyphParams), :3539-3560 (hash/eq), :3812-3823 (quantization), :3697-3701 (variant offset at raster time)`

Scales the glyph origin by the device scale, quantizes x into 4 subpixel variants and y into 1, splits into an integer origin plus a subpixel_variant, and builds RenderGlyphParams{font_id, glyph_id, font_size, subpixel_variant, scale_factor, is_emoji, subpixel_rendering, dilation} as the atlas key. Raster bounds are cached separately from the pixels.

**Nim での再現:** This is the most faithfully ported mechanism in the layer — same 4x1 variant counts, same round-half-toward-zero quantization, same POD key hashed by float bits (the comment at macos_platform.m:1354 names Zed's to_bits()). It lives entirely in C, which is fine: it is the one part that must sit next to CTFontDrawGlyphs. text.nim:124 GlyphKey is a parallel Nim declaration of the same key that appears unused by the real path — two definitions of one key is a divergence worth collapsing.

#### Scene primitive set and per-kind streams — 一部

Zed: `crates/gpui/src/scene.rs:41 (Scene), :222 (Primitive), :501 (Quad), :521 (Underline), :540 (Shadow), :677 (MonochromeSprite), :696 (SubpixelSprite), :715 (PolychromeSprite), :755 (Path), :734 (PaintSurface)`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimnui/platform/macos/macos_platform.m:1393 (NimculusMonochromeSprite), :1403 (NimculusPolychromeSprite); /Users/yoshinui/... (n/a); /Users/yoshinori/work/nimculus/src/nimnui/render.nim:20 (PaintCommand)`

Eight #[repr(C)] primitive types, each accumulated in its own Vec so a whole stream can be handed to one shader as an instance buffer. Every primitive carries bounds, content_mask, and an order.

**Nim での再現:** Nimculus has two of the eight — MonochromeSprite and PolychromeSprite, in C, with the field order deliberately matched (macos_platform.m:1401-1402). There is no Quad, no Underline, no Shadow, no Path, no Surface primitive. What stands in their place is render.nim's PaintCommand, a single object with a `kind` enum whose members are *semantic* (workspaceBackground, editorActiveLine, scrollbarTrack, editorDiagnostic — render.nim:5-12) rather than geometric. That is the deepest divergence in this layer: Zed's scene knows only shapes and lets the theme pick colours before insertion, whereas Nimculus ships a role to the Metal backend and lets the backend look up the theme. In Nim the Zed model is an object variant (`case kind: PrimitiveKind`) or, better for GPU upload, one `seq[Quad]`, `seq[Underline]` etc. per kind exactly as Rust does — Nim seqs of `{.packed.}` objects map onto MTLBuffer contents just as well as Vec<T> does.

#### Draw order, the layer stack, and the BoundsTree — 無

Zed: `crates/gpui/src/scene.rs:43-44, :75 (push_layer), :87 (insert_primitive), :151 (finish)`  

Every inserted primitive gets a DrawOrder from a BoundsTree keyed on its clipped bounds, or inherits the current layer's order; finish() sorts each stream by that order so kinds interleave correctly by depth while still batching by kind. Empty clipped bounds are dropped at insert time.

**Nim での再現:** Nimculus's monochrome sprite struct (macos_platform.m:1393-1398) has no order field at all, and the polychrome one carries `order` but every construction site passes 0 (macos_platform.m:3750). Ordering is instead implicit in the fixed sequence of setRenderPipelineState calls in the frame (macos_platform.m:10475-10641): background quads, then mono glyphs, then polychrome glyphs, per viewport. That works while the z-structure is fixed, and breaks the moment an element needs to sit between two existing kinds. Reproducing Zed needs (a) a uint32 order on every primitive, (b) `sort` by order per stream, which Nim's std/algorithm gives directly, and (c) the BoundsTree — an interval structure I did not read (it is not in the files I was assigned), so I cannot describe its algorithm, only its interface: insert(bounds) -> order.

#### Batching: merging sorted streams into draw calls — 無

Zed: `crates/gpui/src/scene.rs:172 (batches), :288-466 (BatchIterator)`  

Peeks the head order of all eight streams, picks the lowest (ties broken by PrimitiveKind), then consumes from that one stream while its order stays below the runner-up's — additionally breaking sprite batches when the atlas texture_id changes. Result is the minimal set of draw calls that still respects depth.

**Nim での再現:** With no order field there is nothing to merge; Nimculus issues one draw call per pipeline per viewport. The iterator is mechanical in Nim once orders exist: a `closure iterator` yielding a `PrimitiveBatch` object variant reproduces `impl Iterator<Item = PrimitiveBatch>` one-for-one, since Nim iterators and Rust iterators agree on pull semantics. The texture_id split (scene.rs:396, :417, :438) matters as soon as the atlas can be more than one texture — Nimculus currently has exactly two fixed atlas textures (macos_platform.m:1294-1295), which is why it has not needed the split.

#### Hsla and alpha derivation — 無

Zed: `crates/gpui/src/color.rs:334 (Hsla), :424 (hsla), :525 (to_rgb), :580 (blend), :607 (fade_out), :637 (opacity), :667 (alpha), :677 (From<Rgba>)`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimnui/text.nim:51 (TextRun.color: array[4, float32]); /Users/yoshinori/work/nimculus/src/nimnui/platform/macos/macos_platform.m:1384-1389 (NimculusGlyphColor rgba)`

All colour in the scene is Hsla with components in 0..1. opacity(f) multiplies alpha, alpha(a) replaces it, fade_out(f) multiplies by (1-f); Hsla is Hash+Ord via total_cmp on the bits so it can key caches. Conversion to Rgba happens at shader-upload time.

**Nim での再現:** Nimculus is RGBA-only end to end — no Hsla type exists in either the Nim or the Objective-C source I read. That is a real parity risk, because Zed themes are authored in HSL and derive hover/selected states by lightness and by opacity() on the same hue; deriving them from RGBA gives different values. In Nim, Hsla is a plain `object` of four float32 with `hsla()` clamping constructor and `opacity`/`alpha`/`fadeOut`/`blend` procs — no trait machinery needed; `hash` and `==` come from `std/hashes` over the bit patterns. Conversion to the array[4, float32] the Metal side wants happens in one `toRgba` proc at the paint boundary.

#### Background: solid vs gradient vs pattern as one shader-visible tag — 無

Zed: `crates/gpui/src/color.rs:779 (Background), :759 (ColorSpace), :851 (solid_background), :865 (linear_gradient), :827 (pattern_slash), :841 (checkerboard); used by scene.rs:506 (Quad.background) and :761 (Path.color)`  

A single repr(C) struct with a tag, a colour space (sRGB or Oklab), a solid colour, an angle-or-pattern-height float, and two colour stops — so a quad or path fill is one uniform-sized value the shader can branch on.

**Nim での再現:** No fill abstraction exists; Nimculus quads are drawn by dedicated procs (drawRoundedRectangle at macos_platform.m:1789) with colours chosen per semantic paint kind. Reproducible as a Nim object with an explicit `tag` field rather than an object variant, because the struct must stay POD for the MTLBuffer — Nim object variants carry a hidden discriminant but are otherwise layout-compatible if declared `{.packed.}`; still, a plain tag field is the safer transcription of #[repr(C)].

#### TextStyle and its refinement/highlight composition — 無

Zed: `crates/gpui/src/style.rs:434 (TextStyle), :432 (#[derive(Refineable)]), :506 (highlight), :539 (font), :550 (line_height_in_pixels), :555 (to_run), :576 (HighlightStyle), :920 (HighlightStyle::highlight)`  

TextStyle is the resolved style; the derive generates TextStyleRefinement, an all-Option mirror that can be layered over a parent. HighlightStyle is a sparse overlay applied by TextStyle::highlight, which *blends* colour (style.rs:516) rather than replacing it, and multiplies alpha via fade_out. to_run(len) converts the resolved style into the TextRun the shaper consumes.

**Nim での再現:** Nothing in nimnui corresponds to TextStyle; the app passes a fontId and a raw rgba array (text.nim:47-51) and colours are resolved inside the Metal backend from a theme lookup keyed by the semantic paint kind. Rust's Refineable derive has no Nim equivalent, but the pattern does: declare TextStyle with concrete fields and TextStyleRefinement with `Option[T]` fields, and hand-write (or generate with a `macro`) a `refine(base: TextStyle, over: TextStyleRefinement): TextStyle` that assigns each `isSome` field. Nim macros over object field iteration (`fieldPairs`) can do this generically in about twenty lines, which is the closest thing to the derive.

#### UnderlineStyle / StrikethroughStyle and their snapped emission — 無

Zed: `crates/gpui/src/style.rs:824 (UnderlineStyle), :839 (StrikethroughStyle); crates/gpui/src/window.rs:3870 (paint_underline), :3905 (paint_strikethrough)`  

Both are (color: Option<Hsla>, thickness: Pixels) — underline adds `wavy: bool`, which triples the primitive height (window.rs:3880-3884) so the shader can draw the wave inside it. Both round the origin to device pixels and snap the stroke, and both become the *same* Underline primitive; strikethrough is just an Underline with wavy=false.

**Nim での再現:** Neither style nor primitive exists. Two small Nim objects plus one Underline primitive struct reproduce this exactly. The detail worth transcribing literally is that thickness is snapped and the wavy case reserves 3x the thickness in bounds — getting either wrong shows up immediately as a mispositioned squiggle. The existing diagnostic underline path (macos_platform.m:2571) is a per-kind special case that should be replaced by this general primitive rather than extended.

#### Pixels -> ScaledPixels boundary and device-pixel snapping — 一部

Zed: `crates/gpui/src/window.rs:3886 (round_to_device_pixel), :3952 (origin.scale(scale_factor)), :3964 (integer origin), scene.rs:787 (Path::scale)`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimnui/geometry.nim (Pixels/px); /Users/yoshinori/work/nimculus/src/nimnui/platform/macos/macos_platform.m:3810-3823 (scaledX and quantization)`

Element code works in logical Pixels; every paint_* entry point multiplies by the window scale factor and rounds, so the Scene is entirely in ScaledPixels and the renderer never has to think about DPI. The type system enforces the boundary — Bounds<Pixels> and Bounds<ScaledPixels> are distinct types.

**Nim での再現:** Nimculus has a `Pixels` scalar and applies the scale factor inside the Objective-C glyph path, but the two spaces are not distinguished in the type system and the conversion happens in several places rather than at one boundary. Nim's `distinct float32` gives exactly Rust's newtype separation — `type ScaledPixels = distinct float32` with explicit `scale(p: Pixels, factor: float32): ScaledPixels` — and `{.borrow.}` pragmas can re-export the arithmetic operators so the ergonomics match. This is one of the cheapest high-value ports available here.

### 層としての所見

The layer splits cleanly in two, and Nimculus's coverage is lopsided across the split. The *text* half — cache, wrap boundaries, glyph raster key, subpixel quantization, baseline formula — is ported with real fidelity, in places transcribing Zed line for line with comments naming the source (src/nimnui/text.nim:274, macos_platform.m:1354). The *scene* half is largely absent: of eight primitives Nimculus has two, and both are glyph sprites.

Three structural divergences matter more than any single missing function.

First, semantic vs geometric primitives. render.nim:5-12 defines PaintKind members like workspaceBackground, editorActiveLine, scrollbarTrack and editorDiagnostic. Zed's Scene has no idea what a scrollbar is; it has Quads with a Background, and the theme is resolved into a colour before insert_primitive. Nimculus ships the role to the Metal backend and resolves the theme there (the branch chain around macos_platform.m:2440-2580). Every new UI element therefore costs a new enum member, a new backend branch, and a new theme lookup, where in Zed it costs nothing. This is the single largest obstacle to reaching UI parity by porting rather than by reimplementing.

Second, no draw order. NimculusMonochromeSprite (macos_platform.m:1393) has no order field; ordering is the fixed sequence of pipeline switches at macos_platform.m:10475-10641. Zed gets correct interleaving *and* batching from one uint32 plus a sort (scene.rs:151) plus the BatchIterator (scene.rs:288). Until primitives carry an order, any element that needs to sit between two existing kinds requires another hardcoded pass.

Third, colour. There is no Hsla anywhere in what I read — TextRun.color is array[4, float32] (text.nim:51) and NimculusGlyphColor is rgba (macos_platform.m:1384). Zed themes derive hover, selected, and muted states by manipulating l and a on the same hue (color.rs:637, :667, :607). Reproducing those derivations from RGBA gives visibly different colours, so this is a parity bug generator, not just a stylistic difference.

On layering: Zed keeps shape_line/shape_text, decoration coalescing, and paint_line all inside gpui, and the app only supplies TextRuns. Nimculus has pushed the run construction up into the app (editor_text_layout.nim:45) and the entire painting loop *down* into Objective-C (macos_platform.m:3795-3830), leaving nimnui/text.nim holding only the cache. The painting loop is the piece most obviously in the wrong layer: it is pure geometry over LineLayout plus decorations, it needs no CoreText, and moving it into Nim beside the LineLayout type is what would make DecorationRun, UnderlineStyle and a text-level Underline primitive expressible at all. Objective-C should keep only what genuinely needs CTFont: shaping (already correctly isolated in text_platform.m), metric extraction, and rasterize-into-atlas.

Reproducibility in Nim is not the constraint anywhere in this layer. There are no traits to work around — the one dyn trait, PlatformTextSystem, is already collapsed into importc procs, which is the right call for a single-platform target. Rust's Arc maps onto ref+ARC, Refineable onto a fieldPairs macro, newtypes onto distinct types, and Iterator onto closure iterators. The gaps here are unwritten code, not language mismatches.

Two caveats on what I did not read: line_wrapper.rs I saw only in declaration listing, so I describe its interface and not its algorithm; and BoundsTree, which supplies DrawOrder, is outside the files assigned, so I can state its interface (insert(bounds) -> order) but not how it computes one.


## フレームワーク: 入力とアクション

状態: **一部のみ**

### Zed のファイル

| ファイル | 行 | 役割 |
| --- | ---: | --- |
| `crates/gpui/src/window.rs` | 6551 | Runtime side of the layer: FocusId/FocusHandle, DispatchPhase, and the capture/bubble driving of key listeners, modifier listeners and action listeners (read only around lines 88,  |
| `crates/gpui/src/key_dispatch.rs` | 1195 | Builds the per-frame DispatchTree of nodes (key context, focus id, view id, listeners) and resolves keystrokes against it, including multi-keystroke pending/replay. |
| `crates/gpui/src/keymap/context.rs` | 891 | KeyContext (identifier / key=value entry list) and the KeyBindingContextPredicate mini-language with its parser, evaluator, depth_of and is_superset. |
| `crates/gpui/src/interactive.rs` | 878 | The platform input event vocabulary: KeyDown/KeyUp/ModifiersChanged, mouse/touch/scroll/pinch/file-drop events, the PlatformInput enum and the ClickEvent abstraction. |
| `crates/gpui/src/keymap.rs` | 857 | The Keymap itself: stores bindings in load order and resolves input to bindings by context depth, load order and disable markers. |
| `crates/gpui/src/tab_stop.rs` | 615 | TabStopMap: path-ordered (group index, tab index) set of focus handles with next/prev traversal, built by replaying insertion operations. |
| `crates/gpui/src/action.rs` | 458 | The Action trait, the actions! macro, the global ActionRegistry (build by name/JSON, name<->TypeId), and the NoAction/Unbind disable markers. |
| `crates/gpui/src/keymap/binding.rs` | 143 | KeyBinding: an action plus a sequence of keystrokes, an optional context predicate, and a source-metadata index; owns prefix matching. |

### Nimculus の対応物

| ファイル | 行 | 何を担っているか |
| --- | ---: | --- |
| `/Users/yoshinori/work/nimculus/src/nimculus/main.nim` | 9845 | All actual keymap content and dispatch wiring: the global registry (:143), the native shortcut entry point (:663), ~30 hardcoded default bindings (:681-802) and |
| `/Users/yoshinori/work/nimculus/src/nimnui/ui_tree.nim` | 293 | Focus ownership, generation-checked handles, disabled-path rules, per-node KeyContext and contextStack. Covers the FocusHandle/FocusId parts of window.rs and th |
| `/Users/yoshinori/work/nimculus/src/nimnui/controls.nim` | 263 | Nothing from this layer structurally — it is overlay/menu widget state. Relevant only because handleKey (:184) and handlePointerDown (:197) hand-roll the activa |
| `/Users/yoshinori/work/nimculus/src/nimnui/commands.nim` | 228 | Two unrelated things: the command registry with single-keystroke shortcut resolution by context depth (a thin stand-in for keymap.rs + binding.rs + action.rs),  |
| `/Users/yoshinori/work/nimculus/src/nimnui/context.nim` | 196 | KeyContext data structure and the full context-predicate language (parser, evaluator, depthOf). Corresponds to keymap/context.rs minus is_superset, KeyContext:: |
| `/Users/yoshinori/work/nimculus/src/nimnui/accessibility.nim` | 114 | Nothing from this layer. It reads focus/a11y fields off UiNode but has no dispatch, keymap or focus-traversal role. |
| `/Users/yoshinori/work/nimculus/src/nimnui/events.nim` | 95 | The platform event vocabulary and the capture/bubble walk. Corresponds to interactive.rs plus window.rs:4999 dispatch_key_down_up_event. |

### メカニズム

#### Action as a type-erased, registered value — 無

Zed: `crates/gpui/src/action.rs:117 (trait Action), :233 (ActionRegistry), :293 (insert_action), :351 (build_action)`  
Nimculus: `src/nimnui/commands.nim:14 (`Command` = name + shortcut + whenClause + closure)`

An action is a concrete Rust struct behind `dyn Action`. Identity is its TypeId; its name (`editor::Undo`) and a JSON constructor are registered globally at startup via `inventory`, so a keymap file naming a string can produce a boxed action, and a listener registered by TypeId can be matched against it.

**Nim での再現:** Nim has no trait objects and no TypeId-by-type usable across modules. Reproduce as `Action* = object; name*: string; payload*: JsonNode` plus a module-level `Table[string, proc(payload: JsonNode): Action]` registry populated by a `registerAction` call in each module's top-level statement (Nim runs module init before main, which is the `inventory` equivalent). Identity comparison becomes string comparison on `name`, not pointer/TypeId comparison. The `actions!` macro maps to a Nim `macro actions(namespace, names)` emitting one `const` name per action plus its registration. Nimculus today conflates action-with-payload and handler: `Command.action` is the closure itself, so the same action cannot be raised from two places with different data.

#### NoAction / Unbind disable markers — 無

Zed: `crates/gpui/src/action.rs:425-458, crates/gpui/src/keymap.rs:29 (disabled_binding_matches_context), :40 (binding_is_unbound), :195-225`  

`"ctrl-x": null` becomes a NoAction binding that, when it is the highest-precedence match, kills the keystroke entirely; `["zed::Unbind","editor::NewLine"]` kills only later bindings dispatching that named action. Both participate in the normal depth/order precedence, so a binding can be disabled in one context only.

**Nim での再現:** Straightforward once actions are named values: add `actionNone` / `actionUnbind(target: string)` cases to the action object and repeat the two predicates. `is_superset` on predicates (context.rs:328) is required for the context-scoped disable and is the one piece Nimculus has not ported — it is a pure structural recursion over the predicate ref-object tree, no Rust-specific mechanism involved.

#### KeyContext: the per-node context entry list — 一部

Zed: `crates/gpui/src/keymap/context.rs:10 (KeyContext), :14 (ContextEntry), :65 (parse), :117 (add), :126 (set), :137 (contains), :142 (get)`  
Nimculus: `src/nimnui/context.nim:9 (KeyContext), :4 (ContextEntry), :30/:33 (constructors), :41 (contains), :44 (value); attached to nodes at src/nimnui/ui_tree.nim:42 and set at :275`

Each dispatch node may carry a small ordered list of bare identifiers (`Editor`) and key=value pairs (`mode=full`). The stack of these along the focus path is what predicates are evaluated against.

**Nim での再現:** Already a faithful port of the data structure. Missing: `KeyContext.parse` for a whole string (Nimculus can only build entries programmatically, so `keyContext("Editor mode=full")` from a settings file is impossible), `extend`, `primary`/`secondary`, and `new_with_defaults` which injects `os=macos` — the last one matters because Zed keymaps in the wild use `os == macos` predicates. All are plain string/seq work in Nim; nothing blocks them.

#### Context predicate language and depth_of — 済

Zed: `crates/gpui/src/keymap/context.rs:172 (enum), :249 (parse), :350 (parse_expr, precedence table :494-498), :277 (eval_inner), :260 (depth_of), :328 (is_superset)`  
Nimculus: `src/nimnui/context.nim:16 (ref-object AST), :95 (parseExpression, same precedences 1/2/3/4/5), :156 (evalInner), :187 (depthOf), :194 (eval)`

A tiny boolean language over the context stack with `&&`, `||`, `!`, `==`, `!=` and a descendant operator `>`. `depth_of` returns the deepest prefix of the context stack at which the predicate holds — that number is the precedence key for binding resolution.

**Nim での再現:** Done, and done the right way: Zed's `Box<enum>` recursive AST became a Nim `ref object` with a `kind` discriminator, which is the natural translation. Two divergences to note: `depthOf` returns `-1` for both "nil predicate" and "no match" where Zed returns `Option<usize>` (a `tuple[matched: bool, depth: int]` or `Option[int]` would restore that), and `is_superset` is not ported, which blocks context-scoped unbinding.

#### KeyBinding: a keystroke *sequence* with prefix matching — 無

Zed: `crates/gpui/src/keymap/binding.rs:10 (struct), :48 (load, splits on whitespace), :89 (match_keystrokes returning Option<bool> where the bool means "pending")`  
Nimculus: `src/nimnui/commands.nim:11 (`Shortcut` = single keyCode + `set[Modifier]`), :147 (shortcutFromKeyBinding parses only `cmd+shift+p`)`

A binding holds `SmallVec<[KeybindingKeystroke; 2]>`, so `cmd-k left` is one binding. Matching returns three states: no match, exact match, or prefix match (pending) — this tri-state is what makes chords work.

**Nim での再現:** The blocker for chorded keymaps. In Nim: `Shortcut* = object; keystrokes*: seq[Keystroke]` and `proc matchKeystrokes(b: Shortcut, typed: openArray[Keystroke]): tuple[matched: bool, pending: bool]`. Nim has no Option ergonomics problem here — a two-field tuple is idiomatic. Also note Nimculus keys on macOS virtual keyCodes (commands.nim:94-145) rather than on a parsed key name, so a binding cannot be expressed layout-independently and `shortcutFromKeyBinding` uses `+` as separator where Zed uses `-` and whitespace to separate sequence elements.

#### Keymap precedence resolution (bindings_for_input) — 一部

Zed: `crates/gpui/src/keymap.rs:164-242, sort at :187, binding_enabled at :245`  
Nimculus: `src/nimnui/commands.nim:48 (resolve), :63 (tryResolve), :42 (matchingDepth)`

Scans all bindings in reverse load order, keeps those whose predicate matches (with their depth) and whose keystrokes match, then sorts by (depth desc, load index desc). Returns the full ordered candidate list plus a `pending` flag computed from prefix matches that are not shadowed by an already-matched binding.

**Nim での再現:** Nimculus implements the precedence rule correctly (deepest depth wins, later registration breaks ties, iterating `countdown(high,0)`) but returns exactly one `Command` rather than an ordered list, and has no pending flag. Returning `seq[Command]` is trivial in Nim; the list matters because Zed's dispatcher walks candidates and lets a handler decline (propagation continues) so the next candidate runs. Also: `matchingDepth` re-parses the predicate string on every keystroke (commands.nim:44) — Zed parses once at load into `Rc<KeyBindingContextPredicate>`; in Nim store the parsed `KeyBindingContextPredicate` ref in the Command.

#### Binding source metadata (user > vim > base > default) — 無

Zed: `crates/gpui/src/keymap/binding.rs:143 (KeyBindingMetaIndex), crates/gpui/src/keymap.rs:199 (NoAction only breaks for user-sourced bindings), keymap.rs:831 (test documenting User 0 > Vim 1 > Base 2 > Default 3)`  
Nimculus: `src/nimculus/main.nim:804 (applySettingsKeymap rebuilds the whole registry from defaults, then patches shortcuts by command name)`

An opaque u32 tag on each binding recording which keymap layer it came from, used to let a user keymap override a base keymap's disable marker.

**Nim での再現:** A plain `meta*: uint32` field on Command. Nimculus currently gets layering by rebuilding the default registry and mutating matching entries, which cannot express "user removed this binding" or two bindings for one command.

#### Reverse lookup: bindings_for_action, with shadow filtering — 無

Zed: `crates/gpui/src/keymap.rs:95 (bindings_for_action), crates/gpui/src/key_dispatch.rs:401 (bindings_for_action), :420 (highest_precedence_binding_for_action), :435 (binding_matches_predicate_and_not_shadowed)`  

Given an action and the live context stack, find the keystroke to *display* (menu items, tooltips, the picker footer). It re-runs bindings_for_input on the candidate's own keystrokes and only accepts it if it is the winner, so a shadowed binding is never shown.

**Nim での再現:** Needs the action identity and the ordered candidate list first. In Nim: `proc shortcutsForCommand(reg: CommandRegistry, name: string, contexts: openArray[KeyContext]): seq[Shortcut]` plus the same round-trip shadow check. This is the mechanism that makes menu/tooltip shortcut labels correct, so it is UI-visible, not internal.

#### The DispatchTree: per-frame node tree of contexts, focus ids and listeners — 一部

Zed: `crates/gpui/src/key_dispatch.rs:71 (DispatchTree), :83 (DispatchNode), :166 (push_node), :215 (set_key_context), :220 (set_focus_id), :226 (set_view_id), :323/:327/:333 (on_key_event / on_modifiers_changed / on_action)`  
Nimculus: `src/nimnui/ui_tree.nim:44 (UiTree), :19 (UiNode carries context, focusable, tabIndex, tabStop, bounds, a11y all on one object), :279 (contextStack); src/nimnui/events.nim:54 (ancestorPath)`

During paint, each element pushes a node; the node records its key context, focus handle, owning view and the closures registered on it. `focusable_node_ids` maps FocusId to node so the focused element can be located in O(1). The tree is rebuilt every frame and node ids are explicitly not stable across frames.

**Nim での再現:** Nimculus has the tree and the context stack but no per-node listener storage — handlers are passed in from outside as a `seq[tuple[node: NodeId, handler: EventHandler]]` at events.nim:77. In Nim the listener lists are just `keyListeners*: seq[EventHandler]` and `actionListeners*: seq[tuple[action: string, handler: ActionHandler]]` fields on UiNode; `Rc<dyn Fn>` maps directly to Nim's `{.closure.}` proc type, which is already used for `EventHandler` (events.nim:30) and `Command.action`. Also note `nodeIndex` (ui_tree.nim:60) is a linear scan called from every accessor — Zed's FxHashMap lookups become a `Table[NodeId, int]` in Nim.

#### dispatch_path / focus_path / focus_contains — 一部

Zed: `crates/gpui/src/key_dispatch.rs:563 (dispatch_path, root-to-focused), :574 (focus_path), :346 (focus_contains)`  
Nimculus: `src/nimnui/ui_tree.nim:279 (contextStack builds the path inline and only returns contexts), src/nimnui/events.nim:54 (ancestorPath, target-to-root)`

Walks parent links from the focused node up to the root and reverses, producing the ordered path that both the context stack and the capture/bubble walks are built from. focus_contains answers "is this handle an ancestor of the focused one", which drives focus-dependent styling.

**Nim での再現:** Both halves exist but are duplicated in two modules and neither returns a reusable path of nodes. Extract one `proc dispatchPath(tree: UiTree, target: NodeId): seq[NodeId]` in ui_tree.nim returning root-first, and derive contextStack and event dispatch from it. `focusContains` is a five-line parent walk. Note contextStack skips nodes with empty contexts (ui_tree.nim:292), matching Zed's filter_map at key_dispatch.rs:455.

#### Capture/bubble phases for key and action listeners — 一部

Zed: `crates/gpui/src/window.rs:88 (DispatchPhase), :4999 (dispatch_key_down_up_event: capture root-to-focus, bubble focus-to-root, stopping when propagate_event is false), :5130 (dispatch_action_on_node_inner: global listeners first, then window capture, then bubble where `cx.propagate_event = false` is set *before* each bubble listener so actions stop propagation by default)`  
Nimculus: `src/nimnui/events.nim:6 (EventPhase capture/target/bubble), :62 (dispatch — walks phases but invokes nothing), :76 (dispatchWithHandlers)`

Two-pass event routing with a single `propagate_event` flag on the App as the stop signal. The asymmetry matters: key listeners keep bubbling unless a handler explicitly stops, whereas an action handler consumes the action unless it explicitly calls propagate().

**Nim での再現:** Nimculus has the right walk order (capture root-to-target at events.nim:79, bubble target-to-root at :90) and a per-event `handled` flag standing in for `propagate_event`. Two gaps: there is an extra `target` phase Zed does not have, and there is no notion of an action listener that consumes by default. In Nim, `cx.propagate_event` (a field on a shared mutable App) is simply `event.handled` on the `var UiEvent` already threaded through — Rust's borrow discipline around `&mut App` has no Nim counterpart and none is needed. `events.nim:62 dispatch` is dead: it produces a phase list without calling handlers.

#### Multi-keystroke pending state and replay — 無

Zed: `crates/gpui/src/key_dispatch.rs:116 (Replay), :121 (DispatchResult with pending / pending_has_binding / bindings / to_replay), :483 (dispatch_key), :523 (flush_dispatch), :538 (replay_prefix); crates/gpui/src/window.rs:4868-4933 (pending buffer, focus invalidation, timeout)`  

When a keystroke is only a prefix, it is buffered on the window along with the focus it was typed against; if a later keystroke makes the sequence unmatchable, the longest matching prefix is replayed as if it had been dispatched alone and the remainder is re-dispatched. A timer flushes a pending prefix that is also a complete binding.

**Nim での再現:** Requires keystroke sequences first. The algorithm is pure value manipulation on seqs and ports directly; `dispatch_key` recursing on the suffix (key_dispatch.rs:515) is an ordinary recursive proc in Nim. The window-side timeout needs a timer on the main loop, which Nimculus has via its executor. This is the mechanism whose absence is user-visible: no `cmd-k` style prefixes are possible at all today.

#### Synthetic keystrokes from modifier-only presses — 一部

Zed: `crates/gpui/src/window.rs:4815-4844 (a ModifiersChangedEvent that drops from exactly one modifier to zero without an intervening keystroke becomes a `shift`/`control`/`alt`/`platform`/`function` keystroke), crates/gpui/src/key_dispatch.rs:327 (modifiers_changed_listeners), window.rs:5030 (bubble-only dispatch of them)`  
Nimculus: `src/nimnui/events.nim:10 (modifiersChanged kind), :44 (NSEventType 12 mapped to it), src/nimnui/commands.nim:31 (macOSModifiers)`

Lets a keymap bind a tap of a bare modifier, and gives elements a separate listener list for modifier state transitions (used for things like ctrl-hover affordances).

**Nim での再現:** The event reaches NimNUI but nothing consumes it: there is no pending-modifier tracker and no `saw_keystroke` flag. In Nim this is two fields on the window state (`pendingModifiers: set[Modifier]`, `sawKeystroke: bool`) and the same comparison. Note Zed dispatches modifier-changed listeners bubble-only, never capture.

#### FocusHandle / FocusId: refcounted, generation-safe focus identity — 一部

Zed: `crates/gpui/src/window.rs:267 (slotmap key FocusId), :383 (FocusHandle with tab_index and tab_stop), :404 (new, inserts into the FocusMap with a ref_count), :417 (for_id via atomic_incr_if_not_zero), :450 (downgrade to WeakFocusHandle), :457 (focus), :484 (dispatch_action from a handle)`  
Nimculus: `src/nimnui/ui_tree.nim:47 (`focused: NodeId` on the tree), :262 (focus), :12 (NodeHandle = id + generation), :180 (handle), :185 (isValid), :252 (isDisabledPath), :227 (setDisabled clears focus when the focused subtree is disabled)`

Focus is named by a process-wide slotmap key that outlives any one frame's dispatch tree, so focus survives re-renders. The handle carries the element's tab_index and tab_stop, and a weak variant exists so held references do not leak.

**Nim での再現:** Nimculus already has the two important properties: a stable id and a generation check that makes a stale handle detectable — that is the Nim answer to Rust's refcounted slotmap, and it is the right one, since Nim's GC makes the ref_count machinery unnecessary. Missing relative to Zed: no way to obtain a focus handle before the node exists in the tree (Zed's `cx.focus_handle()` mints one independent of any element), and `tabIndex`/`tabStop` live on the node (ui_tree.nim:31-32) rather than on the handle, so a caller cannot configure tab order without touching the tree.

#### Tab stop ordering by (group path, tab index, insertion order) — 済

Zed: `crates/gpui/src/tab_stop.rs:11 (TabStopMap), :36 (TabStopPath), :40 (TabStopNode), :52 (Ord: path then insertion index), :78 (insert appends the handle's tab_index to the current group path), :92/:98 (begin_group/end_group), :111 (next, wraps to first, skips non-tab_stop nodes), :148 (prev), :185 (replay)`  
Nimculus: `src/nimnui/commands.nim:162 (TabStopEntry), :169 (tabPath, walks the parent chain), :180 (compareTabPaths), :187 (tabStopOrder, sorts by path then insertion index), :198 (focusByTabOrder), :226/:228 (focusNext/focusPrev)`

Tab order is not document order: elements are sorted by the path of group indices they sit under plus their own tab_index, with declaration order breaking ties. Non-tab_stop focusables are in the order (so they can be reached programmatically) but are skipped by tab.

**Nim での再現:** Faithfully ported, and the simplification is correct for Nim: Zed's SumTree cursor exists to avoid re-sorting a large set incrementally; Nimculus sorts a `seq` with `algorithm.sort`, which is fine at UI element counts. The real divergence is where the group path comes from — Zed pushes explicit `begin_group(tab_index)` markers during paint, so a group's index is independent of the element hierarchy, whereas Nimculus derives the path from the UI parent chain (commands.nim:169). That means Nimculus cannot express a tab group that does not correspond to a tree node, and cannot reorder groups without reparenting. Nimculus additionally filters disabled subtrees (commands.nim:191, via ui_tree.nim:252), which Zed's TabStopMap does not do.

#### available_actions / is_action_available for the command palette — 無

Zed: `crates/gpui/src/key_dispatch.rs:363 (available_actions, walks the dispatch path collecting listener action types and building a default instance of each), :382 (is_action_available)`  
Nimculus: `src/nimculus/main.nim:681-802 (setupShortcutRegistry registers a flat global list; palette entries come from that list, not from what is focused)`

Answers "what can the user do right now" by looking at which action listeners exist along the focus path, which is what populates the command palette and greys out menu items.

**Nim での再現:** Depends on per-node action listeners existing at all. Once they do, this is a walk over the dispatch path collecting names into a sorted `seq[string]`. Zed's `build_action_type` step (needing the registry to construct a default instance from a TypeId) collapses in Nim to just carrying the name string.

#### Platform input event vocabulary — 一部

Zed: `crates/gpui/src/interactive.rs:735 (PlatformInput enum), :25/:47/:62 (KeyDown/KeyUp/ModifiersChanged), :139/:176/:485/:513 (mouse down/up/move/scroll), :281 (ClickEvent unifying mouse, keyboard and touch activation), :762/:780 (mouse_event/keyboard_event partition)`  
Nimculus: `src/nimnui/events.nim:7 (UiEventKind), :14 (UiEvent — one flat object with keyCode, button, modifiers, deltaX/Y, command all present regardless of kind), :32 (nativeEventKind maps NSEventType), :48 (nativeEventButton)`

One closed enum of everything the platform can deliver, with per-variant payload structs, plus a derived ClickEvent that lets a listener treat Enter-on-a-focused-button and a mouse click identically.

**Nim での再現:** Zed's enum-with-payload is exactly Nim's object variant (`case kind: UiEventKind of keyDown: keystroke: Keystroke ...`), so the flat struct is a choice, not a limitation — and the flat form is why `command: string` and `keyCode` coexist on every event. The one genuinely missing abstraction is ClickEvent: Nimculus has no unified activation event, so keyboard activation of a button (Enter/Space) and pointer activation are separate paths (see controls.nim:184 handleKey vs :197 handlePointerDown, which duplicate the activate-selected logic).

### 層としての所見

Where the layering diverges:

1. The keymap layer is split the wrong way. Nimculus has ported the *hard* half of Zed's keymap (the context predicate language, context.nim, essentially complete) and skipped the *structural* half (actions as values, keystroke sequences, ordered candidate lists, disable markers). The result is that context.nim can evaluate `Editor && mode == full > !Terminal` correctly while commands.nim can only ever resolve one single-keystroke binding to one closure. The predicate work is currently over-engineered relative to what the dispatcher can use.

2. `commands.nim` holds two mechanisms that Zed keeps in different files for good reason: the keymap (keymap.rs) and tab stops (tab_stop.rs). Tab order depends on focus and the element tree, not on commands — `tabStopOrder`/`focusNext`/`focusPrev` (commands.nim:162-228) reach into UiTree on every call and belong in ui_tree.nim next to `focus` and `isDisabledPath`. Nothing else in commands.nim imports ui_tree.

3. There is no DispatchNode/UiNode separation. Zed rebuilds a throwaway DispatchNode tree each frame (key_dispatch.rs:83, node ids explicitly unstable) carrying only context + focus + listeners, alongside a retained element state. Nimculus puts context, focusability, tab index, bounds, clip, paint-dirty flags and a11y strings on one retained UiNode (ui_tree.nim:19-42). That is a defensible choice — it makes `reuse_subtree`/`truncate` (key_dispatch.rs:264, :310) unnecessary — but it means there is nowhere to hang per-frame listeners, which is exactly why events.nim:76 has to take handlers as an external parameter.

4. The dispatch path is computed in two places with two orientations and neither is reusable: ui_tree.nim:279 (`contextStack`, walks and returns contexts) and events.nim:54 (`ancestorPath`, walks and returns nodes, target-first). Zed computes it once (key_dispatch.rs:563) and derives everything from it.

5. `events.nim:62 dispatch` walks the phases and returns a phase list without invoking any handler. It is scaffolding, not a dispatcher; only `dispatchWithHandlers` at :76 does anything.

6. Application-level keymap content lives in main.nim. `setupShortcutRegistry` (main.nim:681-802) hardcodes roughly thirty bindings as Nim code with raw macOS virtual key codes; `applySettingsKeymap` (main.nim:804) rebuilds that whole registry from scratch and then patches shortcuts by matching command name. Zed's equivalent is a JSON asset loaded through a keymap layer with source precedence (KeyBindingMetaIndex). Adding a user binding for a command that has no default, or removing one, cannot be expressed by the current patch-by-name loop.

7. Performance note that will bite the dispatch path: `matchingDepth` (commands.nim:44) re-parses the when-clause string on every keystroke for every candidate command, and `UiTree.nodeIndex` (ui_tree.nim:60) is a linear scan used by nearly every tree accessor including the parent walks in contextStack and tabPath. Zed parses predicates once into an Rc at load time and uses FxHashMap for focus/view lookups.

Not read, therefore unknown: Zed's Keystroke type and KeybindingKeystroke/PlatformKeyboardMapper (referenced from binding.rs:60 but defined elsewhere), the keymap JSON loader in the zed crate, the InteractiveElement builder methods (`on_action`, `track_focus`, `key_context`) that populate the dispatch tree, and Nimculus's ime.nim and platform/ layer.


## デザインシステム層

状態: **未着手**

### Zed のファイル

| ファイル | 行 | 役割 |
| --- | ---: | --- |
| `crates/ui/src/components/context_menu.rs` | 2510 | ContextMenuItem model (separator/header/label/entry/custom/submenu), entry rendering as ListItem + KeyBinding, submenu offset and documentation aside placement. |
| `crates/ui/src/components/scrollbar.rs` | 1575 | Scrollbar width table, ShowBehavior (Always/Autohide/Never), ScrollableHandle abstraction, ScrollbarLayout thumb/track math and click-to-offset conversion. |
| `crates/ui/src/components/toggle.rs` | 1100 | Checkbox and Switch, their ToggleStyle/SwitchColor variants, label position, and container_size(). |
| `crates/ui/src/components/button/button_like.rs` | 981 | The core button: ButtonStyle × elevation × interaction state -> concrete ButtonLikeStyles, ButtonSize height table, and the render that wires aria, focus, hover, active and roundin |
| `crates/ui/src/components/keybinding.rs` | 781 | KeyBinding element: resolves an action to keystrokes via the window, then renders per-keystroke Key/KeyIcon glyphs with platform-specific modifier styling. |
| `crates/ui/src/components/button/button.rs` | 648 | Labelled Button built on ButtonLike: start/end icon, key binding slot, label colour per toggle state. |
| `crates/ui/src/components/list/list_item.rs` | 576 | ListItem: start/end slots, end-slot-on-hover swap, indent level x step size, inset vs non-inset border/hover placement. |
| `crates/ui/src/components/popover_menu.rs` | 508 | PopoverMenu: trigger element, anchor/attach corners, offset, and the handle that lets outside code show/hide/toggle. |
| `crates/ui/src/components/button/icon_button.rs` | 449 | Square/rounded icon-only button; IconButtonShape and the selected-icon/selected-colour pair. |
| `crates/ui/src/components/label/label_like.rs` | 352 | LabelSize/LineHeightStyle/LabelCommon and the render that applies size, weight, truncation mode, underline, strikethrough. |
| `crates/ui/src/components/icon.rs` | 341 | IconSource (embedded svg / external image / raw svg), IconSize table, and square_components() which is how icons get consistent hit boxes. |
| `crates/ui/src/styles/typography.rs` | 292 | `StyledTypography` extension trait, `TextSize` scale (10/12/14/16px) and `Headline`/`HeadlineSize`. |

### Nimculus の対応物

| ファイル | 行 | 何を担っているか |
| --- | ---: | --- |
| `/Users/yoshinori/work/nimculus/src/nimnui/platform/macos/macos_platform.m` | 17976 | Where the real component library lives, as AppKit classes used directly: NimculusChromeButton (:950) is the only reusable styled control; everything else is per |
| `/Users/yoshinori/work/nimculus/src/nimculus/settings.nim` | 921 | The theme token table (ThemeColors, :31, ~48 fields) and the built-in dark/light palettes (:523-578). This is Zed's theme crate's job, not the ui crate's — but  |
| `/Users/yoshinori/work/nimculus/src/nimnui/ui_tree.nim` | 293 | Interaction-state substrate: independent hovered/active/focused/disabled flags with Zed-matching precedence (:88-98), generational node handles (:12, :185), foc |
| `/Users/yoshinori/work/nimculus/src/nimnui/controls.nim` | 263 | The only file resembling a component layer. Covers menu/popup/tooltip geometry and keyboard interaction (OverlayModel), scroll offset clamping (ScrollModel), sp |
| `/Users/yoshinori/work/nimculus/src/nimnui/render.nim` | 170 | Paint command vocabulary. Has semantic kinds (workspacePanel, scrollbarTrack, editorActiveLine) which is a theme-aware move, but no shadow blur/alpha, no stroke |

### メカニズム

#### Semantic colour token enum — 一部

Zed: `crates/ui/src/styles/color.rs:19 (enum), :90 (Color::color)`  
Nimculus: `src/nimculus/settings.nim:31 (ThemeColors, ~48 string fields); src/nimnui/platform/macos/macos_platform.m:942 (themeRoleColor), :908 (themeTokenFallback), :842 (themeHexColor)`

A closed enum of ~24 meanings (Default, Muted, Accent, Error, Created, VersionControlModified, Player(u32), Custom(Hsla)) with exactly one match arm each mapping to cx.theme().colors().X or cx.theme().status().X. Components never name a theme field directly; they name a meaning.

**Nim での再現:** Direct: a Nim `enum` plus a `proc color(c: UiColor, theme: ThemeColors): Rgba` with a `case` — this is the one Zed mechanism that maps to Nim with no loss. What Nimculus has today is the *theme table* (ThemeColors) but not the *semantic indirection*: call sites pass string keys (`themeRoleColor(@"fgPrimary", ...)`) so typos fall back silently, and each call site repeats its own fallback colour. The fallback tables at macos_platform.m:908 duplicate the light/dark palettes that already exist in settings.nim:525/551 — two sources of truth for the same tokens.

#### Style × state -> concrete style resolution — 無

Zed: `crates/ui/src/components/button/button_like.rs:125 (ButtonStyle), :190 (ButtonLikeStyles), :210 enabled(), :257 hovered(), plus active()/disabled() through :448`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:957 (updateChromeButtonAppearance), :1005 (styleWorkspaceNavigationButton), :1053, :1059`

Four pure functions (enabled/hovered/active/disabled) take (ButtonStyle, Option<ElevationIndex>) and return a ButtonLikeStyles {background, border_color, label_color, icon_color}. Every visual difference between Filled/Tinted/Outlined/OutlinedGhost/Subtle/Transparent lives in these tables and nowhere else.

**Nim での再現:** A Nim `enum ButtonStyle` (with the Tinted/OutlinedCustom payloads as an object variant, since Nim variants carry fields fine) and `proc styles(s: ButtonStyle, state: UiState, elevation: ElevationIndex, theme: ThemeColors): ButtonLikeStyles`. Pure data in, pure data out, trivially unit-testable. Nimculus instead computes appearance inline per widget family: updateChromeButtonAppearance hardcodes `accent @ 0.22 alpha` for active and `elementHover @ 0.10` for hover (macos_platform.m:963-975), and styleSidebarIconButton just forwards to it. There is no shared table, so a second button family means a second hand-written appearance proc.

#### Size scale as a pure table — 一部

Zed: `crates/ui/src/components/button/button_like.rs:455 (ButtonSize), :465 (rems); crates/ui/src/components/icon.rs:54 (IconSize), :70 (rems), :86 (square_components); crates/ui/src/styles/typography.rs:93 (TextSize), :132 (rems/pixels); crates/ui/src/components/label/label_like.rs:7 (LabelSize)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:438-473 (NimculusSpace1/2/3=4/8/12, NimculusRowHeight=28, NimculusControlHit=24, NimculusIconPointSize=14, NimculusToolbarIconPointSize=11, NimculusDefaultRemSize=16), :675 (NimculusUiTextSizePixels=14)`

Four parallel enums each with one match arm per variant returning a Rems value: ButtonSize 32/28/22/18/16px, IconSize 10/12/14/16/48px, TextSize 16/14/12/10px, LabelSize mapping onto TextSize. IconSize::square_components additionally pairs each size with a DynamicSpacing padding so an icon's hit box is derived, not guessed.

**Nim での再現:** `enum` + `proc rems(s: ButtonSize): float32` is exact. Nimculus has the *values* as flat CGFloat constants in the ObjC file rather than as named scales, so there is no way to ask "give me the medium button height" — you pick a constant by eye. Two icon sizes already diverged (14 vs 11) with no enum saying which is Small and which is XSmall. Moving these constants into a Nim module and exporting them to ObjC via a generated header would make the scale one source of truth.

#### Density-aware spacing scale — 無

Zed: `crates/ui/src/styles/spacing.rs:29-44 (derive_dynamic_spacing! table), :52 (ui_density)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:438-441 (three fixed constants, no density dimension)`

14 spacing steps, each a (compact, default, comfortable) pixel triple — e.g. Base04 = (2,4,6), Base06 = (3,6,8). A macro turns them into DynamicSpacing::BaseNN with .rems(cx)/.px(cx) accessors that read the user's ui_density setting. Every gap/padding in the crate goes through it (button gap Base04 at button_like.rs:797, ListItem px Base06 at list_item.rs:357).

**Nim での再現:** Nim needs no macro here: a `const spacingTable: array[SpacingStep, array[Density, float32]]` plus `proc px(step: SpacingStep, d: Density): float32` covers it, and a compile-time `const` array is checked as thoroughly as Zed's derive. Nimculus has no density setting at all, so this would be additive; the harder part is that spacing is currently applied by absolute NSView frame arithmetic in ObjC, so there is no single choke point to route through.

#### Elevation -> shadow stack and background — 一部

Zed: `crates/ui/src/styles/elevation.rs:14 (ElevationIndex), :42 (shadow), :84 (bg), :95 (on_elevation_bg), :108 (darker_bg); crates/ui/src/traits/styled_ext.rs:6 (elevated), :45 elevation_1, :62 elevation_2, :83 elevation_3`  
Nimculus: `src/nimnui/controls.nim:222-225 (paintOverlay: single hardcoded shadow offset (2,3), radius 6, one border); src/nimculus/settings.nim:36-38 (surface/elevated/panel tokens exist)`

Five z-layers. shadow() returns a Vec<BoxShadow> that differs per layer AND per light/dark appearance (ModalSurface is four stacked shadows, ElevatedSurface two, Surface none). elevation_N() applies bg + rounded_lg + border_1 + border_variant + that shadow in one call, so every popover/modal/tooltip in Zed shares identical chrome.

**Nim での再現:** An `enum ElevationIndex` plus `proc shadows(e: ElevationIndex, light: bool): seq[BoxShadow]` and a `proc applyElevation(paint: var PaintList, r: Rect, e: ElevationIndex, theme: ThemeColors)`. Nimculus's paintOverlay emits exactly one drawShadow with a fixed offset and no blur radius or per-appearance alpha, so a Nimculus popup and a Nimculus modal are visually identical where Zed's differ; and the PaintKind set (src/nimnui/render.nim:4-12) has a single `shadow` command with no blur/alpha payload, so the multi-shadow stack cannot be expressed until PaintCommand grows blurRadius and colour fields.

#### Builder traits shared across components — 無

Zed: `crates/ui/src/traits/clickable.rs:4, disableable.rs:2, toggleable.rs:5, fixed.rs, visible_on_hover.rs; crates/ui/src/components/button/button_like.rs:12 (SelectableButton), :17 (ButtonCommon)`  
Nimculus: `none found`

Small traits (on_click, disabled, toggle_state, width/full_width, visible_on_hover, style/size/tooltip/layer) that Button, IconButton, ToggleButton, ListItem and popover triggers all implement, so `impl PopoverTrigger: IntoElement + Clickable + Toggleable` (popover_menu.rs:12) accepts any of them interchangeably.

**Nim での再現:** Nim has no traits, but it has two workable substitutes. (a) `concept` — `Clickable = concept c; c.onClick(proc(...))` — checked structurally at instantiation; this is the closest analogue and needs no runtime cost, but concepts are still experimental and error messages are poor. (b) Plain generic procs with `mixin`: `proc onClick*[T](x: var T, h: ClickHandler)` resolved by overload — simple, and what I would recommend. The consuming side (popover_menu.rs:12's trait-bound trigger) becomes a generic proc or, where the trigger must be stored heterogeneously, an object variant `Trigger = object case kind: TriggerKind`. Rust's builder-by-value chaining (`fn on_click(mut self, ...) -> Self`) maps to Nim `proc onClick(b: sink Button): Button` and chains fine.

#### Component-instance identity and state — 一部

Zed: `crates/ui/src/components/button/button_like.rs:484 (ElementId), :512 (focus_handle), :745 render; crates/ui/src/components/context_menu.rs:211 (ContextMenu as an Entity with focus_handle, selected_index, subscriptions)`  
Nimculus: `src/nimnui/ui_tree.nim:6 (NodeId), :12 (NodeHandle with generation), :16 (UiState normal/focused/hovered/active/disabled), :34 (independent focusedState/hoveredState/activeState/disabledState flags), :88 (updateVisualState precedence)`

Stateless components (RenderOnce) are rebuilt every frame and carry only an ElementId; GPUI keys hover/active/focus state to that id across frames. Stateful ones (ContextMenu) are Entities with a Context<T>, a FocusHandle, and Subscriptions that unregister on drop.

**Nim での再現:** Nimculus already solved the identity half better than a naive port would: NodeId + generation (ui_tree.nim:12, :185 isValid) is a generational handle, i.e. exactly what Rust's Entity/WeakEntity gives you, expressed without a borrow checker. The state precedence at ui_tree.nim:91-95 (disabled > active > focused > hovered) is a real reimplementation of what GPUI does through style refinements. What is missing is the *component* layer above it: nothing maps a UiNode's UiState to a ButtonLikeStyles. Rust's Context<T>/borrow discipline has no Nim equivalent and does not need one — Nim's single-threaded UI loop with `var` params over an `UiTree` seq is sufficient; the discipline Zed buys (no re-entrant entity update) has to become a convention or a runtime `inUpdate` flag.

#### Label rendering: size, weight, truncation mode — 一部

Zed: `crates/ui/src/components/label/label_like.rs:7 (LabelSize), :23 (LineHeightStyle), :34 (LabelCommon), :233 (render)`  
Nimculus: `src/nimnui/text.nim (467 lines, not read in detail); src/nimnui/platform/macos/macos_platform.m:4676-4682 (NSLineBreakByTruncatingTail paragraph style), :4757-4767 (manual width arithmetic to reserve room for a shortcut before truncating the title)`

One render applies: size -> text_ui{,_lg,_sm,_xs}; UiLabel line-height forces relative(1.0); and three mutually distinct truncation modes (end / start / middle ellipsis) each expanded to min_w_0 + overflow_x_hidden + whitespace_nowrap + the matching text_ellipsis variant. Font weight defaults to the theme's ui_font weight when unset.

**Nim での再現:** Straightforward as a `LabelSpec` object + `proc layoutLabel(spec, availableWidth): TextLayout`. Nimculus does have truncation, but only tail truncation via AppKit's NSLineBreakByTruncatingTail, and the width budget is computed by hand at each call site (macos_platform.m:4759 subtracts 32.0 + shortcutWidth + 16.0 literals). Middle truncation — which Zed uses specifically for filenames (label_like.rs:141) — I found no evidence of in Nimculus; mark that sub-behaviour absent.

#### Icon source abstraction and square hit box — 無

Zed: `crates/ui/src/components/icon.rs:117 (IconSource), :131 (Icon), :86 (square_components), :102 (square)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:1038 (applySidebarIconConfiguration — NSImageSymbolConfiguration at NimculusIconPointSize), :461 (NimculusControlHit = 24.0, a single global hit size)`

An icon is one of embedded-SVG-path / external raster (for icon themes) / raw SVG string; the renderer picks svg() or img() from that. square_components pairs the glyph size with a DynamicSpacing padding so the clickable square is derived from the size enum rather than set per call site.

**Nim での再現:** `IconSource = object case kind: IconSourceKind` is a direct object-variant port. But Nimculus's icons are SF Symbols configured through NSImageSymbolConfiguration, not SVG assets — so Zed's icon *theme* mechanism (external raster per icon theme, icon.rs:120-125) has no path forward as-is; it would require shipping an SVG rasteriser or an asset pipeline. The hit-box derivation is portable and worth doing: today NimculusControlHit is one constant for all sizes, so a 11pt toolbar icon and a 14pt sidebar icon get the same 24pt target.

#### ListItem slot layout — 無

Zed: `crates/ui/src/components/list/list_item.rs:10 (ListItemSpacing), :26 (struct), :292 (render), :404 (disclosure at left:-1rem), :434 (EndSlotVisibility Always/OnHover/SwapOnHover)`  
Nimculus: `src/nimnui/controls.nim:141 (rowBounds — uniform-height rows only, no slots, no indent); src/nimnui/platform/macos/macos_platform.m:4757 (picker row drawn by hand: title rect, then a right-aligned shortcut rect)`

A row = optional disclosure toggle positioned absolutely at -1rem, a start slot, children, and an end slot whose visibility has three modes including SwapOnHover (hover slot painted normally, the resting slot absolutely overlaid and hidden via group_hover). Indent is indent_level × indent_step_size, applied on the *outer* element when inset and the *inner* one otherwise (list_item.rs:301 vs :401) — that is what makes inset rows draw their hover background inside the indent.

**Nim での再現:** Portable as a `ListItemSpec` object with `startSlot, endSlot: Option[Element]` plus a layout proc; Nim's Option and object fields cover Rust's Option<AnyElement> directly. The subtlety that must be ported deliberately is the inset/non-inset indent placement — it is a two-line difference in Zed that changes where the selection highlight starts, and it is exactly the kind of thing a pixel-parity test catches. Nimculus's rowBounds assumes every row is itemHeight tall with no slots, so tree rows, disclosure arrows and end-slot actions are all currently drawn ad hoc in ObjC.

#### Menu item model separated from menu rendering — 一部

Zed: `crates/ui/src/components/context_menu.rs:46 (ContextMenuItem enum), :82 (ContextMenuEntry), :211 (ContextMenu state), :1449 (render_menu_item), :2180 (render, submenu offset + aside)`  
Nimculus: `src/nimnui/controls.nim:27 (OverlayItem: label, command, enabled, separator), :85 (showOverlay), :122 showContextMenu, :141 rowBounds, :147 itemAt, :160 moveSelection, :184 handleKey, :217 paintOverlay`

Items are data (Separator | Header | HeaderWithLink | Label | Entry | CustomEntry{render,handler} | Submenu{builder}); render_menu_item turns each into a ListItem/ListSeparator/ListSubHeader. Entries carry an optional Action, from which the KeyBinding element resolves and renders the shortcut (context_menu.rs:1838). Submenus compute their vertical offset from trigger bounds minus menu bounds (:2199) and can flip left.

**Nim での再現:** Nimculus's OverlayModel is a genuine partial port and the geometry half is arguably cleaner than Zed's: clampOverlayBounds (controls.nim:70) plus the below/above flip at :105-115 is the anchored-popup contract as a pure function, and keyboard selection with separator skipping (:160) is done. What is missing is the item *variety* — OverlayItem is a flat record with a bool `separator`, so headers, submenus, custom rows, checkmark/toggle entries and end slots cannot be expressed. Port as `OverlayItem = object case kind: OverlayItemKind` (object variant is the exact analogue of the Rust enum); the `CustomEntry{render: Box<dyn Fn>}` arm becomes a `proc` field in the variant, and `Submenu{builder}` becomes a closure returning a child OverlayModel. Note the menus the user actually sees are NSMenu (macos_platform.m:6919, :8510, :11145), not this model.

#### Scrollbar geometry and visibility policy — 一部

Zed: `crates/ui/src/components/scrollbar.rs:352 (ScrollbarStyle), :358 to_pixels (Regular 6px / Editor 15px), :275 (ShowBehavior::Always/Autohide/Never from setting), :993 (ScrollableHandle trait), :1013 (ScrollbarLayout), :1023 compute_click_offset`  
Nimculus: `src/nimnui/controls.nim:17 (ScrollModel: offset/contentSize/viewportSize), :50 (scrollBy with clamp to max(0, content-viewport)); src/nimnui/render.nim:154 drawScrollbar, :166 drawScrollbarTrack (the track-border role is already split out per the comment at render.nim:10-12)`

Width is a two-value table. ShowBehavior::from_setting folds the user setting plus the OS auto-hide global into three behaviours. ScrollableHandle abstracts three different scroll sources (ScrollHandle, UniformListScrollHandle, ListState) behind max_offset/set_offset/offset/viewport. compute_click_offset converts a track click or thumb drag into a scroll offset: clamp(pos - track_origin - thumb_offset, 0, viewport-thumb) / (viewport - thumb) × -max_offset — with the divide-by-zero guard when the thumb fills the track.

**Nim での再現:** compute_click_offset is a pure formula and ports verbatim to a Nim proc — this is the single highest-value thing to copy exactly, because thumb-drag feel is where hand-rolled scrollbars diverge. ScrollableHandle is the one place a Nim `concept` genuinely earns its keep, or failing that a small proc-table `object ScrollableHandle = object maxOffset: proc(): Point; setOffset: proc(p: Point) ...` — a vtable by hand, which is what Nim idiom prefers over concepts today. Nimculus has the scroll *model* (offset clamping) but not the thumb geometry, the drag-offset conversion, or the Always/Autohide/Never policy; and it has one width, not the Regular/Editor split.

#### Keybinding display — 無

Zed: `crates/ui/src/components/keybinding.rs:46 (KeyBinding), :63 for_action, :200 render, :252 render_keybinding_keystroke, :411 (Key), :457 (KeyIcon)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:4685 (commandShortcut — a static NSDictionary literal mapping ~24 command names to pre-composed strings like @"⌘⇧P"), :4757 (the row draws that string right-aligned)`

A KeyBinding element takes an *Action* (not a string), asks the window for the highest-precedence binding for that action in the current focus context, then renders each keystroke. On macOS it emits modifier glyphs plus a key; on Linux/Windows/vim-mode it emits text. Certain keys become icons (arrows, backspace) rather than glyphs. Single-character keys get a fixed square width so shortcuts align in a column (keybinding.rs:428).

**Nim での再現:** Portable as `proc renderKeystroke(k: Keystroke, style: PlatformStyle): seq[KeyGlyph]`. The important structural point: Nimculus's shortcut strings are a hardcoded literal table keyed by command *display name*, so they are decoupled from whatever actually dispatches the keystroke — nothing keeps them in sync, and a rebound key silently shows the old glyph. Zed's direction is the opposite: the display derives from the keymap. Nimculus already has a key/command layer (src/nimnui/commands.nim, 228 lines) and a context stack (ui_tree.nim:279 contextStack, root-to-focused ordering already matching Zed's Descendant semantics), so the resolution path exists — the display just does not use it.

#### Tri-state toggle — 無

Zed: `crates/ui/src/traits/toggleable.rs:12 (ToggleState), :26 inverse, :34 from_any_and_all; crates/ui/src/components/toggle.rs:43 (Checkbox), :181 container_size, :338 (Switch), :328 (SwitchLabelPosition)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:4448 (gitCheckboxes: NSMutableArray<NSButton*> — plain AppKit checkboxes, which do support NSControlStateValueMixed but I found no code setting it)`

ToggleState is three-valued, and from_any_and_all(any, all) derives Indeterminate for partial selections — that is what makes 'stage all' checkboxes correct. Checkbox and Switch both take it; Switch adds colour variants and label position.

**Nim での再現:** `enum ToggleState = tsUnselected, tsIndeterminate, tsSelected` plus the two helper procs; trivial and worth having as shared logic even while the widget stays NSButton, since from_any_and_all is the bit that gets written wrong by hand. Marked absent rather than partial because I found no tri-state derivation in Nimculus; the AppKit checkbox array at :4448 is a bare control list.

#### Divider — 一部

Zed: `crates/ui/src/components/divider.rs:19 (DividerColor), :37 (struct), :96 render_solid, :100 render_dashed`  
Nimculus: `src/nimnui/render.nim:160 (drawWorkspaceSeparator — a semantic paint kind), :104 drawBorder; src/nimnui/platform/macos/macos_platform.m:444 (NimculusChromeBorderHeight = 1.0)`

Solid dividers are a 1px background fill; dashed dividers are drawn through a canvas with PathBuilder::stroke(1px).dash_array([4,2]) offset by 0.5px to land on the pixel grid. Three colour tokens: border, border at 0.6 alpha, border_variant.

**Nim での再現:** Solid is already effectively there via the workspaceSeparator paint kind. Dashed is not expressible: PaintKind (render.nim:4-12) has no stroked-path command and no dash array, so it needs either a new PaintKind with a dash payload or per-segment rectangles. The 0.5px pixel-grid offset must be ported deliberately — on Retina it is the difference between a crisp line and a 2px grey smear, and it is the kind of detail a parity measurement will flag.

#### Tooltip container as shared chrome — 一部

Zed: `crates/ui/src/components/tooltip.rs:216 (tooltip_container), :194 (Tooltip::render), :9 (struct: title, meta, key_binding)`  
Nimculus: `src/nimnui/controls.nim:132 (showTooltip), :226-229 (paintOverlay tooltip branch: 4/8/4/8 insets, radius 6, one shadow); src/nimnui/platform/macos/macos_platform.m:4161, :4241 (NSView.toolTip — the system tooltip, not a custom one)`

tooltip_container is a free function every tooltip in Zed routes through: pl_2 + pt_2p5 outer offset (deliberately so the tooltip does not sit under the cursor), then elevation_2 + ui font + text_ui + py_1 px_2. Tooltip itself is title (max_w_72) + optional right-aligned KeyBinding + optional muted meta line.

**Nim での再現:** A `proc tooltipChrome(paint: var PaintList, r: Rect, theme)` is the direct analogue and Nimculus is close to it already. Two concrete gaps: no cursor-avoidance offset (Zed's pl_2/pt_2p5 at tooltip.rs:224 — Nimculus anchors flush, controls.nim:75-78), and no meta/keybinding rows (OverlayModel carries a single contentText, controls.nim:44). Also note the branch button at macos_platform.m:4161 uses the *AppKit* tooltip, so two tooltip systems coexist with different delay, styling and placement.

### 層としての所見

LAYERING DIVERGENCE — this is the sharpest one of any layer.\n\nZed has a genuine three-tier split: gpui (element/style primitives) -> ui (this crate: semantic tokens + reusable components) -> feature crates (workspace, editor, project) that only compose. The ui crate is 28k lines and imports no feature crate; every component takes colour and size from an enum, never from a literal.\n\nNimculus has that middle tier essentially missing. The split it does have is nimnui (geometry, ui_tree, layout, render, controls — ~1800 lines total) versus macos_platform.m (17976 lines). The middle tier's *behaviour* is in the ObjC file, mixed with feature code: NimculusCommandPaletteOverlay, NimculusGitCommitField, NimculusDocumentSearchOverlay and ~15 other overlay classes each declare their own NSButton/NSTextField properties and style them by calling helpers that hardcode alphas and offsets. So macos_platform.m is playing the same role main.nim plays for application logic — it is the second 'everything' file, and it is nearly twice main.nim's size.\n\nWHAT BELONGS WHERE, concretely:\n- A new src/nimnui/theme.nim: the Color enum and its resolution against ThemeColors. This kills the string-keyed themeRoleColor lookups (macos_platform.m:942) and, more importantly, the duplicate light/dark fallback palettes at macos_platform.m:908-936 that shadow settings.nim:525/551.\n- A new src/nimnui/styles.nim: ButtonSize/IconSize/TextSize/LabelSize tables and the spacing scale, replacing the flat constants at macos_platform.m:438-473. These are pure data; they can be exported to ObjC through a generated header so the two sides cannot drift.\n- Grow src/nimnui/controls.nim into the component layer: ButtonStyle->ButtonLikeStyles resolution, ListItem slot layout, the tri-state ToggleState, and the scrollbar thumb/click math from scrollbar.rs:1023. All of these are pure functions over data — testable in a headless test with no window, which matters given the project's rule that unmeasured means undone.\n- macos_platform.m keeps only what AppKit genuinely owns: NSView hierarchy, tracking areas, IME, NSMenu, accessibility. Appearance decisions move out.\n\nWHAT NIMCULUS ALREADY DID BETTER, and should not be regressed by a port: the generational NodeHandle (ui_tree.nim:12, :185) is Entity/WeakEntity without a borrow checker; the interaction-state precedence at ui_tree.nim:88-98 is a real reimplementation of GPUI's state cascade; contextStack (ui_tree.nim:279) already emits root-to-focused order to match Zed's Descendant predicates; and clampOverlayBounds + the below/above flip (controls.nim:70-115) is the anchored-popup contract expressed as a pure function, which Zed spreads across popover_menu.rs and context_menu.rs.\n\nUNKNOWNS I did not verify: src/nimnui/text.nim (467 lines) — I did not read it, so label text shaping, ellipsis modes and font-weight handling are unknown beyond the AppKit truncation I saw. I did not read main.nim, so I cannot rule out component-like helpers there. I did not read Zed's ui_macros crate, so the exact compact/default/comfortable formula behind the single-value DynamicSpacing entries (spacing.rs:40-43: 24, 32, 40, 48) is unknown — the comment says (n-4, n, n+4) but I did not confirm it in the macro.


## ワークスペース層

状態: **一部のみ**

### Zed のファイル

| ファイル | 行 | 役割 |
| --- | ---: | --- |
| `crates/workspace/src/workspace.rs` | 17052 | Owns the Workspace entity: the center PaneGroup, the three Docks, status bar, modal/toast layers, titlebar slot, follower state, and the top-level render that stacks titlebar / doc |
| `crates/workspace/src/pane.rs` | 9455 | The Pane: an ordered list of Box<dyn ItemHandle>, active index, activation history, pinned prefix, preview item, nav history, zoom flag, toolbar, and the tab-bar/tab rendering and  |
| `crates/workspace/src/persistence.rs` | 5954 | SQLite-backed workspace database; the row shapes live in persistence/model.rs (SerializedWorkspace, DockStructure/DockData, SerializedPaneGroup/Pane/Item) and their deserialize-int |
| `crates/workspace/src/item.rs` | 1869 | The Item trait (tab content, tab icon, tooltip, dirty/conflict, save, breadcrumbs) plus its object-safe ItemHandle, SerializableItem, ProjectItem and FollowableItem, and ItemSettin |
| `crates/workspace/src/pane_group.rs` | 1608 | The recursive split tree: Member = Axis(PaneAxis) | Pane, PaneAxis with per-child flexes and cached bounding boxes, split/remove/resize/swap, SplitDirection, and the handle hitbox  |
| `crates/workspace/src/dock.rs` | 1558 | The Panel trait and its object-safe PanelHandle, the Dock container (one per edge) with panel entries, per-panel size state, open/active/zoom bits, resize handle rendering, and Pan |

### Nimculus の対応物

| ファイル | 行 | 何を担っているか |
| --- | ---: | --- |
| `/Users/yoshinori/work/nimculus/src/nimnui/platform/macos/macos_platform.m` | 17976 | NimculusTabBarOverlay at line 4460 — the actual tab strip, with tab rects, hit testing, drag-reorder, back/forward/new/split/zoom buttons. This is render_tab_ba |
| `/Users/yoshinori/work/nimculus/src/nimculus/main.nim` | 9845 | The wiring: workspace layout application (main.nim:400-580), breadcrumb construction (main.nim:1283-1400), tab-bar sync to the native strip (main.nim:5326-5340) |
| `/Users/yoshinori/work/nimculus/src/nimculus/workspace.nim` | 853 | Despite the name this is NOT Zed's workspace crate — it is the project/worktree layer: roots, ignore rules, directory listing, file CRUD, fuzzy and content sear |
| `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim` | 841 | Dock state and toggling, panel-to-dock ownership and settings reconciliation, dock resize logic, workspace root layout and hit testing, the pane split tree and  |
| `/Users/yoshinori/work/nimculus/src/nimculus/editor_app.nim` | 553 | EditorSession and EditorTab: the item list, active index, pinned prefix, closed-tab stack, tab move/switch, per-tab view state. This is the item-ownership half  |
| `/Users/yoshinori/work/nimculus/src/nimculus/session.nim` | 322 | JSON persistence of the session: dock open/size/panel triples, the flat split scalars, and the tab list with per-tab view state and dirty-content recovery. Coun |
| `/Users/yoshinori/work/nimculus/src/nimculus/status_bar.nim` | 84 | Status-bar footer item composition. Partial counterpart to StatusItemView; the dock PanelButtons equivalent is the packed mask in workspace_ui.nim consumed by A |

### メカニズム

#### Panel trait (what a dock can contain) — 一部

Zed: `crates/workspace/src/dock.rs:36`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim:16 (PanelKind enum), :364 panelPositionIsValid, :330 panelDockSettingKey, :350 panelDockSide`

Defines everything a dock needs from its content without knowing the concrete type: persistent_name/panel_key (persistence identity), position + position_is_valid + set_position (which edges it may live on), default_size/min_size/initial_size_state, icon/icon_tooltip/icon_label/toggle_action (its status-bar button), starts_open, is_zoomed/set_zoomed, set_active, pane() (a panel may itself host a Pane), activation_priority, enabled.

**Nim での再現:** Nimculus has already collapsed the trait into a closed enum `PanelKind` plus case-of procs. That is the right Nim shape while the panel set is fixed and compiled in: `case panel of panelFiles: ...` gives exhaustiveness checking that Zed's dyn dispatch does not. What is missing is the per-panel data the trait also carries (default_size, min_size, icon, starts_open, activation_priority, is_zoomed) — add a `const PanelInfo: array[PanelKind, PanelDescriptor]` table with those fields so panel identity, size defaults and icons stop being scattered. If extensions ever contribute panels, promote to `PanelVTable = object` of proc fields (a proc table, not a Nim `concept` — concepts are compile-time and cannot hold a heterogeneous runtime list).

#### PanelHandle (object-safe erasure of Panel) — 無

Zed: `crates/workspace/src/dock.rs:98`  

A separate object-safe trait, blanket-implemented for every Entity<T: Panel> (dock.rs:148 onward), so the Dock can store Arc<dyn PanelHandle> and call position/size/icon/focus without generics. Also carries to_any() for downcasting back to the concrete panel (dock.rs:484 Dock::panel<T>).

**Nim での再現:** Not needed as long as panels are an enum: the enum ordinal IS the erasure. If panels become dynamic, the Nim equivalent is a `ref object` base with a method table (`PanelHandle = ref object of RootObj` + `method position(p: PanelHandle): DockSide {.base.}`), or an object holding proc pointers. Nim's `RootRef` + `of` downcast replaces `to_any().downcast()`. There is no borrow-checker cost to reproduce.

#### Dock container: open bit, active panel index, per-panel size state — 一部

Zed: `crates/workspace/src/dock.rs:269`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim:51 DockState, :308 dock(), :319 toggleDock, :384 openPanel, :398 togglePanel`

One Dock per edge holds Vec<PanelEntry> (dock.rs:350; each entry = panel + PanelSizeState + subscriptions), is_open, active_panel_index. visible_entry() (dock.rs:843) returns the active entry only when open — that single function is what makes the dock render nothing when closed while keeping the focus handle mounted. Size is per-panel, not per-dock (dock.rs:886 stored_panel_size, :904 set_panel_size_state), so switching panels in a dock changes its width.

**Nim での再現:** DockState already has side/isOpen/activePanel/size/minimumSize. The divergence is that size lives on the dock, not on the panel: `size*: float32` at workspace_ui.nim:55 is shared by every panel on that edge, so switching Files->Git on the right dock keeps the wrong width. Fix in Nim by replacing `size` with `sizes*: array[PanelKind, float32]` (or a `panelSizes` field on WorkspaceUiState keyed by PanelKind), and by making `dock()` return the active panel's stored size. There is also no `panel_entries` ordering — Nimculus derives dock membership by scanning PanelKind (workspace_ui.nim:227 replacementPanel), which loses user-visible panel order; a `seq[PanelKind]` per dock would restore it.

#### DockPosition and its axis — 済

Zed: `crates/workspace/src/dock.rs:290, axis() at dock.rs:335`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim:21 DockSide, :24 DockAxis, :142 axis()`

Left/Bottom/Right, with axis() mapping Left|Right to Horizontal and Bottom to Vertical. The axis decides whether the dock's size means width or height, which resize cursor is shown, and whether a size survives a panel moving between edges.

**Nim での再現:** Already a faithful port; workspace_ui.nim:255 even uses the axis to decide whether to carry the size across a panel move, matching Zed's semantics. Nothing further needed.

#### Dock resize handle geometry and double-click reset — 一部

Zed: `crates/workspace/src/dock.rs:1091 (Render for Dock), handle placement at dock.rs:1124-1150`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim:490 beginDockResize, :499 dockResizeDivider, :510 dockResizeRequest, :519 resetDockSize, :527 resizeDock`

A deferred, occluding handle of RESIZE_HANDLE_SIZE centred on the dock edge: Left gets right(-SIZE/2) full height with col-resize cursor, Right gets left(-SIZE/2), Bottom gets top(-SIZE/2) full width with row-resize. Double-click (click_count == 2, dock.rs:1112) calls resize_active_panel(None, None) which resets to the panel's default size and re-serializes. The handle is suppressed while zoomed or a modal is up (resizable(), dock.rs:480).

**Nim での再現:** The logical half is present and correct in Nim terms (pointer coordinate -> logical size, clamped against MinimumCenterWidth/Height at workspace_ui.nim:534). Missing: the handle is centred on the edge in Zed (half of it overhangs into the neighbour) and there is no half-thickness offset in dockResizeDivider — add a `DockResizeHandleThickness` const and return the hit rect, not just the coordinate. Also missing: the `resizable()` suppression while zoomed/modal — that is one boolean on WorkspaceUiState. Cursor shape must be set through AppKit (`NSCursor.resizeLeftRight`) in the platform layer, keyed off the DockAxis the shared model already computes.

#### Panel size persistence and dock zoom — 無

Zed: `crates/workspace/src/dock.rs:361 PANEL_SIZE_STATE_KEY, dock.rs:547 set_panel_zoomed, workspace.rs:4163 toggle_dock`  

Panel sizes are persisted per panel_key through a KVP store (workspace.persist_panel_size_state, deferred out of the dock update at dock.rs:973), separately from the per-workspace DockStructure. Zoom is a workspace-level singleton: Workspace.zoomed/zoomed_position (workspace.rs:1375-1377), set when a zoomed panel gains focus (dock.rs:428), and render_dock returns None for the zoomed position (workspace.rs:8073) so the other docks disappear.

**Nim での再現:** Zoom is entirely absent from WorkspaceUiState — no `zoomed` / `zoomedPosition` fields, and no grep hit for zoom anywhere in main.nim. Reproducing it in Nim is cheap and purely additive: `zoomedRegion*: WorkspaceRegion` on WorkspaceUiState, checked at the top of `layout()` (workspace_ui.nim:541) to give the zoomed region the full viewport and zero the others. Pane zoom needs the same flag plus a PaneId. Per-panel size persistence needs the array[PanelKind, float32] change above plus three more session fields.

#### PanelButtons (the status-bar dock toggles) — 一部

Zed: `crates/workspace/src/dock.rs:356, Render at dock.rs:1211, StatusItemView at dock.rs:1408`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim:376 panelDockSideMask, consumed at /Users/yoshinori/work/nimculus/src/nimculus/main.nim:651 platformSetFooterPanelDockSides`

A status-bar item bound to one Dock that renders one button per enabled panel, using the panel's icon/icon_tooltip/toggle_action, ordered and filtered by enabled()/hide_button_setting().

**Nim での再現:** Nimculus encodes the whole panel->side mapping as a packed uint32 (2 bits per panel) and hands it to AppKit, which renders the buttons natively. That is a legitimate Nim/AppKit adaptation of the same mechanism, but it flattens bottom and right into one cluster (comment at workspace_ui.nim:378-379), which Zed does not do — Zed has three independent PanelButtons instances. If the parity target is Zed's status bar, the mask needs to become three ordered lists and the ObjC side needs a third cluster.

#### Item trait (what a tab knows how to be) — 一部

Zed: `crates/workspace/src/item.rs:170`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/editor_app.nim:25 EditorTab, :219 displayTitle, :233 tabDisplayLabel; breadcrumb construction at /Users/yoshinori/work/nimculus/src/nimculus/main.nim:1361`

tab_content/tab_content_text(detail) (item.rs:177,186), tab_icon (:194), tab_tooltip_text/content (:201,209), is_dirty (:278), can_save/save/save_as (:293-308), breadcrumb_location/breadcrumbs/breadcrumb_prefix (:343-352). ItemEvent (item.rs:122) is the change channel: CloseItem / UpdateTab / UpdateBreadcrumbs / Edit — the Pane redraws a tab only on UpdateTab.

**Nim での再現:** Nimculus has exactly one item type — EditorTab wrapping a FileDocument — so the trait is collapsed into a concrete object. Title, dirty and breadcrumbs exist; icon, tooltip, and conflict do not. In Nim the honest port when a second item type arrives (terminal tab, diff view, settings) is an object variant: `EditorItem = object; case kind: ItemKind of itemFile: doc: FileDocument; of itemTerminal: ...` with `proc tabTitle(item: EditorItem): string` doing a `case`. That keeps everything in one module and avoids method dispatch. Do NOT reach for Nim `concept`s here — they are structural and compile-time, so you cannot store a heterogeneous `seq` of them, which is precisely what Pane.items is.

#### Tab detail disambiguation — 一部

Zed: `crates/workspace/src/pane.rs:4910 tab_details, called from render_tab_bar at pane.rs:3453`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/editor_app.nim:210 visibleTabTitle, :219 displayTitle`

Before rendering, the whole item list is scanned and each tab gets a `detail: usize` — how many path components it must show to be unique among its siblings. That is why two open files named mod.rs show as `a/mod.rs` and `b/mod.rs` rather than two identical tabs.

**Nim での再現:** editor_app.nim:210-217 already reaches for the parent directory, so some disambiguation exists, but it is computed per-tab from the path rather than as a whole-list pass, so it cannot know how many components are needed. Reproduce in Nim as a free proc `proc tabDetails(tabs: openArray[EditorTab]): seq[int]` that groups by rendered text and increments detail for colliding groups until distinct — a direct transliteration of compute_disambiguation_details, no language obstacle. Call it once per tab-bar sync at main.nim:5326 instead of per tab.

#### Pane: item list, active index, activation history, pinned prefix, preview item — 一部

Zed: `crates/workspace/src/pane.rs:398`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/editor_app.nim:47 EditorSession (tabs/activeTab), :240 pinnedTabCount, :265 setTabPinned; per-pane indices at /Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim:32 PaneState`

items: Vec<Box<dyn ItemHandle>> with active_item_index; activation_history: Vec<ActivationHistoryEntry> (pane.rs:459) with a monotonic timestamp so closing a tab activates the most-recently-used sibling; pinned_tab_count keeps pinned items as a contiguous prefix (used by render_tab_bar at pane.rs:3469 to split the tab strip); preview_item_id marks the single italic preview tab that gets replaced rather than appended.

**Nim での再現:** The pinned-prefix invariant is genuinely ported (editor_app.nim:265-276 moves the tab to the boundary, matching Zed). Missing: activation history (closing a tab in Nimculus picks the neighbour by index, editor_app.nim, not by MRU) and preview tabs (no `preview` field anywhere). Both are plain data: add `activationHistory*: seq[tuple[tab: int, stamp: int]]` and `previewTab*: int` to PaneState. The deeper divergence is ownership: Zed's Pane owns its items, whereas Nimculus splits them — EditorSession.tabs is the global document store and PaneState.tabIndices is a per-pane index list (workspace_ui.nim:33-37, and the migration comment at :706). Every pane currently mirrors the same index set (syncRootTabs, workspace_ui.nim:704), so two panes cannot hold different tab sets. Closing that gap means moving `seq[EditorTab]` ownership into PaneState and leaving EditorSession as a document registry keyed by path — Nim's `ref`/`seq` semantics make this a straightforward move; there is no borrow-checker analogue to fight.

#### Nav history (back/forward across items) — 無

Zed: `crates/workspace/src/pane.rs:471 NavHistory / :474 NavHistoryState, navigate_backward at pane.rs:929`  

A per-pane Arc<Mutex<NavHistoryState>> with backward/forward/closed stacks of NavigationEntry (pane.rs:506: weak item handle + opaque per-item data + timestamp + row for Neovim-style dedup) and a NavigationMode (pane.rs:488) that suppresses recording while the history itself is driving the navigation. Each item is handed an ItemNavHistory (pane.rs:465) so the editor can push cursor positions without knowing about the pane.

**Nim での再現:** No grep hit for navHistory/GoBack anywhere in main.nim. In Nim this is a `NavHistory = object` with three `Deque[NavigationEntry]` (std/deques) held by value inside PaneState — no Arc<Mutex> needed because Nimculus's UI state is single-threaded and mutated through `var WorkspaceUiState`. The `Option<Arc<dyn Any>>` per-entry payload becomes a concrete `EditorViewState`-shaped record (Nimculus has exactly one item type), which is simpler and type-safe. The NavigationMode guard must be reproduced literally, or back/forward will record their own jumps and never terminate.

#### Pane split tree (Member / PaneAxis with flexes) — 一部

Zed: `crates/workspace/src/pane_group.rs:294 Member, :640 PaneAxis, PaneAxis::split at pane_group.rs:694`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim:42 PaneTree, :636 paneLayout, :804 splitFocusedPane, :819 setRootSplitRatio, :827 closeRootSplit`

An n-ary recursive tree: an Axis node holds Vec<Member> plus a parallel Vec<f32> of flexes (one per child, summing to len) and a cache of per-child bounding boxes used for pane_at_pixel_position and directional navigation. Splitting along the parent's own axis inserts a sibling in place; splitting across it replaces the member with a new 2-child axis (pane_group.rs:700-712). HANDLE_HITBOX_SIZE = 4.0, min sizes 80/100 (pane_group.rs:3-5).

**Nim での再現:** Nimculus uses a binary tree (`first`, `second`, one `ratio`) instead of Zed's n-ary axis with a flex vector, and splitFocusedPane (workspace_ui.nim:808) refuses unless the root is a leaf — so exactly one split is possible. The minimum extents 80/100 and the divider recursion ARE ported faithfully (workspace_ui.nim:109-111, :604 minimumPaneExtent, :636 paneLayout). To reach parity, change `PaneTree.paneSplit` to `axis: PaneAxis; children: seq[PaneTree]; flexes: seq[float32]` — Nim object variants hold seqs fine — and make split() recursive by finding the target pane's parent. The `Arc<Mutex<Vec<f32>>>` is only there because Zed's render closure needs shared mutation from a drag handler; in Nim the drag handler already goes through `var WorkspaceUiState`, so plain `seq[float32]` is correct and simpler.

#### Pane group layout: divider placement and per-pane floor — 済

Zed: `crates/workspace/src/pane_group.rs:640 PaneAxis (bounding_boxes), constants at pane_group.rs:3-5`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim:636 paneLayout, :617 clampedRootSplitRatio, :604 minimumPaneExtent`

Renders each child at flex-proportional size along the axis, records its bounds for hit testing, and interleaves resize handles of HANDLE_HITBOX_SIZE, clamped so no child falls below HORIZONTAL_MIN_SIZE (80) / VERTICAL_MIN_SIZE (100).

**Nim での再現:** This is the best-ported mechanism in the layer: paneLayout emits both leaf rects and divider rects in one traversal, minimumPaneExtent aggregates the floor correctly through orthogonal splits (max) vs parallel splits (sum), and clampedRootSplitRatio applies the same clamp to the persisted ratio so a window resize cannot make the divider jump. One numeric divergence to measure: PaneDividerThickness is 2.0 (workspace_ui.nim:111) while Zed's HANDLE_HITBOX_SIZE is 4.0 (pane_group.rs:3) — Zed's is the hitbox, not necessarily the painted rule, so this needs a screenshot measurement before changing.

#### Tab bar rendering (tabs, nav buttons, pinned row, drop targets) — 一部

Zed: `crates/workspace/src/pane.rs:3396 render_tab_bar, per-tab at pane.rs:2825 render_tab, drop target at pane.rs:3626`  
Nimculus: `AppKit-side: /Users/yoshinori/work/nimculus/src/nimnui/platform/macos/macos_platform.m:4460 NimculusTabBarOverlay (tabRectForIndex, tabIndexAtPoint, dispatchTabMoveFrom:to:, back/forward/tabList/new/split/zoom buttons); fed from /Users/yoshinori/work/nimculus/src/nimculus/main.nim:5326-5334 platformSetEditorTabs`

Builds back/forward IconButtons wired to nav history, maps items+tab_details to Tab elements with TabPosition::First/Last, splits the strip at pinned_tab_count (optionally into two rows, pane.rs:3475), and renders a scrollable strip with a ScrollHandle plus drag-drop targets. Per tab: label from tab_content with TabContentParams (selected/preview/deemphasized), icon, close button on the configured side, and the dirty/conflict indicator.

**Nim での再現:** This is the sharpest layering divergence. Zed's tab bar is Rust data-driven; Nimculus's is a native NSView that receives a single newline-joined string of titles plus an active index (main.nim:5330-5334). Everything Zed puts in TabContentParams — preview italics, deemphasized colour when the pane is unfocused (item.rs:141 text_color), per-tab icon, tooltip, diagnostic severity, git status colour — cannot cross that string boundary. Dirty state is smuggled in as a ' •' suffix appended to the title (main.nim:5329), which means the dot cannot be positioned or coloured like Zed's Indicator::dot (pane.rs:4916 uses Warning for conflict, Accent for dirty). The fix in Nim is a struct array across the FFI: `NativeTabItem {title: cstring; detail: uint32; flags: uint32; iconId: uint32; indicator: uint8}` passed as a pointer+count, exactly as platformSetEditorSelections already does at main.nim:5312. That is a small, mechanical change and it unblocks four separate parity items at once.

#### Pane render policy hooks (should_display_tab_bar, render_tab_bar_buttons) — 無

Zed: `crates/workspace/src/pane.rs:421-431`  

The Pane stores Rc<dyn Fn(..)> closures for whether to show the tab bar at all and what buttons to put at each end, so a dock-hosted pane (terminal, agent) renders a different strip from a center pane without a Pane subclass.

**Nim での再現:** Nim has closures and `proc` fields on objects, so this ports directly: `shouldDisplayTabBar*: proc(): bool {.closure.}` on PaneState. But it should not be ported yet — Nimculus has no dock-hosted panes (panels are native views), so the hook has exactly one implementation. Keep it a plain bool until a second pane host exists.

#### Item toolbar / breadcrumb slot — 一部

Zed: `crates/workspace/src/toolbar.rs:64 Toolbar, ToolbarItemLocation at toolbar.rs:56; Item side at item.rs:343 breadcrumb_location, :347 breadcrumbs`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/main.nim:1361 (breadcrumb segment construction with NativeBreadcrumbHighlight), :1290 breadcrumbSymbolsAtCursor, :1304 markdownBreadcrumbHeadings, geometry at main.nim:434 EditorBreadcrumbHeight = 45`

Each Pane owns a Toolbar entity holding (item, location) pairs where location is Hidden/PrimaryLeft/PrimaryRight/Secondary. The active item declares where its breadcrumbs go via breadcrumb_location, and returns Vec<HighlightedText> + optional Font from breadcrumbs(), so the breadcrumb is syntax-highlighted text supplied by the item, not composed by the toolbar.

**Nim での再現:** The breadcrumb content pipeline is well ported — filename first then LSP symbols or markdown headings, with syntax-kind highlights (main.nim:1379-1398), matching item.rs:347's HighlightedText contract. What is absent is the Toolbar container: there is no per-pane toolbar with left/right/secondary slots, so the breadcrumb is hard-wired into the single center editor's geometry (main.nim:434-435 EditorTopInset). In Nim a Toolbar is just `seq[tuple[item: ToolbarItem, location: ToolbarLocation]]` on PaneState with a `case` render; the reason to build it is that search bars and diagnostic bars occupy the same slot in Zed, and today Nimculus has nowhere to put them.

#### Workspace root layout (titlebar / docks+center / status bar) — 済

Zed: `crates/workspace/src/workspace.rs:8984 Render for Workspace, dock wrapper at workspace.rs:8066 render_dock`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim:541 layout(), :565 regionAt, :575 presentedRegionAt`

A vertical flex: optional titlebar item, then a horizontal band containing left dock / (center PaneGroup over bottom dock) / right dock, then the status bar. Docks stay in the element tree when closed (so their focus handles remain mounted, workspace.rs:8113) but get no size. A canvas element captures the workspace bounds and clamps panel sizes on resize (workspace.rs:9108). The bottom dock spans only the center column by default.

**Nim での再現:** layout() reproduces the geometry faithfully, including the bottom dock spanning only the center column (workspace_ui.nim:557 origin.x = leftWidth) and the center-minimum clamp that shrinks a dock rather than the editor (:546-551). The Nim shape — a pure `proc layout(state, viewport): WorkspaceLayout` returning rects — is better than Zed's here, because it is testable without a window. Two divergences: the status band is 2pt (workspace_ui.nim:101) because AppKit draws the real 30pt footer, so the shared model's `status` rect is only a Metal seam; and dockPresentationWidth (:116) can retire the right dock to zero when the native presenter needs more room than the logical dock has, which Zed never does — that is an AppKit-imposed behaviour with no Zed counterpart and should be recorded as an accepted divergence, not a bug.

#### Workspace serialization (DockStructure + pane tree + items) — 一部

Zed: `crates/workspace/src/persistence/model.rs:153 DockStructure, :203 DockData, :234 SerializedPaneGroup, :339 SerializedPane, :424 SerializedItem; writer at workspace.rs:7061 serialize_workspace_internal`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim:297 saveWorkspaceUi, :206 initWorkspaceUi(session), :189 restoreDock; JSON at /Users/yoshinori/work/nimculus/src/nimculus/session.nim:87-103 (write) and :188-196 (read)`

DockStructure = {left, right, bottom}: DockData, each DockData = {visible, active_panel: Option<String>, zoom} — the active panel is stored by persistent_name string, not by index. The center is a recursive SerializedPaneGroup (Group{axis, flexes, children} | Pane), each SerializedPane = {active, children: Vec<SerializedItem>, pinned_count}, each SerializedItem = {kind, item_id, active, preview}. Items are restored by asking the registered deserializer for `kind` to rebuild from item_id (model.rs:254 deserialize). Writes are throttled (workspace.rs:7044 schedules after SERIALIZATION_THROTTLE_TIME).

**Nim での再現:** The dock half exists and is close to DockData: three open bits, three sizes, three active-panel ordinals (session.nim:95-103). Two real defects. (1) The active panel is persisted as an enum ORDINAL (workspace_ui.nim:304 `ord(state.leftDock.activePanel)`), guarded only by the comment at workspace_ui.nim:17 telling future authors to append; Zed persists the string persistent_name precisely so panel reordering cannot silently reinterpret a session. Change to the string from panelDockSettingKey — Nim's `parseEnum`/a `case` table makes this trivial and it removes a whole class of upgrade bug. (2) The center split is persisted as flat scalars on EditorSession (`split`, `splitDirection`, `splitRatio`, `splitSecondaryTab`, session.nim:87-91) rather than as a recursive tree, so the PaneTree that workspace_ui.nim builds cannot round-trip more than one split even after the tree is made recursive. The Nim fix is a recursive JSON encoder over PaneTree — `proc toJson(t: PaneTree): JsonNode` with a `case t.kind` — mirroring SerializedPaneGroup exactly. `zoom` and `pinned_count` are also missing from the persisted shape.

#### Serialization throttle — 一部

Zed: `crates/workspace/src/workspace.rs:7044 serialize_workspace`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/persistence_scheduler.nim (module exists; not read in this pass)`

Coalesces bursts of layout changes into one write by spawning a timer task and dropping further requests while one is pending, so dragging a dock divider does not write the DB on every frame.

**Nim での再現:** Nimculus has a dedicated persistence_scheduler module, which suggests the mechanism exists, but I did not read it, so I am marking this partial/unverified rather than ported. In Nim the pattern is a deadline field plus a check on the run loop tick — no task/future machinery needed, since there is already a poll_scheduler.

### 層としての所見

Three structural divergences matter more than any individual gap.

1. The tab bar crossed the FFI as a string. Zed's Pane hands the tab bar a list of typed items and TabContentParams (item.rs:130). Nimculus hands AppKit `tabsText` — titles joined by newlines, with dirty state encoded as a ' •' suffix (main.nim:5326-5334) — and the strip is drawn by NimculusTabBarOverlay (macos_platform.m:4460). The consequence is not stylistic: preview italics, the unfocused-pane deemphasis colour (item.rs:141), per-tab file icons, diagnostic severity, git status colour, and the dirty-vs-conflict indicator colour split (pane.rs:4916) have no channel to travel through. Widening that one FFI call to a struct array — the pattern platformSetEditorSelections already uses at main.nim:5312 — unblocks several parity items at once and is the single highest-leverage change in this layer.

2. Item ownership is split between two objects, and Zed's is not. Zed's Pane owns `items: Vec<Box<dyn ItemHandle>>` (pane.rs:404). Nimculus keeps documents in `EditorSession.tabs` (editor_app.nim:48) and per-pane index lists in `PaneState.tabIndices` (workspace_ui.nim:36), with syncRootTabs (workspace_ui.nim:704) forcing every pane to mirror the same index set. The code says so itself at workspace_ui.nim:33-34 and :706-708. So splitFocusedPane (workspace_ui.nim:804) can only clone the same tab set, and it refuses anything but a root leaf split. Until `seq[EditorTab]` moves into PaneState and EditorSession becomes a path-keyed document registry, "two panes showing different files" is not reachable, and no amount of pane_group work will get there.

3. Layering: workspace.nim is misnamed. It is the project/worktree layer (roots, ignore rules, file CRUD, search) — Zed's `project` crate. The genuine workspace layer is workspace_ui.nim, and it is the strongest module in this comparison: layout(), paneLayout(), minimumPaneExtent() and clampedRootSplitRatio() are faithful, testable ports with the pane floors (80/100) taken straight from pane_group.rs:4-5. What still lives in main.nim but belongs in the workspace layer: the breadcrumb assembly (main.nim:1283-1400, which is Item::breadcrumbs, item.rs:347), the tab-bar sync (main.nim:5326), and the split/panel command handlers (main.nim:4260, 6914, 8079-8191). Those are Pane and Item responsibilities in Zed and would be ~400 lines out of the 9845.

Two things that are outright absent and should be named as such rather than assumed: zoom (no Workspace.zoomed / zoomed_position analogue anywhere; grep for zoom in main.nim returns nothing, so dock zoom, pane zoom, and the render_dock suppression at workspace.rs:8073 are all missing), and nav history (no NavHistory, no GoBack — pane.rs:471 and :929 have no counterpart).

One persistence hazard worth fixing before it bites: the active panel is stored as an enum ordinal (workspace_ui.nim:304, session.nim:194-196), defended only by a comment telling future authors to append to PanelKind. Zed stores DockData.active_panel as the persistent_name string (model.rs:203-205) specifically so that reordering panels cannot silently reinterpret an old session. Nimculus already has the string keys (panelDockSettingKey, workspace_ui.nim:330) — using them costs nothing.

Unverified in this pass, marked so rather than guessed: persistence_scheduler.nim (throttle behaviour), and Zed's follower/collaboration machinery in workspace.rs, which I read only far enough to confirm Nimculus has no counterpart and did not map.


## エディタ: モデル

状態: **一部のみ**

### Zed のファイル

| ファイル | 行 | 役割 |
| --- | ---: | --- |
| `crates/editor/src/editor.rs` | 12486 | Owns the Editor entity: the MultiBuffer handle, the DisplayMap handle, SelectionsCollection, ScrollManager, edit transactions, selection history, and every editor action. |
| `crates/multi_buffer/src/multi_buffer.rs` | 8280 | MultiBuffer: a SumTree of Excerpts over N language Buffers plus diff transforms, presented as one contiguous text with its own offset/point coordinate space. |
| `crates/editor/src/display_map/block_map.rs` | 5104 | Layer 5: inserts non-text block rows (diagnostics, excerpt headers, spacers) and replacement blocks, mapping WrapRow to BlockPoint/BlockRow, i.e. the final DisplayPoint. |
| `crates/editor/src/display_map.rs` | 4356 | Composes the five transform layers into one DisplayMap/DisplaySnapshot and layers text/inlay/semantic-token highlights on top; defines DisplayPoint/DisplayRow, the display coordina |
| `crates/editor/src/display_map/inlay_map.rs` | 2574 | Layer 1: injects inlay hint text that does not exist on disk, mapping buffer offsets to InlayPoint/InlayOffset. |
| `crates/editor/src/display_map/fold_map.rs` | 2482 | Layer 2: replaces folded ranges with a placeholder, mapping InlayPoint to FoldPoint; also owns FoldPlaceholder and the ChunkRenderer escape hatch. |
| `crates/editor/src/display_map/wrap_map.rs` | 1758 | Layer 4: soft wraps at a pixel wrap_width using a background task, mapping TabPoint to WrapPoint/WrapRow. |
| `crates/editor/src/display_map/tab_map.rs` | 1753 | Layer 3: expands hard tabs to the configured tab_size up to max_expansion_column, mapping FoldPoint to TabPoint. |
| `crates/editor/src/selections_collection.rs` | 1470 | SelectionsCollection: disjoint anchored selections plus one pending selection, with change_with/move_with mutation discipline. |
| `crates/editor/src/scroll.rs` | 1054 | ScrollManager: anchor-based scroll position, OngoingScroll axis locking, scrollbar visibility/thumb state, autoscroll request queue. |
| `crates/multi_buffer/src/anchor.rs` | 536 | Anchor: a Min/Excerpt/Max position that survives edits by delegating to a per-buffer text::Anchor. |
| `crates/editor/src/display_map/crease_map.rs` | 520 | Holds explicitly declared foldable ranges (creases) that supersede the indentation-based fold suggestion. |

### Nimculus の対応物

| ファイル | 行 | 何を担っているか |
| --- | ---: | --- |
| `/Users/yoshinori/work/nimculus/src/nimculus/main.nim` | 9845 | Editor action dispatch, LSP inlay hint state (:167-172, :5513, :5536), soft-wrap scroll reconciliation (:5249-5260), selection publishing to the native renderer |
| `/Users/yoshinori/work/nimculus/src/nimculus/editor_app.nim` | 553 | FileDocument, EditorTab (owning per-tab view + secondaryView), EditorSession with tabs/splits/recents, and ensureCursorVisible (:524) which is Nimculus's entire |
| `/Users/yoshinori/work/nimculus/src/nimculus/syntax.nim` | 398 | FoldRange (:12) and syntax-derived fold candidates (:185) — Zed's crease *source*, though not a CreaseMap. |
| `/Users/yoshinori/work/nimculus/src/nimculus/editor_view.nim` | 331 | Per-view state: selections (primary + additional), scroll position in pixels/lines, soft-wrap and line-number flags, folded ranges, word/grapheme movement, whee |
| `/Users/yoshinori/work/nimculus/src/nimculus/editor_buffer.nim` | 326 | Buffer text storage (piece table), edits, undo/redo transactions with content versioning, UTF-8/UTF-16/grapheme position conversion, line index. Covers Zed's te |
| `/Users/yoshinori/work/nimculus/src/nimculus/session.nim` | 322 | Serialization of view state (selections, scroll) and session composition — Zed's persistence.rs role. |
| `/Users/yoshinori/work/nimculus/src/nimculus/editor_text_layout.nim` | 230 | The whole display pipeline compressed into three procs: buildVisibleEditorLayout (:132), displayRowsBeforeLine (:172), sourceLineForDisplayRow (:205). Handles w |
| `/Users/yoshinori/work/nimculus/src/nimculus/editor_scroll.nim` | 153 | OngoingScroll axis locking (a faithful port of scroll.rs:68/:132) and horizontal scrollbar track/thumb geometry with Zed-measured constants. |

### メカニズム

#### MultiBuffer: N buffers presented as one text — 無

Zed: `crates/multi_buffer/src/multi_buffer.rs:73 (struct MultiBuffer), :691 (MultiBufferSnapshot), :842 (ExcerptRange)`  

A SumTree<Excerpt> over BTreeMap<BufferId, BufferState> exposes many files (or many ranges of one file) as one addressable text. MultiBufferSnapshot also carries diffs/diff_transforms, edit_count, non_text_state_update_count, trailing_excerpt_update_count — the counters the display map layers use to decide whether to invalidate.

**Nim での再現:** Reproducible but it is the single biggest missing piece. Nimculus has one PieceTable per FileDocument (src/nimculus/editor_app.nim:12) and one document per tab; there is no aggregate. In Nim: an `object` holding `seq[Excerpt]` where `Excerpt = object bufferId: int; range: Slice[int]` plus a `Table[int, PieceTable]`, and a prefix-sum index over excerpt lengths to convert multibuffer offsets to (buffer, offset). Zed uses SumTree for O(log n) edits; a `seq` + rebuilt prefix sums matches Nimculus's existing PieceTable.rebuildIndex approach (editor_buffer.nim:62) and is acceptable at Nimculus's current scale. Rust's Entity<MultiBuffer>/RefCell<Snapshot> becomes `ref object` + a plain value copy for the snapshot.

#### Anchor: an edit-surviving position — 無

Zed: `crates/multi_buffer/src/anchor.rs:17 (ExcerptAnchor), :28 (enum Anchor {Min, Excerpt, Max})`  
Nimculus: `src/nimculus/editor_buffer.nim:13 (Selection is two raw ints)`

Every persistent position in the editor — selections, folds, scroll top, highlights, blocks, diagnostics — is an Anchor, not an offset. Anchors are resolved against a snapshot on demand, so an edit anywhere does not require rewriting every stored position.

**Nim での再現:** Nimculus stores every position as a bare byte offset and repairs them after the fact by clamping (editor_view.nim:283 clampSelectionToText). That is not an anchor: it loses relative position across an edit made elsewhere in the document. In Nim an anchor is a small `object` of (insertionId: uint64, offset: int, bias: enum) requiring the buffer to keep a per-insertion fragment identity — which the current PieceTable does not have (its Piece has no id, editor_buffer.nim:7). Cheaper intermediate that is genuinely reproducible: keep offsets but make `edit`/`applyEdits` return the applied Edit list and add a `proc transform(offset: int, edits: openArray[Edit], bias): int` that every stored position is pushed through. That gets anchor semantics without changing the piece table.

#### The five-layer transform chain (inlay → fold → tab → wrap → block) — 無

Zed: `crates/editor/src/display_map.rs:1 (module doc describing the contract), :213 (DisplayMap fields), :604 (snapshot() driving the chain)`  
Nimculus: `src/nimculus/editor_text_layout.nim:132 (buildVisibleEditorLayout collapses all of it into one loop)`

Each layer owns a SumTree<Transform> with a TransformSummary of {input: TextSummary, output: TextSummary}, its own coordinate newtype, its own Snapshot, and a `sync(lower_snapshot, lower_edits) -> (own_snapshot, own_edits)`. Snapshots Deref into the layer below, so a DisplaySnapshot can reach any coordinate space. Edits are treated as invalidation regions, not diffs.

**Nim での再現:** The chain is the structural core and Nimculus has none of it: buildVisibleEditorLayout walks source lines directly, tests each line against `folds` with an O(lines x folds) scan (editor_text_layout.nim:147-152, repeated at :183 and :214), and derives wrap rows from a per-line WrappedLineLayout cache. Reproducible in Nim without traits: define one `Layer` concept-free pattern instead — each layer is its own module exporting `type XSnapshot = object` and `proc sync(map: var XMap, below: YSnapshot, belowEdits: seq[Edit[YPoint]]): (XSnapshot, seq[Edit[XPoint]])`. Rust's Deref chain becomes an explicit field (`XSnapshot.below: YSnapshot`) plus `proc buffer(s: XSnapshot): auto = s.below.buffer` forwarders, or `converter`. The coordinate newtypes map cleanly to `distinct` types (`type FoldPoint = distinct Point`) which give Nim the same compile-time protection against mixing spaces that Zed gets from newtypes — this is the single highest-value thing to port because Nimculus currently has no distinct display coordinate at all.

#### DisplayPoint / DisplayRow — the coordinate space the renderer paints in — 一部

Zed: `crates/editor/src/display_map.rs:2496 (DisplayPoint(BlockPoint)), :2526 (DisplayRow), :2646 (DisplayPointConverter)`  
Nimculus: `src/nimculus/editor_text_layout.nim:12 (VisibleTextRow has both sourceLine and displayRow), :172 displayRowsBeforeLine, :205 sourceLineForDisplayRow`

A DisplayPoint is a BlockPoint, i.e. a row/column after inlays, folds, tab expansion, wrapping and blocks. Everything visual (cursor, selection paint, scroll top, gutter row) speaks DisplayPoint; conversion to buffer Point goes back down the chain.

**Nim での再現:** Nimculus has the concept (displayRow vs sourceLine) but as plain `int`s, and the conversions re-lay-out every line from row 0 each call — displayRowsBeforeLine is O(document) per query and is called on every scroll (main.nim:5249). Port as `type DisplayRow = distinct int` and `SourceRow = distinct int` with explicit converters, and replace the O(n) scans with the wrap layer's cumulative summary so a row query is O(log n).

#### Inlay layer — 一部

Zed: `crates/editor/src/display_map/inlay_map.rs:34 (InlayMap), :40 (InlaySnapshot), :574 (sync)`  
Nimculus: `src/nimculus/main.nim:167-172 (editorLspInlayHints), :5513 syncNativeInlayHints`

Transform is Isomorphic(summary) or Inlay(inlay); an Inlay transform has an empty input summary and a non-empty output summary, so inlay text occupies display space without occupying buffer space.

**Nim での再現:** Nimculus has inlay hints, but as `NativeEditorAnnotation`s handed to the AppKit renderer (main.nim:5528) — they are drawn, not mapped. A caret cannot move through them, and they do not shift columns. Nim port: `InlayTransform = object case isInlay: bool` (an object variant is the exact analogue of Rust's two-variant enum) held in a `seq`, with the same empty-input/non-empty-output summary rule. Note Nimculus's inlay state is invalidated by comparing the whole document string (`editorLspInlayHintSource != text`, main.nim:5520) — a version counter is what Zed uses (InlaySnapshot.version, inlay_map.rs:43).

#### Fold layer and creases — 一部

Zed: `crates/editor/src/display_map/fold_map.rs:360 (FoldMap), :680 (FoldSnapshot), :1225 (Fold), :1232 (FoldRange over Anchors), :27 (FoldPlaceholder); crates/editor/src/display_map/crease_map.rs:15`  
Nimculus: `src/nimculus/editor_view.nim:39 (foldedRanges: seq[FoldRange]), src/nimculus/syntax.nim:12 (FoldRange), :185 foldRanges`

Folds are stored as a SumTree<Fold> keyed on anchor ranges; the transform replaces the folded range with FoldPlaceholder text. Creases are separately declared foldable ranges (from LSP folding ranges or syntax) that supersede the indent heuristic.

**Nim での再現:** Nimculus has fold state on the view and a syntax-derived fold candidate list (the crease equivalent), but no fold transform: folded lines are simply skipped in the render loop (editor_text_layout.nim:147). There is no placeholder text, so a folded region shows nothing where Zed shows an inline ellipsis chip. In Nim: keep `seq[FoldRange]` sorted, add `placeholder: string`, and make the fold layer emit a synthetic chunk. Zed's FoldPlaceholder carries a render closure — in Nim that becomes a `proc` field on the object, or, more idiomatically for Nimculus's C-boundary renderer, an enum discriminant the Metal side switches on.

#### Tab expansion layer — 無

Zed: `crates/editor/src/display_map/tab_map.rs:20 (TabMap), :197 (TabSnapshot with tab_size and max_expansion_column), :41 (sync)`  

Expands hard tabs into a variable number of spaces so a tab lands on the next tab stop, with a max_expansion_column cutoff so pathological lines stay cheap. Column arithmetic above this layer is in expanded columns.

**Nim での再現:** Nimculus has no tab expansion anywhere in the editor model — the only tab handling is syntax.nim:262 counting a tab as `indentWidth` for indent guides, and main.nim:1185 counting a tab as 4 columns for an unrelated width estimate. A hard tab is shaped by the text system as a single glyph, so tab stops are wrong today. In Nim this is the easiest layer to port: a pure proc over a line's bytes producing (expandedColumn -> byteOffset) pairs, driven by `tabSize` which should move from an ad-hoc constant into EditorViewState next to `indentWidth` (editor_view.nim:35).

#### Soft wrap layer with background rewrap — 一部

Zed: `crates/editor/src/display_map/wrap_map.rs:32 (WrapMap with pending_edits, interpolated_edits, background_task), :43 (WrapSnapshot), :146 (sync)`  
Nimculus: `src/nimculus/editor_text_layout.nim:103 addWrappedRows, :160 cache.layoutWrappedLineByHash; src/nimculus/editor_view.nim:34 (softWrap flag)`

Wraps at a pixel wrap_width. Critically, it wraps on a background task and meanwhile serves an *interpolated* snapshot, so typing never blocks on rewrapping the document; edits queue in pending_edits and flush asynchronously.

**Nim での再現:** Nimculus wraps correctly per line and caches by line hash, which is a real and useful mechanism — but it is fully synchronous and there is no document-level wrap summary, so any question about total display rows re-lays-out every line (editor_text_layout.nim:198 displayRowCount). The wrap *algorithm* is ported; the wrap *map* is not. In Nim the background task becomes a thread from the existing scheduler plus a `seq[WrapTransform]` guarded by a version stamp; the interpolation trick (assume unchanged wrap points until the real rewrap lands) is straightforwardly expressible and is what keeps typing in a long soft-wrapped file cheap.

#### Block layer: non-text rows and replacement blocks — 無

Zed: `crates/editor/src/display_map/block_map.rs:38 (BlockMap), :75 (BlockSnapshot), :163 (BlockPlacement Above/Below/Near/Replace), :377 (enum Block: Custom, FoldedBuffer, ExcerptBoundary, BufferHeader, Spacer), :282 (BlockProperties), :303 (BlockStyle)`  
Nimculus: `src/nimculus/editor_diagnostics.nim (23 lines, no block model)`

Inserts rows that correspond to no buffer text — inline diagnostics, excerpt headers, buffer headers, spacers — and can replace a row range entirely. This is the layer that makes the multibuffer's headers and the diagnostics editor possible, and it is why display rows and buffer rows diverge even without wrapping.

**Nim での再現:** Entirely absent. Zed's `enum Block` with a boxed `RenderBlock` closure maps to a Nim object variant whose Custom branch holds a `proc(ctx: BlockContext): Element` — but Nimculus renders through a C/Metal boundary, so the practical Nim form is a variant with a discriminant the renderer knows how to draw plus a measured height, not a closure. BlockPlacement is a four-branch object variant. This layer must be ported before multibuffer headers or inline diagnostics can look like Zed's.

#### SelectionsCollection: disjoint anchored selections plus a pending one — 一部

Zed: `crates/editor/src/selections_collection.rs:26 (SelectionsCollection), :20 (PendingSelection), :547 change_with, :978 move_with, :1027 move_heads_with`  
Nimculus: `src/nimculus/editor_view.nim:13 (selection), :18 (additionalSelections), :97 selectionRanges, :283 clampSelectionToText`

Selections are Selection<Anchor> with an id, a reversed flag and a SelectionGoal (the remembered column for vertical movement). `disjoint` is kept sorted and non-overlapping; the in-progress drag lives separately in `pending` so it may overlap. All mutation goes through change_with, which re-sorts, merges and re-resolves.

**Nim での再現:** Nimculus has multi-cursor but with three divergences: (1) one privileged `selection` plus a `seq` of extras rather than one ordered collection with a newest/oldest — so 'newest cursor' semantics (which autoscroll and many actions depend on) cannot be expressed; (2) merging happens lazily at read time in selectionRanges (editor_view.nim:97) rather than at mutation time, so the stored state can be invalid between edits; (3) there is no SelectionGoal, so moving down through a short line and back loses the column. All three are plain Nim work: make it `selections: seq[Selection]` + `newestId: int`, add `goalColumn: Option[int]` to Selection, and funnel every mutation through one `proc changeWith(view: var EditorViewState, body: proc(...))` — Nim templates give this the same call-site ergonomics as Rust's closure form without the borrow checker.

#### Anchor-based scroll position — 一部

Zed: `crates/editor/src/scroll.rs:38 (ScrollAnchor {anchor, offset}), :388 ScrollManager::scroll_position, :51 ScrollAnchor::scroll_position`  
Nimculus: `src/nimculus/editor_view.nim:24 scrollYPixels, :19 scrollLine, :29 scrollDisplayPixels, :61 reconcileScrollPosition`

The scroll top is stored as (Anchor, fractional offset), not as a row or a pixel count. Resolving it against the current DisplaySnapshot means an edit above the viewport, a fold, an inlay appearing, or a rewrap does not make the viewport jump — the anchored line stays put.

**Nim での再現:** Nimculus stores scroll as absolute pixels with derived line/fraction compatibility fields, plus a *second* independent position for soft-wrapped display rows (scrollDisplayPixels, editor_view.nim:29) reconciled in main.nim:5249-5260. That two-position arrangement is a direct consequence of not having an anchor: Zed needs only one because the anchor resolves through the display map. Porting the anchor collapses scrollLine, scrollYFraction, scrollYPixels, scrollDisplayPixels and scrollDisplayInitialized into `scrollAnchor: Anchor` + `scrollOffset: float32` — a real simplification, not just parity. Requires the anchor mechanism above first.

#### OngoingScroll axis locking — 済

Zed: `crates/editor/src/scroll.rs:68 (OngoingScroll), :132 (filter), SCROLL_EVENT_SEPARATION at :30`  
Nimculus: `src/nimculus/editor_scroll.nim:33 (OngoingScroll), :49 filter, :22-24 (SCROLL_EVENT_SEPARATION, UNLOCK_PERCENT, UNLOCK_LOWER_BOUND)`

Within 28ms of the previous scroll event, a trackpad gesture stays locked to the axis it started on unless the off-axis delta exceeds UNLOCK_PERCENT of the on-axis delta.

**Nim での再現:** Already a faithful port, constants included, with the comment at editor_scroll.nim:21 pinning them to scroll.rs. Rust's Option<Axis> became Nim's std/options Option[ScrollAxis]; Instant became MonoTime. Nothing further needed.

#### Autoscroll strategies — 一部

Zed: `crates/editor/src/scroll/autoscroll.rs:16 (enum Autoscroll), :100 (AutoscrollStrategy), :127 autoscroll_vertically, :345 autoscroll_horizontally; request queued on ScrollManager at scroll.rs:214`  
Nimculus: `src/nimculus/editor_app.nim:524 ensureCursorVisible`

A selection change does not scroll directly; it *requests* an autoscroll (Fit/Newest/Center/Top/Bottom/TopRelative/Focused), which is applied once during the next layout when the viewport size is actually known. vertical_scroll_margin keeps N rows of context around the cursor.

**Nim での再現:** Nimculus has exactly one strategy (the equivalent of Fit, with no margin) applied immediately and in source-line space, so it ignores folds and wrapping. In Nim: `AutoscrollStrategy` is a plain enum, `Autoscroll` an object with an optional target anchor, and the request is an `Option[Autoscroll]` field on EditorViewState consumed at the top of the frame — which also fixes the ordering bug class where a caret move before a resize scrolls against a stale viewport height. verticalScrollMargin belongs next to it as a settings-backed int.

#### ScrollAmount: line / page / column / page-width — 一部

Zed: `crates/editor/src/scroll/scroll_amount.rs:19 (enum ScrollAmount), :30 lines(), :46 columns(), :53 pixels()`  
Nimculus: `src/nimculus/editor_view.nim:257 scrollPixelDelta, :267 scrollLineDelta`

Normalizes every scroll-producing action to one of four units; a full page deliberately subtracts one line to leave an anchor line.

**Nim での再現:** Nimculus ports the wheel-delta half (pixels vs lines, no wheel normalization — matching Zed) but not the action half: there is no Page/Column/PageWidth unit and therefore no shared 'leave one anchor line' rule for PageUp/PageDown. Trivial Nim object variant; the value is that every keyboard scroll action then goes through one conversion.

#### Scrollbar geometry and thumb state — 一部

Zed: `crates/editor/src/scroll.rs:181 (ScrollbarThumbState), :189 (ActiveScrollbarState), :522 show_scrollbars, SCROLLBAR_SHOW_INTERVAL at :31`  
Nimculus: `src/nimculus/editor_scroll.nim:37 (EditorHorizontalScrollbar), :101 horizontalEditorScrollbar, :136 horizontalScrollbarScrollX`

Tracks per-axis hover/drag thumb state, auto-hide timing, and minimap thumb state as editor model state rather than element state.

**Nim での再現:** Nimculus computes horizontal scrollbar track/thumb rects with documented Zed-measured constants (editor_scroll.nim:13-20), but only for the horizontal axis, and there is no thumb hover/drag state nor auto-hide. Straightforward Nim: generalize the proc over an `axis: ScrollAxis` parameter and add a `ScrollbarThumbState = enum idle, hovered, dragging` field to the view.

#### Edit transactions grouped with selection history — 一部

Zed: `crates/editor/src/editor.rs:8286 transact, :8299 start_transaction_at, :8321 end_transaction_at, :1394 SelectionHistory, :1297 SelectionHistoryMode`  
Nimculus: `src/nimculus/editor_buffer.nim:18 (EditTransaction), :159 edit, :178 applyEdits, :209 undo, :222 redo`

A transaction brackets buffer edits *and* records the selections before and after, so undo restores the caret positions, not just the text. Time-based grouping (start_transaction_at(now)) merges rapid typing into one undo step.

**Nim での再現:** Nimculus has real transactions with before/after content versions and multi-record atomic edits — genuinely good. Two gaps: EditTransaction stores no selection state, so undo leaves the caret wherever it was (Zed restores it); and there is no time-based grouping, so every keystroke via `edit` is its own undo step (editor_buffer.nim:169 pushes one transaction per call). Both are additive Nim changes: add `selectionsBefore, selectionsAfter: seq[Selection]` and a `lastEditTime: MonoTime` with a grouping interval on PieceTable. Note the selections field forces editor_buffer to know about Selection, which it already declares at :13, so no new dependency.

#### Highlight layering on top of the transform chain — 一部

Zed: `crates/editor/src/display_map.rs:213 (text_highlights, inlay_highlights, semantic_token_highlights fields), :161 (HighlightKey), :334 (HighlightStyleInterner), :1408 (HighlightedChunk); custom_highlights.rs:30`  
Nimculus: `src/nimculus/editor_text_layout.nim:8 (TextDecoration {startByte, endByte, kind}), :45 fontRunsForLine`

Highlights are keyed by an opaque HighlightKey (usually a TypeId of the feature that owns them) over anchor ranges, merged into the chunk iterator at the top of the chain, and styles are interned to a u32 id.

**Nim での再現:** Nimculus has one flat, pre-ordered, non-overlapping decoration list consumed once per line (a deliberately efficient design, documented at editor_text_layout.nim:48 as the from_chunks analogue) — but there is no per-owner keying, so two features (syntax highlighting and, say, search match highlighting) cannot both contribute without a caller merging them by hand. In Nim, Zed's TypeId key becomes an enum or an int owner id: `Table[HighlightOwner, seq[TextDecoration]]` plus one merge pass into the existing ordered form. The interner maps to a `seq[HighlightStyle]` indexed by the existing `kind: int`, which is already what fontRunsForLine assumes at :78.

#### Invisible character rendering — 無

Zed: `crates/editor/src/display_map/invisibles.rs:34 is_invisible, :49 replacement, :75 FORMAT, :100 OTHER, :114 PRESERVE`  

Classifies zero-width, format and other invisible codepoints and substitutes a visible replacement glyph so they cannot hide in the buffer.

**Nim での再現:** Nothing in Nimculus does this. Pure data plus a lookup — a `const` array of Rune ranges and a `proc replacement(r: Rune): string`, called from the same place fontRunsForLine builds runs. No structural obstacle.

#### EditorMode: one Editor type, several shapes — 無

Zed: `crates/editor/src/editor.rs:464 (enum EditorMode: SingleLine, AutoHeight, Full, Minimap)`  

The same Editor powers the buffer view, single-line inputs, auto-height inline editors, and the minimap; mode gates gutter, scrollbars, active-line background and sizing.

**Nim での再現:** Nimculus's editor is only ever the full buffer view; single-line inputs elsewhere in the app are separate NimNUI controls. Nim object variant is the direct analogue. Worth porting only if Nimculus wants inline/auto-height editors — it is a prerequisite for a minimap that shares the display map.

### 層としての所見

Layering divergence, in order of how much it costs.

1. There is no display map. This is the defining difference. Zed's DisplayMap (display_map.rs:213) is a five-layer chain of incrementally-synced transforms, each with its own snapshot and coordinate space, and every visual question is asked of a DisplaySnapshot. Nimculus's equivalent is three procs in editor_text_layout.nim that walk source lines from the top on every call. The consequences are concrete rather than aesthetic: displayRowsBeforeLine (editor_text_layout.nim:172) is O(document) and runs on every soft-wrapped scroll from main.nim:5249; folds are re-tested per line against the whole fold list (:147, :183, :214); and because there is no snapshot, main.nim must keep two independent scroll positions (scrollYPixels and scrollDisplayPixels, editor_view.nim:24/:29) and reconcile them by hand. Porting the chain removes that whole reconciliation, not just the cost.

2. There is no anchor, and no multibuffer. Every position in Nimculus is a raw byte offset repaired by clamping after the fact (editor_view.nim:283). Zed puts an Anchor (anchor.rs:28) under selections, scroll, folds, highlights and blocks. The anchor is the prerequisite for the anchored scroll position, for undo restoring selections, and for the multibuffer at all. If only one thing is ported from this layer, it should be the anchor — or, as a cheaper honest substitute, an offset-transform proc that every stored position is pushed through on each edit.

3. Two of the five layers are entirely missing and one is missing its map. No tab expansion exists anywhere (the only tab handling is an indent-guide width count at syntax.nim:262 and an unrelated column estimate at main.nim:1185), so hard tabs do not reach tab stops. No block layer exists, so inline diagnostics and excerpt headers have nowhere to live. The wrap *algorithm* is ported and cached well (editor_text_layout.nim:103, cache.layoutWrappedLineByHash) but the wrap *map* — the document-level summary and the background rewrap with an interpolated snapshot (wrap_map.rs:32) — is not, which is why row counting is O(document).

4. Layer boundaries are drawn in a different place. Zed splits workspace / editor / project into separate crates, and within editor splits Editor (state) from EditorElement (paint). Nimculus has no Editor type at all: the state is spread across EditorViewState (editor_view.nim:12), FileDocument/EditorTab/EditorSession (editor_app.nim:12-45), and free variables in main.nim (editorLspInlayHints at :167, editorSession at :257). Where things belong: EditorSession/EditorTab/splits/recents are Zed's *workspace* layer, not the editor model, and should leave editor_app.nim; the inlay hint state and the selection-publishing in main.nim (:5309, :5433) are the editor model and should leave main.nim. ensureCursorVisible (editor_app.nim:524) is autoscroll and belongs with scroll, not with session management.

5. What is genuinely ported and should not be touched. OngoingScroll (editor_scroll.nim:33-89) is a faithful port down to the three constants, with the source pinned in a comment. The undo transaction model in editor_buffer.nim (:18, :178-233) is real — atomic multi-record edits, overlap rejection, content-version tracking — and only needs selection capture and time grouping added. fontRunsForLine (editor_text_layout.nim:45) correctly implements the single-pass, no-resort chunk consumption that Zed's LineWithInvisibles::from_chunks relies on, and its comment says so.

On Nim mechanics: none of this layer needs a trait system. Zed's Transform enums are object variants; the coordinate newtypes (FoldPoint, TabPoint, WrapPoint, BlockPoint, DisplayPoint) are `distinct` types, which give Nim the same protection against mixing coordinate spaces that Rust newtypes give — and Nimculus currently mixes them freely as bare ints, which is the most likely source of off-by-one display bugs. The Deref chain between snapshots becomes an explicit `below` field plus forwarding procs. Rust's Entity<T>/Context borrow discipline has no analogue and needs none: Nimculus is single-threaded on the UI side, so `ref object` plus by-value snapshot copies is sufficient; the one place it matters is the wrap map's background task, where the snapshot must genuinely be copied across a thread boundary. The only mechanism I would call not reproducible as written is Zed's SumTree-backed incremental summaries at their exact complexity — `seq` + prefix sums is the honest Nim substitute and is adequate at Nimculus's scale, but it should be a deliberate choice, not an accident.

Not read, therefore unknown: editor.rs actions (actions.rs), movement.rs, the element/ paint side, block_map's companion/split-diff machinery beyond the struct definitions, and multi_buffer's diff transform internals.


## エディタ: レイアウトと描画

状態: **一部のみ**

### Zed のファイル

| ファイル | 行 | 役割 |
| --- | ---: | --- |
| `crates/editor/src/element.rs` | 12296 | The whole editor element: implements gpui's Element for EditorElement, doing request_layout / prepaint (all layout_* fns producing an EditorLayout) and paint (all paint_* fns), plu |
| `crates/editor/src/items.rs` | 3286 | Implements workspace's Item/FollowableItem/SerializableItem/ProjectItem for Editor: tab title text, tab_content element, tab icon/tooltip, breadcrumb segments and breadcrumb prefix |
| `crates/editor/src/git.rs` | 3148 | Editor-side git state and behaviour: the DiffHunkDelegate trait and its three implementations, diff hunk resolution/staging/restore, and the editor's blame lifecycle (toggle_git_bl |
| `crates/editor/src/git/blame.rs` | 1330 | The GitBlame entity: a SumTree of blame entries kept in sync with buffer edits, blame_for_rows for a row window, max_author_length, and the BlameRenderer trait plus its global regi |
| `crates/editor/src/editor.rs` | 0 | Read only for GutterDimensions (line 1246) and EditorSnapshot::gutter_dimensions (line 11546), which compute the gutter geometry element.rs consumes; MAX_LINE_LEN at line 296. |
| `crates/editor/src/fold.rs` | 0 | Read only for GutterDimensions::fold_area_width (line 5) and EditorSnapshot::render_crease_toggle, which define the gutter's right-hand fold column. |

### Nimculus の対応物

| ファイル | 行 | 何を担っているか |
| --- | ---: | --- |
| `/Users/yoshinori/work/nimculus/src/nimnui/platform/macos/macos_platform.m` | 17976 | Everything Zed's paint half does, plus GutterDimensions (:2207) which in Zed is editor state. Metal paint kinds for caret (:2494), selection (:2500/:2578), scro |
| `/Users/yoshinori/work/nimculus/src/nimculus/main.nim` | 9845 | The prepaint driver (buildVisibleEditorLayout call and FFI publish at :4144-4181), the breadcrumb payload builder (:1360), the git gutter mouse route (:2906), a |
| `/Users/yoshinori/work/nimculus/src/nimculus/syntax.nim` | 398 | The chunk producer feeding from_chunks: HighlightSpan/HighlightKind (10 kinds) and highlightVisible for a byte window, plus fold ranges, outline items and brack |
| `/Users/yoshinori/work/nimculus/src/nimculus/editor_view.nim` | 331 | Per-view paint-relevant state: selections, scroll position (pixel and line), soft wrap flag, indent guides, folded ranges, line height. This is Zed's per-editor |
| `/Users/yoshinori/work/nimculus/src/nimculus/editor_text_layout.nim` | 230 | LineWithInvisibles::from_chunks (font runs per line, wrapped row splitting, glyph positioning), x_for_index (as xAt), layout_lines' visible-window discipline, i |
| `/Users/yoshinori/work/nimculus/src/nimculus/editor_scroll.nim` | 153 | OngoingScroll and scroll-offset arithmetic. The natural home for the missing ScrollbarLayout thumb computation. |
| `/Users/yoshinori/work/nimculus/src/nimculus/git_blame.nim` | 67 | A flat, version-keyed cache standing in for the GitBlame entity, plus the shouldStart/shouldShow gating predicates. No SumTree, no edit splicing, no row-window  |
| `/Users/yoshinori/work/nimculus/src/nimculus/git_gutter.nim` | 33 | Gutter hit testing and the stage/unstage action, i.e. the input half of what DiffHunkDelegate abstracts. No hunk geometry or painting. |
| `/Users/yoshinori/work/nimculus/src/nimculus/editor_app.nim` | 0 | visibleTabTitle/displayTitle/tabDisplayLabel — the tab_content_text half of items.rs, with ordinal disambiguation instead of path disambiguation. |

### メカニズム

#### GutterDimensions — the gutter geometry contract — 一部

Zed: `crates/editor/src/editor.rs:1246 (struct), crates/editor/src/editor.rs:11546 (EditorSnapshot::gutter_dimensions), crates/editor/src/fold.rs:5 (fold_area_width)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:2163 (struct NimculusEditorGutterMetrics), :2207 (editorGutterMetrics), :2244 (editorGutterWidth), :2250 (editorTextOriginX)`

Computes {left_padding, right_padding, width, margin, git_blame_entries_width} once per layout from ch_width/ch_advance of the buffer font and the gutter settings. line_gutter_width = max(measured widest line number, ch_advance * min_line_number_digits). left_padding is git_blame_entries_width + (4ch if multibuffer / 3ch if runnables|breakpoints|bookmarks / 2ch if git gutter AND line numbers / 1ch if either / 0). right_padding is 4ch when folds and line numbers are both shown. Everything downstream (text origin, hunk strip, line-number right alignment, crease toggles) is derived from this one struct.

**Nim での再現:** Already reproduced, but in Objective-C rather than Nim, and only for the singleton-buffer branch with hard-coded 3ch/4ch padding (macos_platform.m:2223-2231 says so explicitly). git_blame_entries_width is not part of the struct at all, so turning on a gutter blame column cannot widen the gutter. The right home in Nim is a plain `object` in a new `editor_gutter.nim` with a `proc gutterDimensions(chWidth, chAdvance, maxLineNumberWidth: float32; settings: GutterSettings): GutterDimensions` — no traits or ownership are involved, it is pure arithmetic over measured font metrics. The font measurement (CTFontGetAdvancesForGlyphs) stays in the platform layer and is passed in.

#### gutter_strip_width — the diff change-bar width — 無

Zed: `crates/editor/src/element.rs:5309`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:6494 draws a fixed 2.0pt-wide bar at x=(left_padding-2)/2 with height line_height-4`

floor(0.275 * line_height). One number that sets the width of every gutter diff strip; a deleted-hunk marker instead uses floor(0.35 * line_height) and is drawn as a lozenge with corner radius = line_height, offset up by line_height/2 and horizontally centred by expanding to 2x width around its origin (element.rs:5313-5386, element.rs:5407-5419).

**Nim での再現:** Trivially portable: `proc gutterStripWidth(lineHeight: float32): float32 = floor(0.275 * lineHeight)` next to gutterDimensions. The current 2.0pt constant and its x position are both wrong against Zed (this is exactly what commit a43c1ff measured). The deleted-hunk lozenge needs a rounded-rect fill, which the Metal path already has (paint kind 18 does rounded selections), so a rounded quad command is the mechanism, not a new capability.

#### diff_hunk_bounds — hunk vertical extent in gutter space — 無

Zed: `crates/editor/src/element.rs:5313`  

Maps a DisplayDiffHunk to a Bounds in gutter coordinates. Folded hunks get exactly one line. Unfolded hunks span display_row_range in pixels minus scroll_top, but the end row is clamped to the first excerpt-boundary/buffer-header block inside the range so a multibuffer header is never painted over. Empty deleted ranges get the half-line-offset lozenge.

**Nim での再現:** A `proc diffHunkBounds(hunk: GitDiffHunk; scrollY, lineHeight: float32; gutterOrigin: Point): Rect` in editor_gutter.nim. Nimculus has no multibuffer and no block/excerpt concept, so the header clamp has no analogue and should be omitted rather than faked. Nimculus's GitDiffHunk (src/nimculus/git_service.nim:56) carries newStart/newCount and a kind enum, which is enough to produce the row range; the deleted-empty-range case needs the hunk to record newCount==0, which parseDiffHunks (git_service.nim:350) already distinguishes as gitHunkDeleted.

#### Diff hunk painting: colour by kind, hollow for unstaged — 無

Zed: `crates/editor/src/element.rs:5202 (paint_gutter_diff_hunks), crates/editor/src/element.rs:6570 (diff_hunk_hollow)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:6483-6497 picks three hard-coded RGB triples at alpha 0.9 and always fills solid`

Colour comes from theme version_control_added/modified/deleted, blended onto editor_background so transparency cannot leak. Staged hunks are painted as a solid quad; unstaged hunks are painted hollow — fill at 0.3 opacity with a 1px solid border in the full colour. In a split diff, side overrides kind (left=deleted colour, right=added colour).

**Nim での再現:** Straightforward: extend the git hunk span payload (NimculusGitHunkSpan, macos_platform.m:1468, set via nimculus_platform_set_editor_git_hunks at :17804) with a `staged: bool`, and read the three colours from the theme role table (macos_platform.m:17233 already lists theme roles) instead of literals. The blend-onto-background step matters for parity and is a two-line lerp. Nimculus's git_service does distinguish staged diffs (`diffHunks(repository, path, staged=true)`, git_service.nim:377), so the data exists.

#### layout_line_numbers — number choice, colour, placement, hit target — 一部

Zed: `crates/editor/src/element.rs:2727; LineNumberStyle at crates/editor/src/element.rs:115-141`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:6414-6503 (NimculusLineNumberOverlay drawRect)`

Per visible row: picks relative or absolute number (relative may be wrapped-aware), skips deleted-diff rows unless number_deleted_lines, colours via LineNumberStyle::new(is_active, is_breakpoint, diff_status), shapes the digits, and right-aligns at gutter.width - shaped_width - right_padding, offset vertically by scroll_top % line_height. Each number gets its own hitbox; singleton buffers show an IBeam cursor and select the line on click, multibuffers show a pointing hand and open the file.

**Nim での再現:** Right alignment (`self.bounds.size.width - gutter.right_padding - size.width`, :6468) and the fractional-scroll offset are already correct. Missing: relative line numbers, diff-status colouring of the number itself, breakpoint colouring, and per-number hitboxes (the overlay returns nil from hitTest, :6417, so line numbers are not clickable at all). In Nim, LineNumberStyle is naturally an enum plus a `proc color(style: LineNumberStyle; theme: Theme): Color` — Rust's `impl` on a Copy enum maps one-to-one. Hit testing should follow the pattern already used by git_gutter.nim:20 (gitGutterActionAt), i.e. a pure Nim proc that maps a pointer position to a row and an action, called from the platform mouse handler.

#### LineWithInvisibles::from_chunks — the line shaping pipeline — 一部

Zed: `crates/editor/src/element.rs:7013 (struct), crates/editor/src/element.rs:7045 (from_chunks), crates/editor/src/element.rs:7021 (enum LineFragment)`  
Nimculus: `src/nimculus/editor_text_layout.nim:45 (fontRunsForLine), :132 (buildVisibleEditorLayout), :103 (addWrappedRows)`

Consumes an iterator of HighlightedChunk in document order and emits one LineWithInvisibles per display row. Accumulates TextRuns (font/colour/background/underline/strikethrough) while text is contiguous, flushes a shape_line call at every '\n' and at every inlay/replacement boundary, tracks a running width and byte length, truncates at MAX_LINE_LEN=1024 bytes on a char boundary, and records Invisible::Tab / Invisible::Whitespace positions (suppressing the fake padding whitespace that soft wrap inserts at the start of a wrapped row).

**Nim での再現:** The core is ported and the comment at editor_text_layout.nim:48-52 names this exact Zed function. Real gaps: (a) a FontRun carries only {len, fontId} (nimnui/text), so colour is not part of the run — main.nim:4164-4172 re-derives a colour per glyph by calling decorationKindAt for every glyph, which is O(glyphs x decorations) and cannot express background_color/underline/strikethrough at all; (b) there is no LineFragment::Element, so inlay hints and fold placeholders cannot occupy horizontal space inside a line (Nimculus paints inlays in a separate AppKit annotation overlay, macos_platform.m:8817); (c) invisibles (rendered tab/space marks) are absent; (d) MAX_LINE_LEN truncation is absent. In Nim, LineFragment is an object variant (`case kind: Text | Element`), which is the direct equivalent of the Rust enum. The colour-per-run fix is to widen FontRun into a GlyphRun object with colour and decoration fields, exactly as TextRun is.

#### x_for_index / index_for_x / alignment_offset — line-local pixel↔column mapping — 一部

Zed: `crates/editor/src/element.rs:7661, crates/editor/src/element.rs:7690, crates/editor/src/element.rs:7745`  
Nimculus: `src/nimculus/editor_text_layout.nim:97 (xAt)`

Walks the fragment list to convert a byte index to an x within the shaped line and back, accounting for element fragments that consume width but have no glyphs, and adds a text-align offset computed against the content width. These are what cursor placement and mouse hit testing are built on.

**Nim での再現:** xAt is the x_for_index half, but it is a linear scan over all runs and all glyphs for every query and returns layout.width past the end rather than an Option. index_for_x has no counterpart in editor_text_layout.nim — the reverse mapping lives in the platform layer. Porting is mechanical (binary search over the run's glyph positions); the reason to do it is that it is the single definition both the caret and mouse selection must agree on, and today they are two implementations in two languages. alignment_offset has no analogue and is only needed if centred/right-aligned editors are ever wanted.

#### calculate_wrap_width — soft wrap mode to a pixel width — 一部

Zed: `crates/editor/src/element.rs:10624, consumed at crates/editor/src/element.rs:8023 and :10672`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:3062-3065 (the two-em reservation, with a comment citing Zed), src/nimculus/editor_text_layout.nim:132 takes wrapWidth as a caller-supplied parameter`

SoftWrap::None yields MAX_LINE_LEN/2 columns of em_width; EditorWidth yields the editor width; Bounded(col) yields min(editor_width, col*em_width); GitDiff yields None. editor_width itself is bounds.width - gutter.width - gutter.margin - overscroll(em_width) - em_width, i.e. two em widths are reserved to the right of the text.

**Nim での再現:** The two-em rule is already transcribed. What is absent is the SoftWrap mode enum itself — EditorViewState (src/nimculus/editor_view.nim:33) has only a `softWrap: bool`, so bounded/preferred-line-length wrapping cannot be expressed. In Nim this is an enum with a payload: `SoftWrap = object case kind: none|editorWidth|bounded|gitDiff; column: int`, plus a `proc wrapWidth(mode: SoftWrap; editorWidth, emWidth: float32): Option[float32]`. Rust's Option maps to Option[float32] from std/options.

#### PositionMap::point_for_position — pixels to a clipped DisplayPoint — 不明

Zed: `crates/editor/src/element.rs:10075 (struct PositionMap), crates/editor/src/element.rs:10142`  

The single mouse-to-buffer-position function. Subtracts the text hitbox origin, clamps y into the viewport, adds horizontal scroll in em units, derives the display row by division, then uses the cached line layout's index_for_x. It returns four positions at once — previous_valid, next_valid, nearest_valid (chosen by inlay bias), exact_unclipped — plus column_overshoot_after_line_end in em units, so callers can distinguish 'clicked past end of line' from 'clicked at end of line'.

**Nim での再現:** I did not find an equivalent in the three Nim files I was asked to read, and the hit-testing code I saw is in Objective-C (editorPointForUTF16Offset and the gutter path in git_gutter.nim). Marking unknown rather than absent. Porting it needs the cached visible layout to be queryable by row, which buildVisibleEditorLayout already produces (EditorTextLayout.rows) — so the natural Nim shape is `proc pointForPosition(layout: EditorTextLayout; pos: Point; scroll: ...): PointForPosition` returning an object with the four variants. The inlay-bias arm has no analogue until inlays become layout fragments.

#### layout_selections + active_rows — 一部

Zed: `crates/editor/src/element.rs:767, SelectionLayout at crates/editor/src/element.rs:142 and :159`  
Nimculus: `src/nimculus/editor_view.nim:13-18 (selection + additionalSelections), src/nimnui/platform/macos/macos_platform.m:311-312 (g_editor_selections array, NIMCULUS_MAX_EDITOR_SELECTIONS)`

Converts buffer selections into per-player display-space SelectionLayouts, and simultaneously builds active_rows: BTreeMap<DisplayRow, LineHighlightSpec> recording, for each row touched by a selection, whether the selection there is non-empty and whether the row has a breakpoint. active_rows drives both the current-line background and the line-number active colour, so the two can never disagree.

**Nim での再現:** Multiple selections exist on both sides. The missing piece is active_rows as a derived, shared value: macos_platform.m:6463 decides the active line number from a single `g_editor_cursor_line`, so with multiple cursors only one row is highlighted. In Nim this is a `Table[int, LineHighlightSpec]` (std/tables) built by one proc from the selection list and handed to both the gutter and the background painter. Zed's per-player colouring (PlayerColor) is collaboration-only and has no Nimculus analogue; skip it.

#### HighlightedRange::paint — the rounded multi-line selection shape — 済

Zed: `crates/editor/src/element.rs:10457 (struct), crates/editor/src/element.rs:10471 (impl), crates/editor/src/element.rs:10487 (paint_lines)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:1841 (buildRoundedSelectionBoundary), :2003 (drawRoundedSelectionWithTransform), paint kind 18 at :2578`

Turns a run of per-line start/end x pairs into a single rounded outline path rather than per-line rectangles, so a multi-line selection reads as one shape with correctly-curved inner corners.

**Nim での再現:** Already implemented, and in the right place (a Metal geometry builder). The boundary walk is in C; it could move to Nim as a pure `proc roundedSelectionBoundary(rows: openArray[SelectionRow]): seq[Point]` and be unit-tested there, which is the only real argument for touching it.

#### CursorLayout — shape, bounds, block glyph, collaborator name — 一部

Zed: `crates/editor/src/element.rs:10318 (struct), crates/editor/src/element.rs:10362 (bounds), crates/editor/src/element.rs:10421 (paint); construction at crates/editor/src/element.rs:1001 (layout_visible_cursors)`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:2494 (paint kind 8, caret)`

Bar is 2px wide by line_height; Block and Hollow are block_width by line_height; Underline is 2px tall at the line bottom. block_width is the measured advance from x_for_index(col) to x_for_index(col+1), falling back to em_advance at end of line. Block cursors re-shape the grapheme under the cursor in the inverted colour and paint it over the fill; Hollow paints an outline instead. Bounds are pixel-snapped at paint time. Cursors in redacted ranges never get block text.

**Nim での再現:** Only the bar is present as a paint kind. The cursor-shape set maps to a Nim enum and a `proc cursorBounds(shape: CursorShape; origin: Point; blockWidth, lineHeight: float32): Rect` — pure geometry, no obstacle. The block-cursor inverted glyph is the only part that needs renderer cooperation: it requires re-shaping one grapheme with a different colour and drawing it after the fill, which the existing glyph batch can express as a one-glyph run. Pixel snapping must be done in logical points before the Retina transform or the caret will shimmer during scroll.

#### ScrollbarLayout — thumb sizing and marker quads — 無

Zed: `crates/editor/src/element.rs:9787 (struct), crates/editor/src/element.rs:9870 (new_with_hitbox_and_track_length), crates/editor/src/element.rs:9931 (thumb_bounds), crates/editor/src/element.rs:9956 (marker_quads_for_ranges); layout at crates/editor/src/element.rs:1285, paint at :5755`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:2507 (paint kind 10 draws a thumb from a caller-supplied rect); :7555-7567 admits the horizontal thumb length is not tracked and spans the full text width`

thumb_size = clamp(track_length * (visible_text_units / total_text_units), MIN_THUMB_SIZE=25px, track_length). text_unit_size = (track_length - thumb_size) / (total_units - page_units), so the thumb reaches the track end exactly when the content does. The thumb is hidden entirely when content fits. Constants: BORDER_WIDTH 1px, LINE_MARKER_HEIGHT 2px, MIN_MARKER_HEIGHT 5px. marker_quads_for_ranges renders diagnostic/search/git markers into the track.

**Nim での再現:** This is pure arithmetic and is the clearest single win available: `proc scrollbarThumb(trackLength, viewport, scrollRange, glyphSpace: float32; scrollPos: float64): tuple[origin, size: float32]` in editor_scroll.nim (which already owns OngoingScroll, editor_scroll.nim, 153 lines). The comment at macos_platform.m:7556-7559 records that the thumb length is currently unmeasured, so there is a known parity gap waiting for exactly this proc. Marker quads need a per-row colour list, which diagnostics and git hunks can already supply.

#### layout_inline_blame — x placement of the end-of-line blame text — 済

Zed: `crates/editor/src/element.rs:2008`  
Nimculus: `src/nimculus/editor_text_layout.nim:27 (inlineBlameStartX), consumed at src/nimnui/platform/macos/macos_platform.m:8851-8857`

start_x = max(line_end + padding*em_width, content_origin.x + min_column_in_pixels) - scroll_x, where line_end is the crease trailer's right edge if present, otherwise content_origin.x + line width. padding comes from settings and gains 14 em widths when a tab-accept edit prediction is showing, so the blame never collides with the prediction hint.

**Nim での再現:** Ported faithfully, including the deliberate 'measure both candidates before scrolling, subtract scrollX once' note at editor_text_layout.nim:29-30. Two divergences: the min_column term uses space advance width in Nim vs em_width via column_pixels in Zed, and the crease-trailer branch is absent (Nimculus has no crease trailers). The Objective-C at :8851 recomputes the same max() inline instead of calling the Nim proc through the FFI, so there are two copies of the formula that can drift.

#### layout_blame_entries — the gutter blame column — 無

Zed: `crates/editor/src/element.rs:2197; width reservation in crates/editor/src/editor.rs:11583-11598 (git_blame_entries_width)`  
Nimculus: `src/nimculus/git_blame.nim provides the per-line data (entryAt, shouldShow) but nothing lays out a gutter column`

When the blame gutter is on, renders one element per visible row at gutter_origin + (em_width, row*line_height - scroll), and reserves the horizontal space in GutterDimensions as ch_advance * (min(max_author_length, renderer max) + SHORT_SHA_LENGTH + len("2 years, 11 months ago") + 4 spacing chars). Consecutive rows from different commits are given different player colours (render_blame_entry, element.rs:6967, bumps the colour index when two adjacent SHAs would collide).

**Nim での再現:** Feasible but it is the mechanism that most depends on GutterDimensions being a real value: without git_blame_entries_width feeding left_padding, turning the column on would overlap the change bar. Order of work is gutterDimensions first, then a `proc blameGutterWidth(maxAuthorLen: int; chAdvance: float32): float32` with the same four-term sum. The adjacent-SHA colour bump is a two-line loop over the visible rows.

#### GitBlame entity — blame kept in sync with edits — 一部

Zed: `crates/editor/src/git/blame.rs:75 (struct GitBlame), :305 (blame_for_rows), :368 (sync), :505 (generate), :681 (regenerate_on_edit), :697 (build_blame_entry_sum_tree)`  
Nimculus: `src/nimculus/git_blame.nim:10 (GitBlameCache, a flat seq[GitBlameLine] keyed by {root, path, documentVersion})`

Holds blame as a SumTree of GitBlameEntry keyed by row count, so an edit shifts entries by splicing rows rather than re-running git blame; regenerate_on_edit debounces a real regeneration. blame_for_rows takes the visible RowInfo slice and yields Option<(BufferId, BlameEntry)> per row.

**Nim での再現:** Nimculus invalidates the whole cache on every documentVersion change (git_blame.nim:35 matches) rather than splicing, so blame disappears on the first keystroke and reappears after a re-run. Reproducing the SumTree is not required for parity; the cheap equivalent is to keep the entries and apply an edit as a row-range splice on the seq — Nim's seq supports `insert`/`delete` on ranges directly. That gives the same user-visible property (blame survives editing) without a balanced tree. The full SumTree would be a generic `Tree[Item, Summary]` with a `concept` for the summary type; that is a large investment for a data structure Nimculus needs in exactly one place.

#### BlameRenderer — blame presentation as an injectable global — 無

Zed: `crates/editor/src/git/blame.rs:88 (trait), :135 (unit impl returning None), :194 (GlobalBlameRenderer)`  

A trait with render_blame_entry / render_inline_blame_entry / render_blame_entry_popover / max_author_length / open_blame_commit, stored as a gpui global so the editor crate can lay out blame without depending on the git_ui crate. The default impl returns None everywhere, which is how the editor works in tests with no UI crate present.

**Nim での再現:** This is the clearest 'Rust trait becomes what?' case in the layer. Nim has no traits; the faithful equivalent is an object of proc fields (a vtable record) held in a module-level var: `BlameRenderer = object; maxAuthorLength: proc(): int; renderInline: proc(entry: GitBlameLine): string`. A `concept` would be wrong here because the point is late binding at runtime (swap the renderer), not compile-time dispatch. Given Nimculus has exactly one renderer, the honest answer is that the indirection is not worth adding until a second one exists — but max_author_length must still be a callable, because GutterDimensions needs it.

#### DiffHunkDelegate — per-editor-kind hunk affordances — 無

Zed: `crates/editor/src/git.rs:23 (trait), :84 UncommittedDiffHunkDelegate, :164 RestoreOnlyDiffHunkDelegate, :201 RestoreOnlyUnstagedDiffHunkDelegate; render_hunk_as_staged at :79`  
Nimculus: `src/nimculus/git_gutter.nim:5-33 hard-codes a two-case action (stage / unstage by modifier key)`

Abstracts what a hunk's controls do (toggle / stage_or_unstage / restore) and how they render, so the same element code serves the project diff view, a single-file diff, and a read-only review. render_hunk_as_staged is the hook that decides whether paint_gutter_diff_hunks draws solid or hollow.

**Nim での再現:** Same answer as BlameRenderer: an object of procs, or — since the variants are a closed set of three — a plain enum plus a `case` in one dispatch proc, which is more idiomatic Nim and cheaper. git_gutter.nim's gitGutterActionAt is already shaped as 'hit test, then return an action value', which is the right factoring; it just needs the action set widened and the delegate kind threaded in.

#### The prepaint→paint split and EditorLayout — 一部

Zed: `crates/editor/src/element.rs:7954 (prepaint), :9598 (struct EditorLayout), :9431 (paint)`  
Nimculus: `src/nimculus/main.nim:4144-4182 builds the layout and ships it over FFI (platformSetEditorLayout); painting order is implicit in macos_platform.m's mix of Metal paint kinds and AppKit overlay views`

prepaint runs every layout_* function once and stores ~45 fields of positioned, already-shaped state into EditorLayout; paint then walks that state in a fixed order and issues no measurement. The paint order is load-bearing: background, indent guides, blame gutter, line numbers, then paint_text (which itself is line backgrounds → highlights → document colours → glyphs → redactions → cursors → inline diagnostics → inline blame → code actions → hunk controls), then spacer blocks, gutter highlights, gutter indicators, blocks, sticky headers, minimap, scrollbars, popovers.

**Nim での再現:** Nimculus has the prepaint half — buildVisibleEditorLayout plus the NativeEditorLayoutRow/Glyph payload is a genuine EditorLayout equivalent, and main.nim:4177-4181 even documents publishing rows before scroll so the frame is atomic. What it does not have is a single ordered paint. Layers are split across Metal paint commands and four separate AppKit NSViews (line numbers :6414, indent guides :6510, annotations :8817, inline blame :8794), each with its own drawRect and its own clip rect, so their z-order is AppKit's subview order rather than a stated sequence. Reproducing Zed's order means either moving these overlays into the Metal command list or writing the intended order down and asserting it — the former is what the layering wants long-term, since three of the four already recompute geometry that Nim already knows.

#### paint_background — active line and highlighted rows — 一部

Zed: `crates/editor/src/element.rs:4890`  
Nimculus: `src/nimnui/platform/macos/macos_platform.m:6435-6438 notes the active-line rectangle is painted by Metal below the line-number overlay`

Fills gutter and text backgrounds separately, then coalesces consecutive active rows with the same selection-emptiness into one quad. CurrentLineHighlight is a four-way setting (Gutter / Line / All / None) that chooses the quad's horizontal range: gutter-only, text-only, or the full editor width. Row highlights honour an include_gutter flag that shifts the origin past the gutter.

**Nim での再現:** The four-way CurrentLineHighlight setting is an enum plus a `proc activeLineRange(mode; hitbox, gutter: Rect): Option[Slice[float32]]` — no obstacle. Run coalescing (merging adjacent equal rows into one quad) matters for the paint-command count and is a simple while-peek loop over a sorted table, mirroring element.rs:4915-4925.

#### items.rs tab_content — the tab label element — 一部

Zed: `crates/editor/src/items.rs:751; MAX_TAB_TITLE_LEN=24 at items.rs:66; entry_git_aware_label_color at items.rs:2200; entry_label_color at items.rs:2172`  
Nimculus: `src/nimculus/editor_app.nim:210 (visibleTabTitle), :219 (displayTitle), :232 (tabDisplayLabel)`

Label colour is derived from the file's git summary when ItemSettings.git_status is on: conflict > deleted > modified > added/untracked > ignored > default, where default is Muted unless the tab is selected. Title is truncated to 24 chars with a trailoff (or truncated in the middle when the pane asks). Preview tabs are italic; files deleted on disk are struck through. An optional smaller Muted description shows the disambiguating path suffix.

**Nim での再現:** Nimculus has the title and a duplicate-disambiguation rule, but disambiguates by appending an ordinal number ('Untitled 2', editor_app.nim:228) where Zed appends distinguishing path components. The italic/strikethrough/git-colour states are all absent. entry_git_aware_label_color is a pure ordered-if over a status summary and ports as-is into a `proc tabLabelColor(status: GitSummary; ignored, selected: bool): ThemeRole`. The bigger structural note: this belongs to the workspace/pane layer, not the editor-paint layer — see notes.

#### path_for_buffer — detail-level path disambiguation — 無

Zed: `crates/editor/src/items.rs:2217 (path_for_buffer), :2227 (path_for_file)`  

Given a 'height' (how many ancestor directories to include, supplied by the pane when two tabs collide), walks up that many parents and returns either a relative suffix or the full path if the height exceeds the tree depth. This is the mechanism behind tabs showing 'src/main.rs' vs 'tests/main.rs'.

**Nim での再現:** Pure path arithmetic over std/os splitPath; no Rust-specific machinery. Replacing the ordinal-suffix scheme in editor_app.nim:219 with this is a self-contained change and would remove a visible parity gap.

#### breadcrumbs — segments from the editor, rendering from the element — 一部

Zed: `crates/editor/src/items.rs:1069 (breadcrumb_location), :1078 (breadcrumbs), :1089 (breadcrumb_prefix); crates/editor/src/element.rs:6726 (render_breadcrumb_text), :6883 (apply_dirty_filename_style)`  
Nimculus: `src/nimculus/main.nim:1360 (editorContextPayload), :1290 (breadcrumbSymbolsAtCursor), :1304 (markdownBreadcrumbHeadings)`

The Item impl returns just data — a Vec<HighlightedText> plus the buffer font — and only for singleton buffers (multibuffers put breadcrumbs on sticky file headers instead). render_breadcrumb_text does the presentation: caps at MAX_SEGMENTS=12 by replacing the middle with '⋯', joins with a Placeholder-coloured '›', newlines in a segment become spaces, and when the tab bar is hidden the first segment's filename is bolded in the default colour to signal dirtiness.

**Nim での再現:** Nimculus builds the same shape — filename first with no highlight, then heading/symbol path, joined with ' › ' and carrying per-segment syntax-kind highlight ranges (main.nim:1391-1399), and the comment at :1362 cites Zed. Missing: the 12-segment ellipsis cap, the newline→space replacement, the Placeholder colour on the separator (Nimculus bakes the separator into one string, so it cannot be coloured separately), and the dirty-filename bold. Splitting the separator out means returning `seq[BreadcrumbSegment]` across the FFI instead of one string plus ranges — a payload change, not a design problem.

#### Editor blame lifecycle and inline-blame gating — 一部

Zed: `crates/editor/src/git.rs:503 (git_blame_inline_enabled), :541 (show_git_blame_gutter), :556 (toggle_git_blame), :571 (toggle_git_blame_inline), :589 (hide_blame_popover), :949 (show_blame_hover_popover), :2131 (start_git_blame)`  
Nimculus: `src/nimculus/git_blame.nim:45 (shouldStart), :64 (shouldShow); visibility flags live in macos_platform.m:292-307`

Owns whether blame is showing at all (gutter vs inline are independent toggles), starts the GitBlame entity lazily, and manages the hover popover's delay and dismissal (including dismissing it when a workspace modal opens, items.rs:1108-1116).

**Nim での再現:** shouldStart/shouldShow are the gating predicates and are correctly isolated as pure procs. What is split awkwardly is that the visible/hidden state itself lives as Objective-C globals (g_editor_inline_blame_visible etc.) rather than on the editor view object. Moving those onto EditorViewState (editor_view.nim:11) is the same move Zed makes — blame visibility is item state, not window state — and is what would let a split pane have independent blame, which the current duplicated g_secondary_* globals only approximate.

### 層としての所見

Three structural divergences, in order of how much they cost.

1. The gutter's geometry lives on the wrong side of the FFI. In Zed, GutterDimensions is computed by EditorSnapshot (editor.rs:11546) and every consumer — text origin, hunk strip x, line-number right edge, crease toggle centre, blame column width — reads the same struct. In Nimculus it is computed in Objective-C (macos_platform.m:2207) and re-derived per drawRect, and the Nim side never sees it. That is why the change-bar x in macos_platform.m:6494 is an independent guess ((left_padding-2)/2, 2pt wide) rather than gutter_strip_width, and why a blame gutter column cannot be added without overlapping it: git_blame_entries_width has nowhere to go. This should move to a Nim editor_gutter.nim and be passed down, with only the font-metric measurement (CTFontGetAdvancesForGlyphs) left in the platform layer.

2. Painting is split across one Metal command list and four independent AppKit overlay views, each with its own clip rect and its own recomputation of the same geometry. Zed's paint() (element.rs:9431) is a single ordered sequence over a single prepainted EditorLayout, and the order is deliberate — line backgrounds before highlights before glyphs before cursors before inline blame. Nimculus's z-order is whatever AppKit's subview order happens to be, and each overlay re-measures text with Core Text (editorInlineBlameLineWidth at :8706, editorMeasuredLineNumberWidth at :2191) even though main.nim already has the shaped layout. The line-number overlay's `hitTest` returns nil (:6417), so Zed's per-line-number hitboxes cannot exist at all. Long-term these belong in the Metal command list; short-term the paint order should at least be written down and asserted.

3. Layer assignment. The prepaint side is actually well placed — editor_text_layout.nim is a real editor-paint module and its comments name the Zed functions it mirrors. But two things sitting in main.nim belong elsewhere: the breadcrumb payload builder (main.nim:1360) is Zed's items.rs `breadcrumbs`, which is a workspace-Item concern, and tab title/label (editor_app.nim:210-238) is workspace/pane, not editor-paint. Conversely, three things that Zed keeps in the element are missing from Nim entirely and would be new files, not additions to main.nim: gutter dimensions + hunk geometry, the scrollbar thumb computation (belongs next to editor_scroll.nim), and pixel↔DisplayPoint hit testing (belongs next to editor_text_layout.nim, since it needs the cached row layouts).

Two Rust-to-Nim translation notes that recur across this layer. Zed's traits here are all runtime-swappable single-implementation indirections (BlameRenderer, blame.rs:88) or closed variant sets (DiffHunkDelegate, git.rs:23) — the first maps to an object of proc fields held in a module var, the second to an enum plus a case, and neither wants a Nim `concept`. Zed's Entity/Context discipline (`editor.update(cx, |editor, cx| ...)`) exists to serialise mutation through the app context; Nimculus's equivalent is that main.nim runs single-threaded on the UI thread and mutates EditorViewState directly, which is sound but gives no compile-time guarantee — the practical substitute is keeping paint-relevant state on EditorViewState rather than in C globals, which is exactly where the blame visibility flags (macos_platform.m:292-307) currently violate the rule and force duplicated g_secondary_* copies for the split pane.

Marked unknown rather than guessed: PositionMap::point_for_position has no counterpart I found in the three Nim files I was asked to read, and I did not audit the Objective-C hit-testing path closely enough to say whether it reproduces the previous/next/nearest/exact distinction. I also read the minimap, sticky-header, block, indent-guide and diagnostic layout functions only at signature level and have deliberately left them out rather than describe them.


## プロジェクト層（サービス）

状態: **一部のみ**

### Zed のファイル

| ファイル | 行 | 役割 |
| --- | ---: | --- |
| `crates/project/src/lsp_store.rs` | 15529 | Owns language server processes, their lifecycle state, per-buffer LSP document synchronization and snapshot history, diagnostics storage and summaries, and per-buffer caches of LSP |
| `crates/project/src/git_store.rs` | 10737 | Owns git Repository entities, per-buffer diff bases (head/index text) and their recalculation, the serialized git job queue, blame, status scanning and the commit-data cat-file bat |
| `crates/worktree/src/worktree.rs` | 7199 | The filesystem model: Snapshot/LocalSnapshot of entries in SumTrees, the BackgroundScanner that watches the fs and produces scan-id-versioned snapshots plus UpdatedEntriesSet delta |
| `crates/project/src/project.rs` | 6847 | The Project entity: owns one instance of every store (worktree/buffer/lsp/git/dap/image/task/toolchain), subscribes to each store's event stream, and re-emits a single unified proj |
| `crates/buffer_diff/src/buffer_diff.rs` | 4315 | The BufferDiff entity: hunks stored anchored to the buffer in a SumTree, hunk status kind/secondary(staged) status, pending-hunk overlay, and range/row queries used by the editor g |
| `crates/project/src/buffer_store.rs` | 1835 | Opens, deduplicates, saves and reloads buffers by ProjectPath, maps entry ids to buffer ids, and emits BufferAdded / BufferChangedFilePath / BufferDropped. |
| `crates/project/src/worktree_store.rs` | 1445 | Holds the ordered collection of Worktree entities, creates them lazily by path, and forwards each worktree's entry/git-repo change events upward as WorktreeStoreEvent. |
| `crates/git/src/status.rs` | 600 | FileStatus / TrackedStatus / StatusCode / GitSummary types and their summing, used to roll a directory's git status up a tree. |
| `crates/git/src/blame.rs` | 333 | Runs git blame --incremental, parses BlameEntry per line range, and batch-fetches commit messages and tag names for the referenced SHAs. |
| `crates/worktree/src/ignore.rs` | 129 | Gitignore matching used by the scanner to mark entries is_ignored. |

### Nimculus の対応物

| ファイル | 行 | 何を担っているか |
| --- | ---: | --- |
| `/Users/yoshinori/work/nimculus/src/nimculus/main.nim` | 9845 | Everything Zed puts in Project itself: the store instances (main.nim:989-1034), the subscription/event wiring (replaced by per-frame polling), the git status→pa |
| `/Users/yoshinori/work/nimculus/src/nimculus/lsp.nim` | 1134 | LSP transport: framing, request tracking with timeouts, message construction and parsing for ~15 requests, diagnostics table, work-done progress. Corresponds to |
| `/Users/yoshinori/work/nimculus/src/nimculus/workspace.nim` | 853 | Roots, entry listing, ignore stacks, fs watching and change coalescing, fuzzy and text search jobs. Corresponds to worktree.rs plus worktree_store.rs plus proje |
| `/Users/yoshinori/work/nimculus/src/nimculus/lsp_editor_bridge.nim` | 788 | Per-feature request/response state machine and document open/change/close tracking for one server. Corresponds to LspStore's BufferLspData and the buffer regist |
| `/Users/yoshinori/work/nimculus/src/nimculus/git_service.nim` | 567 | Repository resolution and caching, the async GitJob process wrapper, status/diff/branch/log/blame/commit command surface and their parsers. Covers the command l |
| `/Users/yoshinori/work/nimculus/src/nimculus/status_bar.nim` | 84 | Status-bar item assembly including inline-blame text formatting. Consumer of this layer rather than part of it, but it is where git blame surfaces. |
| `/Users/yoshinori/work/nimculus/src/nimculus/git_blame.nim` | 67 | Blame caching keyed by (repo root, path, document version) with an explicit negative-result state. No Zed counterpart at this granularity; Zed caches blame in t |
| `/Users/yoshinori/work/nimculus/src/nimculus/git_gutter.nim` | 33 | Gutter hit-testing and pointer-to-line resolution for stage/unstage. Corresponds to editor-layer gutter geometry rather than to project/src, and is deliberately |
| `/Users/yoshinori/work/nimculus/src/nimculus/editor_diagnostics.nim` | 23 | Resolves LSP line/character diagnostics to buffer byte offsets. A sliver of LspStore's diagnostic handling; no storage, no summaries. |

### メカニズム

#### Store composition + event re-emission (Project as hub) — 無

Zed: `crates/project/src/project.rs:214 (struct Project), :335 (enum Event), :1201-1329 (cx.subscribe wiring), :3581 on_buffer_store_event, :3638 on_lsp_store_event, :3866 on_worktree_store_event`  
Nimculus: `src/nimculus/main.nim:989-1034 (flat module-level vars: lspBridge, editorGitStatusJob, editorGitStatusEntries, editorGitBlameCache, ...)`

Project holds Entity<WorktreeStore>, Entity<BufferStore>, Entity<LspStore>, Entity<GitStore> etc. Each store emits its own typed event enum; Project subscribes to all of them and translates into one project::Event that workspace/editor items observe. This is what lets a UI element say 'observe the project' without knowing which store produced the change.

**Nim での再現:** Nimculus has no hub and no event enum: services are module-level globals in main.nim and the UI reads them directly. Reproducible in Nim as a `Project = ref object` holding `lsp: LspEditorBridge; git: GitStore; workspace: Workspace`, plus `ProjectEvent = object case kind: ProjectEventKind` and `observers: seq[proc(ev: ProjectEvent) {.closure.}]`. Zed's `cx.subscribe` returning a droppable Subscription becomes an explicit `unsubscribe(id)` handle since Nim's ARC will not drop a registration for you. The Entity/Context borrow discipline (a store may not be borrowed while another is updated) has no Nim analogue and no need for one — single-threaded main-loop mutation is already what Nimculus does; the risk it replaces is reentrancy, which must be handled by queueing events rather than dispatching them inside a mutation.

#### Worktree snapshot + background scanner with scan ids — 一部

Zed: `crates/worktree/src/worktree.rs:176 (Snapshot), :249 (LocalSnapshot), :270 (BackgroundScannerState), :410 (enum ScanState), :4267 (BackgroundScanner), :4288 (BackgroundScannerPhase)`  
Nimculus: `src/nimculus/workspace.nim:62 (Workspace with `entries: Table[string, WorkspaceEntry]`), :842 startWatching, :805 changedPaths`

A background task walks the fs and watches it, producing immutable versioned Snapshots. `scan_id` increments when a scan starts, `completed_scan_id` when all preceding scans finish (worktree.rs:186-207), so a consumer can tell whether the snapshot it holds is settled. Entries live in `entries_by_path: SumTree<Entry>` and `entries_by_id: SumTree<PathEntry>`.

**Nim での再現:** Nimculus watches via a C FSEvents shim pushing paths into `workspace.changes` under a Lock, drained by `changedPaths` which coalesces and normalizes (workspace.nim:805-825) — the comment there explicitly claims parity with UpdatedEntriesSet. What is missing is versioning (no scan_id/completed_scan_id) and the ordered tree (a `Table[string, WorkspaceEntry]` cannot answer 'entries under this prefix in path order' without a full scan). In Nim: add `scanId, completedScanId: uint64` fields, and replace the Table with a sorted `seq[WorkspaceEntry]` keyed by relative path plus binary search — that gives Zed's prefix traversal without needing a SumTree. A full SumTree port is feasible (a generic `SumTree[T; S]` with a `summary` proc as a concept or a static proc parameter) but is only needed once directory-level aggregate summaries (git status rollup, counts) are wanted.

#### Entry identity: ProjectEntryId, inode-based rename detection — 無

Zed: `crates/worktree/src/worktree.rs:3896 (struct Entry, fields id/inode/mtime/is_ignored/is_hidden/is_private/is_external), :292 (RemovedEntries with by_inode and by_path)`  
Nimculus: `src/nimculus/workspace.nim:22 (WorkspaceEntry has only path/relativePath/rootPath/kind/ignored)`

Every file/dir gets a stable ProjectEntryId that survives renames: when the scanner sees a removal followed by a creation with the same inode, it reuses the id. Buffers, the project panel selection, and git repo tracking all key off this id rather than off a path.

**Nim での再現:** WorkspaceEntry carries no id, no inode, no mtime, so a rename is indistinguishable from delete+create and any open document or panel selection keyed by path breaks. In Nim: add `id: uint32; inode: uint64; mtime: Time` to WorkspaceEntry, keep a `nextEntryId` counter and a `removedByInode: Table[uint64, WorkspaceEntry]` drained at the end of each change batch, exactly as RemovedEntries does. `std/os` `getFileInfo` yields both fields on posix. This is cheap and is the prerequisite for everything else path-keyed in Nimculus.

#### Repository as an entity with a snapshot + a serialized job queue — 一部

Zed: `crates/project/src/git_store.rs:476 (struct Repository), :401 (RepositorySnapshot), :607 (GitJob), :614 (enum GitJobKey), :498 (Deref<Target=RepositorySnapshot>)`  
Nimculus: `src/nimculus/git_service.nim:68 (GitRepository = ref object with only `root: string`), :62 (GitJob wrapping one Process); state lives in main.nim:992-1034 as editorGitStatusJob / editorGitStatusSourceEntries / editorGitBranches / editorGitStatusGeneration`

Repository owns a RepositorySnapshot (statuses_by_path SumTree, branch, branch_list, head_commit, merge details, stash, scan_id) and a single-consumer job queue. GitJobKey lets a newly queued job supersede a pending identical job (WriteIndex/RefreshStatuses/ReloadBufferDiffBases/ReloadGitState) so a burst of edits collapses into one status refresh.

**Nim での再現:** Nimculus has the async job primitive (git_service.nim:252 startGitJob, :292 poll) but no repository object holding state and no queue: main.nim keeps one in-flight job per concern in a global and cancels the previous one by hand (main.nim:2491-2493, 3905-3907). The `editorGitStatusGeneration` counter (main.nim:1031) is a hand-rolled stand-in for scan_id. In Nim: `GitRepository` grows a `snapshot: RepositorySnapshot` field and a `jobs: Deque[GitJob]` with `key: Option[GitJobKey]`; enqueue does a linear scan for an equal key and replaces in place. No trait needed — GitJob's `job` closure field is `proc(repo: GitRepository) {.closure.}`, which is Nim's direct analogue of Zed's `Box<dyn FnOnce(RepositoryState, &mut AsyncApp) -> Task<()>>`.

#### Per-buffer diff bases (head text / index text) and diff recalculation — 無

Zed: `crates/project/src/git_store.rs:120 (BufferGitState: head_text, index_text, head_text_buffer, index_text_buffer, head_changed, index_changed), :184 (DiffBasesChange), :195 (DiffKind), :4671 (recalculate_diffs)`  
Nimculus: `src/nimculus/main.nim:3985 scheduleNativeGitHunks, :4019 pollNativeGitHunks (spawns `git diff` and parses the unified-diff text)`

For each open buffer the store keeps the HEAD blob and the index blob as *buffers* (not strings), so the deleted side of a hunk can be syntax-highlighted. When either base or the buffer changes, recalculate_diffs re-derives the unstaged/staged/uncommitted BufferDiffs off-thread and settles them together, with a `recalculating_tx` watch channel consumers can await.

**Nim での再現:** Nimculus does not hold diff bases at all: it shells out to `git diff` per document and parses @@ headers (git_service.nim:350 parseDiffHunks), so hunks reflect the *saved file*, not the in-memory buffer, and there is no staged-vs-unstaged distinction. Reproducible in Nim without a full port: fetch base text once per (path, head-oid) with `git show :path` and `git show HEAD:path`, cache as `Table[string, string]`, and run a Myers diff in Nim against the live PieceTable. Nim has no borrow discipline problem here; the real work is a diff implementation and an anchor type so hunks survive edits — Nimculus's PieceTable would need an anchor/version concept it does not appear to have.

#### Anchored diff hunks with secondary (staged) status — 一部

Zed: `crates/buffer_diff/src/buffer_diff.rs:100 (DiffHunk: range as Points, buffer_range as Anchors, diff_base_byte_range, secondary_status, word diffs), :70 (DiffHunkStatus), :85 (DiffHunkSecondaryStatus with the 5 states incl. the two Pending ones), :125 (PendingHunk), :423 hunks_in_row_range`  
Nimculus: `src/nimculus/git_service.nim:56 (GitDiffHunk: oldStart/oldCount/newStart/newCount/kind/patchText), src/nimculus/git_gutter.nim:5 (GitGutterActionKind: none/stage/unstage)`

A hunk is anchored, so it tracks edits rather than being invalidated. secondary_status drives the gutter's staged/unstaged/partially-staged rendering, and the two Pending variants make the gutter respond optimistically the instant the user clicks, before git returns.

**Nim での再現:** Nimculus's GitDiffHunk is line numbers plus the raw patch text, with kind added/deleted/modified — a fair match for DiffHunkStatusKind but with no secondary status, so the gutter cannot show staged vs unstaged vs partially staged, and no optimistic pending state (a click waits for `git apply` to return: main.nim:2759-2788). In Nim: add `secondary: GitHunkSecondaryStatus` (a plain enum, the direct analogue) to GitDiffHunk, and compute it by intersecting the worktree diff with the `--cached` diff — main.nim:2541 already knows to add `--cached` for unstage, so both diffs are one call apart. Anchoring requires the diff-base mechanism above; without it the enum is still worth having because it is what the gutter draws.

#### Git status scan → panel projection (staged / unstaged / conflicts) — 一部

Zed: `crates/project/src/git_store.rs:317 (StatusEntry), :366 (impl sum_tree::Item so statuses roll up per directory), crates/git/src/status.rs:10 (FileStatus), :31 (TrackedStatus: index_status + worktree_status), :351 (GitSummary)`  
Nimculus: `src/nimculus/git_service.nim:26 (GitStatusEntry: indexStatus, worktreeStatus, path, originalPath, conflict), :307 parseStatus, src/nimculus/main.nim:953 (GitStatusProjection), :2591-2709 (section building), :1138-1141 (per-file-tree status lookup by linear scan)`

Status is stored per repo path in a SumTree whose summary is a GitSummary, so any directory node can report its aggregate status in O(log n) — that is what colors folder names in the project panel. Each entry carries both index_status and worktree_status, which is what lets a file appear in both the staged and unstaged sections.

**Nim での再現:** The per-file model is faithful — both status chars are kept and main.nim:953 documents the deliberate choice to render a partially-staged file in both sections, matching TrackedStatus. What is absent is the directory rollup: main.nim:1138-1141 linearly scans editorGitStatusSourceEntries for every file-tree row, which is O(files × entries) per frame and cannot color a collapsed folder. In Nim the rollup does not need a SumTree — build a `Table[string, GitSummary]` keyed by directory once per status generation by walking each entry's parent chain, and invalidate it on editorGitStatusGeneration change. That is the whole win, at a few dozen lines.

#### Blame: entries by line range, plus batch commit-message fetch — 一部

Zed: `crates/git/src/blame.rs:17 (struct Blame: entries, messages by Oid, tag_names by Oid), :164 (BlameEntry: sha, range: Range<u32>, original_line_number, author/committer fields, summary), :29-58 (unique SHAs then one batched get_messages/get_tag_names); crates/project/src/git_store.rs:1880 blame_buffer`  
Nimculus: `src/nimculus/git_service.nim:43 (GitBlameLine: hash, author, authorTime, summary, line, text) and :538 parseBlame/:561 blame; src/nimculus/git_blame.nim:11 (GitBlameCache keyed by repositoryRoot+documentPath+documentVersion), src/nimculus/status_bar.nim:78 gitBlameStatusText`

Blame is computed against the *current buffer content* (git_store.rs:1908 passes the rope and line ending to `git blame --contents -`), so it stays correct on an unsaved buffer. Entries cover line ranges, not lines, and commit metadata is deduplicated by SHA and fetched in one batch.

**Nim での再現:** Nimculus models blame per line rather than per range and stores summary inline per line, so a 400-line file from one commit stores 400 copies of the message — correct output, more memory, and no tag names. The caching layer (git_blame.nim) is genuinely good and has no direct Zed counterpart: it keys on document version and has an explicit negative-result state (`beginUnavailable`, git_blame.nim:27). Missing: blame runs against the file on disk, not buffer contents, so an unsaved buffer blames stale text. Fix in Nim by switching git_service.blame to `startGitJobInput` (already exists, git_service.nim:261) with `git blame --contents -`. Range-compression is a straightforward post-parse pass into `seq[tuple[range: Slice[int], sha: string]]` plus `Table[string, string]` for messages.

#### Buffer store: open-by-path deduplication and load coalescing — 不明

Zed: `crates/project/src/buffer_store.rs:34 (BufferStore: loading_buffers, opened_buffers, path_to_buffer_id), :859 open_buffer, :964 add_buffer, :1049 get_by_path, :78 (LocalBufferStore.local_buffer_ids_by_entry_id), :89 (BufferStoreEvent incl. BufferChangedFilePath)`  
Nimculus: `not in the files I was asked to read — document/buffer ownership lives in main.nim (`FileDocument`, `activeDocument()`, e.g. main.nim:2903, 5449) which I did not read in full`

One buffer per ProjectPath, guaranteed. Concurrent opens of the same path share one Shared<Task> (loading_buffers) rather than racing to two buffers. Buffers are also indexed by ProjectEntryId, which is how a rename on disk updates the buffer's file without reopening it.

**Nim での再現:** Nim analogue is direct and needs no exotic feature: `documents: Table[string, ref FileDocument]` keyed by canonical path plus `loading: Table[string, Future[ref FileDocument]]` so a second open awaits the first Future rather than starting a second read — `std/asyncfutures` is already used in git_service.nim:180 for exactly this pattern. The entry-id index depends on the ProjectEntryId mechanism above. I did not verify whether main.nim already dedupes by path, so this is marked unknown rather than absent.

#### Language server lifecycle: Starting/Running state and the seed key that decides identity — 無

Zed: `crates/project/src/lsp_store.rs:14783 (enum LanguageServerState Starting{startup task, pending_workspace_folders} / Running{adapter, server, ...}), :267 (LanguageServerSeed: worktree_id + name + toolchain + settings), :251 (UnifiedLanguageServer with project_roots), :350 get_or_insert_language_server`  
Nimculus: `src/nimculus/main.nim:989 (`var lspBridge: LspEditorBridge`) — one global bridge, one server, for the whole app; src/nimculus/lsp.nim:135 (LspSessionState: initializing/ready/stopped/failed)`

Server identity is a hash key (worktree, name, toolchain, binary+init options) — two buffers under the same key share one process, and its project_roots set grows. Deliberately excludes dynamic settings (comment at lsp_store.rs:262) so a settings change that can be pushed via didChangeConfiguration does not restart the server. Requests issued while a server is Starting queue into pending_workspace_folders instead of failing.

**Nim での再現:** Nimculus has a per-session state enum that maps onto Starting/Running, but only ever one session, so it cannot serve two languages at once nor two roots. In Nim: `servers: Table[LanguageServerSeed, LspEditorBridge]` where `LanguageServerSeed = object` with `{.hash.}`-able fields (Nim gets structural `hash` for objects via `std/hashes` once you write a one-line `hash` proc, as lsp.nim:194 already does for LspProgressToken). Routing becomes `serversForBuffer(path): seq[LspEditorBridge]` driven by extension→language→server settings. The refactor's cost is not the table — it is that every one of the ~30 `lspBridge.xxx` call sites in main.nim assumes a single server and a single in-flight request id per feature (lsp_editor_bridge.nim:18-79 has one `completionRequestId`, one `hoverRequestId`, ... per bridge, which is per-server state that happens to be fine, but the *merging* of results across servers has nowhere to live).

#### Per-buffer LSP request keying and cancellation — 一部

Zed: `crates/project/src/lsp_store.rs:4140 (BufferLspData: buffer_version, per-feature caches, lsp_requests: HashMap<LspKey, HashMap<LspRequestId, Task<()>>>), :4154 (LspKey = request TypeId + server id), :4172-4208 remove_server_data`  
Nimculus: `src/nimculus/lsp_editor_bridge.nim:18-79 (one `<feature>RequestId: int` field per feature), :350 cancelDocumentFeatureRequests, :310 requestInlayHintsForPath (guards with inlayHintsRequestVersion)`

Every in-flight LSP request is keyed by (request type, server) so a new request of the same type cancels the old one by dropping its Task, and all of a server's cached data can be evicted in one call when the server dies. buffer_version gates whether cached results are still valid.

**Nim での再現:** Nimculus achieves the same effect by hand: one int field per feature is exactly 'one in-flight request per request type', and version fields (completionVersion, hoverVersion, formattingVersion, inlayHintsRequestVersion) reproduce buffer_version gating. It does not generalize — adding a feature means adding three fields, and there is no per-server eviction because there is one server. Nim's TypeId analogue for LspKey is the `typeof`/`name` of a request enum, so the clean form is `requests: Table[(LspRequestKind, ServerId), int]` with `LspRequestKind` a plain enum; that collapses ~24 fields of LspEditorBridge into one table and makes eviction a `del` loop. No Rust feature is being lost here.

#### Buffer→server document synchronization with snapshot history for incremental didChange — 一部

Zed: `crates/project/src/lsp_store.rs:8431 on_buffer_edited (:8452-8470 builds incremental changes from edits_since against the last snapshot), :331 (buffer_snapshots: buffer_id → server_id → Vec<LspBufferSnapshot>), :14647 (LspBufferSnapshot), :236 (OpenLspBufferHandle — refcounted 'this buffer is open in servers'), :328 (registered_buffers: BufferId → count)`  
Nimculus: `src/nimculus/lsp_editor_bridge.nim:9 (LspDocumentState keeps `lastText`), :539 syncDocument, :587 updateDocument, :80 (documents: Table[string, LspDocumentState]); src/nimculus/lsp.nim:321 didChangeNotification (full-text form only)`

Each server keeps a history of the buffer versions it has been told about, so didChange can send *ranges* rather than the whole document. Refcounted OpenLspBufferHandle means the buffer stays open in the server while any UI holds a handle, and didClose fires exactly when the last one drops.

**Nim での再現:** Nimculus sends full-document didChange every time (lsp.nim:321 builds `contentChanges: [{text: ...}]`), and keeps `lastText` per document purely to detect no-ops. It does keep documents open across pane switches deliberately (comment at lsp_editor_bridge.nim:76-79), which is the OpenLspBufferHandle intent without the refcount — good enough for one pane pair, wrong once a document can be closed in one pane and open in another. In Nim: `documents` gains `openRefs: int`, and incremental sync needs a diff between lastText and the new text — Nimculus's PieceTable knows its own edits, so the honest fix is to have the editor hand the bridge an edit list instead of a full string, which is a signature change to updateDocument, not new machinery. Refcounting in Nim is a plain int; there is no Drop to hook, so decrement must be explicit at the call sites.

#### Diagnostics storage, per-path grouping and per-worktree summaries — 一部

Zed: `crates/project/src/lsp_store.rs:320-330 (LocalLspStore.diagnostics: WorktreeId → RelPath → Vec<(server_id, entries)>), :4131 (LspStore.diagnostic_summaries same shape → DiagnosticSummary), :14850 (DiagnosticSummary::new counts only is_primary entries), :4234 (LspStoreEvent::DiagnosticsUpdated{server_id, paths})`  
Nimculus: `src/nimculus/lsp.nim:171 (`diagnostics: Table[string, seq[LspDiagnostic]]` keyed by URI, single server), src/nimculus/lsp_editor_bridge.nim:735 diagnosticsForPath, src/nimculus/editor_diagnostics.nim:13 resolveDiagnostics`

Diagnostics are stored per worktree-relative path *and per server*, so one server's publish never clobbers another's, and a rolled-up error/warning count per path feeds the project panel and status bar without re-walking the entries. Only primary diagnostics count toward the summary, so a multi-span rust error counts once.

**Nim での再現:** Storage by URI exists and is the right shape; it is missing the server dimension (only one server) and any summary type — there is no per-path error/warning count, so nothing can color a file-tree row or fill an error-count status item. In Nim: `DiagnosticSummary = object errorCount, warningCount: int` plus `summaries: Table[string, DiagnosticSummary]` recomputed when a publishDiagnostics arrives. The is_primary distinction has no counterpart in Nimculus's LspDiagnostic (lsp.nim:64) — related-information/multi-span is not parsed — so a naive count will over-report for servers that emit span groups; either parse `relatedInformation` or accept the divergence and document it.

#### Work-done progress aggregation into a single activity string — 済

Zed: `crates/project/src/lsp_store.rs:14839 (LanguageServerProgress: is_disk_based_diagnostics_progress, title, message, percentage, last_update_at), :4258 (LanguageServerStatus.pending_work: BTreeMap<ProgressToken, ...>), :178 (enum ProgressToken)`  
Nimculus: `src/nimculus/lsp.nim:141-160 (LspProgressToken as an object variant over number|string, LspProgress), :488 registerProgressToken, :531 activityProgressText, :576 handleWorkDoneProgress; surfaced at main.nim:5126`

Every server's $/progress tokens are kept in an ordered map per server, and the status bar picks the most relevant one to display. Disk-based diagnostics progress is flagged so 'checking project' can be distinguished from ordinary work.

**Nim での再現:** This is the one mechanism ported faithfully, and the Nim rendering is idiomatic: Rust's `enum ProgressToken { Number, String }` became a Nim object variant (lsp.nim:144) with a hand-written `hash` (lsp.nim:194) so it can key a Table — exactly the right translation. The comment at lsp.nim:157-160 explicitly records that disk_based_diagnostics_progress_token is not represented because Nimculus has no language-adapter settings layer; that is a correct scoping decision, not a gap to close now. Only divergence: Zed keys progress per server, Nimculus per session, which follows from the single-server design.

#### Multi-root workspace with per-root ignore stacks — 一部

Zed: `crates/project/src/worktree_store.rs:352 worktrees / :359 visible_worktrees / :700 create_worktree; crates/worktree/src/worktree.rs:255 (ignores_by_parent_abs_path), :208 (enum WorkDirectory InProject/AboveProject)`  
Nimculus: `src/nimculus/workspace.nim:62 (roots: seq[string], ignoreStacksByRoot: Table[string, IgnoreStack]), :110 addRoot, :118 reloadIgnoreRules, :89 canonicalWorkspaceRoot`

Several roots coexist as ordered Worktrees; gitignore state is per parent directory so a nested .gitignore applies only below itself; WorkDirectory::AboveProject handles the case where the user opened a subdirectory of a repo.

**Nim での再現:** Multi-root and per-root ignore stacks exist and roots are canonicalized so symlink aliases cannot duplicate a tree (workspace.nim:89-101) — that is the same defense as SanitizedPath. Divergences: ignore state is per *root* not per parent directory (workspace.nim:38 IgnoreStack is opaque here, so nested-gitignore precision is unknown), invalidation is whole-stack replacement (workspace.nim:118-124, deliberately, as the comment says), and there is no WorkDirectory::AboveProject concept — instead git_service.nim:214 repositoryForPath runs `git rev-parse --show-toplevel` per path, which gets the same answer at the cost of a process spawn. main.nim:1401-1420 documents the resulting fallback dance. In Nim the cleaner form is to resolve toplevel once per root at addRoot and store `workDirKind: InProject|AboveProject` on the root, removing the per-document probe entirely.

#### Off-thread work with a main-thread completion boundary — 済

Zed: `crates/project/src/git_store.rs:512-545 (LocalRepositoryState::new using cx.background_spawn), crates/worktree/src/worktree.rs:424 (UpdateObservationState channels), :410 (ScanState delivered over an UnboundedSender)`  
Nimculus: `src/nimculus/git_service.nim:180 newGitRepository (BackgroundExecutor.spawn + Future callback), :292 poll (non-blocking process poll), src/nimculus/workspace.nim:827 receiveWorkspaceChange (locked queue drained on the main thread), src/nimculus/lsp_editor_bridge.nim:608 poll`

All fs/git/LSP work happens on a background executor; results come back to the app thread as messages, and the app thread is the only mutator of entity state.

**Nim での再現:** Nimculus's model is poll-based rather than message-driven — main.nim's frame loop calls pollNativeGitHunks/lspBridge.poll/pollWorkspaceSearch (e.g. main.nim:4019, 6860) — but the discipline is the same and the reason is recorded in git_service.nim:149-155: a synchronous `git rev-parse` on the input path once parked the main thread in nanosleep during a scroll burst. `newGitRepository` (git_service.nim:180) is the correct pattern and its docstring states the ownership rule explicitly. The remaining hazard is that `newGitRepositorySync` (git_service.nim:207) still exists and repositoryForPath (:214) calls it, so the blocking path is reachable from document open. Rust's Send/Sync would have made that unrepresentable; in Nim the only enforcement available is `{.gcsafe.}` on the worker proc (already used) plus deleting the sync entry point.

### 層としての所見

The layering divergence is sharper here than the file list suggests. Zed's project crate is a *state* layer: stores own versioned snapshots, mutate them on the app thread, and emit typed events; the UI observes and re-renders. Nimculus's equivalents (git_service.nim, lsp.nim, workspace.nim) are *command and transport* layers — they know how to run git, speak LSP, and walk a directory, but they hold almost no state. All the state Zed keeps in GitStore/LspStore/Project lives instead as ~40 module-level `var`s in main.nim (main.nim:989-1034), and all the change propagation Zed does with cx.subscribe is done by per-frame polling from main.nim's loop. That is a real architectural split, not just a file-count difference, and it has three concrete consequences visible in the code.

First, ownership: there is no object that owns a repository's state, so cancellation and supersession are hand-written per concern (main.nim:2491-2493 for the branch job, :3905-3907 for the status job) and generation counters stand in for scan ids (editorGitStatusGeneration, main.nim:1031). Zed's GitJobKey (git_store.rs:614) does this once for all job kinds. What belongs where: a `GitStore` module holding `repositories: Table[string, GitRepository]`, each with a snapshot and a keyed job deque, would move roughly 200 lines out of main.nim and make the supersession rule stateable in one place.

Second, the diff-base gap is the largest single functional divergence in this layer. Zed keeps HEAD and index text as buffers per open document and re-diffs against the live buffer (git_store.rs:120, :4671). Nimculus shells out to `git diff` and parses the unified diff (main.nim:4019 → git_service.nim:350), so the gutter shows the *saved file's* hunks and cannot distinguish staged from unstaged. DiffHunkSecondaryStatus (buffer_diff.rs:85) has no representation at all, including its two optimistic Pending states — which is why the Nimculus gutter click path has to wait for `git apply` (main.nim:2759-2788) where Zed repaints immediately.

Third, single-server LSP is a structural ceiling, not a missing feature. `var lspBridge: LspEditorBridge` (main.nim:989) is referenced from ~30 sites that each assume one server and one in-flight request per feature. Zed's identity key (LanguageServerSeed, lsp_store.rs:267) and its deliberate exclusion of dynamic settings from that key are the design worth copying before the call sites multiply further.

Two places where Nimculus is genuinely ahead of a naive port and should not be "corrected": the blame cache in git_blame.nim, which keys on document version and has an explicit negative-result state (git_blame.nim:27) that Zed has no equivalent of; and the recorded reasons in the docstrings — git_service.nim:149-155 (blocking rev-parse parked the main thread during scroll) and main.nim:953 (a partially-staged file is intentionally rendered in both panel sections) are exactly the kind of measured knowledge a port loses. Also worth noting: workspace.nim:805-825 already claims and appears to deliver Zed's UpdatedEntriesSet coalescing contract.

Not read, hence unmarked: buffer/document ownership in main.nim (whether opens are deduplicated by path), the IgnoreStack implementation behind workspace.nim:38, and Zed's remote/collab halves of every store (RemoteLspStore, RemoteBufferStore, RemoteWorktree, the proto handlers) — those are roughly a third of the Zed line count in this layer and have no Nimculus counterpart by design.


## 機能 crate 群

状態: **一部のみ**

### Zed のファイル

| ファイル | 行 | 役割 |
| --- | ---: | --- |
| `crates/workspace/src/workspace.rs` | 17052 | Hosts docks, panes, items and the status bar — the shell that all feature crates plug into. |
| `crates/agent_ui/src/agent_panel.rs` | 13399 | AI agent thread panel: `init` (371), `impl Panel for AgentPanel` (4954). |
| `crates/git_ui/src/git_panel.rs` | 12239 | Git status/stage/commit panel: `impl Panel for GitPanel` (8064). |
| `crates/sidebar/src/sidebar.rs` | 8441 | Newer unified sidebar container (8.4k lines) sitting alongside the dock mechanism. |
| `crates/outline_panel/src/outline_panel.rs` | 8170 | Symbol/outline tree panel: `init` (653), `impl Panel for OutlinePanel` (4954). |
| `crates/project_panel/src/project_panel.rs` | 7738 | File tree panel: `init` (464), `impl Panel for ProjectPanel` (7567), `persistent_name` (7607). |
| `crates/zed/src/zed.rs` | 7250 | Turns a bare Workspace into the Zed workspace: `initialize_workspace` (429), `initialize_panels` (775), `initialize_agent_panel` (874), `initialize_pane` (1402) — i.e. which panels |
| `crates/settings_ui/src/settings_ui.rs` | 6797 | Graphical settings editor built from generated page_data over the settings schema. |
| `crates/terminal/src/terminal.rs` | 4947 | The PTY + alacritty terminal model behind terminal_view (no UI). |
| `crates/terminal_view/src/terminal_panel.rs` | 2404 | Docked terminal container with its own tab strip: `init` (55), `impl Panel for TerminalPanel` (1529). |
| `crates/vim/src/vim.rs` | 2397 | Modal editing: an addon attached to each Editor, `init` at 286; 47k lines across 39 files in the crate. |
| `crates/file_finder/src/file_finder.rs` | 2286 | Fuzzy file open modal, a Picker delegate. |

### Nimculus の対応物

| ファイル | 行 | 何を担っているか |
| --- | ---: | --- |
| `/Users/yoshinori/work/nimculus/src/nimculus/main.nim` | 9845 | Almost every feature crate's *view* half at once: panel rendering, quick open (4707), command palette, workspace search (4663), diagnostics painting (286), brea |
| `/Users/yoshinori/work/nimculus/src/nimculus/terminal.nim` | 1289 | crates/terminal (model only) — the cleanest model/view split in the tree |
| `/Users/yoshinori/work/nimculus/src/nimculus/lsp.nim` | 1134 | crates/lsp + parts of project's language server management |
| `/Users/yoshinori/work/nimculus/src/nimculus/settings.nim` | 921 | crates/settings + theme_settings; no settings_ui counterpart |
| `/Users/yoshinori/work/nimculus/src/nimculus/workspace.nim` | 853 | project + worktree + project_panel model + search project half (fuzzy at 385, ripgrep at 715) |
| `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim` | 841 | workspace/src/dock.rs — PanelKind, DockState, dock sides, pane tree, panel list selection, persistence of dock layout |
| `/Users/yoshinori/work/nimculus/src/nimculus/lsp_editor_bridge.nim` | 788 | the editor-side of LSP (completions, hover, diagnostics routing) |
| `/Users/yoshinori/work/nimculus/src/nimculus/git_service.nim` | 567 | crates/git — subprocess git with polled jobs |
| `/Users/yoshinori/work/nimculus/src/nimculus/dap.nim` | 400 | crates/dap wire protocol only; no debugger_ui counterpart |
| `/Users/yoshinori/work/nimculus/src/nimculus/agent_service.nim` | 370 | crates/agent reduced to an external ACP subprocess session |

### メカニズム

#### Crate init() registration order — 無

Zed: `crates/zed/src/main.rs:491-771`  

Every feature is a crate exposing `pub fn init(cx: &mut App)`; the binary calls them in a deliberate order so later crates can observe registries the earlier ones populated (settings::init at 499 before everything, editor::init at 731 before workspace::init at 737, vim::init at 761 after editor).

**Nim での再現:** Nim's natural equivalent is a module-level registration block plus an explicit `initFeatures()` proc in main.nim that calls `featureX.init(app)` in order. Nim `{.push.}`/module init sections run at import time in dependency order, which is *not* controllable enough — so make it explicit procs, not module top-level side effects. Nimculus currently has no such seam: setup is inlined (src/nimculus/main.nim:334 setupDemoUi, :680 setupShortcutRegistry, :804 applySettingsKeymap).

#### Panel trait / dock contract — 一部

Zed: `crates/workspace/src/dock.rs:36 (trait Panel), :98 (PanelHandle), :290 (DockPosition)`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim:16 (PanelKind), :21 (DockSide), :51 (DockState), :358 panelPositionIsValid, :384 openPanel`

A single trait a feature crate implements — position, position_is_valid, set_active, persistent_name — that lets the workspace host any panel without knowing its type; PanelHandle is the object-safe erasure used for storage in a Dock.

**Nim での再現:** Nimculus already chose the opposite shape: a closed `PanelKind` enum with per-panel data in fixed arrays (`panelDockSides*: array[PanelKind, DockSide]`, workspace_ui.nim:84). That is a legitimate Nim translation of the trait — dynamic dispatch replaced by a tag — but it makes panels non-extensible from outside the enum. To match Zed's openness the Nim form would be a `Panel = ref object of RootObj` with method-based dispatch, or a `PanelVTable` object of procs (`position: proc(p: Panel): DockSide`) held in a `seq[Panel]`. The proc-table form is the closer analogue of PanelHandle and avoids Nim `method` dispatch costs.

#### Panel persistence identity (persistent_name) — 一部

Zed: `crates/project_panel/src/project_panel.rs:7607, crates/outline_panel/src/outline_panel.rs:4955, crates/terminal_view/src/terminal_panel.rs:1625`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim:17-19 ("Keep new values at the end: panel ordinals are persisted in sessions"), :185 panelFromOrdinal, :297 saveWorkspaceUi`

Each panel yields a stable string used as its serialization key in workspace persistence, so a restored session re-docks the right panel.

**Nim での再現:** Nimculus persists the enum *ordinal*, which is brittle in exactly the way Zed's string key avoids. A one-line fix in Nim: a `const PanelPersistentName: array[PanelKind, string]` and serialize that instead of `ord`.

#### Startup panel construction — 一部

Zed: `crates/zed/src/zed.rs:775 initialize_panels, :874 initialize_agent_panel`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim:206 initWorkspaceUi(session, settings), :234 applyPanelDockSettings`

Async construction of each panel after the workspace exists, then `workspace.add_panel`, deciding what is present at first paint.

**Nim での再現:** Nimculus builds all panel state eagerly and synchronously from a session record. Zed's async form exists because panels load from the DB; Nim's counterpart would be the existing `persistence_scheduler.nim`/`poll_scheduler.nim` pattern rather than async/await.

#### Project panel (file tree) — 済

Zed: `crates/project_panel/src/project_panel.rs:464 init, :7567 impl Panel`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/workspace.nim:159 listChildrenAt, :272-353 create/delete/rename/copy; rendered from /Users/yoshinori/work/nimculus/src/nimculus/main.nim:4322 refreshWorkspacePreview, :6329 openFilesDockEntry`

Worktree file tree with rename/move/delete, git status decoration, drag-drop.

**Nim での再現:** Already reproduced, but split differently: the tree *model* is a real module (workspace.nim) while the panel *view* lives inline in main.nim. The Nim-native cleanup is a `project_panel.nim` owning a `PanelListState` (workspace_ui.nim:58) and a render proc, with main.nim only calling it.

#### Outline panel — 一部

Zed: `crates/outline_panel/src/outline_panel.rs:653 init, :4954 impl Panel`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/workspace_ui.nim:18 (panelOutline exists); symbol source at /Users/yoshinori/work/nimculus/src/nimculus/lsp.nim`

Tree of document symbols / search results, driven by LSP and syntax outlines.

**Nim での再現:** The panel slot and an LSP client exist; I did not find a dedicated outline module. Reproducing it in Nim is straightforward — a recursive `OutlineNode = ref object` built from LSP documentSymbol plus the existing PanelListState selection model. Marked partial because only the slot is confirmed.

#### Terminal (model) and terminal panel (view) — 済

Zed: `crates/terminal/src/terminal.rs (4947 lines, model), crates/terminal_view/src/terminal_panel.rs:55 init, :1529 impl Panel`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/terminal.nim (1289 lines; TerminalScreen/TerminalCell, style interning at :147, hyperlink cells at :172), /Users/yoshinori/work/nimculus/src/nimculus/windows_terminal.nim`

Zed splits the PTY/grid model from the docked view with its own tab strip; the model crate has no GPUI view types.

**Nim での再現:** This is the one place Nimculus already mirrors Zed's model/view split cleanly. The Nim version interns styles into `uint32` ids rather than boxing them, which is the right idiom for a value-type language without cheap Arc sharing.

#### Git panel / git integration — 一部

Zed: `crates/git_ui/src/git_panel.rs:8064 impl Panel (crate is 44979 lines over 32 files)`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/git_service.nim (567 lines, subprocess job model), /Users/yoshinori/work/nimculus/src/nimculus/git_blame.nim:19 begin/:51 finish cache, /Users/yoshinori/work/nimculus/src/nimculus/git_gutter.nim:14 gitGutterContains/:20 gitGutterActionAt`

Status list, staging, commit composition, branch picker, blame and diff hunk UI.

**Nim での再現:** Nimculus shells out to `git` with a polled job object (`GitJob`, git_service.nim:123 poll) where Zed uses libgit2 plus async tasks. The polled-subprocess pattern is a sound Nim translation of Rust's spawned Task and is used identically in task_service.nim and agent_service.nim. What is absent is the panel: staging/commit UI. 44979 Zed lines vs ~670 Nim lines is the honest scale gap.

#### Agent panel / agent runtime — 一部

Zed: `crates/agent_ui/src/agent_panel.rs:371 init, :4954 impl Panel; crates/agent (85010 lines, 56 files)`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/agent_service.nim:186 newAgentSession, :113 resolveAgentLaunchSpec, :150 appendBoundedAgentOutput`

AI threads, tool calls, edit review; agent is the largest non-editor crate in the tree.

**Nim での再現:** Nimculus takes the ACP-subprocess route: spawn an external agent binary and stream framed output, rather than embedding provider clients (Zed has anthropic/open_ai/ollama/bedrock/mistral/… as separate crates). That is the pragmatic Nim choice — no async HTTP stack needed — and it keeps the panel a text stream view. The provider-registry side (language_model, language_models) has no counterpart and does not need one under this design.

#### Debugger panel / DAP client — 一部

Zed: `crates/debugger_ui/src/debugger_panel.rs:1541 impl Panel; crates/dap (2800 lines), initialised at crates/zed/src/main.rs:593`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/dap.nim:88 encodeDapMessage, :108 DapFrameDecoder.feed, :133 DapRequestTracker`

DAP session lifecycle, stack/variables/breakpoints panel, adapter discovery via dap_adapters and debug_adapter_extension.

**Nim での再現:** The wire protocol half is ported and looks like the right shape: an explicit frame decoder plus a request/sequence tracker, which is how Nim should model Rust's request-future correlation (a `Table[int, PendingRequest]` instead of oneshot channels). Panel UI and adapter registry are absent.

#### Search: buffer search bar vs project search item — 一部

Zed: `crates/search/src/search.rs:1-247 plus buffer_search.rs, project_search.rs, search_bar.rs, text_finder.rs (crate 12698 lines)`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/search.nim:24 findMatches (in-buffer), /Users/yoshinori/work/nimculus/src/nimculus/workspace.nim:491 startSearch/:546 pollSearch/:715 searchRipgrep (project), UI at /Users/yoshinori/work/nimculus/src/nimculus/main.nim:4663 renderWorkspaceSearch, :4876 syncDocumentSearchUi`

Two distinct things share one options vocabulary: an in-editor toolbar (buffer search) and a full multibuffer search Item (project search).

**Nim での再現:** Both halves exist and, notably, Nimculus keeps the same split Zed does (buffer matcher vs cancellable project job). The Nim project search returns results by polling a `SearchJob` with a `CancelToken` (workspace.nim:86) — the correct translation of Rust's Task + cancellation, since Nim has no structured cancellation. Missing: project search as a first-class editor tab; it is a modal overlay in main.nim.

#### Settings UI (schema-driven) — 無

Zed: `crates/settings_ui/src/settings_ui.rs (6797 lines) with page_data.rs, pages/, components/`  

Renders a settings editor from typed setting descriptors rather than hand-built forms.

**Nim での再現:** Nimculus has the settings *store* (/Users/yoshinori/work/nimculus/src/nimculus/settings.nim, 921 lines, JSON-backed) but no UI over it. Zed derives descriptors with macros (settings_macros, refineable); Nim's equivalent is a compile-time macro walking an object's fields to emit a `seq[SettingDescriptor]` — genuinely feasible with `typetraits`/`fieldPairs`, and cheaper than the Rust derive machinery.

#### Extension host (wasm) and extension store UI — 一部

Zed: `crates/extension_host/src/extension_host.rs (1995 lines), crates/extensions_ui/src/extensions_ui.rs (2096), registered at crates/zed/src/main.rs:526 and :663`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/extension_service.nim:102 parseExtensionManifest, :79 validateExtensionHostPermissions; /Users/yoshinori/work/nimculus/src/nimculus/extension_catalog.nim:48 parseExtensionCatalog, :137 installCatalogArchive; /Users/yoshinori/work/nimculus/src/nimculus/wasm_runtime.nim:75 resolveWasmRuntime, :143 startWasmComponentJob`

Installs extensions, runs their wasm components, and lets them contribute languages, themes, and debug adapters through proxies (language_extension, theme_extension, debug_adapter_extension).

**Nim での再現:** Manifest parsing, catalog download with sha256 validation (extension_catalog.nim:45 validSha256), and permission gating are ported. The key divergence: Nimculus runs wasm by spawning an *external* runtime binary (wasm_runtime.nim:75) where Zed links wasmtime in-process. That is the right call for Nim — no wasmtime binding — but it means extensions cannot hold host callbacks, so Zed's proxy-registry model (extension contributes a language server) needs a different, message-passing design.

#### Vim modal editing as an editor addon — 無

Zed: `crates/vim/src/vim.rs:286 init (crate 47454 lines, 39 files); registered after editor at crates/zed/src/main.rs:761`  

Attaches per-Editor mode state and swaps the keymap context, so every editor action gains modal behaviour without editor knowing about vim.

**Nim での再現:** No vim code in Nimculus (only an unrelated 'vim' string in src/nimnui/context.nim). The mechanism is reproducible: Nimculus already has the keymap-context predicate machinery (/Users/yoshinori/work/nimculus/src/nimnui/commands.nim:42 matchingDepth, :48 resolve with contexts) which is precisely what vim mode needs — push a `keyContext("VimNormal")` onto the editor's context stack and register mode-specific commands. The hard part is not the dispatch, it is 47k lines of operators and motions.

#### Picker: one modal, many delegates — 一部

Zed: `crates/picker/src/picker.rs (1898 lines); delegates in file_finder/src/file_finder.rs:1, command_palette/src/command_palette.rs:1, tab_switcher, outline, project_symbols, theme_selector, language_selector, toolchain_selector, recent_projects, go_to_line`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/editor_view.nim:40 commandPaletteOpen, :326 openCommandPalette; quick-open at /Users/yoshinori/work/nimculus/src/nimculus/main.nim:4707 renderQuickOpen, :4775 showQuickOpen; fuzzy matcher at /Users/yoshinori/work/nimculus/src/nimculus/workspace.nim:385 fuzzyScore, :370 startFuzzySearch`

A single filtered-list modal with a delegate trait; ten-plus features are just delegates, which is why each of those crates is only 600-2300 lines.

**Nim での再現:** Nimculus has two ad-hoc modals (quick open, command palette) and a boolean flag per modal on EditorViewState — no shared abstraction. This is the highest-leverage missing mechanism: a `PickerDelegate` object of procs (`matchCount`, `renderMatch`, `confirm`) in Nim would collapse every future selector to ~50 lines, exactly as it does for Zed. Nim's closure-in-object form is a direct substitute for the Rust trait here, with no dispatch subtlety.

#### Diagnostics as a multibuffer Item — 一部

Zed: `crates/diagnostics/src/diagnostics.rs (1154 lines), init at crates/zed/src/main.rs:734`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/editor_diagnostics.nim:12 resolveDiagnostics (23 lines), inline rendering at /Users/yoshinori/work/nimculus/src/nimculus/main.nim:286-318`

Project diagnostics open as an editor tab over a synthetic multibuffer, not as a panel — deliberately reusing all editor machinery.

**Nim での再現:** Nimculus draws inline squiggles only. A project-wide diagnostics tab is blocked by the absence of a multibuffer (Zed's multi_buffer is 16331 lines); without excerpt-of-many-buffers there is nothing to open as a tab. In Nim this would be an `Excerpt = object (docId, range)` list feeding the existing text layout — feasible but it is a whole layer, not a feature.

#### Task templates and spawn UI — 一部

Zed: `crates/tasks_ui/src/tasks_ui.rs (625 lines), init at crates/zed/src/main.rs:747; model in crates/task`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/task_service.nim:128 startTask, :94 parseTaskProblems, :49 appendBoundedTaskOutput; panelTasks slot at workspace_ui.nim:18`

Resolves task templates with variable substitution and spawns them into a terminal tab.

**Nim での再現:** Runner exists with problem-matcher parsing; the template resolution and the spawn picker do not. In Nim the template layer is plain JSON to an object plus `strutils.replace` over `${…}` variables — no mechanism gap, just unwritten.

#### Collaboration (collab, collab_ui, call, channel, livekit) — 無

Zed: `crates/collab_ui/src/collab_ui.rs (62 lines entry; crate 6392, collab server 15013), init at crates/zed/src/main.rs:749 (channel) and :771 (call)`  

Channels, calls, screen share, following, shared projects over rpc/proto.

**Nim での再現:** Nothing in Nimculus (grep for collab/livekit/channel finds only unrelated hits). Reproducible in principle but it requires the whole rpc/proto/client stack plus a server; it is the one family where I would say the cost is out of proportion to a local editor's goals.

#### REPL / notebook — 無

Zed: `crates/repl/src/repl.rs:31 init (crate 12400 lines), notebook initialised separately at crates/zed/src/main.rs:733`  

Jupyter kernel connection, inline execution results in the editor, and a notebook item.

**Nim での再現:** Absent. The kernel side is ZeroMQ + JSON messaging; Nim would need a zmq binding or a subprocess shim. Inline results also require block decorations in the editor, which Nimculus does not have.

#### Auxiliary viewers (image_viewer, markdown_preview, svg_preview, csv_preview) — 無

Zed: `crates/image_viewer (1050 lines), crates/markdown_preview (2609), init at crates/zed/src/main.rs:732`  

Non-text editor Items registered for particular file types, proving Item is not editor-specific.

**Nim での再現:** Nimculus tabs are `FileDocument` records, so a tab is always text (main.nim:135 activeDocument returns ptr FileDocument). Supporting a viewer means turning the tab payload into an object variant — `TabContent = ref object; case kind: tkText, tkImage, tkPreview` — which is Nim's clean answer to Zed's `Item` trait and would be the single change unlocking all four.

#### Auto update — 済

Zed: `crates/auto_update init at crates/zed/src/main.rs:659, auto_update_ui at :661`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/update_service.nim:143 parseUpdateManifest, :44 macosUpdateMountedAppPath, :140 isHttpsUrl, :36 artifactWithinLimit`

Checks a release manifest, downloads and swaps the app bundle, shows update UI.

**Nim での再現:** Already reproduced with the same shape (manifest → download → mount → swap), including https-only and size-bound checks. UI side unverified.

#### Status bar, title bar, breadcrumbs, activity indicator — 一部

Zed: `crates/title_bar/src/title_bar.rs (1446 lines), crates/breadcrumbs (127), crates/activity_indicator (781), crates/notifications (684)`  
Nimculus: `/Users/yoshinori/work/nimculus/src/nimculus/status_bar.nim:30 statusBarFooter, :78 gitBlameStatusText; breadcrumb geometry at /Users/yoshinori/work/nimculus/src/nimculus/main.nim:434 EditorBreadcrumbHeight, :524-529`

Small crates that contribute items into the workspace's status bar / toolbar slots.

**Nim での再現:** Nimculus has a status bar *content* module but the slot mechanism (crates contributing items) is absent — breadcrumbs are a hardcoded 45pt band in main.nim. The Nim form of a slot is a `seq[proc(): StatusItem]` registered at init; trivial once the init-registration mechanism above exists.

#### Unified sidebar (newer container) — 不明

Zed: `crates/sidebar/src/sidebar.rs (8441 lines, 3 files, 23736 total)`  

A large newer container crate that appears to sit alongside the dock/Panel mechanism.

**Nim での再現:** I only measured this crate's size and did not read it, so I cannot say how it relates to Dock/Panel or whether Nimculus's `MacNativeSidebarMinimumDockWidth` handling (main.nim:401-406) corresponds to it. Marked unknown deliberately.

### 層としての所見

Census result in one line: of Zed's ~25 user-facing feature families, Nimculus has model-level coverage for about nine (project panel, terminal, git, search, tasks, dap, agent, extensions, auto-update), UI-level coverage for roughly three, and nothing at all for vim, collab, repl/notebook, settings_ui, and the auxiliary viewers.\n\nThe layering diverges in three specific, nameable ways.\n\n(1) Zed's unit of a feature is a crate that owns BOTH its model and its view and registers itself via `init(cx)` (crates/zed/src/main.rs:491-771). Nimculus's unit of a feature is a *model* module in src/nimculus/ with its view amputated and re-attached inside main.nim. git_service.nim (567 lines) has no git panel; task_service.nim (195) has no tasks UI; dap.nim (400) has no debugger panel; search.nim (54) has its UI at main.nim:4663. The consequence is not aesthetic: because views live in one 9845-line file, adding a feature means editing that file, so there is no seam at which a feature can be added or removed. Zed's `Panel` trait plus `init()` is exactly the seam that avoids this, and the Nim translation is available — a proc-table `PanelVTable` plus an explicit `initFeatures()` — but unbuilt.\n\n(2) Nimculus made panels a closed enum where Zed made them an open trait. `PanelKind` (workspace_ui.nim:16) with `array[PanelKind, DockSide]` (:84) is idiomatic Nim and is fine while the panel set is fixed, but it forecloses extension-contributed panels, which is a stated Zed capability (extension_host proxies at crates/zed/src/main.rs:563, :673). It also produced a real defect: panel ordinals are persisted (workspace_ui.nim:17-19 says so explicitly), where Zed persists `persistent_name` strings (project_panel.rs:7607). Reordering the enum breaks saved sessions.\n\n(3) The Picker layer is missing entirely, and that is why Nimculus's modal features feel expensive. In Zed, ten features (command palette, file finder, tab switcher, outline, project symbols, theme/language/toolchain selector, recent projects, go to line) are Picker delegates of 600-2300 lines each because picker.rs:1-1898 does the work. Nimculus instead carries a boolean per modal on EditorViewState (editor_view.nim:40) and a bespoke render proc per modal (main.nim:4663 renderWorkspaceSearch, :4707 renderQuickOpen). Building one `PickerDelegate` object-of-procs would be the single highest-leverage structural change in this layer.\n\nTwo things Nimculus does that are genuinely well-adapted rather than merely reduced: the terminal keeps Zed's model/view split and improves on it for a value-type language by interning styles to `uint32` ids (terminal.nim:147); and every subprocess-backed feature (git, tasks, agent, wasm, update) uses the same polled-job-plus-CancelToken pattern (workspace.nim:86, git_service.nim:123, task_service.nim:166), which is the correct Nim answer to Rust's spawned `Task` and is applied consistently.\n\nUnread and therefore unknown: crates/sidebar (8441 lines in sidebar.rs) — I measured it but did not open it, so its relationship to the Dock/Panel mechanism, and whether Nimculus's native-sidebar handling at main.nim:401-406 corresponds to it, is not something I can state. I also did not read the individual selector crates, vim's operator files, or any collab crate beyond the entry point.
