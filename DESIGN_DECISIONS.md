# Design Decisions

## M1-001: Keep the macOS bridge in Objective-C

The first macOS vertical slice uses Objective-C for Cocoa and Metal APIs and
exposes a small C ABI to Nim. This keeps Objective-C Runtime details and
framework ownership out of NimNUI and the application layer while the platform
contract is still evolving.

## M1-002: Use CAMetalLayer directly

NimNUI owns a `CAMetalLayer` through its macOS view. Drawable size is derived
from the backing scale factor during layout, so logical points and drawable
pixels remain distinct for Retina displays.
