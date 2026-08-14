import std/[json, os, unittest]
import nimculus/settings

suite "UI density spacing":
  test "all density-aware spacing rungs match Zed":
    let expected: array[SpacingStep, array[Density, float32]] = [
      [0'f32, 0'f32, 0'f32],
      [1'f32, 1'f32, 2'f32],
      [1'f32, 2'f32, 4'f32],
      [2'f32, 3'f32, 4'f32],
      [2'f32, 4'f32, 6'f32],
      [3'f32, 6'f32, 8'f32],
      [4'f32, 8'f32, 10'f32],
      [10'f32, 12'f32, 14'f32],
      [14'f32, 16'f32, 18'f32],
      [18'f32, 20'f32, 22'f32],
      [20'f32, 24'f32, 28'f32],
      [28'f32, 32'f32, 36'f32],
      [36'f32, 40'f32, 44'f32],
      [44'f32, 48'f32, 52'f32]
    ]
    for step in SpacingStep:
      for density in Density:
        check px(step, density) == expected[step][density]
    check spacingTable.len == 14
    check spacingTable[Base04][compact] == 2'f32
    check spacingTable[Base04][Density.default] == 4'f32
    check spacingTable[Base04][comfortable] == 6'f32
    check spacingTable[Base06][compact] == 3'f32
    check spacingTable[Base06][Density.default] == 6'f32
    check spacingTable[Base06][comfortable] == 8'f32

  test "ui density is retained as a typed settings field":
    let defaults = loadSettings("", "")
    check defaults.uiDensity == Density.default
    check settingDescriptor("ui_density").default.getStr == "default"
    let configured = parseJson("{\"ui_density\":\"comfortable\"}")
    let diagnostics = validateSettings(configured)
    check diagnostics.len == 0
    let root = getTempDir() / ("nimculus-density-spacing-" & $getCurrentProcessId())
    createDir(root)
    let path = root / "settings.json"
    writeFile(path, "{\"ui_density\":\"comfortable\"}")
    let loaded = loadSettings(path, "")
    check loaded.uiDensity == comfortable
    check loaded.diagnostics.len == 0
    removeFile(path)
    removeDir(root)
