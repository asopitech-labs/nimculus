# 移植タスクの分解と棚卸し

[`ZED_ARCHITECTURE.md`](ZED_ARCHITECTURE.md) の 190 メカニズムを作業単位に分け、
`DESIGN_DECISIONS.md` の 154 件と突き合わせたもの。**この文書が移植の台帳。**

`[x]` は作業が残っていないもの、`[ ]` は残っているもの。
**作業を終えたらここを `[x]` にする。** 番号は表題で照合済み（2026-08-10 の採番し直しを反映）。

## 1. 進捗

| | 済 | 残 | 計 |
| --- | ---: | ---: | ---: |
| メカニズム | 19 | **171** | 190 |
| 設計判断 | 147 | **7** | 154 |

**メカニズムの残り 171 件のうち、99 件が「一部のみ」。**
動いているように見えて条件を変えると壊れるので、新しい機能を足すより先に片付ける。

番号の衝突 22 件は 2026-08-10 に UI-135〜UI-156 へ振り直して解消済み。
対応表と採番台帳は `DESIGN_DECISIONS.md` の冒頭。

## 2. 層ごとのタスク

詳細と Nim での再現方式は [`ZED_ARCHITECTURE.md`](ZED_ARCHITECTURE.md) の同名の節。


### プラットフォーム層

メカニズム 3/26 済 — 一部のみ 10 / 無い 13

**一部のみ — 先に片付ける**

- [ ] **NSApplication bootstrap and app-delegate callbacks** — Zed `crates/gpui_macos/src/platform.rs:70 (build_classes), :488 (Platform::run), :1274 (did_finish_launching)`
- [ ] **Runtime NSView/NSWindow subclass synthesis with a fixed selector set** — Zed `crates/gpui_macos/src/window.rs:131-303 (VIEW_CLASS), :365-474 (build_window_class)`
- [x] **Display-link frame pacing** — Zed `crates/gpui_macos/src/display_link.rs:65-226 (immortal per-display CVDisplayLink registry), :231 (WindowFrameSource), crates/gpui_macos/src/window.rs:670 (start_display_link), :2689 (step callback)`
- [ ] **Metal renderer: pipeline states per primitive kind and a pooled instance buffer** — Zed `crates/gpui_macos/src/metal_renderer.rs:111-140 (MetalRenderer fields), :56-109 (InstanceBufferPool), :446 (draw), :1047-1568 (draw_shadows/quads/paths/underlines/mono+poly sprites/surfaces)`
- [ ] **Sprite atlas with shelf packing and keyed tiles** — Zed `crates/gpui_macos/src/metal_atlas.rs:13 (MetalAtlas), :40 (get_or_insert_with), :96 (allocate), :121 (push_texture), :62/:250 (remove + refcount)`
- [ ] **IME arbitration: who sees a key first, the keybinding matcher or the input context** — Zed `crates/gpui_macos/src/window.rs:2253 (handle_key_event), :2226 (is_ime_input_source_active), :2993 (do_command_by_selector)`
- [ ] **NSEvent to portable input event translation** — Zed `crates/gpui_macos/src/events.rs:258-286 (scroll phase and precise vs line deltas), :288-300 (button numbers incl. Navigate back/forward), crates/gpui_macos/src/window.rs:319 (convert_mouse_position, y-flip)`
- [ ] **Pasteboard read/write with typed content** — Zed `crates/gpui_macos/src/pasteboard.rs:22 (Pasteboard), :50 (read), :92 (read_image), :165 (write), :264-333 (UTType mapping for png/jpeg/gif/webp/bmp/svg/ico/tiff/pnm)`
- [ ] **Menu bar construction from a declarative menu tree with keystrokes from the keymap** — Zed `crates/gpui_macos/src/platform.rs:241 (create_menu_bar), :305 (create_menu_item), :1434 (handle_menu_item), :1451 (validate_menu_item)`
- [ ] **Accessibility tree** — Zed `crates/gpui_macos/src/window.rs:1994 (a11y_init), :2013 (a11y_tree_update), :2025 (a11y_update_window_bounds), :546 (accesskit_macos::SubclassingAdapter field), :1898-1911 (activation and action handlers)`

**無い**

- [ ] **The Platform trait as the OS boundary** — Zed `crates/gpui_macos/src/platform.rs:475 (impl Platform for MacPlatform)`
- [ ] **Per-window state behind a handle stored in an ObjC ivar** — Zed `crates/gpui_macos/src/window.rs:77 (WINDOW_STATE_IVAR), :551 (MacWindowState), :2091 (get_window_state), :2101 (drop_window_state)`
- [ ] **Traffic-light repositioning for an app-drawn titlebar** — Zed `crates/gpui_macos/src/window.rs:552 (move_traffic_light), :612 (capture_traffic_light_frames), :649 (restore_traffic_light)`
- [ ] **presents-with-transaction during synchronous redraw** — Zed `crates/gpui_macos/src/window.rs:2818 (display_layer), crates/gpui_macos/src/metal_renderer.rs:374 (set_presents_with_transaction), :482-499 (commit/wait_until_scheduled/present)`
- [ ] **Glyph rasterization with subpixel variants and dilation** — Zed `crates/gpui_macos/src/text_system.rs:421 (raster_bounds, dilated by 1px), :436 (rasterize_glyph)`
- [ ] **Font fallback cascade and OpenType features** — Zed `crates/gpui_macos/src/open_type.rs:34 (apply_features_and_fallbacks), :102 (generate_fallback_array), :155 (append_system_fallbacks)`
- [x] **Key-equivalent vs key-down de-duplication** — Zed `crates/gpui_macos/src/window.rs:2177 (handle_key_equivalent), :2282-2153 (last_key_equivalent), :2243 (don't forward modified key equivalents)`
- [ ] **Keyboard layout identity and per-layout key-equivalent remapping** — Zed `crates/gpui_macos/src/keyboard.rs:13 (MacKeyboardLayout), :18 (MacKeyboardMapper), :30-50 (map_key_equivalent), plus ~1400 lines of per-layout character tables`
- [ ] **Display enumeration and coordinate space** — Zed `crates/gpui_macos/src/display.rs:16 (MacDisplay), :28 (primary), :48 (all), :79 (uuid), :108 (bounds), :121 (visible_bounds)`
- [x] **Cursor style ownership** — Zed `crates/gpui_macos/src/window.rs:334 (set_active_window_cursor_style), :2126 (reset_cursor_rects), crates/gpui_macos/src/platform.rs:1039, :1092 (hide_cursor_until_mouse_moves)`
- [ ] **External file drag-and-drop onto the window** — Zed `crates/gpui_macos/src/window.rs:3080 (dragging_entered), :3096 (dragging_updated), :3116 (perform_drag_operation), :3122 (external_paths_from_event), :3086 (send_file_drop_event)`
- [ ] **Window blur / vibrancy background** — Zed `crates/gpui_macos/src/window.rs:304 (BLURRED_VIEW_CLASS on NSVisualEffectView), :1537 (set_background_appearance), :3278 (blurred_view_update_layer), :3288 (remove_layer_background)`
- [ ] **Native window tabs** — Zed `crates/gpui_macos/src/window.rs:448-471 (tab selectors), :1052-1080 (addTabbedWindow at open), :1153 (get_user_tabbing_preference), :1238-1294, :1707-1761`

**移植済み**

- [x] Single-line text shaping (CTLine) as the platform's only text job — Zed `crates/gpui_macos/src/text_system.rs:532 (layout_line)`
- [x] Task dispatcher over GCD — Zed `crates/gpui_macos/src/dispatcher.rs:31-79 (PlatformDispatcher impl), :166 (trampoline)`
- [x] Backing scale and drawable resize — Zed `crates/gpui_macos/src/window.rs:2775 (view_did_change_backing_properties), :2780 (set_frame_size), :2624 (update_window_scale_factor), :2065 (get_scale_factor), crates/gpui_macos/src/metal_renderer.rs:381 (update_drawable_size)`

設計判断 2/2 済

- [x] UI-069 Convert logical top-origin frames at the AppKit boundary — 実装済み
- [x] UI-111 最大の構造差 — chrome を AppKit で描いていること — 却下


### フレームワーク中核

メカニズム 0/13 済 — 一部のみ 7 / 無い 6

**一部のみ — 先に片付ける**

