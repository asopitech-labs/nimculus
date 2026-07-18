import nimnui/nimnui
import nimculus/editor_app
import nimculus/editor_buffer
import nimculus/editor_view

var demoTree = newUiTree()
var demoButton = NodeId(0)

proc setupDemoUi() =
  demoTree = newUiTree()
  let root = demoTree.addNode()
  let button = makeControl(demoTree, root, ControlKind.button, "Nimculus", focusable = true)
  demoButton = button.node
  let spec = LayoutSpec(direction: row,
    size: Size(width: px(0), height: px(0)),
    minSize: Size(width: px(0), height: px(0)),
    maxSize: Size(width: px(10000), height: px(10000)),
    padding: EdgeInsets(top: px(20), right: px(20), bottom: px(20), left: px(20)),
    gap: px(8), alignment: alignCenter,
    viewport: Rect(size: Size(width: px(960), height: px(640))))
  demoTree.layoutNode(root, Rect(size: Size(width: px(960), height: px(640))), spec)
  let bounds = demoTree.node(button.node).bounds
  platformSetUiRectangle(float32(bounds.origin.x), float32(bounds.origin.y),
                         float32(bounds.size.width), float32(bounds.size.height))

var imeState = newImeState()
var editorSession: EditorSession
var editorViewState = newEditorView()

proc activeDocument(): ptr FileDocument =
  if editorSession.tabs.len == 0 or editorSession.activeTab < 0 or
      editorSession.activeTab >= editorSession.tabs.len: return nil
  addr editorSession.tabs[editorSession.activeTab].document

proc receiveNativeText(text: cstring, composing: bool) {.cdecl.} =
  let value = if text == nil: "" else: $text
  imeState.receiveText(value, composing)
  if not composing and value.len > 0:
    let document = activeDocument()
    if document != nil:
      let selected = editorViewState.selectedRange()
      document[].buffer.edit(Edit(startByte: selected.startByte,
        endByte: selected.endByte, text: value))
      editorViewState.moveCursor(selected.startByte + value.len)

proc receiveNativeFile(path: cstring, saving: bool) {.cdecl.} =
  if path == nil or ($path).len == 0: return
  let filePath = $path
  if saving:
    let document = activeDocument()
    if document != nil: document[].save(filePath)
  else:
    try:
      editorSession.addTab(openDocument(filePath))
      let document = activeDocument()
      if document != nil: editorViewState.moveCursor(0)
    except CatchableError:
      discard

proc receiveNativeInput(event: ptr NimculusInputEvent) {.cdecl.} =
  if event.isNil: return
  let kind = case event.kind
    of 1'u32: pointerDown
    of 2'u32: pointerUp
    of 5'u32: pointerMove
    of 10'u32: keyDown
    of 11'u32: keyUp
    of 22'u32: scroll
    else: command
  var uiEvent = UiEvent(kind: kind, target: demoButton,
    position: Point(x: px(float32(event.x)), y: px(float32(event.y))),
    keyCode: event.keyCode)
  discard demoTree.dispatch(uiEvent)

when isMainModule:
  when defined(macosx):
    setupDemoUi()
    platformSetTextCallback(receiveNativeText)
    platformSetInputCallback(receiveNativeInput)
    platformSetFileCallback(receiveNativeFile)
    platformSetUiRectangle(360, 260, 240, 120)
  discard platformRun()
