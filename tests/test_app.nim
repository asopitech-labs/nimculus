import std/[os, unittest]
import nimculus/app
import nimculus/settings

suite "application feature initialization":
  test "settings initialize before a feature reads them":
    let root = getTempDir() / ("nimculus-app-settings-" & $getCurrentProcessId())
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, "{\"editor\":{\"fontSize\":21}}")
    defer:
      if fileExists(path): removeFile(path)
      if dirExists(root): removeDir(root)

    let app = newApp(path)
    var observedFontSize = 0
    app.initFeature("settings", proc(app: App) =
      app.settings = newSettingsStore(app.settingsGlobalPath, app.settingsWorkspacePath))
    app.initFeature("probe", proc(app: App) =
      observedFontSize = app.settings.intSetting("editor.fontSize"))

    check observedFontSize == 21
    check app.registeredFeatures() == @["settings", "probe"]

  test "registering a feature twice raises instead of replacing it":
    let app = newApp()
    let initializer: FeatureInitializer = proc(app: App) = discard app
    app.registerFeature("probe", initializer)

    expect ValueError:
      app.registerFeature("probe", initializer)
