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
then restores the active recovery buffer when present. A main-loop tick writes
the active dirty document to a separate recovery file, while a successful save
or an explicit Don't Save decision removes it. The recovery file intentionally
contains only the active buffer; the session file remains the source of truth
for tab paths and recent files.

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

Editor navigation and deletion use the same `textPositions` boundary list as
layout and cursor conversion. UTF-8 codepoint boundaries are insufficient for
combining sequences and emoji ZWJ sequences, so Backspace/Delete and word
movement must never introduce a boundary inside one grapheme cluster.