- [ ] **WindowInvalidator + DrawPhase state machine** — Zed `crates/gpui/src/window.rs:117 WindowInvalidatorInner, :140 impl, :158 invalidate_view, :217 set_phase, :1416 enum DrawPhase, :1891 Window::refresh`
- [ ] **Three-phase element pipeline: request_layout -> prepaint -> paint** — Zed `crates/gpui/src/window.rs:3174 draw_roots (Prepaint at :3175, root request_layout :3206, stretch_auto_size_to_fill :3210, prepaint_as_root :3211, Paint at :3244, root paint :2924), :4734 request_layout, :4783 compute_layout, :4800 layout_bounds, :3360 prepaint_deferred_draws, :3430 paint_deferred_draws`
- [ ] **Hitbox list + topmost hit testing with blocking behaviors** — Zed `crates/gpui/src/window.rs:799 struct Hitbox, :724 enum HitboxBehavior, :4820 insert_hitbox, :1059 Frame::hit_test, :2919 (per-frame cache)`
- [x] **Content mask stack and element offset stack** — Zed `crates/gpui/src/window.rs:2075 ContentMask, :3644 with_content_mask, :3663 with_element_offset, :3681 with_absolute_element_offset, :3794 element_offset, :4800-4327 (layout_bounds applies snapped offset)`
- [ ] **Typed pixel units and the scale-factor ladder** — Zed `crates/gpui/src/geometry.rs:2677 Pixels, :2781 impl (floor/round/ceil/scale/pow/abs), :2829 Pixels::scale, :2982 DevicePixels, :3075 ScaledPixels, :3131 ScaledPixels->DevicePixels, :3238 Rems, :3298 AbsoluteLength, :3460 DefiniteLength, :3611 Length, :3736 px()`
- [ ] **Bounds / Point / Size / Edges / Corners generic over unit** — Zed `crates/gpui/src/geometry.rs:85 Point<T>, :396 Size<T>, :723 Bounds<T>, :1750 Edges<T>, :2258 Corners<T>, :43 trait Along, :25 enum Axis, :1694 Bounds<Pixels>::scale, :1707 to_device_pixels`
- [ ] **Frame profiling: dirty-timestamp accumulation and present** — Zed `crates/gpui/src/window.rs:126 FrameDirtyAccumulator, :2979 take_frame_dirty, :3096 record_frame_timing, :2827 present, :3156 present_if_needed`

**無い**

- [ ] **Entity handle + type-erased entity store (lease discipline)** — Zed `crates/gpui/src/app/entity_map.rs:414 (Entity<T>), :114 reserve, :120 insert, :134 lease, :151 end_lease, :156 read`
- [ ] **Context<'a,T> - entity-scoped view of App** — Zed `crates/gpui/src/app/context.rs:20 (struct), :50 entity(), :229 notify(), :765 emit()`
- [ ] **Effect queue + flush_effects re-entrancy guard** — Zed `crates/gpui/src/app.rs:1593 push_effect, :1614 flush_effects, :1048 App::update, :1055 start_update, :1059 finish_update`
- [ ] **Double-buffered Frame with element-state carryover** — Zed `crates/gpui/src/window.rs:944 struct Frame, :988 Frame::new, :1017 Frame::clear, :1089 Frame::finish, :1138-1016 rendered_frame/next_frame fields, :3040-2741 mem::swap in draw`
- [ ] **Per-element retained state keyed by GlobalElementId** — Zed `crates/gpui/src/window.rs:3883 with_element_state, :3838 use_keyed_state, :3867 use_state, :3826 with_element_namespace, :6693 enum ElementId`
- [ ] **Window/App split: root view, viewport, scale factor, refresh** — Zed `crates/gpui/src/window.rs:1044 struct Window (root :1006, viewport_size :1127, layout_engine :1128, scale_factor :1152), :2627 viewport_size(), :2750 scale_factor(), :2763 rem_size(), app.rs:704 windows SlotMap, app.rs:1236 open_window, app.rs:1805 update_window_id`

設計判断 3/3 済

- [x] UI-101 Port Zed's accessibility tree through NimNUI and NSAccessibility — 実装済み
- [x] UI-102 Port Zed's async execution on Nim's own Future — 実装済み
- [x] UI-103 Extend the layout spec toward Zed's Style, without adopting a layout engine — 実装済み


### テキストと描画

メカニズム 3/17 済 — 一部のみ 7 / 無い 7

**一部のみ — 先に片付ける**

- [ ] **Font identity and FontId interning** — Zed `crates/gpui/src/text_system.rs:1051 (Font), :107 (font_id), :148 (resolve_font)`
- [ ] **Font metrics cache and the em_width / em_advance / ch_width / ch_advance distinction** — Zed `crates/gpui/src/text_system.rs:226-249, :292 (read_metrics), :1104 (FontMetrics), :1137-1177`
- [ ] **Line geometry queries (index_for_x, x_for_index, position_for_index)** — Zed `crates/gpui/src/text_system/line_layout.rs:58, :75, :105, :117, :283-362`
- [ ] **DecorationRun coalescing (style runs separated from font runs)** — Zed `crates/gpui/src/text_system.rs:397-427 (shape_line), :509-567 (shape_text), crates/gpui/src/text_system/line.rs:24 (DecorationRun)`
- [ ] **paint_line: turning a layout plus decorations into primitives** — Zed `crates/gpui/src/text_system/line.rs:334-578, background variant at :580`
- [ ] **Scene primitive set and per-kind streams** — Zed `crates/gpui/src/scene.rs:41 (Scene), :222 (Primitive), :535 (Quad), :555 (Underline), :574 (Shadow), :711 (MonochromeSprite), :730 (SubpixelSprite), :749 (PolychromeSprite), :755 (Path), :768 (PaintSurface)`
- [ ] **Pixels -> ScaledPixels boundary and device-pixel snapping** — Zed `crates/gpui/src/window.rs:4296 (round_to_device_pixel), :4362 (origin.scale(scale_factor)), :4374 (integer origin), scene.rs:821 (Path::scale)`

**無い**

- [x] **The pooled LineWrapper** — Zed `crates/gpui/src/text_system.rs:307 (line_wrapper), :56 (wrapper_pool), :850 (LineWrapperHandle), crates/gpui/src/text_system/line_wrapper.rs`
- [ ] **Draw order, the layer stack, and the BoundsTree** — Zed `crates/gpui/src/scene.rs:43-44, :75 (push_layer), :87 (insert_primitive), :151 (finish)`
- [ ] **Batching: merging sorted streams into draw calls** — Zed `crates/gpui/src/scene.rs:172 (batches), :288-466 (BatchIterator)`
- [ ] **Hsla and alpha derivation** — Zed `crates/gpui/src/color.rs:334 (Hsla), :424 (hsla), :525 (to_rgb), :580 (blend), :607 (fade_out), :637 (opacity), :667 (alpha), :677 (From<Rgba>)`
- [ ] **Background: solid vs gradient vs pattern as one shader-visible tag** — Zed `crates/gpui/src/color.rs:779 (Background), :759 (ColorSpace), :851 (solid_background), :865 (linear_gradient), :827 (pattern_slash), :841 (checkerboard); used by scene.rs:535 (Quad.background) and :761 (Path.color)`
- [ ] **TextStyle and its refinement/highlight composition** — Zed `crates/gpui/src/style.rs:434 (TextStyle), :432 (#[derive(Refineable)]), :506 (highlight), :539 (font), :550 (line_height_in_pixels), :555 (to_run), :576 (HighlightStyle), :920 (HighlightStyle::highlight)`
- [ ] **UnderlineStyle / StrikethroughStyle and their snapped emission** — Zed `crates/gpui/src/style.rs:824 (UnderlineStyle), :839 (StrikethroughStyle); crates/gpui/src/window.rs:4280 (paint_underline), :4315 (paint_strikethrough)`

**移植済み**

- [x] Two-frame line layout cache with hash keys — Zed `crates/gpui/src/text_system/line_layout.rs:392 (LineLayoutCache), :398 (FrameCache), :497 (finish_frame), :577 (layout_line), :638/:694 (by-hash variants)`
- [x] Wrap boundary computation on the already-shaped glyph stream — Zed `crates/gpui/src/text_system/line_layout.rs:128 (compute_wrap_boundaries), :212 (WrappedLineLayout), :225 (WrapBoundary)`
- [x] Glyph rasterization key and subpixel quantization — Zed `crates/gpui/src/text_system.rs:44-48 (SUBPIXEL_VARIANTS_X/Y), :1023 (RenderGlyphParams), :324 (raster_bounds), :336 (rasterize_glyph); crates/gpui/src/window.rs:3954-3976`

