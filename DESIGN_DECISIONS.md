# Design Decisions

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
the edit boundary. Edit records store before/after text so Undo/Redo and
multi-cursor transactions share one atomic path. UTF-8 byte offsets remain the
internal source of truth; grapheme and UTF-16 positions are derived at API
boundaries.

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

## M2-012: Keep placeholder drawing separate from M3 text and image resources

M2 now emits visible placeholder rectangles for text and image paint kinds,
so every initial paint kind has a native path without inventing a texture
resource ABI prematurely. M3 owns Core Text text surfaces; a future image
resource API can replace the image placeholder without changing layout or
dirty-region contracts. Affine transforms are applied in PaintList before
dirty filtering, keeping hit-test and repaint bounds in logical UI space.

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
