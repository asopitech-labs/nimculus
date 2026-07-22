# Design Decisions

## M11-006: Bound update artifacts before verification and installation

Zed downloads update bodies in bounded chunks and verifies the completed
artifact before installation. Nimculus now gives curl a 1 GiB maximum, checks
the destination size while an asynchronous download is running, terminates
and removes an oversized file, and repeats the size check before SHA-256
verification. This prevents a malformed or compromised update endpoint from
consuming unbounded disk space.

## M9-006: Bound Git process output before it reaches UI state

Zed compresses large commit diffs for presentation and applies explicit
limits before exposing process output to UI state. Nimculus now consumes Git
stdout/stderr through a non-blocking stream while the process is running,
keeps at most `MaxGitOutputBytes` (16 MiB), and records `outputTruncated`.
The retained suffix is cut only at UTF-8 and complete-line boundaries. This
applies to status, diff, log, blame, and command results, preventing a large
repository or generated diff from blocking on a full pipe or growing the
editor's memory without limit.

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

## M10-005: Compact scrollback in batches without changing its public shape

Zed's terminal configuration passes an explicit maximum scroll history to a
deque-backed terminal implementation. Nimculus already exposes a sequence for
compatibility, so replacing the field type would be an unnecessary API break.
Instead, history now retains the newest rows and compacts in batches below the
configured limit. This keeps memory bounded and avoids repeatedly shifting the
whole sequence with `delete(0)` during long-running terminal sessions.

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

## M20-003: Measure input latency through the next presented frame

Zed's input-latency tracker records the first input received in a frame
interval and measures from that input until the next frame is presented.
Nimculus follows the same boundary: macOS records the first event with
mach_absolute_time and Windows records the first event with QPC, then both
backends publish the elapsed value after a successful frame submission and
reset the pending timestamp. This avoids reporting the time of an input that
arrived after the frame's input interval and keeps the metric tied to a
presented frame.

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