設計判断 5/5 済

- [x] UI-100 Port Zed's text-layout layers without moving document state into platform — 実装済み
- [x] UI-105 Rounded selection first, as a shaped primitive rather than a path engine — 実装済み
- [x] UI-106 Font features and fallbacks as CTFont attributes — 実装済み
- [x] UI-109 Zed の Primitive は「形」で、Nimculus の PaintKind は「意味」で分かれている — 却下
- [x] UI-110 PolychromeSprite を入れて、まずカラー絵文字を描く — 実装済み


### 入力とアクション

メカニズム 2/17 済 — 一部のみ 8 / 無い 7

**一部のみ — 先に片付ける**

- [x] **KeyContext: the per-node context entry list** — Zed `crates/gpui/src/keymap/context.rs:10 (KeyContext), :14 (ContextEntry), :65 (parse), :117 (add), :126 (set), :137 (contains), :142 (get)`
- [x] **Keymap precedence resolution (bindings_for_input)** — Zed `crates/gpui/src/keymap.rs:164-242, sort at :187, binding_enabled at :245`
- [x] **The DispatchTree: per-frame node tree of contexts, focus ids and listeners** — Zed `crates/gpui/src/key_dispatch.rs:71 (DispatchTree), :83 (DispatchNode), :166 (push_node), :215 (set_key_context), :220 (set_focus_id), :226 (set_view_id), :323/:327/:333 (on_key_event / on_modifiers_changed / on_action)`
- [x] **dispatch_path / focus_path / focus_contains** — Zed `crates/gpui/src/key_dispatch.rs:563 (dispatch_path, root-to-focused), :574 (focus_path), :346 (focus_contains)`
- [x] **Capture/bubble phases for key and action listeners** — Zed `crates/gpui/src/window.rs:88 (DispatchPhase), :4999 (dispatch_key_down_up_event: capture root-to-focus, bubble focus-to-root, stopping when propagate_event is false), :5130 (dispatch_action_on_node_inner: global listeners first, then window capture, then bubble where `cx.propagate_event = false` is set *before* each bubble listener so actions stop propagation by default)`
- [x] **Synthetic keystrokes from modifier-only presses** — Zed `crates/gpui/src/window.rs:4815-4844 (a ModifiersChangedEvent that drops from exactly one modifier to zero without an intervening keystroke becomes a `shift`/`control`/`alt`/`platform`/`function` keystroke), crates/gpui/src/key_dispatch.rs:327 (modifiers_changed_listeners), window.rs:5030 (bubble-only dispatch of them)`
- [x] **FocusHandle / FocusId: refcounted, generation-safe focus identity** — Zed `crates/gpui/src/window.rs:304 (slotmap key FocusId), :469 (FocusHandle with tab_index and tab_stop), :466 (new, inserts into the FocusMap with a ref_count), :535 (for_id via atomic_incr_if_not_zero), :570 (downgrade to WeakFocusHandle), :457 (focus), :484 (dispatch_action from a handle)`
- [x] **Platform input event vocabulary** — Zed `crates/gpui/src/interactive.rs:762 (PlatformInput enum), :25/:47/:62 (KeyDown/KeyUp/ModifiersChanged), :139/:176/:485/:513 (mouse down/up/move/scroll), :281 (ClickEvent unifying mouse, keyboard and touch activation), :762/:790 (mouse_event/keyboard_event partition)`

**無い**

- [x] **Action as a type-erased, registered value** — Zed `crates/gpui/src/action.rs:117 (trait Action), :233 (ActionRegistry), :293 (insert_action), :351 (build_action)`
- [x] **NoAction / Unbind disable markers** — Zed `crates/gpui/src/action.rs:425-458, crates/gpui/src/keymap.rs:29 (disabled_binding_matches_context), :40 (binding_is_unbound), :195-225`
- [x] **KeyBinding: a keystroke *sequence* with prefix matching** — Zed `crates/gpui/src/keymap/binding.rs:10 (struct), :48 (load, splits on whitespace), :89 (match_keystrokes returning Option<bool> where the bool means "pending")`
- [ ] **Binding source metadata (user > vim > base > default)** — Zed `crates/gpui/src/keymap/binding.rs:143 (KeyBindingMetaIndex), crates/gpui/src/keymap.rs:199 (NoAction only breaks for user-sourced bindings), keymap.rs:831 (test documenting User 0 > Vim 1 > Base 2 > Default 3)`
- [ ] **Reverse lookup: bindings_for_action, with shadow filtering** — Zed `crates/gpui/src/keymap.rs:95 (bindings_for_action), crates/gpui/src/key_dispatch.rs:401 (bindings_for_action), :420 (highest_precedence_binding_for_action), :435 (binding_matches_predicate_and_not_shadowed)`
- [x] **Multi-keystroke pending state and replay** — Zed `crates/gpui/src/key_dispatch.rs:116 (Replay), :121 (DispatchResult with pending / pending_has_binding / bindings / to_replay), :483 (dispatch_key), :523 (flush_dispatch), :538 (replay_prefix); crates/gpui/src/window.rs:4868-4933 (pending buffer, focus invalidation, timeout)`
- [x] **available_actions / is_action_available for the command palette** — Zed `crates/gpui/src/key_dispatch.rs:363 (available_actions, walks the dispatch path collecting listener action types and building a default instance of each), :382 (is_action_available)`

**移植済み**

- [x] Context predicate language and depth_of — Zed `crates/gpui/src/keymap/context.rs:172 (enum), :249 (parse), :350 (parse_expr, precedence table :494-498), :277 (eval_inner), :260 (depth_of), :328 (is_superset)`
- [x] Tab stop ordering by (group path, tab index, insertion order) — Zed `crates/gpui/src/tab_stop.rs:11 (TabStopMap), :36 (TabStopPath), :40 (TabStopNode), :52 (Ord: path then insertion index), :78 (insert appends the handle's tab_index to the current group path), :92/:98 (begin_group/end_group), :111 (next, wraps to first, skips non-tab_stop nodes), :148 (prev), :185 (replay)`

設計判断 4/4 済

- [x] UI-005 One focused pane defines the complete macOS IME document context — 実装済み
- [x] UI-104 Port Zed's ongoing-scroll axis lock, not its touch gestures — 実装済み
- [x] UI-107 Context-dependent key dispatch, and the `when` clause already being parsed — 実装済み
- [x] UI-108 Tab-order focus traversal, and the fact that Tab is not bound to it — 実装済み


### デザインシステム

メカニズム 0/16 済 — 一部のみ 9 / 無い 7

**一部のみ — 先に片付ける**

- [x] **Semantic colour token enum** — Zed `crates/ui/src/styles/color.rs:19 (enum), :90 (Color::color)`
- [x] **Size scale as a pure table** — Zed `crates/ui/src/components/button/button_like.rs:455 (ButtonSize), :465 (rems); crates/ui/src/components/icon.rs:54 (IconSize), :70 (rems), :86 (square_components); crates/ui/src/styles/typography.rs:93 (TextSize), :132 (rems/pixels); crates/ui/src/components/label/label_like.rs:7 (LabelSize)`
- [x] **Elevation -> shadow stack and background** — Zed `crates/ui/src/styles/elevation.rs:14 (ElevationIndex), :42 (shadow), :84 (bg), :95 (on_elevation_bg), :108 (darker_bg); crates/ui/src/traits/styled_ext.rs:6 (elevated), :45 elevation_1, :62 elevation_2, :83 elevation_3`
- [x] **Component-instance identity and state** — Zed `crates/ui/src/components/button/button_like.rs:484 (ElementId), :512 (focus_handle), :745 render; crates/ui/src/components/context_menu.rs:211 (ContextMenu as an Entity with focus_handle, selected_index, subscriptions)`
- [x] **Label rendering: size, weight, truncation mode** — Zed `crates/ui/src/components/label/label_like.rs:7 (LabelSize), :23 (LineHeightStyle), :34 (LabelCommon), :233 (render)`
- [x] **Menu item model separated from menu rendering** — Zed `crates/ui/src/components/context_menu.rs:46 (ContextMenuItem enum), :82 (ContextMenuEntry), :211 (ContextMenu state), :1459 (render_menu_item), :2180 (render, submenu offset + aside)`
- [x] **Scrollbar geometry and visibility policy** — Zed `crates/ui/src/components/scrollbar.rs:352 (ScrollbarStyle), :373 to_pixels (Regular 6px / Editor 15px), :275 (ShowBehavior::Always/Autohide/Never from setting), :1000 (ScrollableHandle trait), :1039 (ScrollbarLayout), :1049 compute_click_offset`
- [x] **Divider** — Zed `crates/ui/src/components/divider.rs:19 (DividerColor), :37 (struct), :96 render_solid, :100 render_dashed`
- [x] **Tooltip container as shared chrome** — Zed `crates/ui/src/components/tooltip.rs:216 (tooltip_container), :194 (Tooltip::render), :9 (struct: title, meta, key_binding)`

