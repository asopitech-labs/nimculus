# Design Decisions

## M0-001: Use Nim standard tooling for the first quality gate

`nimpretty` is exposed through `nimble format` and `nim check` through
`nimble lint`. Both run without an additional package manager dependency and
the static check is part of the macOS CI gate. A third-party linter can be
added later only when it covers a demonstrated gap.

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

## M6-003: Search yields cooperatively and streams file contents

The UI-facing `SearchJob` processes a bounded number of files and lines per
poll, preserves pending directory/file state between polls, and reads the
active file with `readLine` instead of loading the complete file. Cancellation
closes an active file immediately. The existing synchronous search functions
remain as convenience APIs, while application UI code must use the yielding
job for large workspaces.
