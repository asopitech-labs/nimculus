# 移植タスクの分解と棚卸し

`ZED_ARCHITECTURE.md` の 190 メカニズムを作業単位に分け、
`DESIGN_DECISIONS.md` の 154 件と突き合わせて、済みを消し込んだもの。

## 1. 設計台帳の状態

| 状態 | 件数 |
| --- | ---: |
| 実装済み | 136 |
| 後の判断で置き換え | 8 |
| 調査のみ | 4 |
| 一部実装 | 3 |
| 却下 | 3 |
| **計** | **154** |

### 番号の衝突 20 件

**同じ番号の判断が 2 つずつある。参照しても一意に定まらない。**

| 番号 | 片方 | もう片方 |
| --- | --- | --- |
| UI-059 | Keep workspace-search controls inside the Search panel | Model Git History as explicit loading, error, and loaded sta |
| UI-060 | Invert resize coordinates for the macOS right Project dock | Make Files-panel tree navigation continuously reachable |
| UI-061 | Keep editor-tab actions at the tab that invoked them | Keep document search and navigation inside the editor surfac |
| UI-062 | Branch context actions are non-destructive by default | Present the command palette as editor chrome, not an alert |
| UI-063 | Pinning is tab order, not a transient decoration | Start workspace search without a blocking prompt |
| UI-064 | Reopen closed tabs from paths, never discarded buffers | Edit a Git commit message in the Changes surface |
| UI-065 | Drag reordering does not implicitly change a pin | Keep Quick Open inside the editor workflow |
| UI-075 | Filesの選択identityはアクティブ文書のcanonical pathで再解決する | Keep split-pane viewport calculations local |
| UI-076 | 未折返し編集は主・副ペイン共通の横スクロール境界を使う | Make multi-selection a user-visible editor feature |
| UI-077 | ワークスペースの空エディタはWelcomeを表示しFilesを残す | Synchronize the selected tab at the session/UI composition b |
| UI-078 | macOS workspace presenters are single-row and pane-clipped | Keep the native Files selection row readable while inactive |
| UI-079 | Make unwrapped editor scrolling Zed-compatible | Keep Outline useful before LSP symbols arrive |
| UI-080 | Expose syntax selection expansion through the macOS editor | Keep wheel scrolling independent from cursor visibility |
| UI-081 | Make editor and project-panel chrome share hard Zed-style ed | Reconstruct syntax siblings from Tree-sitter ranges |
| UI-082 | Adopt Zed One themes and a single comfortable editor line me | Keep syntax folding as an item-owned display map |
| UI-083 | Use Zed One terminal palettes as the native terminal source  | Derive structural brackets from the syntax snapshot |
| UI-084 | Clone Zed's Outline and diagnostic presentation | Keep fold commands semantically separate |
| UI-092 | Replace the left activity rail with Zed-style status-bar pan | Port Zed's option-aware search bars and project filters |
| UI-093 | Condense the status-bar dock controls to a Zed-style left cl | Make Git Changes rows native checkbox controls with a pinned |
| UI-094 | Make editor chrome container-owned and overlay-safe | Snap editor rows and wrap width to Zed's pixel contract |

**これを直さないと「実行済みの消し込み」ができない。** 採番の台帳が無く、
末尾に追記し続けた結果。以後は本文書の層ごとの表を台帳とする。

## 2. 層ごとの残作業

各層の「一部のみ」と「無い」を作業単位として並べる。
**「一部のみ」を先に片付ける。** 動いているように見えて条件を変えると壊れるため、
新しい機能を足すより優先度が高い。


### プラットフォーム層（一部 10 / 無 13）

**一部のみ — 先に片付ける**

- NSApplication bootstrap and app-delegate callbacks — `crates/gpui_macos/src/platform.rs:70 (build_classes), :488 (Platform::run), :1227 (did_finish_launching)`
- Runtime NSView/NSWindow subclass synthesis with a fixed selector set — `crates/gpui_macos/src/window.rs:131-303 (VIEW_CLASS), :365-474 (build_window_class)`
- Display-link frame pacing — `crates/gpui_macos/src/display_link.rs:65-226 (immortal per-display CVDisplayLink registry), :231 (WindowFrameSource), crates/gpui_macos/src/window.rs:659 (start_display_link), :2689 (step callback)`
- Metal renderer: pipeline states per primitive kind and a pooled instance buffer — `crates/gpui_macos/src/metal_renderer.rs:111-140 (MetalRenderer fields), :56-109 (InstanceBufferPool), :446 (draw), :1047-1568 (draw_shadows/quads/paths/underlines/mono+poly sprites/surfaces)`
- Sprite atlas with shelf packing and keyed tiles — `crates/gpui_macos/src/metal_atlas.rs:13 (MetalAtlas), :40 (get_or_insert_with), :96 (allocate), :121 (push_texture), :62/:250 (remove + refcount)`
- IME arbitration: who sees a key first, the keybinding matcher or the input context — `crates/gpui_macos/src/window.rs:2121 (handle_key_event), :2094 (is_ime_input_source_active), :2848 (do_command_by_selector)`
- NSEvent to portable input event translation — `crates/gpui_macos/src/events.rs:258-286 (scroll phase and precise vs line deltas), :288-300 (button numbers incl. Navigate back/forward), crates/gpui_macos/src/window.rs:319 (convert_mouse_position, y-flip)`
- Pasteboard read/write with typed content — `crates/gpui_macos/src/pasteboard.rs:22 (Pasteboard), :50 (read), :92 (read_image), :165 (write), :264-333 (UTType mapping for png/jpeg/gif/webp/bmp/svg/ico/tiff/pnm)`
- Menu bar construction from a declarative menu tree with keystrokes from the keymap — `crates/gpui_macos/src/platform.rs:241 (create_menu_bar), :305 (create_menu_item), :1387 (handle_menu_item), :1404 (validate_menu_item)`
- Accessibility tree — `crates/gpui_macos/src/window.rs:1862 (a11y_init), :1881 (a11y_tree_update), :1893 (a11y_update_window_bounds), :535 (accesskit_macos::SubclassingAdapter field), :1898-1911 (activation and action handlers)`