**無い**

- [x] **Style × state -> concrete style resolution** — Zed `crates/ui/src/components/button/button_like.rs:125 (ButtonStyle), :190 (ButtonLikeStyles), :210 enabled(), :257 hovered(), plus active()/disabled() through :448`
- [ ] **Density-aware spacing scale** — Zed `crates/ui/src/styles/spacing.rs:29-44 (derive_dynamic_spacing! table), :52 (ui_density)`
- [ ] **Builder traits shared across components** — Zed `crates/ui/src/traits/clickable.rs:4, disableable.rs:2, toggleable.rs:5, fixed.rs, visible_on_hover.rs; crates/ui/src/components/button/button_like.rs:12 (SelectableButton), :17 (ButtonCommon)`
- [ ] **Icon source abstraction and square hit box** — Zed `crates/ui/src/components/icon.rs:131 (IconSource), :145 (Icon), :86 (square_components), :102 (square)`
- [ ] **ListItem slot layout** — Zed `crates/ui/src/components/list/list_item.rs:10 (ListItemSpacing), :26 (struct), :292 (render), :404 (disclosure at left:-1rem), :442 (EndSlotVisibility Always/OnHover/SwapOnHover)`
- [ ] **Keybinding display** — Zed `crates/ui/src/components/keybinding.rs:46 (KeyBinding), :63 for_action, :200 render, :252 render_keybinding_keystroke, :411 (Key), :457 (KeyIcon)`
- [x] **Tri-state toggle** — Zed `crates/ui/src/traits/toggleable.rs:12 (ToggleState), :26 inverse, :34 from_any_and_all; crates/ui/src/components/toggle.rs:43 (Checkbox), :181 container_size, :338 (Switch), :328 (SwitchLabelPosition)`

設計判断 13/14 済

- [x] UI-012 Shared native sidebar keeps panel-level visual hierarchy — 実装済み
- [x] UI-030 Workspace navigation owns explicit contrast — 実装済み
- [x] UI-031 Git navigation uses explicit native button states — 実装済み
- [x] UI-033 Git controls preserve labels at narrow dock widths — 実装済み
- [x] UI-037 Files creation actions use explicit dark-theme contrast — 実装済み
- [x] UI-082 Adopt Zed One themes and a single comfortable editor line metric — 実装済み
- [x] UI-083 Use Zed One terminal palettes as the native terminal source of truth — 実装済み
- [x] UI-091 Use one Zed-style picker surface for Command Palette and Quick Open — 実装済み
- [x] UI-095 Use Zed search glyph geometry and one find-row baseline — 実装済み
- [x] UI-112 焼き込まれた色補正 `#fafafa` → `#fcfcfc` は、AppKit と Metal の色管理差の症状 — 実装済み
- [x] UI-122 罫線の色が観測値になっていた（高さの指摘は私の測定ミス） — 実装済み
- [ ] UI-131 ステータスバーのアイコンが Zed より大きい — 調査のみ
- [x] UI-145 Keep the native Files selection row readable while inactive — 実装済み
- [x] UI-153 Clone Zed's Project Panel presentation in the native Files dock — 実装済み


### ワークスペース

メカニズム 3/19 済 — 一部のみ 12 / 無い 4

**一部のみ — 先に片付ける**

- [ ] **Panel trait (what a dock can contain)** — Zed `crates/workspace/src/dock.rs:36`
- [x] **Dock container: open bit, active panel index, per-panel size state** — Zed `crates/workspace/src/dock.rs:269`
- [ ] **Dock resize handle geometry and double-click reset** — Zed `crates/workspace/src/dock.rs:1132 (Render for Dock), handle placement at dock.rs:1124-1150`
- [ ] **PanelButtons (the status-bar dock toggles)** — Zed `crates/workspace/src/dock.rs:356, Render at dock.rs:1252, StatusItemView at dock.rs:1449`
- [ ] **Item trait (what a tab knows how to be)** — Zed `crates/workspace/src/item.rs:170`
- [ ] **Tab detail disambiguation** — Zed `crates/workspace/src/pane.rs:4965 tab_details, called from render_tab_bar at pane.rs:3400`
- [x] **Pane: item list, active index, activation history, pinned prefix, preview item** — Zed `crates/workspace/src/pane.rs:398`
- [x] **Pane split tree (Member / PaneAxis with flexes)** — Zed `crates/workspace/src/pane_group.rs:294 Member, :648 PaneAxis, PaneAxis::split at pane_group.rs:694`
- [ ] **Tab bar rendering (tabs, nav buttons, pinned row, drop targets)** — Zed `crates/workspace/src/pane.rs:3396 render_tab_bar, per-tab at pane.rs:2825 render_tab, drop target at pane.rs:3626`
- [ ] **Item toolbar / breadcrumb slot** — Zed `crates/workspace/src/toolbar.rs:64 Toolbar, ToolbarItemLocation at toolbar.rs:56; Item side at item.rs:343 breadcrumb_location, :347 breadcrumbs`
- [x] **Workspace serialization (DockStructure + pane tree + items)** — Zed `crates/workspace/src/persistence/model.rs:153 DockStructure, :203 DockData, :234 SerializedPaneGroup, :339 SerializedPane, :424 SerializedItem; writer at workspace.rs:7075 serialize_workspace_internal`
- [ ] **Serialization throttle** — Zed `crates/workspace/src/workspace.rs:7058 serialize_workspace`

**無い**

- [x] **PanelHandle (object-safe erasure of Panel)**（意図的な差異 / UI-157） — Zed `crates/workspace/src/dock.rs:98`
- [ ] **Panel size persistence and dock zoom** — Zed `crates/workspace/src/dock.rs:375 PANEL_SIZE_STATE_KEY, dock.rs:564 set_panel_zoomed, workspace.rs:4163 toggle_dock`
- [ ] **Nav history (back/forward across items)** — Zed `crates/workspace/src/pane.rs:471 NavHistory / :474 NavHistoryState, navigate_backward at pane.rs:929`
- [x] **Pane render policy hooks (should_display_tab_bar, render_tab_bar_buttons)**（意図的な差異 / UI-158） — Zed `crates/workspace/src/pane.rs:421-431`

**移植済み**

- [x] DockPosition and its axis — Zed `crates/workspace/src/dock.rs:290, axis() at dock.rs:335`
- [x] Pane group layout: divider placement and per-pane floor — Zed `crates/workspace/src/pane_group.rs:648 PaneAxis (bounding_boxes), constants at pane_group.rs:3-5`
- [x] Workspace root layout (titlebar / docks+center / status bar) — Zed `crates/workspace/src/workspace.rs:8984 Render for Workspace, dock wrapper at workspace.rs:8080 render_dock`

設計判断 50/55 済

