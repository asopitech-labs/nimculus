import ScreenCaptureKit
import AppKit
import Foundation

@available(macOS 12.3, *)
func capture(owner: String, to path: String) async throws {
  let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                    onScreenWindowsOnly: true)
  guard let win = content.windows.first(where: {
    $0.owningApplication?.applicationName == owner &&
    ($0.frame.width > 400 && $0.frame.height > 300) && $0.windowLayer == 0
  }) else { print("window not found: \(owner)"); return }

  let filter = SCContentFilter(desktopIndependentWindow: win)
  let cfg = SCStreamConfiguration()
  cfg.width  = Int(win.frame.width  * 2)   // retina
  cfg.height = Int(win.frame.height * 2)
  cfg.showsCursor = false
  cfg.scalesToFit = false

  let img = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                       configuration: cfg)
  let rep = NSBitmapImageRep(cgImage: img)
  guard let data = rep.representation(using: .png, properties: [:]) else { return }
  try data.write(to: URL(fileURLWithPath: path))
  print("\(owner)\t\(img.width)x\(img.height)\tframe=\(Int(win.frame.width))x\(Int(win.frame.height))\t-> \(path)")
}

// Connecting to the window server requires an initialized NSApplication;
// without it SCContentFilter aborts in CGS_REQUIRE_INIT.
_ = NSApplication.shared
let args = CommandLine.arguments
if #available(macOS 12.3, *), args.count >= 3 {
  let sem = DispatchSemaphore(value: 0)
  Task {
    do { try await capture(owner: args[1], to: args[2]) }
    catch { print("error: \(error)") }
    sem.signal()
  }
  sem.wait()
}
