// Post real scroll-wheel events to whichever app is frontmost.
//
// Key events are not a stand-in for scrolling: an editor can ignore Page Down
// entirely and still be slow to scroll, which is exactly how a measurement
// built on key events can report a cost for work that never happened.
//
// Scroll is delivered to the window under the pointer, not to the frontmost
// app, so the pointer is warped onto the target first.
//
// Usage: post_scroll <count> <x> <y> [lines_per_event] [interval_ms]
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let count = arguments.count > 1 ? Int(arguments[1]) ?? 60 : 60
let pointX = arguments.count > 3 ? Double(arguments[2]) ?? 0 : 0
let pointY = arguments.count > 3 ? Double(arguments[3]) ?? 0 : 0
let lines = arguments.count > 4 ? Int32(arguments[4]) ?? 3 : 3
let intervalMs = arguments.count > 5 ? UInt32(arguments[5]) ?? 16 : 16

if pointX > 0 || pointY > 0 {
  CGWarpMouseCursorPosition(CGPoint(x: pointX, y: pointY))
  CGAssociateMouseAndMouseCursorPosition(1)
  usleep(150_000)
}

guard CGPreflightListenEventAccess() || CGRequestListenEventAccess() else {
  FileHandle.standardError.write(
    "post_scroll: this process may not post events. Grant Accessibility to the\n"
      .data(using: .utf8)!)
  FileHandle.standardError.write(
    "app that runs it, then start that app again.\n".data(using: .utf8)!)
  exit(2)
}

for index in 0..<count {
  // Alternate direction so a document end never turns the rest of the run into
  // free no-ops.
  let delta = index % 2 == 0 ? -lines : lines
  guard
    let event = CGEvent(
      scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0,
      wheel3: 0)
  else { continue }
  event.post(tap: .cghidEventTap)
  usleep(intervalMs * 1000)
}