**無い**

- The Platform trait as the OS boundary — `crates/gpui_macos/src/platform.rs:475 (impl Platform for MacPlatform)`
- Per-window state behind a handle stored in an ObjC ivar — `crates/gpui_macos/src/window.rs:77 (WINDOW_STATE_IVAR), :490 (MacWindowState), :1959 (get_window_state), :1969 (drop_window_state)`
- Traffic-light repositioning for an app-drawn titlebar — `crates/gpui_macos/src/window.rs:541 (move_traffic_light), :601 (capture_traffic_light_frames), :638 (restore_traffic_light)`
- presents-with-transaction during synchronous redraw — `crates/gpui_macos/src/window.rs:2673 (display_layer), crates/gpui_macos/src/metal_renderer.rs:374 (set_presents_with_transaction), :492-499 (commit/wait_until_scheduled/present)`
- Glyph rasterization with subpixel variants and dilation — `crates/gpui_macos/src/text_system.rs:421 (raster_bounds, dilated by 1px), :436 (rasterize_glyph)`
- Font fallback cascade and OpenType features — `crates/gpui_macos/src/open_type.rs:34 (apply_features_and_fallbacks), :102 (generate_fallback_array), :155 (append_system_fallbacks)`
- Key-equivalent vs key-down de-duplication — `crates/gpui_macos/src/window.rs:2045 (handle_key_equivalent), :2149-2153 (last_key_equivalent), :2243 (don't forward modified key equivalents)`
- Keyboard layout identity and per-layout key-equivalent remapping — `crates/gpui_macos/src/keyboard.rs:13 (MacKeyboardLayout), :18 (MacKeyboardMapper), :30-50 (map_key_equivalent), plus ~1400 lines of per-layout character tables`
- Display enumeration and coordinate space — `crates/gpui_macos/src/display.rs:16 (MacDisplay), :28 (primary), :48 (all), :79 (uuid), :108 (bounds), :121 (visible_bounds)`
- Cursor style ownership — `crates/gpui_macos/src/window.rs:334 (set_active_window_cursor_style), :1994 (reset_cursor_rects), crates/gpui_macos/src/platform.rs:1039, :1045 (hide_cursor_until_mouse_moves)`
- External file drag-and-drop onto the window — `crates/gpui_macos/src/window.rs:2931 (dragging_entered), :2943 (dragging_updated), :2958 (perform_drag_operation), :2964 (external_paths_from_event), :3011 (send_file_drop_event)`
- Window blur / vibrancy background — `crates/gpui_macos/src/window.rs:304 (BLURRED_VIEW_CLASS on NSVisualEffectView), :1525 (set_background_appearance), :3082 (blurred_view_update_layer), :3092 (remove_layer_background), :123 (CGSSetWindowBackgroundBlurRadius)`
- Native window tabs — `crates/gpui_macos/src/window.rs:448-471 (tab selectors), :1052-1080 (addTabbedWindow at open), :1141 (get_user_tabbing_preference), :1238-1294, :1707-1761`


### フレームワーク中核（一部 7 / 無 6）

関連する設計判断 3 件（うち実装済み 3）: UI-103, UI-102, UI-101

**一部のみ — 先に片付ける**

- WindowInvalidator + DrawPhase state machine — `crates/gpui/src/window.rs:117 WindowInvalidatorInner, :140 impl, :153 invalidate_view, :180 set_phase, :1197 enum DrawPhase, :1891 Window::refresh`
- Three-phase element pipeline: request_layout -> prepaint -> paint — `crates/gpui/src/window.rs:2853 draw_roots (Prepaint at :2854, root request_layout :2884, stretch_auto_size_to_fill :2885, prepaint_as_root :2889, Paint at :2923, root paint :2924), :4252 request_layout, :4301 compute_layout, :4318 layout_bounds, :3039 prepaint_deferred_draws, :3109 paint_deferred_draws`
- Hitbox list + topmost hit testing with blocking behaviors — `crates/gpui/src/window.rs:678 struct Hitbox, :724 enum HitboxBehavior, :4338 insert_hitbox, :935 Frame::hit_test, :2919 (per-frame cache)`
- Content mask stack and element offset stack — `crates/gpui/src/window.rs:1793 ContentMask, :3323 with_content_mask, :3341 with_element_offset, :3360 with_absolute_element_offset, :3473 element_offset, :4325-4327 (layout_bounds applies snapped offset)`
- Typed pixel units and the scale-factor ladder — `crates/gpui/src/geometry.rs:2677 Pixels, :2781 impl (floor/round/ceil/scale/pow/abs), :2829 Pixels::scale, :2982 DevicePixels, :3075 ScaledPixels, :3131 ScaledPixels->DevicePixels, :3238 Rems, :3298 AbsoluteLength, :3460 DefiniteLength, :3611 Length, :3736 px()`
- Bounds / Point / Size / Edges / Corners generic over unit — `crates/gpui/src/geometry.rs:85 Point<T>, :396 Size<T>, :723 Bounds<T>, :1750 Edges<T>, :2258 Corners<T>, :43 trait Along, :25 enum Axis, :1694 Bounds<Pixels>::scale, :1707 to_device_pixels`
- Frame profiling: dirty-timestamp accumulation and present — `crates/gpui/src/window.rs:126 FrameDirtyAccumulator, :2681 take_frame_dirty, :2789 record_frame_timing, :2827 present, :2841 present_if_needed`