- [x] UI-002 Own workspace layout as application state before rendering it — 実装済み
- [x] UI-003 Persist workspace composition as scalar session state — 実装済み
- [x] UI-004 PaneTree is the canonical pane-geometry owner — 実装済み
- [x] UI-006 Dock list selection is application state, not a text-overlay side effect — 実装済み
- [x] UI-007 Files Dock opens into the focused pane — 実装済み
- [x] UI-008 Tab presentation and activation are pane-local — 実装済み
- [x] UI-009 Close requests resolve through the focused Pane — 実装済み
- [x] UI-010 Empty editor panes expose a native welcome surface — 実装済み
- [x] UI-021 Every document tab exposes its close target — 実装済み
- [x] UI-024 The workspace header contains real navigation — 実装済み
- [x] UI-025 Persistent workspace navigation shows its active destination — 実装済み
- [x] UI-027 A left activity bar owns persistent workspace destinations — 置換
- [x] UI-028 Pane chrome exposes the current split action — 実装済み
- [x] UI-032 Background file refresh never replaces the active panel — 実装済み
- [x] UI-035 Git tab selection maps behavior, not enum order — 実装済み
- [x] UI-036 Document tabs never paint past the editor edge — 置換
- [x] UI-038 Many document tabs retain readable labels — 実装済み
- [x] UI-039 Status messages and cursor position are distinct fields — 実装済み
- [x] UI-041 Persist the secondary pane item separately from the primary tab — 実装済み
- [x] UI-043 Expose both supported split axes through the macOS UI — 実装済み
- [x] UI-045 Bind native Save Panels to their initiating tab — 実装済み
- [x] UI-050 Navigation commands follow the focused split pane — 実装済み
- [x] UI-055 Bound navigation lists at the presentation boundary — 実装済み
- [x] UI-060 Invert resize coordinates for the macOS right Project dock — 実装済み
- [x] UI-061 Keep editor-tab actions at the tab that invoked them — 実装済み
- [x] UI-063 Pinning is tab order, not a transient decoration — 実装済み
- [x] UI-064 Reopen closed tabs from paths, never discarded buffers — 実装済み
- [x] UI-065 Drag reordering does not implicitly change a pin — 実装済み
- [x] UI-067 Constrain native editor overlays to their owning pane — 実装済み
- [x] UI-068 Preserve usable workspace and pane minimum sizes — 実装済み
- [x] UI-070 Let a narrowed workspace collapse native sidebar presentation — 実装済み
- [x] UI-071 Do not reserve a second macOS titlebar in workspace content — 実装済み
- [x] UI-073 An open workspace replaces the launch welcome surface — 実装済み
- [x] UI-075 Filesの選択identityはアクティブ文書のcanonical pathで再解決する — 実装済み
- [x] UI-077 ワークスペースの空エディタはWelcomeを表示しFilesを残す — 実装済み
- [x] UI-078 macOS workspace presenters are single-row and pane-clipped — 実装済み
- [x] UI-090 Port Zed's status-bar order and summaries — 置換
- [x] UI-092 Replace the left activity rail with Zed-style status-bar panel buttons — 置換
- [x] UI-093 Condense the status-bar dock controls to a Zed-style left cluster — 実装済み
- [x] UI-096 Keep footer status semantics text-only and remove dead breadcrumb actions — 実装済み
- [x] UI-097 Group the terminal toggle with the status-bar dock controls — 置換
- [x] UI-113 ステータスバーの項目は Zed の既定表示条件に従う — 実装済み
- [ ] UI-114 ステータスバー左側の 7 項目（未着手） — 調査のみ
- [ ] UI-115 診断サマリーを Zed の判定と一致させる — 一部
- [x] UI-116 検索ボタンの文言と設定 — 実装済み
- [x] UI-117 ステータスバーの左右の振り分けは、ドックの位置で決まる — 実装済み
- [ ] UI-118 パネルが自分の位置を持つ構造（UI-117 の 4 番目） — 一部
- [x] UI-119 設定が変わったときのパネルの引き取り直し（UI-118 の 5） — 実装済み
- [x] UI-120 git blame をステータスバーに出す（UI-114 の 3） — 実装済み
- [x] UI-127 アクティビティインジケータの表示（UI-126 の 6） — 実装済み
- [x] UI-128 パンくずのシンボルは構文の色で描く — 実装済み
- [x] UI-130 セッションが無いときドックを開かない — 実装済み
- [ ] UI-132 タイトルバーの中身が違う — 一部
- [ ] UI-133 フォルダを開いた条件で出た差 — 調査のみ
- [x] UI-144 Synchronize the selected tab at the session/UI composition boundary — 実装済み


### エディタ: モデル

メカニズム 1/19 済 — 一部のみ 11 / 無い 7

**一部のみ — 先に片付ける**

- [ ] **DisplayPoint / DisplayRow — the coordinate space the renderer paints in** — Zed `crates/editor/src/display_map.rs:2525 (DisplayPoint(BlockPoint)), :2555 (DisplayRow), :2675 (DisplayPointConverter)`
- [ ] **Inlay layer** — Zed `crates/editor/src/display_map/inlay_map.rs:34 (InlayMap), :40 (InlaySnapshot), :574 (sync)`
- [ ] **Fold layer and creases** — Zed `crates/editor/src/display_map/fold_map.rs:360 (FoldMap), :680 (FoldSnapshot), :1225 (Fold), :1232 (FoldRange over Anchors), :27 (FoldPlaceholder); crates/editor/src/display_map/crease_map.rs:15`
- [ ] **Soft wrap layer with background rewrap** — Zed `crates/editor/src/display_map/wrap_map.rs:32 (WrapMap with pending_edits, interpolated_edits, background_task), :43 (WrapSnapshot), :146 (sync)`
- [ ] **SelectionsCollection: disjoint anchored selections plus a pending one** — Zed `crates/editor/src/selections_collection.rs:26 (SelectionsCollection), :20 (PendingSelection), :560 change_with, :992 move_with, :1041 move_heads_with`
- [ ] **Anchor-based scroll position** — Zed `crates/editor/src/scroll.rs:38 (ScrollAnchor {anchor, offset}), :305 ScrollManager::scroll_position, :51 ScrollAnchor::scroll_position`
- [ ] **Autoscroll strategies** — Zed `crates/editor/src/scroll/autoscroll.rs:16 (enum Autoscroll), :100 (AutoscrollStrategy), :127 autoscroll_vertically, :345 autoscroll_horizontally; request queued on ScrollManager at scroll.rs:169`
- [ ] **ScrollAmount: line / page / column / page-width** — Zed `crates/editor/src/scroll/scroll_amount.rs:19 (enum ScrollAmount), :30 lines(), :46 columns(), :53 pixels()`
- [ ] **Scrollbar geometry and thumb state** — Zed `crates/editor/src/scroll.rs:165 (ScrollbarThumbState), :161 (ActiveScrollbarState), :438 show_scrollbars, SCROLLBAR_SHOW_INTERVAL at :31`
- [ ] **Edit transactions grouped with selection history** — Zed `crates/editor/src/editor.rs:8286 transact, :8392 start_transaction_at, :8414 end_transaction_at, :1394 SelectionHistory, :1297 SelectionHistoryMode`
- [ ] **Highlight layering on top of the transform chain** — Zed `crates/editor/src/display_map.rs:229 (text_highlights, inlay_highlights, semantic_token_highlights fields), :161 (HighlightKey), :334 (HighlightStyleInterner), :1408 (HighlightedChunk); custom_highlights.rs:30`

**無い**

- [ ] **MultiBuffer: N buffers presented as one text** — Zed `crates/multi_buffer/src/multi_buffer.rs:73 (struct MultiBuffer), :691 (MultiBufferSnapshot), :842 (ExcerptRange)`
- [ ] **Anchor: an edit-surviving position** — Zed `crates/multi_buffer/src/anchor.rs:17 (ExcerptAnchor), :28 (enum Anchor {Min, Excerpt, Max})`
- [ ] **The five-layer transform chain (inlay → fold → tab → wrap → block)** — Zed `crates/editor/src/display_map.rs:1 (module doc describing the contract), :213 (DisplayMap fields), :604 (snapshot() driving the chain)`
- [ ] **Tab expansion layer** — Zed `crates/editor/src/display_map/tab_map.rs:20 (TabMap), :197 (TabSnapshot with tab_size and max_expansion_column), :41 (sync)`
- [ ] **Block layer: non-text rows and replacement blocks** — Zed `crates/editor/src/display_map/block_map.rs:38 (BlockMap), :75 (BlockSnapshot), :163 (BlockPlacement Above/Below/Near/Replace), :377 (enum Block: Custom, FoldedBuffer, ExcerptBoundary, BufferHeader, Spacer), :282 (BlockProperties), :303 (BlockStyle)`
- [ ] **Invisible character rendering** — Zed `crates/editor/src/display_map/invisibles.rs:34 is_invisible, :49 replacement, :75 FORMAT, :100 OTHER, :114 PRESERVE`
- [ ] **EditorMode: one Editor type, several shapes** — Zed `crates/editor/src/editor.rs:464 (enum EditorMode: SingleLine, AutoHeight, Full, Minimap)`

