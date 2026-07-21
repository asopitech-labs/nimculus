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

  ScrollModel* = object
    offset*, contentSize*, viewportSize*: Pixels

  SplitPaneModel* = object
    ratio*: float32
    dragging*: bool

proc scrollBy*(model: var ScrollModel, delta: Pixels) =
  let maximum = maxPx(px(0), model.contentSize - model.viewportSize)
  model.offset = minPx(maximum, maxPx(px(0), model.offset + delta))

proc beginDrag*(model: var SplitPaneModel) = model.dragging = true
proc endDrag*(model: var SplitPaneModel) = model.dragging = false
proc dragTo*(model: var SplitPaneModel, ratio: float32) =
  if model.dragging: model.ratio = min(1'f32, max(0'f32, ratio))

proc makeControl*(tree: var UiTree, parent: NodeId, kind: ControlKind,
                  text = "", focusable = false): Control =
  result.node = tree.addNode(parent, focusable)
  result.kind = kind
  result.text = text
  result.layout = LayoutSpec(direction: stack, size: Size(width: px(0), height: px(0)),
                             minSize: Size(width: px(0), height: px(0)),
                             maxSize: Size(width: px(100000), height: px(100000)))
  tree.setLayoutSpec(result.node, result.layout)