**無い**

- Entity handle + type-erased entity store (lease discipline) — `crates/gpui/src/app/entity_map.rs:414 (Entity<T>), :114 reserve, :120 insert, :134 lease, :151 end_lease, :156 read`
- Context<'a,T> - entity-scoped view of App — `crates/gpui/src/app/context.rs:20 (struct), :50 entity(), :229 notify(), :765 emit()`
- Effect queue + flush_effects re-entrancy guard — `crates/gpui/src/app.rs:1516 push_effect, :1531 flush_effects, :1029 App::update, :1036 start_update, :1040 finish_update`
- Double-buffered Frame with element-state carryover — `crates/gpui/src/window.rs:824 struct Frame, :867 Frame::new, :884 Frame::clear, :965 Frame::finish, :1015-1016 rendered_frame/next_frame fields, :2737-2741 mem::swap in draw`
- Per-element retained state keyed by GlobalElementId — `crates/gpui/src/window.rs:3562 with_element_state, :3517 use_keyed_state, :3546 use_state, :3505 with_element_namespace, :6157 enum ElementId`
- Window/App split: root view, viewport, scale factor, refresh — `crates/gpui/src/window.rs:989 struct Window (root :1006, viewport_size :1004, layout_engine :1005, scale_factor :1029), :2347 viewport_size(), :2460 scale_factor(), :2466 rem_size(), app.rs:711 windows SlotMap, app.rs:1217 open_window, app.rs:1728 update_window_id`


### テキストと描画（一部 7 / 無 7）

関連する設計判断 5 件（うち実装済み 4）: UI-110, UI-109, UI-106, UI-105, UI-100

**一部のみ — 先に片付ける**

- Font identity and FontId interning — `crates/gpui/src/text_system.rs:1051 (Font), :107 (font_id), :148 (resolve_font)`
- Font metrics cache and the em_width / em_advance / ch_width / ch_advance distinction — `crates/gpui/src/text_system.rs:226-249, :292 (read_metrics), :1104 (FontMetrics), :1137-1177`
- Line geometry queries (index_for_x, x_for_index, position_for_index) — `crates/gpui/src/text_system/line_layout.rs:58, :75, :105, :117, :283-362`
- DecorationRun coalescing (style runs separated from font runs) — `crates/gpui/src/text_system.rs:409-427 (shape_line), :537-567 (shape_text), crates/gpui/src/text_system/line.rs:24 (DecorationRun)`
- paint_line: turning a layout plus decorations into primitives — `crates/gpui/src/text_system/line.rs:334-578, background variant at :580`
- Scene primitive set and per-kind streams — `crates/gpui/src/scene.rs:41 (Scene), :222 (Primitive), :501 (Quad), :521 (Underline), :540 (Shadow), :677 (MonochromeSprite), :696 (SubpixelSprite), :715 (PolychromeSprite), :755 (Path), :734 (PaintSurface)`
- Pixels -> ScaledPixels boundary and device-pixel snapping — `crates/gpui/src/window.rs:3886 (round_to_device_pixel), :3952 (origin.scale(scale_factor)), :3964 (integer origin), scene.rs:787 (Path::scale)`

**無い**

- The pooled LineWrapper — `crates/gpui/src/text_system.rs:307 (line_wrapper), :56 (wrapper_pool), :850 (LineWrapperHandle), crates/gpui/src/text_system/line_wrapper.rs`
- Draw order, the layer stack, and the BoundsTree — `crates/gpui/src/scene.rs:43-44, :75 (push_layer), :87 (insert_primitive), :151 (finish)`
- Batching: merging sorted streams into draw calls — `crates/gpui/src/scene.rs:172 (batches), :288-466 (BatchIterator)`
- Hsla and alpha derivation — `crates/gpui/src/color.rs:334 (Hsla), :424 (hsla), :525 (to_rgb), :580 (blend), :607 (fade_out), :637 (opacity), :667 (alpha), :677 (From<Rgba>)`
- Background: solid vs gradient vs pattern as one shader-visible tag — `crates/gpui/src/color.rs:779 (Background), :759 (ColorSpace), :851 (solid_background), :865 (linear_gradient), :827 (pattern_slash), :841 (checkerboard); used by scene.rs:506 (Quad.background) and :761 (Path.color)`
- TextStyle and its refinement/highlight composition — `crates/gpui/src/style.rs:434 (TextStyle), :432 (#[derive(Refineable)]), :506 (highlight), :539 (font), :550 (line_height_in_pixels), :555 (to_run), :576 (HighlightStyle), :920 (HighlightStyle::highlight)`
- UnderlineStyle / StrikethroughStyle and their snapped emission — `crates/gpui/src/style.rs:824 (UnderlineStyle), :839 (StrikethroughStyle); crates/gpui/src/window.rs:3870 (paint_underline), :3905 (paint_strikethrough)`


### 入力とアクション（一部 8 / 無 7）

関連する設計判断 4 件（うち実装済み 4）: UI-108, UI-107, UI-104, UI-005

**一部のみ — 先に片付ける**

