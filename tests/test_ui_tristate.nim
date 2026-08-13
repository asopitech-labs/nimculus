import std/unittest
import nimnui/nimnui

suite "ToggleState":
  test "fromAnyAndAll derives the three states":
    check fromAnyAndAll(false, false) == tsUnselected
    check fromAnyAndAll(true, false) == tsIndeterminate
    check fromAnyAndAll(true, true) == tsSelected

  test "inverse follows Zed toggle semantics":
    check inverse(tsUnselected) == tsSelected
    check inverse(tsSelected) == tsUnselected
    check inverse(tsIndeterminate) == tsSelected
