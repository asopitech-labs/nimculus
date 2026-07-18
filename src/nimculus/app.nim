type
  AppState* = object
    title*: string
    running*: bool

proc initialAppState*(): AppState =
  AppState(title: "Nimculus", running: false)