**移植済み**

- [x] OngoingScroll axis locking — Zed `crates/editor/src/scroll.rs:16 (OngoingScroll), :297 (filter_scroll_delta), SCROLL_EVENT_SEPARATION moved to crates/gpui/src/gestures.rs:17`

設計判断 14/14 済

- [x] UI-040 Split panes own independent syntax buffers — 実装済み
- [x] UI-074 macOS新規エディタはソフトラップを既定で有効にする — 置換
- [x] UI-076 未折返し編集は主・副ペイン共通の横スクロール境界を使う — 実装済み
- [x] UI-079 Make unwrapped editor scrolling Zed-compatible — 実装済み
- [x] UI-080 Expose syntax selection expansion through the macOS editor — 実装済み
- [x] UI-099 Preserve the fractional editor scroll phase — 実装済み
- [x] UI-142 Keep split-pane viewport calculations local — 実装済み
- [x] UI-143 Make multi-selection a user-visible editor feature — 実装済み
- [x] UI-147 Reconstruct syntax siblings from Tree-sitter ranges — 実装済み
- [x] UI-148 Keep syntax folding as an item-owned display map — 実装済み
- [x] UI-149 Derive structural brackets from the syntax snapshot — 実装済み
- [x] UI-150 Keep fold commands semantically separate — 実装済み
- [x] UI-151 Use a continuous macOS editor scroll position — 実装済み
- [x] UI-152 Keep wheel scrolling independent from cursor visibility — 実装済み


### エディタ: 描画

メカニズム 2/24 済 — 一部のみ 13 / 無い 8 / 不明 1

**一部のみ — 先に片付ける**

- [ ] **GutterDimensions — the gutter geometry contract** — Zed `crates/editor/src/editor.rs:1246 (struct), crates/editor/src/editor.rs:11562 (EditorSnapshot::gutter_dimensions), crates/editor/src/fold.rs:5 (fold_area_width)`
- [ ] **layout_line_numbers — number choice, colour, placement, hit target** — Zed `crates/editor/src/element.rs:2727; LineNumberStyle at crates/editor/src/element.rs:115-141`
- [ ] **LineWithInvisibles::from_chunks — the line shaping pipeline** — Zed `crates/editor/src/element.rs:7013 (struct), crates/editor/src/element.rs:7071 (from_chunks), crates/editor/src/element.rs:7047 (enum LineFragment)`
- [ ] **x_for_index / index_for_x / alignment_offset — line-local pixel↔column mapping** — Zed `crates/editor/src/element.rs:7661, crates/editor/src/element.rs:7690, crates/editor/src/element.rs:7745`
- [ ] **calculate_wrap_width — soft wrap mode to a pixel width** — Zed `crates/editor/src/element.rs:10624, consumed at crates/editor/src/element.rs:8023 and :10672`
- [ ] **layout_selections + active_rows** — Zed `crates/editor/src/element.rs:767, SelectionLayout at crates/editor/src/element.rs:142 and :159`
- [ ] **CursorLayout — shape, bounds, block glyph, collaborator name** — Zed `crates/editor/src/element.rs:10318 (struct), crates/editor/src/element.rs:10362 (bounds), crates/editor/src/element.rs:10421 (paint); construction at crates/editor/src/element.rs:1001 (layout_visible_cursors)`
- [ ] **GitBlame entity — blame kept in sync with edits** — Zed `crates/editor/src/git/blame.rs:75 (struct GitBlame), :305 (blame_for_rows), :368 (sync), :505 (generate), :681 (regenerate_on_edit), :697 (build_blame_entry_sum_tree)`
- [ ] **The prepaint→paint split and EditorLayout** — Zed `crates/editor/src/element.rs:7954 (prepaint), :9632 (struct EditorLayout), :9431 (paint)`
- [ ] **paint_background — active line and highlighted rows** — Zed `crates/editor/src/element.rs:4890`
- [ ] **items.rs tab_content — the tab label element** — Zed `crates/editor/src/items.rs:751; MAX_TAB_TITLE_LEN=24 at items.rs:66; entry_git_aware_label_color at items.rs:2205; entry_label_color at items.rs:2177`
- [ ] **breadcrumbs — segments from the editor, rendering from the element** — Zed `crates/editor/src/items.rs:1074 (breadcrumb_location), :1078 (breadcrumbs), :1094 (breadcrumb_prefix); crates/editor/src/element.rs:6752 (render_breadcrumb_text), :6909 (apply_dirty_filename_style)`
- [ ] **Editor blame lifecycle and inline-blame gating** — Zed `crates/editor/src/git.rs:511 (git_blame_inline_enabled), :549 (show_git_blame_gutter), :564 (toggle_git_blame), :579 (toggle_git_blame_inline), :597 (hide_blame_popover), :949 (show_blame_hover_popover), :2148 (start_git_blame)`

**無い**

- [x] **gutter_strip_width — the diff change-bar width** — Zed `crates/editor/src/element.rs:5309`
- [x] **diff_hunk_bounds — hunk vertical extent in gutter space** — Zed `crates/editor/src/element.rs:5313`
- [ ] **Diff hunk painting: colour by kind, hollow for unstaged** — 色は済（テーマの added/modified/deleted から引く、UI-134）。**hollow が未着手** — Zed `crates/editor/src/element.rs:5210 (paint_gutter_diff_hunks), crates/editor/src/element.rs:6596 (diff_hunk_hollow)`
- [ ] **ScrollbarLayout — thumb sizing and marker quads** — Zed `crates/editor/src/element.rs:9787 (struct), crates/editor/src/element.rs:9904 (new_with_hitbox_and_track_length), crates/editor/src/element.rs:9931 (thumb_bounds), crates/editor/src/element.rs:9990 (marker_quads_for_ranges); layout at crates/editor/src/element.rs:1285, paint at :5755`
- [ ] **layout_blame_entries — the gutter blame column** — Zed `crates/editor/src/element.rs:2197; width reservation in crates/editor/src/editor.rs:11672-11598 (git_blame_entries_width)`
- [ ] **BlameRenderer — blame presentation as an injectable global** — Zed `crates/editor/src/git/blame.rs:88 (trait), :158 (unit impl returning None), :194 (GlobalBlameRenderer)`
- [ ] **DiffHunkDelegate — per-editor-kind hunk affordances** — Zed `crates/editor/src/git.rs:23 (trait), :84 UncommittedDiffHunkDelegate, :164 RestoreOnlyDiffHunkDelegate, :211 RestoreOnlyUnstagedDiffHunkDelegate; render_hunk_as_staged at :79`
- [x] **path_for_buffer — detail-level path disambiguation** — Zed `crates/editor/src/items.rs:2222 (path_for_buffer), :2227 (path_for_file)`

**不明（読めていない）**

- [ ] PositionMap::point_for_position — pixels to a clipped DisplayPoint — Zed `crates/editor/src/element.rs:10075 (struct PositionMap), crates/editor/src/element.rs:10142`（まず読む）

**移植済み**

- [x] HighlightedRange::paint — the rounded multi-line selection shape — Zed `crates/editor/src/element.rs:10457 (struct), crates/editor/src/element.rs:10471 (impl), crates/editor/src/element.rs:10521 (paint_lines)`
- [x] layout_inline_blame — x placement of the end-of-line blame text — Zed `crates/editor/src/element.rs:2008`

設計判断 9/10 済

- [x] UI-044 Render Git hunks from each visible pane's document — 実装済み
- [x] UI-081 Make editor and project-panel chrome share hard Zed-style edges — 実装済み
- [x] UI-087 Clip every editor overlay in the same local text viewport — 実装済み
- [x] UI-089 Synchronize editor horizontal scrolling before retained paint — 実装済み
- [x] UI-094 Make editor chrome container-owned and overlay-safe — 実装済み
- [x] UI-098 Match Zed's singleton editor gutter geometry — 実装済み
- [x] UI-121 行内 blame（カーソル行の行末に出す） — 実装済み
- [x] UI-124 Markdown 見出しの色が観測値のせいでテーマから離れている — 実装済み
- [ ] UI-134 ガターの変更バー（UI-133 の 4） — 調査のみ
- [x] UI-155 Snap editor rows and wrap width to Zed's pixel contract — 実装済み


