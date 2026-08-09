import XCTest
import AppKit

/// The Zed comparison, driven through XCUITest inside the test VM.
///
/// This is deliberately *not* the ScreenCaptureKit + CGEvent path used from the
/// host. Those need screen-recording and accessibility grants; XCUITest reaches
/// the machine through testmanagerd and needs neither. Running both editors in
/// the same guest, back to back, also removes the conditions that kept breaking
/// the host measurements: no other window can overlap, the screen cannot sleep,
/// and neither app can steal the developer's focus.
///
/// Every number here is paired with proof that the view actually moved. A
/// scroll run that delivers no events is cheap and meaningless - measuring on
/// the host once produced 1.25 ms/scroll, faster than Zed, because not a single
/// wheel event had arrived.
final class ZedParityTests: XCTestCase {
  private static let outDir = URL(
    fileURLWithPath: "/Users/admin/nimculus/build/ui-test", isDirectory: true)

  private static let document = "/Users/admin/nimculus/DEVELOPMENT_GUIDELINES.md"

  /// Scroll events per measured run, matching tools/scroll_cost.sh.
  private static let scrollCount = 40

  /// Event counts to calibrate pixels-per-event at. One fixed count cannot
  /// serve both editors; the harness uses the first step whose displacement is
  /// large enough to correlate and small enough to stay on screen.
  private static let calibrationSteps = [1, 2, 4, 8, 16]

  override func setUpWithError() throws {
    continueAfterFailure = false
    try FileManager.default.createDirectory(
      at: Self.outDir, withIntermediateDirectories: true)
  }

  // MARK: - helpers

  private func write(_ data: Data, _ name: String) {
    try? data.write(to: Self.outDir.appendingPathComponent(name))
  }

