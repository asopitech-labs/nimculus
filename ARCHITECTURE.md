# Nimculus Architecture

## Layers

```text
macOS platform (Cocoa / Metal / input)
              ↓
NimNUI platform contract and renderer
              ↓
Nimculus application layer
```

The OS-independent ABI value types are isolated in
`src/nimnui/platform/contracts.nim`. The macOS Objective-C implementation is
isolated under `src/nimnui/platform/macos`; Nim code communicates with it
through the small C ABI declared in `platform.h` and wrapped by
`platform.nim`. Future Windows/Linux backends consume the same value contract
without importing Cocoa or Metal code.

## M1 boundary

M1 provides a Cocoa window backed by `CAMetalLayer`, a Metal clear pass and
rectangle pass, Retina-aware drawable sizing, basic resize handling, and
keyboard/pointer/scroll input accounting. Editor state, text shaping, IME,
layout, and command routing are intentionally deferred to later milestones.

## M2/M3 boundary

M2 provides the platform-independent NimNUI core: geometry, a parent/child UI
tree, Row/Column/Stack layout, alignment, scrolling and viewport clipping,
focus and dirty state, capture/target/bubble event phases, command shortcuts,
control descriptors, and a dirty-filtered `PaintList`. Native macOS input is
translated into Nim events and the demo UI submits a rectangle to Metal.

M3 provides UTF-8/grapheme position tracking, combining and joiner handling,
Core Text font enumeration and measurement, a reusable glyph atlas with
eviction and visible-range layout, Core Graphics rasterization into an
`MTLTexture`, and a Metal text pipeline. The native view implements the
`NSTextInputClient` contract, forwards composition/commit events to Nim,
returns screen-space candidate rectangles, and exposes the macOS clipboard.

## M4/M5 editor layers

```text
FileDocument / EditorSession / EditorView
                 ↓
PieceTable + edit transactions + line/UTF-16 indexes
                 ↓
NimNUI text, selection, cursor, status and native AppKit services
```

The Piece Table is independent of the UI and is exercised by deterministic
fuzz tests. M5 services preserve CRLF/LF style, detect external changes, and
persist tabs, recent files, and recovery data separately from rendering.
LSP diagnostics are resolved at this boundary from UTF-16 line/character
positions to safe UTF-8 byte ranges before a renderer or editor command sees
them; surrogate-pair and out-of-line positions are clamped.

## M6 workspace layer

`src/nimculus/workspace.nim` owns lazy directory enumeration, `.gitignore`
filtering, multiple roots, path-confined file operations, fuzzy/ripgrep search,
Git Worktree discovery, cancellable file search, and change batching. The macOS-only
`workspace_macos.m` file is a narrow FSEvents bridge; CoreServices types do
not leak into the application layer. File contents are loaded only when a
search or editor open operation explicitly requests them.

## M7 syntax layer

`tree_sitter.nim` exposes a small parser/tree API and statically registers the
initial Nim, Rust, TypeScript, Python, JSON, and Markdown grammars. The core
runtime and every generated grammar are compiled as separate C translation
units because generated parsers reuse internal symbol names. `syntax.nim`
converts syntax nodes into highlight spans and structural services.

## M8 LSP boundary

`src/nimculus/lsp.nim` owns protocol concerns independently from the editor
and UI: UTF-8 byte-accurate `Content-Length` framing, incremental frame
decoding, JSON-RPC request construction, cancellation state, and
method-scoped stale-response rejection. This follows Zed's separation of
transport/protocol handling from the project language-server store. Process
lifecycle, stdio reads, document synchronization, and feature adapters must
build on this boundary rather than parsing JSON directly in UI callbacks.
`LspProcess` keeps stdout as framed protocol data, exposes explicit stop and
restart transitions, and is driven by a non-blocking AppKit idle callback;
`readMessages` never belongs on the Metal render callback path.
`LspSession` owns the initialize handshake, pending-response transitions, and
per-document diagnostics cache, while feature consumers receive decoded JSON
through the request generation they initiated.
The protocol module also converts standard response shapes into locations,
text edits, completion items, hover text, and symbols; these parsers reject
stale responses before application state can consume them.

When `NIMCULUS_LSP_COMMAND` is configured, `lsp_editor_bridge` owns the
active-document URI, language ID, and monotonically increasing full-sync
version. It sends `didOpen`/`didChange`/`didClose`, polls the non-blocking
transport from the macOS idle callback, and converts cached diagnostics into a
separate native span array. No language server is started when the setting is
absent.

Feature responses are retained by request ID until the owning editor bridge
consumes them. Completion stores its cursor snapshot and cancels the previous
request before issuing a new one; the macOS popup is only a rendering surface,
and accepted candidates are applied through the Piece Table.

## M9 Git boundary

`src/nimculus/git_service.nim` keeps Git CLI process management separate from
the UI. Status uses porcelain v1 with NUL delimiters so filenames containing
spaces or colons remain lossless; rename/copy records retain both new and old
paths, and conflict states are derived from the two index/worktree status
columns. Diff, stage/unstage, commit, log, blame, branch, and HEAD operations
return explicit results; unified diff headers are converted into old/new line
ranges and hunk kinds for inline and gutter consumers, and checkout is kept as
an explicit source-plus-path operation. Long-running commands can be represented by a
`GitJob` and terminated without blocking the Metal or AppKit event loop. The
application can later layer inline diff and gutter presentation on these
stable repository contracts.
