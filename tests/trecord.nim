## Checks for the pure parts of recording: geometry and the ffmpeg/wf-recorder
## argument lists.
##
##   nimble test

import std/strutils
import ../src/record

doAssert geometry(10, 20, 301, 201, 1.0) == "10,20 300x200"      # even sizes
doAssert geometry(0, 0, 1920, 1080, 2.0) == "0,0 960x540"        # logical units

doAssert recorderArgs(30, "0,0 10x10", "DP-1") == @["-y", "-c", "libx264", "-x", "yuv420p", "-r", "30", "-g", "0,0 10x10"]
doAssert recorderArgs(60, "", "DP-1") == @["-y", "-c", "libx264", "-x", "yuv420p", "-r", "60", "-o", "DP-1"]

doAssert joinArgs("l", "o.mp4", vfMp4)[^3 .. ^1] == @["-c", "copy", "o.mp4"]
doAssert "libvpx-vp9" in joinArgs("l", "o.webm", vfWebm)
doAssert "paletteuse" in joinArgs("l", "o.gif", vfGif)[^2]

doAssert concatList(@["/a/b.mkv", "/it's.mkv"]) ==
  "file '/a/b.mkv'\nfile '/it'\\''s.mkv'\n"
echo "record ok"
