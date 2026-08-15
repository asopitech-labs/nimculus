when defined(macosx):
  import nimnui/platform/macos/platform
elif defined(windows):
  import nimnui/platform/windows/platform
else:
  import nimnui/platform/headless/platform
import nimnui/mock_renderer
import nimnui/geometry
import nimnui/ui_tree
import nimnui/context
import nimnui/layout
import nimnui/events
import nimnui/controls
import nimnui/text
import nimnui/render
import nimnui/ime
import nimnui/commands
import nimnui/accessibility
import nimnui/executor
import nimnui/entity
import nimnui/entity_context

export platform
export mock_renderer
export geometry, ui_tree, context, layout, events, controls, text
export render
export ime
export commands
export accessibility
export executor
export entity
export entity_context

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
