import nimnui/geometry

const
  EditorTextLeftInset* = 8'f32
  EditorTextRightInset* = 28'f32
  EditorScrollbarBottomInset* = 14'f32
  EditorScrollbarHeight* = 8'f32
  EditorScrollbarMinimumThumb* = 24'f32

type
  EditorHorizontalScrollbar* = object
    track*: Rect
    thumb*: Rect
    viewportWidth*: float32
    contentWidth*: float32
    maxScroll*: float32

proc emptyRect(): Rect =
  Rect(size: Size(width: px(0), height: px(0)))

proc editorTextViewportWidth*(bounds: Rect): float32 =
  max(0'f32, float32(bounds.size.width) - EditorTextLeftInset -
    EditorTextRightInset)

proc clampEditorScrollX*(scrollX, widestLineWidth, viewportWidth: float32): float32 =
  let maxScroll = max(0'f32, widestLineWidth - max(0'f32, viewportWidth))
  min(max(0'f32, scrollX), maxScroll)

proc horizontalEditorScrollbar*(bounds: Rect, widestLineWidth,
                                scrollX: float32): EditorHorizontalScrollbar =
  let viewportWidth = editorTextViewportWidth(bounds)
  let contentWidth = max(0'f32, widestLineWidth)
  result.viewportWidth = viewportWidth
  result.contentWidth = contentWidth
  result.track = emptyRect()
  result.thumb = emptyRect()
  # The caller supplies the renderer's measured width. Native macOS returns
  # zero while soft wrap is active, so visibility follows the actual content
  # geometry instead of a second, potentially stale soft-wrap flag.
  if viewportWidth <= 0'f32 or contentWidth <= viewportWidth:
    return
  let trackX = float32(bounds.origin.x) + EditorTextLeftInset
  let editorBottom = float32(bounds.origin.y) + float32(bounds.size.height)
  let trackY = min(editorBottom - EditorScrollbarHeight,
    max(float32(bounds.origin.y), editorBottom - EditorScrollbarBottomInset))
  result.track = Rect(origin: Point(x: px(trackX), y: px(trackY)),
    size: Size(width: px(viewportWidth), height: px(EditorScrollbarHeight)))
  let maxScroll = contentWidth - viewportWidth
  result.maxScroll = maxScroll
  let thumbWidth = min(viewportWidth, max(EditorScrollbarMinimumThumb,
    viewportWidth * viewportWidth / contentWidth))
  let thumbTravel = max(0'f32, viewportWidth - thumbWidth)
  let normalized = clampEditorScrollX(scrollX, contentWidth, viewportWidth) /
    maxScroll
  let thumbX = trackX + thumbTravel * normalized
  result.thumb = Rect(origin: Point(x: px(thumbX), y: px(trackY)),
    size: Size(width: px(thumbWidth), height: px(EditorScrollbarHeight)))

proc horizontalScrollbarScrollX*(scrollbar: EditorHorizontalScrollbar,
                                 x: float32): float32 =
  if scrollbar.maxScroll <= 0'f32 or float32(scrollbar.track.size.width) <=
      float32(scrollbar.thumb.size.width):
    return 0'f32
  let thumbWidth = float32(scrollbar.thumb.size.width)
  let travel = float32(scrollbar.track.size.width) - thumbWidth
  let centerAdjusted = x - float32(scrollbar.track.origin.x) - thumbWidth / 2'f32
  let normalized = min(1'f32, max(0'f32, centerAdjusted / travel))
  scrollbar.maxScroll * normalized

proc contains*(scrollbar: EditorHorizontalScrollbar, x, y: float32): bool =
  let left = float32(scrollbar.track.origin.x)
  let top = float32(scrollbar.track.origin.y)
  let right = left + float32(scrollbar.track.size.width)
  let bottom = top + float32(scrollbar.track.size.height)
  float32(scrollbar.track.size.width) > 0'f32 and x >= left and x < right and
    y >= top and y < bottom
