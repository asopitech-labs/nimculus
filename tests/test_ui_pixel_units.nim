import std/unittest
import nimnui/geometry
import nimnui/render

proc checkPixels(actual: Pixels, expected: float32) =
  check abs(float32(actual) - expected) < 0.0001'f32

suite "UI pixel units":
  test "pixel division returns a ratio":
    let ratio: float32 = px(10) / px(4)
    check abs(ratio - 2.5'f32) < 0.0001'f32

  test "pixel units scale up to device pixels through the Zed ladder":
    let scaled = px(10.3'f32).scale(2.0'f32)
    check scaled == ScaledPixels(20.6'f32)
    check toDevicePixels(scaled) == DevicePixels(21)

  test "pixelSnap uses nearest device pixel with half ties toward zero":
    pixelSnap(px(0.5), 1.0).checkPixels(0)
    pixelSnap(px(1.5), 1.0).checkPixels(1)
    pixelSnap(px(1.5001), 1.0).checkPixels(2)

    pixelSnap(px(-0.5), 1.0).checkPixels(0)
    pixelSnap(px(-1.5), 1.0).checkPixels(-1)
    pixelSnap(px(-1.5001), 1.0).checkPixels(-2)

    pixelSnap(px(0), 1.0).checkPixels(0)
    pixelSnap(px(-0.0), 1.0).checkPixels(0)

  test "pixelSnap applies the same rule in device-pixel space":
    pixelSnap(px(0.25), 2.0).checkPixels(0)
    pixelSnap(px(0.3), 2.0).checkPixels(0.5)
    pixelSnap(px(-0.25), 2.0).checkPixels(0)
    pixelSnap(px(-0.3), 2.0).checkPixels(-0.5)

  test "pixelSnapPoint routes both coordinates through pixelSnap":
    let snapped = pixelSnapPoint(Point(x: px(1.5), y: px(-1.5001)), 1.0)
    snapped.x.checkPixels(1)
    snapped.y.checkPixels(-2)
