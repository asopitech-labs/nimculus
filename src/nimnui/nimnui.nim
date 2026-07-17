import nimnui/platform/macos/platform
import nimnui/mock_renderer

export platform
export mock_renderer

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