- KeyContext: the per-node context entry list — `crates/gpui/src/keymap/context.rs:10 (KeyContext), :14 (ContextEntry), :65 (parse), :117 (add), :126 (set), :137 (contains), :142 (get)`
- Keymap precedence resolution (bindings_for_input) — `crates/gpui/src/keymap.rs:164-242, sort at :187, binding_enabled at :245`
- The DispatchTree: per-frame node tree of contexts, focus ids and listeners — `crates/gpui/src/key_dispatch.rs:71 (DispatchTree), :83 (DispatchNode), :166 (push_node), :215 (set_key_context), :220 (set_focus_id), :226 (set_view_id), :323/:327/:333 (on_key_event / on_modifiers_changed / on_action)`
- dispatch_path / focus_path / focus_contains — `crates/gpui/src/key_dispatch.rs:563 (dispatch_path, root-to-focused), :574 (focus_path), :346 (focus_contains)`
- Capture/bubble phases for key and action listeners — `crates/gpui/src/window.rs:88 (DispatchPhase), :4999 (dispatch_key_down_up_event: capture root-to-focus, bubble focus-to-root, stopping when propagate_event is false), :5130 (dispatch_action_on_node_inner: global listeners first, then window capture, then bubble where `cx.propagate_event = false` is set *before* each bubble listener so actions stop propagation by default)`
- Synthetic keystrokes from modifier-only presses — `crates/gpui/src/window.rs:4815-4844 (a ModifiersChangedEvent that drops from exactly one modifier to zero without an intervening keystroke becomes a `shift`/`control`/`alt`/`platform`/`function` keystroke), crates/gpui/src/key_dispatch.rs:327 (modifiers_changed_listeners), window.rs:5030 (bubble-only dispatch of them)`
- FocusHandle / FocusId: refcounted, generation-safe focus identity — `crates/gpui/src/window.rs:267 (slotmap key FocusId), :383 (FocusHandle with tab_index and tab_stop), :404 (new, inserts into the FocusMap with a ref_count), :417 (for_id via atomic_incr_if_not_zero), :450 (downgrade to WeakFocusHandle), :457 (focus), :484 (dispatch_action from a handle)`
- Platform input event vocabulary — `crates/gpui/src/interactive.rs:735 (PlatformInput enum), :25/:47/:62 (KeyDown/KeyUp/ModifiersChanged), :139/:176/:485/:513 (mouse down/up/move/scroll), :281 (ClickEvent unifying mouse, keyboard and touch activation), :762/:780 (mouse_event/keyboard_event partition)`

**無い**

- Action as a type-erased, registered value — `crates/gpui/src/action.rs:117 (trait Action), :233 (ActionRegistry), :293 (insert_action), :351 (build_action)`
- NoAction / Unbind disable markers — `crates/gpui/src/action.rs:425-458, crates/gpui/src/keymap.rs:29 (disabled_binding_matches_context), :40 (binding_is_unbound), :195-225`
- KeyBinding: a keystroke *sequence* with prefix matching — `crates/gpui/src/keymap/binding.rs:10 (struct), :48 (load, splits on whitespace), :89 (match_keystrokes returning Option<bool> where the bool means "pending")`
- Binding source metadata (user > vim > base > default) — `crates/gpui/src/keymap/binding.rs:143 (KeyBindingMetaIndex), crates/gpui/src/keymap.rs:199 (NoAction only breaks for user-sourced bindings), keymap.rs:831 (test documenting User 0 > Vim 1 > Base 2 > Default 3)`
- Reverse lookup: bindings_for_action, with shadow filtering — `crates/gpui/src/keymap.rs:95 (bindings_for_action), crates/gpui/src/key_dispatch.rs:401 (bindings_for_action), :420 (highest_precedence_binding_for_action), :435 (binding_matches_predicate_and_not_shadowed)`
- Multi-keystroke pending state and replay — `crates/gpui/src/key_dispatch.rs:116 (Replay), :121 (DispatchResult with pending / pending_has_binding / bindings / to_replay), :483 (dispatch_key), :523 (flush_dispatch), :538 (replay_prefix); crates/gpui/src/window.rs:4868-4933 (pending buffer, focus invalidation, timeout)`
- available_actions / is_action_available for the command palette — `crates/gpui/src/key_dispatch.rs:363 (available_actions, walks the dispatch path collecting listener action types and building a default instance of each), :382 (is_action_available)`


### デザインシステム（一部 9 / 無 7）

関連する設計判断 14 件（うち実装済み 13）: UI-131, UI-122, UI-112, UI-095, UI-083, UI-082, UI-012, UI-030, UI-031, UI-033, UI-037, UI-078, UI-082, UI-091

**一部のみ — 先に片付ける**

- Semantic colour token enum — `crates/ui/src/styles/color.rs:19 (enum), :90 (Color::color)`
- Size scale as a pure table — `crates/ui/src/components/button/button_like.rs:455 (ButtonSize), :465 (rems); crates/ui/src/components/icon.rs:54 (IconSize), :70 (rems), :86 (square_components); crates/ui/src/styles/typography.rs:93 (TextSize), :132 (rems/pixels); crates/ui/src/components/label/label_like.rs:7 (LabelSize)`
- Elevation -> shadow stack and background — `crates/ui/src/styles/elevation.rs:14 (ElevationIndex), :42 (shadow), :84 (bg), :95 (on_elevation_bg), :108 (darker_bg); crates/ui/src/traits/styled_ext.rs:6 (elevated), :45 elevation_1, :62 elevation_2, :83 elevation_3`
- Component-instance identity and state — `crates/ui/src/components/button/button_like.rs:484 (ElementId), :512 (focus_handle), :745 render; crates/ui/src/components/context_menu.rs:211 (ContextMenu as an Entity with focus_handle, selected_index, subscriptions)`
- Label rendering: size, weight, truncation mode — `crates/ui/src/components/label/label_like.rs:7 (LabelSize), :23 (LineHeightStyle), :34 (LabelCommon), :233 (render)`
- Menu item model separated from menu rendering — `crates/ui/src/components/context_menu.rs:46 (ContextMenuItem enum), :82 (ContextMenuEntry), :211 (ContextMenu state), :1449 (render_menu_item), :2180 (render, submenu offset + aside)`
- Scrollbar geometry and visibility policy — `crates/ui/src/components/scrollbar.rs:352 (ScrollbarStyle), :358 to_pixels (Regular 6px / Editor 15px), :275 (ShowBehavior::Always/Autohide/Never from setting), :993 (ScrollableHandle trait), :1013 (ScrollbarLayout), :1023 compute_click_offset`
- Divider — `crates/ui/src/components/divider.rs:19 (DividerColor), :37 (struct), :96 render_solid, :100 render_dashed`
- Tooltip container as shared chrome — `crates/ui/src/components/tooltip.rs:216 (tooltip_container), :194 (Tooltip::render), :9 (struct: title, meta, key_binding)`

