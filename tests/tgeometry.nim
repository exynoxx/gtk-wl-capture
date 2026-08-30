## Geometry checks for the two pure functions the capture path depends on:
## cropping a Shot and composing several outputs into one image.
##
##   nimble test

import std/[os, strformat]
import ../src/capture

proc solid(w, h: int; value: uint8; scale = 1.0; ox = 0, oy = 0): Shot =
  result = Shot(w: w, h: h, stride: w * 4, data: newSeq[uint8](w * h * 4),
                hasAlpha: false, scale: scale, originX: ox, originY: oy)
  for i in 0 ..< result.data.len: result.data[i] = value

proc pixel(s: Shot; x, y: int): uint8 = s.data[y * s.stride + x * 4]

block cropStaysInside:
  var s = solid(10, 8, 0)
  s.data[3 * s.stride + 4 * 4] = 200      # mark 4,3
  let c = s.crop(4, 3, 2, 2)
  doAssert c.w == 2 and c.h == 2, &"got {c.w}x{c.h}"
  doAssert c.stride == 8
  doAssert c.pixel(0, 0) == 200
  doAssert c.pixel(1, 1) == 0

block cropClampsToTheImage:
  let s = solid(10, 8, 7)
  let c = s.crop(8, 6, 100, 100)          # runs off the bottom-right corner
  doAssert c.w == 2 and c.h == 2, &"got {c.w}x{c.h}"
  doAssert c.data.len == 2 * 2 * 4

block cropOutsideIsEmptyNotACrash:
  let s = solid(10, 8, 7)
  let c = s.crop(50, 50, 4, 4)
  doAssert c.isEmpty
  doAssert c.data.len == 0

block cropCarriesTheLogicalOrigin:
  # A shot of a 2x-scaled output that starts at logical 1920,0.
  let s = solid(400, 200, 0, scale = 2.0, ox = 1920, oy = 0)
  let c = s.crop(100, 40, 50, 50)
  doAssert c.originX == 1920 + 50, &"got {c.originX}"
  doAssert c.originY == 20, &"got {c.originY}"
  doAssert c.scale == 2.0

block pxMapsLogicalToPixels:
  let s = solid(3840, 2160, 0, scale = 2.0, ox = 100, oy = 50)
  doAssert s.px(100, 50) == (0, 0)
  doAssert s.px(200, 150) == (200, 200)

block composeSingleOutputIsUntouched:
  let s = solid(1920, 1080, 9)
  let c = compose(@[Part(shot: s, lx: 0, ly: 0, lw: 1920, lh: 1080)])
  doAssert c.w == 1920 and c.h == 1080
  doAssert c.data.len == s.data.len

block composeSideBySide:
  let c = compose(@[
    Part(shot: solid(800, 600, 1), lx: 0, ly: 0, lw: 800, lh: 600),
    Part(shot: solid(640, 480, 2), lx: 800, ly: 0, lw: 640, lh: 480)])
  doAssert c.w == 1440 and c.h == 600, &"got {c.w}x{c.h}"
  doAssert c.scale == 1.0
  doAssert c.pixel(10, 10) == 1           # left output
  doAssert c.pixel(1000, 10) == 2         # right output
  doAssert c.pixel(1000, 550) == 0        # below the shorter output

block composeUsesTheHighestScale:
  # A 1x 1920x1080 next to a 2x 2560x1440-in-1280x720-logical panel.
  let c = compose(@[
    Part(shot: solid(1920, 1080, 1), lx: 0, ly: 0, lw: 1920, lh: 1080),
    Part(shot: solid(2560, 1440, 2), lx: 1920, ly: 0, lw: 1280, lh: 720)])
  doAssert c.scale == 2.0, &"got {c.scale}"
  doAssert c.w == (1920 + 1280) * 2, &"got {c.w}"
  doAssert c.h == 1080 * 2, &"got {c.h}"
  doAssert c.pixel(100, 100) == 1         # 1x panel, upscaled
  doAssert c.pixel(4000, 100) == 2        # 2x panel at native pixels

block composeHandlesNegativeOrigins:
  # A second monitor placed to the left of the primary.
  let c = compose(@[
    Part(shot: solid(800, 600, 1), lx: 0, ly: 0, lw: 800, lh: 600),
    Part(shot: solid(800, 600, 2), lx: -800, ly: 0, lw: 800, lh: 600)])
  doAssert c.originX == -800, &"got {c.originX}"
  doAssert c.w == 1600
  doAssert c.pixel(10, 10) == 2           # the left-hand monitor comes first
  doAssert c.pixel(900, 10) == 1

block pngRoundTrip:
  # savePng/shotFromPng are the two ends of the portal fallback's decode path.
  var s = solid(64, 32, 0)
  for y in 0 ..< 32:
    for x in 0 ..< 64:
      s.data[y * s.stride + x * 4] = uint8(x * 4)       # blue ramp
      s.data[y * s.stride + x * 4 + 2] = uint8(y * 8)   # red ramp
  let path = getTempDir() / "tgeometry-roundtrip.png"
  s.savePng(path)
  defer: removeFile(path)
  let back = shotFromPng(path)
  doAssert back.w == 64 and back.h == 32, &"got {back.w}x{back.h}"
  doAssert back.pixel(0, 0) == s.pixel(0, 0)
  doAssert back.pixel(63, 31) == s.pixel(63, 31)
  doAssert back.data[31 * back.stride + 63 * 4 + 2] == 31 * 8

echo "tgeometry: all checks passed"