  /// Total CPU milliseconds consumed by every process with this name.
  ///
  /// Reading the app's own accounting is what makes the number comparable
  /// between Nimculus and Zed: it excludes the driving overhead, which differs
  /// between the two.
  private func cpuMilliseconds(ofProcessNamed name: String) -> Int {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/sh")
    ps.arguments = ["-c", "ps -Ao time=,comm= | grep -i '\(name)$' | grep -v grep"]
    let pipe = Pipe()
    ps.standardOutput = pipe
    try? ps.run()
    let out = String(
      data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    ps.waitUntilExit()

    var total = 0
    for line in out.split(separator: "\n") {
      guard let field = line.split(separator: " ").first else { continue }
      // ps prints [[hh:]mm:]ss.ff
      let parts = field.split(separator: ":").map(String.init)
      guard let secondsField = parts.last else { continue }
      let seconds = secondsField.split(separator: ".").map(String.init)
      var ms = (Int(seconds.first ?? "0") ?? 0) * 1000
      if seconds.count > 1 { ms += (Int(seconds[1]) ?? 0) * 10 }
      if parts.count >= 2 { ms += (Int(parts[parts.count - 2]) ?? 0) * 60_000 }
      if parts.count >= 3 { ms += (Int(parts[parts.count - 3]) ?? 0) * 3_600_000 }
      total += ms
    }
    return total
  }

  /// Fraction of pixels that differ between two PNGs, as a share of the image.
  private static func changedPixelShare(_ a: Data, _ b: Data) -> Double {
    guard let ia = NSBitmapImageRep(data: a), let ib = NSBitmapImageRep(data: b),
          ia.pixelsWide == ib.pixelsWide, ia.pixelsHigh == ib.pixelsHigh,
          let pa = ia.bitmapData, let pb = ib.bitmapData else { return 0 }
    let bytes = ia.bytesPerRow * ia.pixelsHigh
    let spp = max(1, ia.samplesPerPixel)
    var changed = 0
    var i = 0
    while i + spp <= bytes {
      var differs = false
      for c in 0..<spp where pa[i + c] != pb[i + c] { differs = true; break }
      if differs { changed += 1 }
      i += spp
    }
    let total = max(1, ia.pixelsWide * ia.pixelsHigh)
    return Double(changed) / Double(total)
  }

  private func window(of app: XCUIApplication) -> XCUIElement {
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 30), "no window")
    return window
  }

  /// Scroll, and return the per-event CPU cost plus a calibration pair.
  ///
  /// The two editors move very different distances for the same synthetic
  /// wheel delta: 40 events take Zed 708px but carry Nimculus from line 1 to
  /// line 163. Comparing milliseconds per event across that is comparing
  /// different amounts of work, so the run also records a short, screen-bounded
  /// scroll the harness can correlate into pixels-per-event. Cost is then
  /// normalised to milliseconds per scrolled pixel.
  private func measureScroll(
    app: XCUIApplication, processName: String, label: String
  ) -> Double {
    let window = self.window(of: app)
    let target = window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))

    func parkAtTop() {
      for _ in 0..<40 { target.scroll(byDeltaX: 0, deltaY: 120) }
      sleep(1)
    }

    // Calibration: capture at several event counts. The two editors move very
    // different distances per event, so a single count is either too small to
    // correlate (Zed at 2 events moved ~35px and read as "no movement") or
    // large enough to leave the screen entirely (Nimculus at 8 events). The
    // harness picks whichever step produced a usable, screen-bounded shift.
    parkAtTop()
    write(window.screenshot().pngRepresentation, "\(label)-cal-0.png")
    var delivered = 0
    for step in Self.calibrationSteps {
      while delivered < step {
        target.scroll(byDeltaX: 0, deltaY: -120)
        delivered += 1
      }
      sleep(1)
      write(window.screenshot().pngRepresentation, "\(label)-cal-\(step).png")
    }

    // Timed run.
    parkAtTop()
    let before = window.screenshot().pngRepresentation
    write(before, "\(label)-before.png")
    let start = cpuMilliseconds(ofProcessNamed: processName)
    for _ in 0..<Self.scrollCount { target.scroll(byDeltaX: 0, deltaY: -120) }
    sleep(1)
    let end = cpuMilliseconds(ofProcessNamed: processName)
    write(window.screenshot().pngRepresentation, "\(label)-after.png")

    return Double(end - start) / Double(Self.scrollCount)
  }

  // MARK: - tests

  func testNimculusScrollCost() {
    let app = XCUIApplication(bundleIdentifier: "com.asopitech.nimculus")
    app.launchArguments = [Self.document]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
    sleep(5)

    let msPerScroll = measureScroll(app: app, processName: "Nimculus", label: "nimculus-scroll")
    write(Data("\(msPerScroll)\n".utf8), "nimculus-ms-per-scroll.txt")
  }

  func testZedScrollCost() {
    let app = XCUIApplication(bundleIdentifier: "dev.zed.Zed")
    app.activate()
    if !app.wait(for: .runningForeground, timeout: 10) {
      app.launch()
      XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
    }
    sleep(5)

    let msPerScroll = measureScroll(app: app, processName: "zed", label: "zed-scroll")
    write(Data("\(msPerScroll)\n".utf8), "zed-ms-per-scroll.txt")
  }

  /// Window-only images of both editors, for the pixel comparison.
  func testCaptureBothWindows() {
    let zed = XCUIApplication(bundleIdentifier: "dev.zed.Zed")
    zed.activate()
    sleep(3)
    write(window(of: zed).screenshot().pngRepresentation, "zed-window.png")

    let nimculus = XCUIApplication(bundleIdentifier: "com.asopitech.nimculus")
    nimculus.launchArguments = [Self.document]
    nimculus.launch()
    sleep(5)
    write(window(of: nimculus).screenshot().pngRepresentation, "nimculus-window.png")
  }

  // MARK: - profiling

  /// A scroll burst long enough that a `sample` window is guaranteed to land
  /// inside it. Sampling the ordinary measurement runs caught mostly idle
  /// wait: the burst is over in a moment and the profile was dominated by
  /// __workq_kernreturn and mach_msg2_trap in both editors, which says nothing.
  private func longScroll(app: XCUIApplication) {
    let window = self.window(of: app)
    let target = window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
    for _ in 0..<20 { target.scroll(byDeltaX: 0, deltaY: 120) }
    // ~30s of continuous scrolling, alternating direction so the view never
    // parks against an end and starts producing free no-op events.
    for round in 0..<12 {
      let delta: CGFloat = round % 2 == 0 ? -120 : 120
      for _ in 0..<60 { target.scroll(byDeltaX: 0, deltaY: delta) }
    }
  }

  func testNimculusLongScroll() {
    let app = XCUIApplication(bundleIdentifier: "com.asopitech.nimculus")
    app.launchArguments = [Self.document]
    // Report the atlas hit rate: guessing from sample offsets got the diagnosis
    // wrong twice, so measure whether the lookups actually hit.
    app.launchEnvironment = ["NIMCULUS_GLYPH_ATLAS_DEBUG": "1"]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
    sleep(3)
    longScroll(app: app)
  }

  func testZedLongScroll() {
    let app = XCUIApplication(bundleIdentifier: "dev.zed.Zed")
    app.activate()
    if !app.wait(for: .runningForeground, timeout: 10) {
      app.launch()
      XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
    }
    sleep(3)
    longScroll(app: app)
  }

  /// Capture a multi-line selection in both editors, for the rounded-selection
  /// comparison. Zed rounds the outline of the whole region, so the corners
  /// where consecutive lines differ in width are what to look at.
  func testCaptureMultiLineSelection() {
    for (id, label) in [("dev.zed.Zed", "zed"), ("com.asopitech.nimculus", "nimculus")] {
      let app = XCUIApplication(bundleIdentifier: id)
      // Both editors must be showing the same document. Activating Zed without
      // opening one caught it on its onboarding screen, and the capture pair
      // was not a comparison at all.
      app.launchArguments = [Self.document]
      app.launch()
      XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
      sleep(6)

      let window = self.window(of: app)
      XCTAssertTrue(
        Self.showsDocument(window),
        "\(label) is not showing \(Self.document); the capture would not be a comparison")

      // Click into the body, then extend the selection down several lines so
      // the region spans lines of differing width.
      window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25)).click()
      sleep(1)
      for _ in 0..<6 {
        window.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: .shift)
      }
      sleep(2)
      write(window.screenshot().pngRepresentation, "\(label)-selection.png")
    }
  }

  /// True when the window is showing the document rather than a welcome or
  /// onboarding screen. Zed puts the file name in the window title; Nimculus
  /// titles its window "Nimculus" and names the document in the tab and the
  /// breadcrumb, so matching on the title alone rejected a window that was in
  /// fact correct. Accept any descendant that carries the name.
  private static func showsDocument(_ window: XCUIElement) -> Bool {
    let name = (Self.document as NSString).lastPathComponent
    if window.title.contains(name) { return true }
    let stem = (name as NSString).deletingPathExtension
    let predicate = NSPredicate(
      format: "label CONTAINS %@ OR title CONTAINS %@ OR value CONTAINS %@",
      stem, stem, stem)
    return window.descendants(matching: .any).matching(predicate).firstMatch
      .waitForExistence(timeout: 10)
  }
}