**無い**

- Style × state -> concrete style resolution — `crates/ui/src/components/button/button_like.rs:125 (ButtonStyle), :190 (ButtonLikeStyles), :210 enabled(), :257 hovered(), plus active()/disabled() through :448`
- Density-aware spacing scale — `crates/ui/src/styles/spacing.rs:29-44 (derive_dynamic_spacing! table), :52 (ui_density)`
- Builder traits shared across components — `crates/ui/src/traits/clickable.rs:4, disableable.rs:2, toggleable.rs:5, fixed.rs, visible_on_hover.rs; crates/ui/src/components/button/button_like.rs:12 (SelectableButton), :17 (ButtonCommon)`
- Icon source abstraction and square hit box — `crates/ui/src/components/icon.rs:117 (IconSource), :131 (Icon), :86 (square_components), :102 (square)`
- ListItem slot layout — `crates/ui/src/components/list/list_item.rs:10 (ListItemSpacing), :26 (struct), :292 (render), :404 (disclosure at left:-1rem), :434 (EndSlotVisibility Always/OnHover/SwapOnHover)`
- Keybinding display — `crates/ui/src/components/keybinding.rs:46 (KeyBinding), :63 for_action, :200 render, :252 render_keybinding_keystroke, :411 (Key), :457 (KeyIcon)`
- Tri-state toggle — `crates/ui/src/traits/toggleable.rs:12 (ToggleState), :26 inverse, :34 from_any_and_all; crates/ui/src/components/toggle.rs:43 (Checkbox), :181 container_size, :338 (Switch), :328 (SwitchLabelPosition)`


### ワークスペース（一部 12 / 無 4）

関連する設計判断 55 件（うち実装済み 45）: UI-133, UI-132, UI-130, UI-128, UI-127, UI-120, UI-119, UI-118, UI-117, UI-116, UI-115, UI-114, UI-113, UI-097…

**一部のみ — 先に片付ける**

- Panel trait (what a dock can contain) — `crates/workspace/src/dock.rs:36`
- Dock container: open bit, active panel index, per-panel size state — `crates/workspace/src/dock.rs:269`
- Dock resize handle geometry and double-click reset — `crates/workspace/src/dock.rs:1091 (Render for Dock), handle placement at dock.rs:1124-1150`
- PanelButtons (the status-bar dock toggles) — `crates/workspace/src/dock.rs:356, Render at dock.rs:1211, StatusItemView at dock.rs:1408`
- Item trait (what a tab knows how to be) — `crates/workspace/src/item.rs:170`
- Tab detail disambiguation — `crates/workspace/src/pane.rs:4910 tab_details, called from render_tab_bar at pane.rs:3453`
- Pane: item list, active index, activation history, pinned prefix, preview item — `crates/workspace/src/pane.rs:398`
- Pane split tree (Member / PaneAxis with flexes) — `crates/workspace/src/pane_group.rs:294 Member, :640 PaneAxis, PaneAxis::split at pane_group.rs:694`
- Tab bar rendering (tabs, nav buttons, pinned row, drop targets) — `crates/workspace/src/pane.rs:3396 render_tab_bar, per-tab at pane.rs:2825 render_tab, drop target at pane.rs:3626`
- Item toolbar / breadcrumb slot — `crates/workspace/src/toolbar.rs:64 Toolbar, ToolbarItemLocation at toolbar.rs:56; Item side at item.rs:343 breadcrumb_location, :347 breadcrumbs`
- Workspace serialization (DockStructure + pane tree + items) — `crates/workspace/src/persistence/model.rs:153 DockStructure, :203 DockData, :234 SerializedPaneGroup, :339 SerializedPane, :424 SerializedItem; writer at workspace.rs:7061 serialize_workspace_internal`
- Serialization throttle — `crates/workspace/src/workspace.rs:7044 serialize_workspace`

**無い**

- PanelHandle (object-safe erasure of Panel) — `crates/workspace/src/dock.rs:98`
- Panel size persistence and dock zoom — `crates/workspace/src/dock.rs:361 PANEL_SIZE_STATE_KEY, dock.rs:547 set_panel_zoomed, workspace.rs:4163 toggle_dock`
- Nav history (back/forward across items) — `crates/workspace/src/pane.rs:471 NavHistory / :474 NavHistoryState, navigate_backward at pane.rs:929`
- Pane render policy hooks (should_display_tab_bar, render_tab_bar_buttons) — `crates/workspace/src/pane.rs:421-431`


### エディタ: モデル（一部 11 / 無 7）

関連する設計判断 14 件（うち実装済み 13）: UI-099, UI-079, UI-074, UI-076, UI-040, UI-075, UI-076, UI-080, UI-081, UI-082, UI-083, UI-084, UI-079, UI-080

**一部のみ — 先に片付ける**

