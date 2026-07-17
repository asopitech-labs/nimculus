import nimnui/geometry
import nimnui/ui_tree
import nimnui/layout

type
  ControlKind* = enum
    label, button, scrollView, splitPane, tabBar, contextMenu, popup, tooltip

  Control* = object
    node*: NodeId
    kind*: ControlKind
    text*: string
    layout*: LayoutSpec

proc makeControl*(tree: var UiTree, parent: NodeId, kind: ControlKind,
                  text = "", focusable = false): Control =
  result.node = tree.addNode(parent, focusable)
  result.kind = kind
  result.text = text
  result.layout = LayoutSpec(direction: stack, size: Size(width: px(0), height: px(0)),
                             minSize: Size(width: px(0), height: px(0)),
                             maxSize: Size(width: px(100000), height: px(100000)))
