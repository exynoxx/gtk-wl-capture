## Screen recording through wf-recorder (wlroots-family compositors only).
##
## Each stretch between pauses is its own mkv segment: wf-recorder has no
## pause, and stopping it cleanly is the only way to get a valid file. Segments
## are encoded live in the final codec, so on stop ffmpeg only stitches them
## (gif aside). Everything streams through files on disk, never RAM.

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
    jobs: seq[seq[string]]   ## ffmpeg runs still to go after `job`
    job: Process
    output*: string          ## the finished video, inside `dir`

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

func recorderArgs*(fmt: VideoFormat; fps: int; geom, output: string): seq[string] =
  ## `geom` wins over `output`; with neither, wf-recorder would prompt on stdin.
  # wf-recorder 0.6 defaults to VP9 and 4:4:4. VP9 cannot keep up in real time
  # and wf-recorder queues the frames in RAM; VP8 and x264 at yuv420p can.
  let codec = if fmt == vfWebm: "libvpx" else: "libx264"
  result = @["-y", "-c", codec, "-x", "yuv420p", "-r", $fps]
  if geom.len > 0: result.add ["-g", geom]
  elif output.len > 0: result.add ["-o", output]

func joinCmds*(listFile, palette, dest: string; fmt: VideoFormat): seq[seq[string]] =
  ## ffmpeg runs, in order. Gif takes two passes: palettegen in one filter
  # graph with paletteuse would hold every frame in memory until the end.
  let input = @["-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", listFile]
  if fmt == vfGif:
    @[input & @["-vf", "palettegen", palette],
      input & @["-i", palette, "-lavfi", "paletteuse", dest]]
  else:
    @[input & @["-c", "copy", dest]]

func concatList*(segs: seq[string]): string =
  for s in segs: result.add "file '" & s.replace("'", "'\\''") & "'\n"

proc newRecorder*(args: seq[string]; dir: string): Recorder =
  ## `dir` should be on a real disk next to where the video ends up: /tmp is
  ## often tmpfs, and saving is then a rename.
  for tool in ["wf-recorder", "ffmpeg"]:
    if findExe(tool).len == 0:
      raise newException(RecordError, "recording needs " & tool & " installed")
  Recorder(args: args, dir: dir)

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

proc runNext(r: var Recorder) =
  r.job = startProcess("ffmpeg", args = r.jobs[0], options = {poUsePath, poParentStreams})
  r.jobs.delete(0)

proc poll*(r: var Recorder): int =
  ## Exit code of the ffmpeg chain started by `finish`, -1 while it runs.
  if r.job == nil: return 0
  result = r.job.peekExitCode
  if result == -1: return
  r.job.close()
  r.job = nil
  if result == 0 and r.jobs.len > 0:
    r.runNext()
    result = -1

proc cleanup*(r: var Recorder) =
  r.pause()
  if r.job != nil:
    r.job.terminate()
    discard r.job.waitForExit()
    r.job.close()
    r.job = nil
  r.jobs = @[]
  removeDir(r.dir)

proc finish*(r: var Recorder; fmt: VideoFormat) =
  ## Stops recording and starts ffmpeg on `output`; `poll` until it is done.
  r.pause()
  var good: seq[string]
  for s in r.segs:
    if fileExists(s) and getFileSize(s) > 0: good.add s
  if good.len == 0:
    r.cleanup()
    raise newException(RecordError, "nothing was recorded")
  let list = r.dir / "list.txt"
  writeFile(list, concatList(good))
  r.output = r.dir / "video." & $fmt
  r.jobs = joinCmds(list, r.dir / "palette.png", r.output, fmt)
  r.runNext()
