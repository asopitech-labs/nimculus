import std/options
import nimnui/geometry

type
  LayoutDirection* = enum
    row, column, stack

  ## The positioning strategy used by a child. `absolute` removes the child
  ## from the parent's row/column allocation, just like CSS and Zed.
  Position* = enum
    relative, absolute

  ## Overflow is kept axis-aware because Zed's Style stores a Point<Overflow>.
  Overflow* = enum
    visible, clip, hidden, scroll

  OverflowPoint* = object
    x*, y*: Overflow

  Alignment* = enum
    alignStart, alignCenter, alignEnd, alignStretch, alignSpaceBetween,
    alignSpaceEvenly, alignSpaceAround

  ## AlignItems and JustifyContent intentionally share the legacy enum values
  ## so existing `alignment: alignCenter` call sites remain source-compatible.
  ## The two fields are nevertheless independent, as in Zed's Style.
  AlignItems* = Alignment
  JustifyContent* = Alignment

  LengthKind* = enum
    lengthAuto, lengthPixels

  ## Zed's inset is Edges<Length>, where an omitted edge is `auto`. Keeping
  ## that distinction lets `inset: length(px(0))` remain a real zero inset.
  Length* = object
    kind*: LengthKind
    value*: Pixels

  LengthEdges* = object
    top*, right*, bottom*, left*: Length

  LayoutSpec* = object
    direction*: LayoutDirection
    position*: Position
    inset*: LengthEdges
    size*: Size
    minSize*: Size
    maxSize*: Size
    margin*: EdgeInsets
    padding*: EdgeInsets
    gap*: Pixels
    flexGrow*: float32
    alignment*: Alignment
    alignItems*: Option[AlignItems]
    justifyContent*: Option[JustifyContent]
    overflow*: OverflowPoint
    scrollOffset*: Pixels
    viewport*: Rect

const
  justifyStart* = alignStart
  justifyCenter* = alignCenter
  justifyEnd* = alignEnd
  justifySpaceBetween* = alignSpaceBetween
  justifySpaceEvenly* = alignSpaceEvenly
  justifySpaceAround* = alignSpaceAround
  alignFlexStart* = alignStart
  alignFlexEnd* = alignEnd

proc pxLength*(value: Pixels): Length =
  Length(kind: lengthPixels, value: value)

proc autoLength*(): Length = Length(kind: lengthAuto)

proc overflowPoint*(value: Overflow): OverflowPoint =
  OverflowPoint(x: value, y: value)

proc defaultLayoutSpec*(): LayoutSpec =
  LayoutSpec(direction: stack, position: relative,
    overflow: overflowPoint(visible))

proc normalizeLayoutSpec*(spec: LayoutSpec): LayoutSpec =
  ## A missing maximum means unbounded in the public style API. Keep the
  ## internal node maximum finite so allocation arithmetic remains stable.
  result = spec
  if float32(result.maxSize.width) <= 0: result.maxSize.width = px(100000)
  if float32(result.maxSize.height) <= 0: result.maxSize.height = px(100000)
