when defined(macosx):
  import nimnui/platform/macos/platform
else:
  import nimnui/platform/headless/platform
import nimnui/mock_renderer
import nimnui/geometry
import nimnui/ui_tree
import nimnui/layout
import nimnui/events
import nimnui/controls
import nimnui/text
import nimnui/render
import nimnui/ime
import nimnui/commands

export platform
export mock_renderer
export geometry, ui_tree, layout, events, controls, text
export render
export ime
export commands

type
  RendererKind* = enum
    mockRenderer
    metalRenderer

  RendererInfo* = object
    kind*: RendererKind
    name*: string

proc rendererInfo*(): RendererInfo =
  when defined(macosx):
    RendererInfo(kind: metalRenderer, name: "Metal")
  else:
    RendererInfo(kind: mockRenderer, name: "Mock")
