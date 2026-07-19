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
    # Keep the latest commit as an event payload, not an unbounded history.
    # The editor consumes committed text immediately; retaining every IME
    # commit would grow for the lifetime of a session.
    state.committed = text
    state.composition.setLen(0)
    state.cursor += text.len

proc clearCommitted*(state: var ImeState) = state.committed.setLen(0)