### プロジェクト層

メカニズム 2/16 済 — 一部のみ 9 / 無い 4 / 不明 1

**一部のみ — 先に片付ける**

- [ ] **Worktree snapshot + background scanner with scan ids** — Zed `crates/worktree/src/worktree.rs:176 (Snapshot), :249 (LocalSnapshot), :270 (BackgroundScannerState), :410 (enum ScanState), :4295 (BackgroundScanner), :4304 (BackgroundScannerPhase)`
- [ ] **Repository as an entity with a snapshot + a serialized job queue** — Zed `crates/project/src/git_store.rs:505 (struct Repository), :430 (RepositorySnapshot), :636 (GitJob), :643 (enum GitJobKey), :527 (Deref<Target=RepositorySnapshot>)`
- [ ] **Anchored diff hunks with secondary (staged) status** — Zed `crates/buffer_diff/src/buffer_diff.rs:117 (DiffHunk: range as Points, buffer_range as Anchors, diff_base_byte_range, secondary_status, word diffs), :87 (DiffHunkStatus), :85 (DiffHunkSecondaryStatus with the 5 states incl. the two Pending ones), :142 (PendingHunk), :440 hunks_in_row_range`
- [ ] **Git status scan → panel projection (staged / unstaged / conflicts)** — Zed `crates/project/src/git_store.rs:326 (StatusEntry), :395 (impl sum_tree::Item so statuses roll up per directory), crates/git/src/status.rs:10 (FileStatus), :31 (TrackedStatus: index_status + worktree_status), :351 (GitSummary)`
- [ ] **Blame: entries by line range, plus batch commit-message fetch** — Zed `crates/git/src/blame.rs:17 (struct Blame: entries, messages by Oid, tag_names by Oid), :164 (BlameEntry: sha, range: Range<u32>, original_line_number, author/committer fields, summary), :29-58 (unique SHAs then one batched get_messages/get_tag_names); crates/project/src/git_store.rs:1967 blame_buffer`
- [x] **Per-buffer LSP request keying and cancellation** — Zed `crates/project/src/lsp_store.rs:4098 (BufferLspData: buffer_version, per-feature caches, lsp_requests: HashMap<LspKey, HashMap<LspRequestId, Task<()>>>), :4265 (LspKey = request TypeId + server id), :4291-4208 remove_server_data`
- [ ] **Buffer→server document synchronization with snapshot history for incremental didChange** — Zed `crates/project/src/lsp_store.rs:8534 on_buffer_edited (:8568-8470 builds incremental changes from edits_since against the last snapshot), :331 (buffer_snapshots: buffer_id → server_id → Vec<LspBufferSnapshot>), :14165 (LspBufferSnapshot), :246 (OpenLspBufferHandle — refcounted 'this buffer is open in servers'), :328 (registered_buffers: BufferId → count)`
- [x] **Diagnostics storage, per-path grouping and per-worktree summaries** — Zed `crates/project/src/lsp_store.rs:320-330 (LocalLspStore.diagnostics: WorktreeId → RelPath → Vec<(server_id, entries)>), :4181 (LspStore.diagnostic_summaries same shape → DiagnosticSummary), :14835 (DiagnosticSummary::new counts only is_primary entries), :4166 (LspStoreEvent::DiagnosticsUpdated{server_id, paths})`
- [ ] **Multi-root workspace with per-root ignore stacks** — Zed `crates/project/src/worktree_store.rs:352 worktrees / :432 visible_worktrees / :773 create_worktree; crates/worktree/src/worktree.rs:255 (ignores_by_parent_abs_path), :208 (enum WorkDirectory InProject/AboveProject)`

**無い**

- [ ] **Store composition + event re-emission (Project as hub)** — Zed `crates/project/src/project.rs:214 (struct Project), :335 (enum Event), :1201-1329 (cx.subscribe wiring), :3603 on_buffer_store_event, :3660 on_lsp_store_event, :3906 on_worktree_store_event`
- [ ] **Entry identity: ProjectEntryId, inode-based rename detection** — Zed `crates/worktree/src/worktree.rs:3896 (struct Entry, fields id/inode/mtime/is_ignored/is_hidden/is_private/is_external), :292 (RemovedEntries with by_inode and by_path)`
- [ ] **Per-buffer diff bases (head text / index text) and diff recalculation** — Zed `crates/project/src/git_store.rs:170 (BufferGitState: head_text, index_text, head_text_buffer, index_text_buffer, head_changed, index_changed), :193 (DiffBasesChange), :204 (DiffKind), :4725 (recalculate_diffs)`
- [ ] **Language server lifecycle: Starting/Running state and the seed key that decides identity** — Zed `crates/project/src/lsp_store.rs:14312 (enum LanguageServerState Starting{startup task, pending_workspace_folders} / Running{adapter, server, ...}), :267 (LanguageServerSeed: worktree_id + name + toolchain + settings), :261 (UnifiedLanguageServer with project_roots), :367 get_or_insert_language_server`

**不明（読めていない）**

- [ ] Buffer store: open-by-path deduplication and load coalescing — Zed `crates/project/src/buffer_store.rs:34 (BufferStore: loading_buffers, opened_buffers, path_to_buffer_id), :859 open_buffer, :964 add_buffer, :1049 get_by_path, :78 (LocalBufferStore.local_buffer_ids_by_entry_id), :89 (BufferStoreEvent incl. BufferChangedFilePath)`（まず読む）

**移植済み**

- [x] Work-done progress aggregation into a single activity string — Zed `crates/project/src/lsp_store.rs:14368 (LanguageServerProgress: is_disk_based_diagnostics_progress, title, message, percentage, last_update_at), :4242 (LanguageServerStatus.pending_work: BTreeMap<ProgressToken, ...>), :188 (enum ProgressToken)`
- [x] Off-thread work with a main-thread completion boundary — Zed `crates/project/src/git_store.rs:512-545 (LocalRepositoryState::new using cx.background_spawn), crates/worktree/src/worktree.rs:424 (UpdateObservationState channels), :410 (ScanState delivered over an UnboundedSender)`

設計判断 9/9 済

- [x] UI-011 Git panel resolves workspace context without an open document — 実装済み
- [x] UI-029 Git panel resolves its branch asynchronously — 実装済み
- [x] UI-042 Keep LSP document lifetimes and diagnostic buffers pane-local — 実装済み
- [x] UI-046 Keep Git history bound to its source repository — 実装済み
- [x] UI-056 Scope folder search through the workspace path resolver — 実装済み
- [x] UI-057 Never signal a shared process group from a UI cancellation action — 実装済み
- [x] UI-126 LSP の `$/progress`（アクティビティインジケータの前提） — 実装済み
- [x] UI-129 長時間の git ジョブ（アクティビティインジケータの源 4） — 却下
- [x] UI-146 Keep Outline useful before LSP symbols arrive — 実装済み


### 機能 crate

メカニズム 3/23 済 — 一部のみ 13 / 無い 6 / 不明 1

**一部のみ — 先に片付ける**

