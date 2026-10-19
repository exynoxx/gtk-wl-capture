## Screen recording through wf-recorder (wlroots-family compositors only).
##
## Each stretch between pauses is its own mkv segment: wf-recorder has no
## pause, and stopping it cleanly is the only way to get a valid file. On stop,
## ffmpeg joins the segments and converts them to the chosen format.

import std/[os, osproc, posix, strutils]

type
  VideoFormat* = enum
    vfMp4 = "mp4"
    vfWebm = "webm"
    vfMkv = "mkv"
    vfGif = "gif"

  Recorder* = object
    dir: string
    args: seq[string]   ## wf-recorder arguments, minus the output file
    segs: seq[string]
    cur: Process

  RecordError* = object of CatchableError

func geometry*(originX, originY, w, h: int; scale: float): string =
  ## wf-recorder's "x,y WxH" in logical coords, from an image-pixel rectangle.
  ## Even sizes, because yuv420p encoders refuse odd ones.
  # ponytail: a single-output Shot keeps scale 1.0 even on HiDPI, so there the
  # size comes out in physical pixels; feed it the monitor scale if that bites.
  let
    lw = int(w.float / scale) and not 1
    lh = int(h.float / scale) and not 1
  $originX & "," & $originY & " " & $lw & "x" & $lh

func recorderArgs*(fps: int; geom, output: string): seq[string] =
  ## `geom` wins over `output`; with neither, wf-recorder would prompt on stdin.
  # wf-recorder 0.6 defaults to VP9 and 4:4:4; H.264 yuv420p plays everywhere
  # and copies straight into mp4/mkv.
  result = @["-y", "-c", "libx264", "-x", "yuv420p", "-r", $fps]
  if geom.len > 0: result.add ["-g", geom]
  elif output.len > 0: result.add ["-o", output]

func joinArgs*(listFile, dest: string; fmt: VideoFormat): seq[string] =
  result = @["-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", listFile]
  case fmt
  of vfMp4, vfMkv: result.add ["-c", "copy"]
  of vfWebm: result.add ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "32", "-row-mt", "1"]
  of vfGif: result.add ["-vf", "split[a][b];[a]palettegen[p];[b][p]paletteuse"]
  result.add dest

func concatList*(segs: seq[string]): string =
  for s in segs: result.add "file '" & s.replace("'", "'\\''") & "'\n"

proc newRecorder*(args: seq[string]): Recorder =
  for tool in ["wf-recorder", "ffmpeg"]:
    if findExe(tool).len == 0:
      raise newException(RecordError, "recording needs " & tool & " installed")
  Recorder(args: args,
           dir: getTempDir() / "gtk-wl-capture-rec-" & $getCurrentProcessId())

func recording*(r: Recorder): bool = r.cur != nil

proc resume*(r: var Recorder) =
  if r.cur != nil: return
  createDir(r.dir)
  let seg = r.dir / "seg" & $r.segs.len & ".mkv"
  r.segs.add seg
  # Parent streams, not pipes: wf-recorder is chatty and would block on a
  # full pipe nobody reads.
  r.cur = startProcess("wf-recorder", args = r.args & @["-f", seg],
                       options = {poUsePath, poParentStreams})

proc died*(r: Recorder): bool =
  ## wf-recorder quit on its own - bad geometry, output gone, compositor said no.
  r.cur != nil and r.cur.peekExitCode != -1

proc pause*(r: var Recorder) =
  if r.cur == nil: return
  if r.cur.running:
    discard kill(Pid(r.cur.processID), SIGINT)   # what wf-recorder wants for a clean stop
  discard r.cur.waitForExit()
  r.cur.close()
  r.cur = nil

proc cleanup*(r: var Recorder) =
  r.pause()
  removeDir(r.dir)

proc finish*(r: var Recorder; dest: string; fmt: VideoFormat): Process =
  ## Stops recording and starts the ffmpeg join; poll its exit, then `cleanup`.
  r.pause()
  var good: seq[string]
  for s in r.segs:
    if fileExists(s) and getFileSize(s) > 0: good.add s
  if good.len == 0:
    r.cleanup()
    raise newException(RecordError, "nothing was recorded")
  let list = r.dir / "list.txt"
  writeFile(list, concatList(good))
  createDir(dest.parentDir)
  startProcess("ffmpeg", args = joinArgs(list, dest, fmt),
               options = {poUsePath, poParentStreams})
