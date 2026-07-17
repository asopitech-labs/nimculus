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

M2 introduces the platform-independent NimNUI core: geometry, a parent/child
UI tree, Row/Column/Stack layout, focus and dirty state, capture/target/bubble
event phases, and control descriptors. It does not yet submit UI primitives to
Metal or connect all native events to the tree.

M3 introduces UTF-8 and minimal grapheme position tracking, a reusable glyph
atlas allocator, and the native `NSTextInputClient` boundary for composition.
Font shaping, glyph rasterization into Metal textures, candidate positioning,
and editor-buffer integration remain follow-up work.