- DisplayPoint / DisplayRow — the coordinate space the renderer paints in — `crates/editor/src/display_map.rs:2496 (DisplayPoint(BlockPoint)), :2526 (DisplayRow), :2646 (DisplayPointConverter)`
- Inlay layer — `crates/editor/src/display_map/inlay_map.rs:34 (InlayMap), :40 (InlaySnapshot), :574 (sync)`
- Fold layer and creases — `crates/editor/src/display_map/fold_map.rs:360 (FoldMap), :680 (FoldSnapshot), :1225 (Fold), :1232 (FoldRange over Anchors), :27 (FoldPlaceholder); crates/editor/src/display_map/crease_map.rs:15`
- Soft wrap layer with background rewrap — `crates/editor/src/display_map/wrap_map.rs:32 (WrapMap with pending_edits, interpolated_edits, background_task), :43 (WrapSnapshot), :146 (sync)`
- SelectionsCollection: disjoint anchored selections plus a pending one — `crates/editor/src/selections_collection.rs:26 (SelectionsCollection), :20 (PendingSelection), :547 change_with, :978 move_with, :1027 move_heads_with`
- Anchor-based scroll position — `crates/editor/src/scroll.rs:38 (ScrollAnchor {anchor, offset}), :388 ScrollManager::scroll_position, :51 ScrollAnchor::scroll_position`
- Autoscroll strategies — `crates/editor/src/scroll/autoscroll.rs:16 (enum Autoscroll), :100 (AutoscrollStrategy), :127 autoscroll_vertically, :345 autoscroll_horizontally; request queued on ScrollManager at scroll.rs:214`
- ScrollAmount: line / page / column / page-width — `crates/editor/src/scroll/scroll_amount.rs:19 (enum ScrollAmount), :30 lines(), :46 columns(), :53 pixels()`
- Scrollbar geometry and thumb state — `crates/editor/src/scroll.rs:181 (ScrollbarThumbState), :189 (ActiveScrollbarState), :522 show_scrollbars, SCROLLBAR_SHOW_INTERVAL at :31`
- Edit transactions grouped with selection history — `crates/editor/src/editor.rs:8286 transact, :8299 start_transaction_at, :8321 end_transaction_at, :1394 SelectionHistory, :1297 SelectionHistoryMode`
- Highlight layering on top of the transform chain — `crates/editor/src/display_map.rs:213 (text_highlights, inlay_highlights, semantic_token_highlights fields), :161 (HighlightKey), :334 (HighlightStyleInterner), :1408 (HighlightedChunk); custom_highlights.rs:30`

**無い**

- MultiBuffer: N buffers presented as one text — `crates/multi_buffer/src/multi_buffer.rs:73 (struct MultiBuffer), :691 (MultiBufferSnapshot), :842 (ExcerptRange)`
- Anchor: an edit-surviving position — `crates/multi_buffer/src/anchor.rs:17 (ExcerptAnchor), :28 (enum Anchor {Min, Excerpt, Max})`
- The five-layer transform chain (inlay → fold → tab → wrap → block) — `crates/editor/src/display_map.rs:1 (module doc describing the contract), :213 (DisplayMap fields), :604 (snapshot() driving the chain)`
- Tab expansion layer — `crates/editor/src/display_map/tab_map.rs:20 (TabMap), :197 (TabSnapshot with tab_size and max_expansion_column), :41 (sync)`
- Block layer: non-text rows and replacement blocks — `crates/editor/src/display_map/block_map.rs:38 (BlockMap), :75 (BlockSnapshot), :163 (BlockPlacement Above/Below/Near/Replace), :377 (enum Block: Custom, FoldedBuffer, ExcerptBoundary, BufferHeader, Spacer), :282 (BlockProperties), :303 (BlockStyle)`
- Invisible character rendering — `crates/editor/src/display_map/invisibles.rs:34 is_invisible, :49 replacement, :75 FORMAT, :100 OTHER, :114 PRESERVE`
- EditorMode: one Editor type, several shapes — `crates/editor/src/editor.rs:464 (enum EditorMode: SingleLine, AutoHeight, Full, Minimap)`


### エディタ: 描画（一部 13 / 無 8）

関連する設計判断 10 件（うち実装済み 9）: UI-134, UI-124, UI-121, UI-098, UI-094, UI-081, UI-044, UI-087, UI-089, UI-094

**一部のみ — 先に片付ける**

- GutterDimensions — the gutter geometry contract — `crates/editor/src/editor.rs:1246 (struct), crates/editor/src/editor.rs:11546 (EditorSnapshot::gutter_dimensions), crates/editor/src/fold.rs:5 (fold_area_width)`
- layout_line_numbers — number choice, colour, placement, hit target — `crates/editor/src/element.rs:2727; LineNumberStyle at crates/editor/src/element.rs:115-141`
- LineWithInvisibles::from_chunks — the line shaping pipeline — `crates/editor/src/element.rs:7013 (struct), crates/editor/src/element.rs:7045 (from_chunks), crates/editor/src/element.rs:7021 (enum LineFragment)`
- x_for_index / index_for_x / alignment_offset — line-local pixel↔column mapping — `crates/editor/src/element.rs:7661, crates/editor/src/element.rs:7690, crates/editor/src/element.rs:7745`
- calculate_wrap_width — soft wrap mode to a pixel width — `crates/editor/src/element.rs:10624, consumed at crates/editor/src/element.rs:8023 and :10672`
- layout_selections + active_rows — `crates/editor/src/element.rs:767, SelectionLayout at crates/editor/src/element.rs:142 and :159`
- CursorLayout — shape, bounds, block glyph, collaborator name — `crates/editor/src/element.rs:10318 (struct), crates/editor/src/element.rs:10362 (bounds), crates/editor/src/element.rs:10421 (paint); construction at crates/editor/src/element.rs:1001 (layout_visible_cursors)`
- GitBlame entity — blame kept in sync with edits — `crates/editor/src/git/blame.rs:75 (struct GitBlame), :305 (blame_for_rows), :368 (sync), :505 (generate), :681 (regenerate_on_edit), :697 (build_blame_entry_sum_tree)`
- The prepaint→paint split and EditorLayout — `crates/editor/src/element.rs:7954 (prepaint), :9598 (struct EditorLayout), :9431 (paint)`
- paint_background — active line and highlighted rows — `crates/editor/src/element.rs:4890`
- items.rs tab_content — the tab label element — `crates/editor/src/items.rs:751; MAX_TAB_TITLE_LEN=24 at items.rs:66; entry_git_aware_label_color at items.rs:2200; entry_label_color at items.rs:2172`
- breadcrumbs — segments from the editor, rendering from the element — `crates/editor/src/items.rs:1069 (breadcrumb_location), :1078 (breadcrumbs), :1089 (breadcrumb_prefix); crates/editor/src/element.rs:6726 (render_breadcrumb_text), :6883 (apply_dirty_filename_style)`
- Editor blame lifecycle and inline-blame gating — `crates/editor/src/git.rs:503 (git_blame_inline_enabled), :541 (show_git_blame_gutter), :556 (toggle_git_blame), :571 (toggle_git_blame_inline), :589 (hide_blame_popover), :949 (show_blame_hover_popover), :2131 (start_git_blame)`

