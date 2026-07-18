type
  ImeState* = object
    composition*: string
    committed*: string
    cursor*: int

proc newImeState*(): ImeState = ImeState(cursor: 0)

proc receiveText*(state: var ImeState, text: string, composing: bool) =
  if composing:
    state.composition = text
  else:
    state.committed.add(text)
    state.composition.setLen(0)
    state.cursor += text.len

proc clearCommitted*(state: var ImeState) = state.committed.setLen(0)
