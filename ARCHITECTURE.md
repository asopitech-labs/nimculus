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
