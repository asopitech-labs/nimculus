import std/unittest
import nimnui/nimnui
import nimculus/settings

proc resolvedColor(color: Color): bool =
  ## Transparent is a resolved colour too; validity is about its four scalar
  ## components being initialized and in the renderer's accepted range.
  color.red >= 0'f32 and color.red <= 1'f32 and
    color.green >= 0'f32 and color.green <= 1'f32 and
    color.blue >= 0'f32 and color.blue <= 1'f32 and
    color.alpha >= 0'f32 and color.alpha <= 1'f32

proc checkResolved(styles: ButtonLikeStyles) =
  check resolvedColor(styles.background)
  check resolvedColor(styles.borderColor)
  check resolvedColor(styles.labelColor)
  check resolvedColor(styles.iconColor)

suite "ButtonLike style resolution":
  test "every style and UI state returns four resolved colours":
    let theme = ThemeColors(
      foreground: "#d7dae0", accent: "#4daafc", border: "#3b4048",
      element: "#24282e", elementHover: "#39424f",
      elementActive: "#46515f", textDisabled: "#747b85",
      borderVariant: "#30353d", borderFocused: "#76c7ff",
      elevated: "#2d333b")
    for style in ButtonStyle:
      for state in UiState:
        checkResolved(buttonStyles(style, state, background, theme))

  test "transparent chrome preserves the existing active and hover alphas":
    let theme = ThemeColors(
      foreground: "#d7dae0", accent: "#4daafc",
      element: "#24282e", elementHover: "#39424f")
    let activeStyles = buttonStyles(transparent, active, background, theme)
    let hoveredStyles = buttonStyles(transparent, hovered, background, theme)
    check activeStyles.background == Color(red: float32(0x4d) / 255'f32,
      green: float32(0xaa) / 255'f32, blue: float32(0xfc) / 255'f32,
      alpha: 0.22'f32)
    check hoveredStyles.background == Color(red: float32(0x39) / 255'f32,
      green: float32(0x42) / 255'f32, blue: float32(0x4f) / 255'f32,
      alpha: 0.10'f32)
