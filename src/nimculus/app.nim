import nimculus/settings

type
  AppState* = object
    title*: string
    running*: bool

  App* = ref object
    state*: AppState
    settings*: SettingsStore
    settingsGlobalPath*: string
    settingsWorkspacePath*: string
    featureNames*: seq[string]

  FeatureInitializer* = proc(app: App)

proc initialAppState*(): AppState =
  AppState(title: "Nimculus", running: false)

proc newApp*(settingsGlobalPath = "", settingsWorkspacePath = ""): App =
  App(state: initialAppState(), settingsGlobalPath: settingsGlobalPath,
    settingsWorkspacePath: settingsWorkspacePath)

proc hasFeature(app: App, name: string): bool =
  name in app.featureNames

proc registerFeature*(app: App, name: string, initializer: FeatureInitializer) =
  if app == nil:
    raise newException(ValueError, "cannot register a feature on a nil app")
  if name.len == 0:
    raise newException(ValueError, "feature name must not be empty")
  if initializer == nil:
    raise newException(ValueError, "feature initializer must not be nil")
  if app.hasFeature(name):
    raise newException(ValueError, "feature already registered: " & name)
  app.featureNames.add(name)

proc initFeature*(app: App, name: string, initializer: FeatureInitializer) =
  app.registerFeature(name, initializer)
  initializer(app)

proc registeredFeatures*(app: App): seq[string] =
  if app == nil: return @[]
  app.featureNames
