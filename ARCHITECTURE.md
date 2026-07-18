# Nimculus Architecture

## Layers

```text
macOS platform (Cocoa / Metal / input)
              ↓
NimNUI platform contract and renderer
              ↓
Nimculus application layer
```

The macOS Objective-C implementation is isolated under
`src/nimnui/platform/macos`. Nim code communicates with it through the small
C ABI declared in `platform.h` and wrapped by `platform.nim`.

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