**無い**

- gutter_strip_width — the diff change-bar width — `crates/editor/src/element.rs:5309`
- diff_hunk_bounds — hunk vertical extent in gutter space — `crates/editor/src/element.rs:5313`
- Diff hunk painting: colour by kind, hollow for unstaged — `crates/editor/src/element.rs:5202 (paint_gutter_diff_hunks), crates/editor/src/element.rs:6570 (diff_hunk_hollow)`
- ScrollbarLayout — thumb sizing and marker quads — `crates/editor/src/element.rs:9787 (struct), crates/editor/src/element.rs:9870 (new_with_hitbox_and_track_length), crates/editor/src/element.rs:9931 (thumb_bounds), crates/editor/src/element.rs:9956 (marker_quads_for_ranges); layout at crates/editor/src/element.rs:1285, paint at :5755`
- layout_blame_entries — the gutter blame column — `crates/editor/src/element.rs:2197; width reservation in crates/editor/src/editor.rs:11583-11598 (git_blame_entries_width)`
- BlameRenderer — blame presentation as an injectable global — `crates/editor/src/git/blame.rs:88 (trait), :135 (unit impl returning None), :194 (GlobalBlameRenderer)`
- DiffHunkDelegate — per-editor-kind hunk affordances — `crates/editor/src/git.rs:23 (trait), :84 UncommittedDiffHunkDelegate, :164 RestoreOnlyDiffHunkDelegate, :201 RestoreOnlyUnstagedDiffHunkDelegate; render_hunk_as_staged at :79`
- path_for_buffer — detail-level path disambiguation — `crates/editor/src/items.rs:2217 (path_for_buffer), :2227 (path_for_file)`


### プロジェクト層（一部 9 / 無 4）

関連する設計判断 9 件（うち実装済み 8）: UI-129, UI-126, UI-011, UI-029, UI-042, UI-046, UI-056, UI-057, UI-079

**一部のみ — 先に片付ける**

- Worktree snapshot + background scanner with scan ids — `crates/worktree/src/worktree.rs:176 (Snapshot), :249 (LocalSnapshot), :270 (BackgroundScannerState), :410 (enum ScanState), :4267 (BackgroundScanner), :4288 (BackgroundScannerPhase)`
- Repository as an entity with a snapshot + a serialized job queue — `crates/project/src/git_store.rs:476 (struct Repository), :401 (RepositorySnapshot), :607 (GitJob), :614 (enum GitJobKey), :498 (Deref<Target=RepositorySnapshot>)`
- Anchored diff hunks with secondary (staged) status — `crates/buffer_diff/src/buffer_diff.rs:100 (DiffHunk: range as Points, buffer_range as Anchors, diff_base_byte_range, secondary_status, word diffs), :70 (DiffHunkStatus), :85 (DiffHunkSecondaryStatus with the 5 states incl. the two Pending ones), :125 (PendingHunk), :423 hunks_in_row_range`
- Git status scan → panel projection (staged / unstaged / conflicts) — `crates/project/src/git_store.rs:317 (StatusEntry), :366 (impl sum_tree::Item so statuses roll up per directory), crates/git/src/status.rs:10 (FileStatus), :31 (TrackedStatus: index_status + worktree_status), :351 (GitSummary)`
- Blame: entries by line range, plus batch commit-message fetch — `crates/git/src/blame.rs:17 (struct Blame: entries, messages by Oid, tag_names by Oid), :164 (BlameEntry: sha, range: Range<u32>, original_line_number, author/committer fields, summary), :29-58 (unique SHAs then one batched get_messages/get_tag_names); crates/project/src/git_store.rs:1880 blame_buffer`
- Per-buffer LSP request keying and cancellation — `crates/project/src/lsp_store.rs:4140 (BufferLspData: buffer_version, per-feature caches, lsp_requests: HashMap<LspKey, HashMap<LspRequestId, Task<()>>>), :4154 (LspKey = request TypeId + server id), :4172-4208 remove_server_data`
- Buffer→server document synchronization with snapshot history for incremental didChange — `crates/project/src/lsp_store.rs:8431 on_buffer_edited (:8452-8470 builds incremental changes from edits_since against the last snapshot), :331 (buffer_snapshots: buffer_id → server_id → Vec<LspBufferSnapshot>), :14647 (LspBufferSnapshot), :236 (OpenLspBufferHandle — refcounted 'this buffer is open in servers'), :328 (registered_buffers: BufferId → count)`
- Diagnostics storage, per-path grouping and per-worktree summaries — `crates/project/src/lsp_store.rs:320-330 (LocalLspStore.diagnostics: WorktreeId → RelPath → Vec<(server_id, entries)>), :4131 (LspStore.diagnostic_summaries same shape → DiagnosticSummary), :14850 (DiagnosticSummary::new counts only is_primary entries), :4234 (LspStoreEvent::DiagnosticsUpdated{server_id, paths})`
- Multi-root workspace with per-root ignore stacks — `crates/project/src/worktree_store.rs:352 worktrees / :359 visible_worktrees / :700 create_worktree; crates/worktree/src/worktree.rs:255 (ignores_by_parent_abs_path), :208 (enum WorkDirectory InProject/AboveProject)`

