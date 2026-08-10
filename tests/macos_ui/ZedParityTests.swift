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
  private static let documentFirstLine = "# Nimculus 開発ガイドライン"

  /// A file whose text mixes scripts, symbols and several kinds of emoji.
  /// DEVELOPMENT_GUIDELINES.md contains no emoji at all, so it cannot show
  /// whether the colour path draws them.
  private static let emojiDocument = "/Users/admin/nimculus/tests/macos_ui/emoji_sample.md"
  private static let emojiContentMarkers = [
    "# Mixed script sample",
    "Emoji, plain:",
    "Emoji, ZWJ sequence:"
  ]

  /// Created inside the guest so both editors see the same repository and file.
  private static let inlineBlameRepository = "/Users/admin/inline-blame-repo"
  private static let inlineBlameDocument =
    "/Users/admin/inline-blame-repo/inline_blame.txt"

  /// A multi-file repository for the workspace parity capture. The target file
  /// is changed after its initial commit so the branch, file tree, git hunk,
  /// and status items all have something to render.
  private static let workspaceRepository = "/Users/admin/workspace-capture-repo"
  private static let workspaceDocument =
    "/Users/admin/workspace-capture-repo/workspace_target.txt"
  private static let workspaceDocumentFirstLine = "# Workspace capture target"

  /// Nimculus persists this in the guest's per-user Application Support
  /// directory.  Reset it between XCTest cases because app relaunches reuse
  /// the same guest user and `restoreSession()` reads it on every startup.
  private static let nimculusSessionDirectory =
    "/Users/admin/Library/Application Support/Nimculus"

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
    resetNimculusSession()
    removeInlineBlameRepositories()
    removeWorkspaceRepository()
  }

  // MARK: - helpers

  private func write(_ data: Data, _ name: String) {
    try? data.write(to: Self.outDir.appendingPathComponent(name))
  }

  private func resetNimculusSession() {
    let app = XCUIApplication(bundleIdentifier: "com.asopitech.nimculus")
    if app.state != .notRunning {
      app.terminate()
      _ = app.wait(for: .notRunning, timeout: 10)
    }
    for name in ["session.json", "active.recovery"] {
      try? FileManager.default.removeItem(
        atPath: Self.nimculusSessionDirectory + "/" + name)
    }
  }

  private func removeInlineBlameRepositories() {
    let fileManager = FileManager.default
    let parent = (Self.inlineBlameRepository as NSString).deletingLastPathComponent
    let prefix = (Self.inlineBlameRepository as NSString).lastPathComponent + "-padding-"
    let generated = (try? fileManager.contentsOfDirectory(atPath: parent)) ?? []
    let names = generated.filter { $0.hasPrefix(prefix) }
      .map { (parent as NSString).appendingPathComponent($0) }
    for path in [Self.inlineBlameRepository] + names {
      try? fileManager.removeItem(atPath: path)
    }
  }

  private func removeWorkspaceRepository() {
    try? FileManager.default.removeItem(atPath: Self.workspaceRepository)
  }

  private func prepareInlineBlameRepository(
    repositoryPath: String? = nil) throws {
    let repository = URL(fileURLWithPath: repositoryPath ?? Self.inlineBlameRepository)
    let fileURL = repository.appendingPathComponent("inline_blame.txt")
    try FileManager.default.createDirectory(
      at: repository, withIntermediateDirectories: true)
    try Data("first line\nsecond line\nthird line\n".utf8).write(to: fileURL)

    let commands = [
      ["init", "-q", repository.path],
      ["-C", repository.path, "config", "user.name", "Nimculus UI Test"],
      ["-C", repository.path, "config", "user.email", "ui-test@nimculus.local"],
      ["-C", repository.path, "add", fileURL.path],
      ["-C", repository.path, "commit", "-q", "-m", "Initial inline blame sample"]
    ]
    for arguments in commands {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = arguments
      try process.run()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0, "git command failed: git \(arguments.joined(separator: " "))")
    }
  }

  private func setInlineBlamePadding(_ padding: Int,
                                     repositoryPath: String? = nil) throws {
    let settingsDirectory = URL(fileURLWithPath: repositoryPath ?? Self.inlineBlameRepository)
      .appendingPathComponent(".nimculus")
    try FileManager.default.createDirectory(
      at: settingsDirectory, withIntermediateDirectories: true)
    let settings = "{\"git\":{\"inlineBlame\":{\"padding\":\(padding)}}}\n"
    try Data(settings.utf8).write(to: settingsDirectory.appendingPathComponent("settings.json"))
  }

  private func prepareWorkspaceRepository() throws {
    let fileManager = FileManager.default
    let repository = URL(fileURLWithPath: Self.workspaceRepository)
    try fileManager.createDirectory(at: repository, withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: repository.appendingPathComponent("src"), withIntermediateDirectories: true)
    try Data("# Workspace capture target\ncommitted line\nchanged line\n".utf8)
      .write(to: repository.appendingPathComponent("workspace_target.txt"))
    try Data("# Workspace notes\nThis file keeps the project tree non-trivial.\n".utf8)
      .write(to: repository.appendingPathComponent("notes.md"))
    try Data("helper = true\n".utf8)
      .write(to: repository.appendingPathComponent("src/helper.txt"))

    let commands = [
      ["init", "-q", repository.path],
      ["-C", repository.path, "config", "user.name", "Nimculus UI Test"],
      ["-C", repository.path, "config", "user.email", "ui-test@nimculus.local"],
      ["-C", repository.path, "add", "."],
      ["-C", repository.path, "commit", "-q", "-m", "Initial workspace capture sample"],
      ["-C", repository.path, "branch", "-M", "ui-132-workspace"]
    ]
    for arguments in commands {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments = arguments
      try process.run()
      process.waitUntilExit()
      XCTAssertEqual(
        process.terminationStatus, 0,
        "git command failed: git \(arguments.joined(separator: " "))")
    }

    // Leave a tracked-file hunk in the working tree while keeping the target
    // file's first line stable for the Nimculus accessibility assertion.
    try Data("# Workspace capture target\ncommitted line\nworking tree hunk\n".utf8)
      .write(to: repository.appendingPathComponent("workspace_target.txt"))
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

  /// Put the editor focus and cursor at a position independent of window size.
  ///
  /// A normalized click maps to a different document row when the two editor
  /// windows differ in height. The fixed point offset below is only inside the
  /// editor body and establishes focus; Cmd+Up determines the final cursor
  /// position in both editors.
  private func moveCursorToDocumentStart(in window: XCUIElement) {
    let editorPoint = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
      .withOffset(CGVector(dx: 250, dy: 150))
    editorPoint.click()
    window.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: .command)
    sleep(1)
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
  ///
  /// Both must be showing the same document. Activating Zed without opening one
  /// caught it on its onboarding screen and the pair compared an editor against
  /// a welcome page - the same mistake the selection capture made, in a second
  /// test, so the guard lives in one place now.
  func testCaptureBothWindows() {
    for (id, label) in [("dev.zed.Zed", "zed"), ("com.asopitech.nimculus", "nimculus")] {
      let app = XCUIApplication(bundleIdentifier: id)
      app.launchArguments = [Self.document]
      app.launch()
      XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
      sleep(6)
      let window = self.window(of: app)
      XCTAssertTrue(
        Self.showsDocument(window),
        "\(label) is not showing \(Self.document); the capture would not be a comparison")
      if let text = Self.accessibleEditorText(window, containing: Self.documentFirstLine) {
        let firstLine = text.components(separatedBy: .newlines).first ?? ""
        XCTAssertEqual(firstLine, Self.documentFirstLine,
                       "\(label) is showing the wrong first line")
      } else {
        XCTAssertTrue(
          Self.showsEditorBody(window.screenshot().pngRepresentation),
          "\(label) shows the document tab but no rendered editor body")
      }
      moveCursorToDocumentStart(in: window)
      write(window.screenshot().pngRepresentation, "\(label)-window.png")
    }
  }

  private func captureNimculusInlineBlame(
    padding: Int, repositoryPath: String? = nil) throws {
    let repository = repositoryPath ??
      "\(Self.inlineBlameRepository)-padding-\(padding)"
    let document = "\(repository)/inline_blame.txt"
    if repositoryPath == nil {
      try prepareInlineBlameRepository(repositoryPath: repository)
    }
    try setInlineBlamePadding(padding, repositoryPath: repository)
    let app = XCUIApplication(bundleIdentifier: "com.asopitech.nimculus")
    defer {
      app.terminate()
      sleep(2)
    }
    app.launchArguments = [repository, document]
    app.launchEnvironment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
    ]
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
    sleep(6)

    let window = self.window(of: app)
    XCTAssertTrue(
      Self.showsDocument(window, document: document),
      "nimculus padding=\(padding) is not showing the comparison document")
    moveCursorToDocumentStart(in: window)
    sleep(10)
    let screenshot = window.screenshot().pngRepresentation
    let name = padding == 7 ? "nimculus-inline-blame.png" :
      "nimculus-inline-blame-padding-\(padding).png"
    write(screenshot, name)
    XCTAssertTrue(
      Self.showsInlineBlame(screenshot),
      "nimculus padding=\(padding) did not render inline blame")
    XCTAssertTrue(
      Self.showsInlineBlameBody(screenshot),
      "nimculus padding=\(padding) did not render the first line")
  }

  /// Capture inline blame from the same committed file in both editors.
  /// The repository is created in the guest because the source archive does
  /// not contain the host worktree's .git directory.
  func testCaptureInlineBlame() throws {
    defer {
      resetNimculusSession()
      XCUIApplication(bundleIdentifier: "dev.zed.Zed").terminate()
      removeInlineBlameRepositories()
    }
    try prepareInlineBlameRepository()
    // Keep the parity capture at Zed's default padding, then restart
    // Nimculus at padding zero in this same XCTest.
    try setInlineBlamePadding(7)
    let zed = XCUIApplication(bundleIdentifier: "dev.zed.Zed")
    zed.launchArguments = [Self.inlineBlameRepository, Self.inlineBlameDocument]
    zed.launch()
    XCTAssertTrue(zed.wait(for: .runningForeground, timeout: 60))
    sleep(6)
    let zedWindow = self.window(of: zed)
    XCTAssertTrue(Self.showsDocument(zedWindow, document: Self.inlineBlameDocument))
    moveCursorToDocumentStart(in: zedWindow)
    sleep(10)
    let zedScreenshot = zedWindow.screenshot().pngRepresentation
    XCTAssertTrue(Self.showsInlineBlame(zedScreenshot), "zed did not render inline blame")
    XCTAssertTrue(Self.showsInlineBlameBody(zedScreenshot), "zed did not render the first line")
    write(zedScreenshot, "zed-inline-blame.png")
    zed.terminate()
    sleep(2)

    try captureNimculusInlineBlame(
      padding: 7, repositoryPath: Self.inlineBlameRepository)
    try captureNimculusInlineBlame(
      padding: 0, repositoryPath: Self.inlineBlameRepository)
  }

  /// Capture both editors with the same git repository open as a workspace and
  /// the same tracked file active inside it. This intentionally complements
  /// testCaptureBothWindows: the single-file pair cannot exercise workspace
  /// tree, branch, hunk, or git status presentation.
  func testCaptureWorkspace() throws {
    defer {
      resetNimculusSession()
      XCUIApplication(bundleIdentifier: "dev.zed.Zed").terminate()
      removeWorkspaceRepository()
    }
    try prepareWorkspaceRepository()

    for (id, label) in [("dev.zed.Zed", "zed"), ("com.asopitech.nimculus", "nimculus")] {
      let app = XCUIApplication(bundleIdentifier: id)
      if app.state != .notRunning {
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 10)
      }
      // The directory opens the workspace; the file selects the identical
      // document in that workspace for a directly comparable editor surface.
      app.launchArguments = [Self.workspaceRepository, Self.workspaceDocument]
      if id == "com.asopitech.nimculus" {
        app.launchEnvironment = [
          "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
        ]
      }
      app.launch()
      XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
      sleep(6)

      let window = self.window(of: app)
      XCTAssertTrue(
        Self.showsDocument(window, document: Self.workspaceDocument),
        "\(label) is not showing the workspace comparison document")
      if id == "com.asopitech.nimculus" {
        let text = Self.accessibleEditorText(
          window, containing: Self.workspaceDocumentFirstLine)
        XCTAssertNotNil(text, "nimculus does not expose the workspace document body")
        XCTAssertTrue(
          text?.contains("working tree hunk") == true,
          "nimculus is showing stale workspace document content")
      } else {
        // Zed does not expose its editor surface through accessibility. The
        // target filename plus rendered editor ink are the available checks.
        XCTAssertTrue(
          Self.showsEditorBody(window.screenshot().pngRepresentation),
          "zed shows the workspace document tab but no rendered editor body")
      }
      moveCursorToDocumentStart(in: window)
      write(window.screenshot().pngRepresentation, "\(label)-workspace.png")
    }
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

      // Start at the first line, then extend the selection down several lines
      // so the region spans lines of differing width.
      moveCursorToDocumentStart(in: window)
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
  private static func showsDocument(_ window: XCUIElement, document: String? = nil) -> Bool {
    let document = document ?? Self.document
    let name = (document as NSString).lastPathComponent
    if window.title.contains(name) { return true }
    let stem = (name as NSString).deletingPathExtension
    let predicate = NSPredicate(
      format: "label CONTAINS %@ OR title CONTAINS %@ OR value CONTAINS %@",
      stem, stem, stem)
    return window.descendants(matching: .any).matching(predicate).firstMatch
      .waitForExistence(timeout: 10)
  }

  /// Return text exposed by the editor's accessibility element. Nimculus uses
  /// `editor.content`; Zed does not expose its editor surface in the
  /// accessibility tree. Looking for a known document marker keeps this from
  /// accepting a tab title or a stale window label as proof that the buffer is
  /// correct.
  private static func accessibleEditorText(
    _ window: XCUIElement, containing marker: String
  ) -> String? {
    // Do not query `editor.content` directly: that identifier is Nimculus'
    // contract and is absent from Zed, where a missing match is itself
    // reported as an XCUITest failure. Scan the one accessibility snapshot
    // instead and select the longest matching value; Nimculus' full editor
    // text is longer than its breadcrumb and tab labels.
    var candidates: [String] = []
    for element in window.descendants(matching: .any).allElementsBoundByIndex {
      guard let value = element.value as? String, !value.isEmpty,
            value.contains(marker) else { continue }
      candidates.append(value)
    }
    return candidates.max(by: { $0.count < $1.count })
  }

  /// Zed's editor surface is not an accessibility text element. Verify that
  /// the document window contains rendered editor ink instead of accepting a
  /// title/tab as proof that a buffer is visible.
  private static func showsEditorBody(_ data: Data) -> Bool {
    guard let image = NSBitmapImageRep(data: data),
          image.pixelsWide > 0, image.pixelsHigh > 0 else { return false }

    var pixel = [Int](repeating: 0, count: max(3, image.samplesPerPixel))
    let minX = min(120, image.pixelsWide)
    let maxX = image.pixelsWide
    let minY = min(200, image.pixelsHigh)
    let maxY = min(image.pixelsHigh, 900)
    var inkPixels = 0
    for y in minY..<maxY {
      for x in minX..<maxX {
        image.getPixel(&pixel, atX: x, y: y)
        let luminance = 0.299 * Double(pixel[0]) +
          0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])
        if luminance < 245.0 { inkPixels += 1 }
      }
    }
    return inkPixels >= 500
  }

  /// Inline blame is drawn by the editor surface, which does not expose its
  /// text or icon through the XCUITest accessibility tree. The One Light hint
  /// colour is stable for this comparison, so use the first-line paint as the
  /// pre-capture assertion instead.
  private static func showsInlineBlame(_ data: Data) -> Bool {
    guard let image = NSBitmapImageRep(data: data),
          image.pixelsWide > 0, image.pixelsHigh > 0 else { return false }

    let hint = NSColor(calibratedRed: 0x72 / 255.0,
                       green: 0x74 / 255.0,
                       blue: 0xa7 / 255.0,
                       alpha: 1.0)
    var pixel = [Int](repeating: 0, count: max(3, image.samplesPerPixel))
    let minX = min(300, image.pixelsWide)
    let maxX = image.pixelsWide
    let minY = min(image.pixelsHigh, 160)
    let maxY = min(image.pixelsHigh, 300)
    for y in minY..<maxY {
      for x in minX..<maxX {
        image.getPixel(&pixel, atX: x, y: y)
        let red = CGFloat(pixel[0]) / 255.0
        let green = CGFloat(pixel[1]) / 255.0
        let blue = CGFloat(pixel[2]) / 255.0
        if abs(red - hint.redComponent) + abs(green - hint.greenComponent) +
            abs(blue - hint.blueComponent) < 0.08 { return true }
      }
    }
    return false
  }

  private static func showsInlineBlameBody(_ data: Data) -> Bool {
    guard let image = NSBitmapImageRep(data: data),
          image.pixelsWide > 0, image.pixelsHigh > 0 else { return false }

    var pixel = [Int](repeating: 0, count: max(3, image.samplesPerPixel))
    let minX = min(120, image.pixelsWide)
    let maxX = min(370, image.pixelsWide)
    let minY = min(200, image.pixelsHigh)
    let maxY = min(265, image.pixelsHigh)
    var darkPixels = 0
    for y in minY..<maxY {
      for x in minX..<maxX {
        image.getPixel(&pixel, atX: x, y: y)
        let luminance = 0.299 * Double(pixel[0]) +
          0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])
        if luminance < 120.0 { darkPixels += 1 }
      }
    }
    return darkPixels >= 20
  }

  /// Capture the mixed-script sample in both editors. Colour emoji were being
  /// dropped before they reached the atlas, so this is the capture that shows
  /// whether they are drawn at all.
  func testCaptureEmoji() {
    for (id, label) in [("dev.zed.Zed", "zed"), ("com.asopitech.nimculus", "nimculus")] {
      let app = XCUIApplication(bundleIdentifier: id)
      app.launchArguments = [Self.emojiDocument]
      app.launch()
      XCTAssertTrue(app.wait(for: .runningForeground, timeout: 60))
      sleep(6)
      let window = self.window(of: app)
      XCTAssertTrue(
        Self.showsDocument(window, document: Self.emojiDocument),
        "\(label) is not showing \(Self.emojiDocument)")
      if let text = Self.accessibleEditorText(
        window, containing: Self.emojiContentMarkers[0]) {
        let matches = Self.emojiContentMarkers.filter { marker in
          text.contains(marker)
        }
        XCTAssertEqual(matches, Self.emojiContentMarkers,
                       "\(label) exposes incomplete or stale emoji content")
      } else {
        XCTAssertTrue(
          Self.showsEditorBody(window.screenshot().pngRepresentation),
          "\(label) shows the emoji document tab but no rendered editor body")
      }
      moveCursorToDocumentStart(in: window)
      write(window.screenshot().pngRepresentation, "\(label)-emoji.png")
    }
  }
}
