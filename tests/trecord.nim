## Checks for the pure parts of recording: geometry and the ffmpeg/wf-recorder
## argument lists.
##
##   nimble test

import ../src/record

doAssert geometry(10, 20, 301, 201, 1.0) == "10,20 300x200"      # even sizes
doAssert geometry(0, 0, 1920, 1080, 2.0) == "0,0 960x540"        # logical units

doAssert recorderArgs(vfMp4, 30, "0,0 10x10", "DP-1") ==
  @["-y", "-c", "libx264", "-x", "yuv420p", "-r", "30", "-g", "0,0 10x10"]
doAssert recorderArgs(vfWebm, 60, "", "DP-1") ==
  @["-y", "-c", "libvpx", "-x", "yuv420p", "-r", "60", "-o", "DP-1"]

let mp4 = joinCmds("l", "p.png", "o.mp4", vfMp4)
doAssert mp4.len == 1 and mp4[0][^3 .. ^1] == @["-c", "copy", "o.mp4"]
doAssert joinCmds("l", "p.png", "o.webm", vfWebm)[0][^3 .. ^1] == @["-c", "copy", "o.webm"]
let gif = joinCmds("l", "p.png", "o.gif", vfGif)
doAssert gif.len == 2
doAssert gif[0][^1] == "p.png" and "palettegen" in gif[0]
doAssert gif[1][^1] == "o.gif" and "paletteuse" in gif[1] and "p.png" in gif[1]

doAssert concatList(@["/a/b.mkv", "/it's.mkv"]) ==
  "file '/a/b.mkv'\nfile '/it'\\''s.mkv'\n"
echo "record ok"