**無い**

- Store composition + event re-emission (Project as hub) — `crates/project/src/project.rs:214 (struct Project), :335 (enum Event), :1201-1329 (cx.subscribe wiring), :3581 on_buffer_store_event, :3638 on_lsp_store_event, :3866 on_worktree_store_event`
- Entry identity: ProjectEntryId, inode-based rename detection — `crates/worktree/src/worktree.rs:3896 (struct Entry, fields id/inode/mtime/is_ignored/is_hidden/is_private/is_external), :292 (RemovedEntries with by_inode and by_path)`
- Per-buffer diff bases (head text / index text) and diff recalculation — `crates/project/src/git_store.rs:120 (BufferGitState: head_text, index_text, head_text_buffer, index_text_buffer, head_changed, index_changed), :184 (DiffBasesChange), :195 (DiffKind), :4671 (recalculate_diffs)`
- Language server lifecycle: Starting/Running state and the seed key that decides identity — `crates/project/src/lsp_store.rs:14783 (enum LanguageServerState Starting{startup task, pending_workspace_folders} / Running{adapter, server, ...}), :267 (LanguageServerSeed: worktree_id + name + toolchain + settings), :251 (UnifiedLanguageServer with project_roots), :350 get_or_insert_language_server`


### 機能 crate（一部 13 / 無 6）

**一部のみ — 先に片付ける**

- Panel trait / dock contract — `crates/workspace/src/dock.rs:36 (trait Panel), :98 (PanelHandle), :290 (DockPosition)`
- Panel persistence identity (persistent_name) — `crates/project_panel/src/project_panel.rs:7607, crates/outline_panel/src/outline_panel.rs:4955, crates/terminal_view/src/terminal_panel.rs:1625`
- Startup panel construction — `crates/zed/src/zed.rs:775 initialize_panels, :874 initialize_agent_panel`
- Outline panel — `crates/outline_panel/src/outline_panel.rs:653 init, :4954 impl Panel`
- Git panel / git integration — `crates/git_ui/src/git_panel.rs:8064 impl Panel (crate is 44979 lines over 32 files)`
- Agent panel / agent runtime — `crates/agent_ui/src/agent_panel.rs:371 init, :4954 impl Panel; crates/agent (85010 lines, 56 files)`
- Debugger panel / DAP client — `crates/debugger_ui/src/debugger_panel.rs:1541 impl Panel; crates/dap (2800 lines), initialised at crates/zed/src/main.rs:593`
- Search: buffer search bar vs project search item — `crates/search/src/search.rs:1-247 plus buffer_search.rs, project_search.rs, search_bar.rs, text_finder.rs (crate 12698 lines)`
- Extension host (wasm) and extension store UI — `crates/extension_host/src/extension_host.rs (1995 lines), crates/extensions_ui/src/extensions_ui.rs (2096), registered at crates/zed/src/main.rs:526 and :663`
- Picker: one modal, many delegates — `crates/picker/src/picker.rs (1898 lines); delegates in file_finder/src/file_finder.rs:1, command_palette/src/command_palette.rs:1, tab_switcher, outline, project_symbols, theme_selector, language_selector, toolchain_selector, recent_projects, go_to_line`
- Diagnostics as a multibuffer Item — `crates/diagnostics/src/diagnostics.rs (1154 lines), init at crates/zed/src/main.rs:734`
- Task templates and spawn UI — `crates/tasks_ui/src/tasks_ui.rs (625 lines), init at crates/zed/src/main.rs:747; model in crates/task`
- Status bar, title bar, breadcrumbs, activity indicator — `crates/title_bar/src/title_bar.rs (1446 lines), crates/breadcrumbs (127), crates/activity_indicator (781), crates/notifications (684)`

**無い**

- Crate init() registration order — `crates/zed/src/main.rs:491-771`
- Settings UI (schema-driven) — `crates/settings_ui/src/settings_ui.rs (6797 lines) with page_data.rs, pages/, components/`
- Vim modal editing as an editor addon — `crates/vim/src/vim.rs:286 init (crate 47454 lines, 39 files); registered after editor at crates/zed/src/main.rs:761`
- Collaboration (collab, collab_ui, call, channel, livekit) — `crates/collab_ui/src/collab_ui.rs (62 lines entry; crate 6392, collab server 15013), init at crates/zed/src/main.rs:749 (channel) and :771 (call)`
- REPL / notebook — `crates/repl/src/repl.rs:31 init (crate 12400 lines), notebook initialised separately at crates/zed/src/main.rs:733`
- Auxiliary viewers (image_viewer, markdown_preview, svg_preview, csv_preview) — `crates/image_viewer (1050 lines), crates/markdown_preview (2609), init at crates/zed/src/main.rs:732`


## 3. 合計

| | 件数 |
| --- | ---: |
| 一部のみ（先に片付ける）| **99** |
| 無い | **69** |
| 計 | **168** |

## 4. 着手順の原則

1. **同じ層の「一部のみ」をまとめて片付ける。** 1 件ずつ直すと、
   今日 5 回起きた「テーマの値はあるが別の色を塗る」のように同じ構図を何度も踏む

2. **下の層から。** デザインシステムが無いままエディタの見た目を直すと、
   AppKit のクラスに直接書くことになり、次の項目でまた同じことをする

3. **1 つの条件で確認したものは、その条件でしか確認されていない。**
   単一ファイル・フォルダ・git リポジトリの 3 条件で見る