- [ ] **Panel trait / dock contract** — Zed `crates/workspace/src/dock.rs:36 (trait Panel), :106 (PanelHandle), :284 (DockPosition)`
- [x] **Panel persistence identity (persistent_name)** — Zed `crates/project_panel/src/project_panel.rs:7607, crates/outline_panel/src/outline_panel.rs:4955, crates/terminal_view/src/terminal_panel.rs:1625`
- [x] **Startup panel construction** — Zed `crates/zed/src/zed.rs:775 initialize_panels, :874 initialize_agent_panel`
- [ ] **Outline panel** — Zed `crates/outline_panel/src/outline_panel.rs:653 init, :4954 impl Panel`
- [ ] **Git panel / git integration** — Zed `crates/git_ui/src/git_panel.rs:8267 impl Panel (crate is 44979 lines over 32 files)`
- [ ] **Agent panel / agent runtime** — Zed `crates/agent_ui/src/agent_panel.rs:371 init, :4946 impl Panel; crates/agent (85010 lines, 56 files)`
- [ ] **Debugger panel / DAP client** — Zed `crates/debugger_ui/src/debugger_panel.rs:1472 impl Panel; crates/dap (2800 lines), initialised at crates/zed/src/main.rs:593`
- [ ] **Search: buffer search bar vs project search item** — Zed `crates/search/src/search.rs:1-247 plus buffer_search.rs, project_search.rs, search_bar.rs, text_finder.rs (crate 12698 lines)`
- [ ] **Extension host (wasm) and extension store UI** — Zed `crates/extension_host/src/extension_host.rs (1995 lines), crates/extensions_ui/src/extensions_ui.rs (2096), registered at crates/zed/src/main.rs:526 and :663`
- [ ] **Picker: one modal, many delegates** — Zed `crates/picker/src/picker.rs (1898 lines); delegates in file_finder/src/file_finder.rs:1, command_palette/src/command_palette.rs:1, tab_switcher, outline, project_symbols, theme_selector, language_selector, toolchain_selector, recent_projects, go_to_line`
- [ ] **Diagnostics as a multibuffer Item** — Zed `crates/diagnostics/src/diagnostics.rs (1154 lines), init at crates/zed/src/main.rs:734`
- [ ] **Task templates and spawn UI** — Zed `crates/tasks_ui/src/tasks_ui.rs (625 lines), init at crates/zed/src/main.rs:747; model in crates/task`
- [ ] **Status bar, title bar, breadcrumbs, activity indicator** — Zed `crates/title_bar/src/title_bar.rs (1446 lines), crates/breadcrumbs (127), crates/activity_indicator (781), crates/notifications (684)`

**無い**

- [ ] **Crate init() registration order** — Zed `crates/zed/src/main.rs:491-771`
- [x] **Settings UI (schema-driven)** — Zed `crates/settings_ui/src/settings_ui.rs (6797 lines) with page_data.rs, pages/, components/`
- [ ] **Vim modal editing as an editor addon** — Zed `crates/vim/src/vim.rs:286 init (crate 47454 lines, 39 files); registered after editor at crates/zed/src/main.rs:761`
- [ ] **Collaboration (collab, collab_ui, call, channel, livekit)** — Zed `crates/collab_ui/src/collab_ui.rs (62 lines entry; crate 6392, collab server 15013), init at crates/zed/src/main.rs:749 (channel) and :771 (call)`
- [ ] **REPL / notebook** — Zed `crates/repl/src/repl.rs:31 init (crate 12400 lines), notebook initialised separately at crates/zed/src/main.rs:733`
- [ ] **Auxiliary viewers (image_viewer, markdown_preview, svg_preview, csv_preview)** — Zed `crates/image_viewer (1050 lines), crates/markdown_preview (2609), init at crates/zed/src/main.rs:732`

**不明（読めていない）**

- [ ] Unified sidebar (newer container) — Zed `crates/sidebar/src/sidebar.rs (8441 lines, 3 files, 23736 total)`（まず読む）

**移植済み**

- [x] Project panel (file tree) — Zed `crates/project_panel/src/project_panel.rs:464 init, :7567 impl Panel`
- [x] Terminal (model) and terminal panel (view) — Zed `crates/terminal/src/terminal.rs (4947 lines, model), crates/terminal_view/src/terminal_panel.rs:55 init, :1544 impl Panel`
- [x] Auto update — Zed `crates/auto_update init at crates/zed/src/main.rs:659, auto_update_ui at :661`

設計判断 37/37 済

- [x] UI-001 UI を機能の入口として扱う — 実装済み
- [x] UI-013 Files panel owns contextual workspace actions — 実装済み
- [x] UI-014 Git navigation is visible in the sidebar — 実装済み
- [x] UI-015 Files creation is visible at the point of use — 実装済み
- [x] UI-016 Git status rows own safe stage actions — 実装済み
- [x] UI-017 Git history exposes commit-level actions — 実装済み
- [x] UI-018 Command Palette presents discoverable primary actions — 実装済み
- [x] UI-019 Terminal sessions are explicit panel controls — 実装済み
- [x] UI-020 Commit details use an identified, dismissible inspector — 実装済み
- [x] UI-022 An empty Files panel starts a workspace — 実装済み
- [x] UI-023 Git has an explicit no-repository state — 実装済み
- [x] UI-026 Git Changes exposes a native commit entry point — 実装済み
- [x] UI-034 Git status has one primary presentation — 実装済み
- [x] UI-047 Make changed-file diffs visible from the Git panel — 実装済み
- [x] UI-048 Enter file history from the file tree — 実装済み
- [x] UI-049 Copy a file-tree entry path without opening it — 実装済み
- [x] UI-051 Make Git change actions follow their rendered section — 実装済み
- [x] UI-052 Keep Quick Open out of the editor document surface — 実装済み
- [x] UI-053 Give workspace search its own navigation panel — 実装済み
- [x] UI-054 Open an integrated terminal from a project entry — 実装済み
- [x] UI-059 Keep workspace-search controls inside the Search panel — 実装済み
- [x] UI-062 Branch context actions are non-destructive by default — 実装済み
- [x] UI-066 Edit supported settings without blocking the workspace — 実装済み
- [x] UI-072 External file changes must not block the editor window — 実装済み
- [x] UI-084 Clone Zed's Outline and diagnostic presentation — 実装済み
- [x] UI-085 Keep Files panel creation and trash actions at the selection boundary — 実装済み
- [x] UI-086 Make implemented editor services discoverable from Command Palette — 実装済み
- [x] UI-088 Route macOS View menu actions through the existing command boundary — 実装済み
- [x] UI-135 Model Git History as explicit loading, error, and loaded states — 実装済み
- [x] UI-136 Make Files-panel tree navigation continuously reachable — 実装済み
- [x] UI-137 Keep document search and navigation inside the editor surface — 実装済み
- [x] UI-138 Present the command palette as editor chrome, not an alert — 置換
- [x] UI-139 Start workspace search without a blocking prompt — 実装済み
- [x] UI-140 Edit a Git commit message in the Changes surface — 置換
- [x] UI-141 Keep Quick Open inside the editor workflow — 実装済み
- [x] UI-154 Port Zed's option-aware search bars and project filters — 実装済み
- [x] UI-156 Make Git Changes rows native checkbox controls with a pinned commit footer — 実装済み


### 層に属さない判断

測定手順・テスト方針など、Zed のコード構成に対応物を持たないもの。
1/1 済

- [x] UI-058 Keep GUI acceptance independent of terminal-session hangups — 実装済み

## 3. 着手順の原則

1. **同じ層の `[ ]` をまとめて片付ける。** 1 件ずつ直すと、
   2026-08-10 に 5 回起きた「テーマの値はあるが別の色を塗る」のように同じ構図を何度も踏む

2. **下の層から。** デザインシステムが無いままエディタの見た目を直すと
   AppKit のクラスに直接書くことになり、次の項目でまた同じことをする

3. **1 つの条件で確認したものは、その条件でしか確認されていない。**
   単一ファイル・フォルダ・git リポジトリの 3 条件で見る

### 「台帳に無かった項目」は全て重複だった（2026-08-13 に訂正）

この位置に 5 件を「指示書にあり台帳に無かった」として追加したが、**5 件とも
既に台帳にあった**。照合を項目名の完全一致で行ったため、次のずれを取りこぼしていた。

| 台帳の名前 | 指示書の名前 | ずれ |
| --- | --- | --- |
| KeyBinding: a keystroke *sequence* with prefix matching | KeyBinding: a keystroke sequence with prefix matching | 強調記号 |
| Style × state -> concrete style resolution | Style x state -> concrete style resolution | × と x |
| Platform input event vocabulary | Platform input event vocabulary (PlatformInput / ClickEvent) | 接尾辞 |
| NoAction / Unbind disable markers | NoAction / Unbind disable markers and predicate is_superset | 接尾辞 |
| Entry identity: ProjectEntryId, inode-based rename detection | Entry identity: ProjectEntryId with inode-based rename detection | , と with |

5 件とも削除し、元の項目に一本化した。**名前一致による重複検出は
この 5 種類のずれを全部すり抜ける。** 以後は Zed の参照（`file:line`）が
2 件以上重なる組を探す:

```python
refs = 各項目の crates/....rs:NNN の集合
if len(a.refs & b.refs) >= 2: 重複の疑い
```

この方法で 191 項目を突き合わせ、重複 0 件を確認した。
