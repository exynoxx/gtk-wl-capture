## gtk-wl-capture - a GTK4 screenshot tool for Wayland.
##
##   gtk-wl-capture              open the window
##   gtk-wl-capture --shot FILE  capture every output and write FILE, no UI

import std/[json, os, osproc, sequtils, streams, strutils, times, uri]
import gintro/[gtk4, gdk4, gobject, gio, glib, cairo]
import capture, record

const
  AppId = "dev.gtkwlcapture.GtkWlCapture"
  KeyEscape = 0xff1b

type
  Mode = enum
    mRegion = "region"
    mScreen = "screen"

  Config = object
    autoSave: bool
    saveDir: string
    filename: string       ## std/times format string
    copyOnCapture: bool
    closeOnCapture: bool   ## only meaningful together with copyOnCapture
    includePointer: bool
    hideWindow: bool
    delay: float
    lightTheme: bool
    mode: Mode
    videoFormat: VideoFormat
    fps: int
    recordKey, pauseKey: string   ## GTK accelerator strings, "" = none

  App = ref object
    win: ApplicationWindow
    thumb: Picture
    thumbFrame: Frame
    resultBox: Box
    status: Label
    copyBtn, saveBtn, saveAsBtn: Button
    regionBtn, screenBtn: ToggleButton
    delayEntry: Entry
    pointerSw, hideSw: Switch
    cfg: Config
    shot: Shot
    overlay: gtk4.Window
    area: DrawingArea
    sel: array[4, float]   ## x0, y0, x1, y1 in overlay widget coords
    hasSel: bool
    stack: Stack
    recTime, recHint: Label
    pauseBtn: Button
    wantRecord, recActive: bool
    recOutput: string      ## connector of the window's monitor, for -o
    recSecs: int
    rec: Recorder
    recFormat: VideoFormat ## fixed at start: the segments are encoded for it
    encoding: bool         ## ffmpeg is still turning segments into the video
    video: string          ## the last result when it is a recording, else ""
    videoStaged: bool      ## `video` still sits in the recorder's folder

var app: App   # single window, single capture at a time

# --- settings --------------------------------------------------------------

proc picturesDir(): string =
  result = getUserSpecialDir(UserDirectory.directoryPictures)
  if result.len == 0 or not dirExists(result):
    result = os.getHomeDir() / "Pictures"

proc defaultConfig(): Config =
  Config(autoSave: false, saveDir: picturesDir(),
         filename: "'Screenshot_'yyyy'-'MM'-'dd'_'HH'-'mm'-'ss'.png'",
         copyOnCapture: false, closeOnCapture: false,
         includePointer: false, hideWindow: true,
         delay: 0.0, lightTheme: true, mode: mRegion,
         videoFormat: vfMp4, fps: 30,
         recordKey: "<Control>r", pauseKey: "<Control>p")

proc configPath(): string =
  getConfigDir() / "gtk-wl-capture" / "config.json"

proc loadConfig(): Config =
  result = defaultConfig()
  if not fileExists(configPath()): return
  try:
    let j = parseFile(configPath())
    if j.hasKey("autoSave"): result.autoSave = j["autoSave"].getBool
    if j.hasKey("saveDir"): result.saveDir = j["saveDir"].getStr(result.saveDir)
    if j.hasKey("filename"): result.filename = j["filename"].getStr(result.filename)
    if j.hasKey("copyOnCapture"): result.copyOnCapture = j["copyOnCapture"].getBool
    if j.hasKey("closeOnCapture"): result.closeOnCapture = j["closeOnCapture"].getBool
    if j.hasKey("includePointer"): result.includePointer = j["includePointer"].getBool
    if j.hasKey("hideWindow"): result.hideWindow = j["hideWindow"].getBool
    if j.hasKey("delay"): result.delay = j["delay"].getFloat
    if j.hasKey("lightTheme"): result.lightTheme = j["lightTheme"].getBool
    if j.hasKey("mode") and j["mode"].getStr == $mScreen: result.mode = mScreen
    if j.hasKey("videoFormat"):
      result.videoFormat = parseEnum[VideoFormat](j["videoFormat"].getStr, vfMp4)
    if j.hasKey("fps"): result.fps = clamp(j["fps"].getInt(30), 1, 120)
    if j.hasKey("recordKey"): result.recordKey = j["recordKey"].getStr
    if j.hasKey("pauseKey"): result.pauseKey = j["pauseKey"].getStr
  except CatchableError:
    discard   # a corrupt config should never stop the app from starting

proc saveConfig(c: Config) =
  createDir(configPath().parentDir)
  writeFile(configPath(), (%*{
    "autoSave": c.autoSave, "saveDir": c.saveDir, "filename": c.filename,
    "copyOnCapture": c.copyOnCapture, "closeOnCapture": c.closeOnCapture,
    "includePointer": c.includePointer,
    "hideWindow": c.hideWindow, "delay": c.delay,
    "lightTheme": c.lightTheme, "mode": $c.mode,
    "videoFormat": $c.videoFormat, "fps": c.fps,
    "recordKey": c.recordKey, "pauseKey": c.pauseKey
  }).pretty)

proc timestampedPath(c: Config; ext = "png"): string =
  var name = try: now().format(c.filename)
             except CatchableError: now().format("'Screenshot_'yyyy'-'MM'-'dd'_'HH'-'mm'-'ss'.png'")
  if not name.endsWith(".png"): name.add ".png"
  c.saveDir / name.changeFileExt(ext)

# --- result handling -------------------------------------------------------

proc say(msg: string) =
  if app.status != nil: app.status.setLabel(msg)

proc savePath(): string =
  timestampedPath(app.cfg, if app.video.len > 0: app.video.splitFile.ext[1 .. ^1]
                           else: "png")

proc hasResult(): bool = app.video.len > 0 or not app.shot.isEmpty

proc copyBytes(mime: string; bytes: glib.Bytes) =
  ## wl-copy forks a holder process, so the data survives this app exiting.
  ## GDK's clipboard cannot: Wayland requires the source client to stay alive.
  var size: uint64
  let data = bytes.getData(size)
  if findExe("wl-copy").len > 0:
    let p = startProcess("wl-copy", args = ["--type", mime],
                         options = {poUsePath})
    p.inputStream.writeData(unsafeAddr data[0], data.len)
    p.inputStream.close()
    discard p.waitForExit()
    p.close()
    say("Copied to clipboard")
  else:
    let cb = app.win.getDisplay.getClipboard
    discard cb.setContent(newContentProviderForBytes(cstring(mime), bytes))
    say("Copied (only while this window stays open - install wl-clipboard)")

proc saveVideo(path: string) =
  try:
    createDir(path.parentDir)
    if app.videoStaged:
      moveFile(app.video, path)   # same disk as the save folder: a rename
      app.video = path
      app.videoStaged = false
      app.rec.cleanup()
    else:
      copyFile(app.video, path)
    say("Saved " & path)
  except CatchableError as e:
    say("Save failed: " & e.msg)

proc saveShot(path: string) =
  if app.video.len > 0:
    saveVideo(path)
    return
  try:
    createDir(path.parentDir)
    app.shot.savePng(path)
    say("Saved " & path)
  except CatchableError as e:
    say("Save failed: " & e.msg)

proc copyShot() =
  if app.video.len == 0:
    copyBytes("image/png", app.shot.pngBytes())
    return
  # A video goes on the clipboard as a file, so it has to stay where it is.
  if app.videoStaged: saveVideo(savePath())
  if app.videoStaged: return   # the save failed and said why
  let uri = $gio.newGFileForPath(cstring(app.video)).getUri & "\r\n"
  copyBytes("text/uri-list", newBytes(@(uri.toOpenArrayByte(0, uri.high))))

proc keepVideo() =
  ## An unsaved recording is too costly to drop silently.
  if app.videoStaged: saveVideo(savePath())

proc onSaveResponse(d: FileChooserDialog; response: int) =
  if response == ResponseType.accept.ord:
    let f = d.getFile
    if f != nil: saveShot(f.getPath)
  gtk4.destroy(d)

proc saveAs() =
  let d = newFileChooserDialog(cstring(if app.video.len > 0: "Save Recording" else: "Save Screenshot"),
                               app.win, FileChooserAction.save)
  discard d.addButton("_Cancel", ResponseType.cancel.ord)
  discard d.addButton("_Save", ResponseType.accept.ord)
  let suggested = savePath()
  d.setCurrentName(cstring(suggested.extractFilename))
  try:
    discard d.setCurrentFolder(gio.newGFileForPath(cstring(app.cfg.saveDir)))
  except CatchableError:
    discard
  d.connect("response", onSaveResponse)
  d.show

proc afterCapture() =
  app.resultBox.setVisible(true)
  if app.cfg.copyOnCapture: copyShot()
  # Copying a video already saved it.
  if app.cfg.autoSave and (app.video.len == 0 or app.videoStaged):
    saveShot(savePath())
  if app.cfg.copyOnCapture and app.cfg.closeOnCapture:
    gtk4.destroy(app.win)

proc showShot() =
  app.video = ""
  app.thumb.setPaintable(app.shot.toPaintable)
  app.thumbFrame.setVisible(true)
  say($app.shot.w & " x " & $app.shot.h)
  afterCapture()

proc delayValue(): float =
  try: clamp(parseFloat(app.delayEntry.getText.strip), 0.0, 60.0)
  except ValueError: 0.0

proc setDelay(v: float) =
  app.delayEntry.setText(cstring($int(clamp(v, 0.0, 60.0))))

proc onDelayMinus(b: Button) = setDelay(delayValue() - 1)
proc onDelayPlus(b: Button) = setDelay(delayValue() + 1)

# --- recording -------------------------------------------------------------

proc clock(secs: int): string =
  align($(secs div 60), 2, '0') & ":" & align($(secs mod 60), 2, '0')

proc encoded(code: int) =
  app.encoding = false
  if code != 0:
    app.rec.cleanup()
    say("ffmpeg failed (exit " & $code & ") - the recording was discarded")
    return
  app.video = app.rec.output
  app.videoStaged = true
  app.thumbFrame.setVisible(false)
  say(clock(app.recSecs) & " " & $app.recFormat & " recording")
  afterCapture()

proc onEncodeTick(data: pointer): gboolean {.cdecl.} =
  if not app.encoding: return gboolean(false)   # onWinClose finished it
  let code = app.rec.poll
  if code == -1: return gboolean(true)
  encoded(code)
  gboolean(false)

proc stopRecording() =
  if not app.recActive: return
  app.recActive = false
  app.stack.setVisibleChildName("main")
  try:
    app.rec.finish(app.recFormat)
  except CatchableError as e:
    say(e.msg)
    return
  app.encoding = true
  say("Finishing the recording...")
  discard timeoutAdd(0, 200, onEncodeTick, nil, nil)

proc togglePause() =
  if not app.recActive: return
  if app.rec.recording:
    app.rec.pause()
    app.pauseBtn.setLabel("Resume")
    say("Paused")
  else:
    try:
      app.rec.resume()
    except CatchableError as e:
      say(e.msg)
      return
    app.pauseBtn.setLabel("Pause")
    say("Recording")

proc onRecTick(data: pointer): gboolean {.cdecl.} =
  if not app.recActive: return gboolean(false)
  if app.rec.died:
    say("wf-recorder stopped on its own")
    stopRecording()
    return gboolean(false)
  if app.rec.recording:
    inc app.recSecs
    app.recTime.setLabel(cstring(clock(app.recSecs)))
  gboolean(true)

proc beginRecording(geom, output: string) =
  app.win.setVisible(true)
  app.win.present
  try:
    app.recFormat = app.cfg.videoFormat
    app.rec = newRecorder(recorderArgs(app.recFormat, app.cfg.fps, geom, output),
                          app.cfg.saveDir / ".gtk-wl-capture-rec-" & $getCurrentProcessId())
    app.rec.resume()
  except CatchableError as e:
    say(e.msg)
    return
  app.recActive = true
  app.recSecs = 0
  app.recTime.setLabel("00:00")
  app.pauseBtn.setLabel("Pause")
  var keys: seq[string]
  if app.cfg.pauseKey.len > 0: keys.add app.cfg.pauseKey & " pauses"
  if app.cfg.recordKey.len > 0: keys.add app.cfg.recordKey & " stops"
  app.recHint.setLabel(cstring(keys.join(", ")))
  app.stack.setVisibleChildName("rec")
  say("Recording")
  discard timeoutAdd(0, 1000, onRecTick, nil, nil)

# --- region overlay --------------------------------------------------------

proc selRect(): tuple[x, y, w, h: float] =
  let
    x0 = min(app.sel[0], app.sel[2])
    y0 = min(app.sel[1], app.sel[3])
  (x0, y0, max(app.sel[0], app.sel[2]) - x0, max(app.sel[1], app.sel[3]) - y0)

proc mapping(w, h: float): tuple[offX, offY, scale: float] =
  ## The Picture below the overlay uses content-fit "contain", so the image is
  ## centred and letterboxed. Convert widget pixels to image pixels.
  let
    imgAspect = app.shot.w / app.shot.h
    winAspect = w / h
  if imgAspect > winAspect:
    let drawH = w / imgAspect
    (0.0, (h - drawH) / 2, app.shot.w.float / w)
  else:
    let drawW = h * imgAspect
    ((w - drawW) / 2, 0.0, app.shot.h.float / h)

proc drawOverlay(a: ptr DrawingArea00; cr: ptr cairo.Context00;
                 w, h: int32; data: pointer) {.cdecl.} =
  let (fw, fh) = (w.float, h.float)
  cairo_set_source_rgba(cr, 0, 0, 0, 0.45)
  if not app.hasSel:
    cairo_rectangle(cr, 0, 0, fw, fh)
    cairo_fill(cr)
    return
  let r = selRect()
  # Dim in four bands around the selection rather than fiddling with fill rules.
  for band in [(0.0, 0.0, fw, r.y), (0.0, r.y + r.h, fw, fh - r.y - r.h),
               (0.0, r.y, r.x, r.h), (r.x + r.w, r.y, fw - r.x - r.w, r.h)]:
    cairo_rectangle(cr, band[0], band[1], band[2], band[3])
    cairo_fill(cr)
  cairo_set_source_rgba(cr, 1, 1, 1, 0.9)
  cairo_set_line_width(cr, 1.0)
  cairo_rectangle(cr, r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1)
  cairo_stroke(cr)
  if r.w >= 1 and r.h >= 1:
    let (_, _, scale) = mapping(fw, fh)
    let label = $int(r.w * scale) & " x " & $int(r.h * scale)
    cairo_select_font_face(cr, "sans-serif", FontSlant.normal, FontWeight.normal)
    cairo_set_font_size(cr, 13)
    var ext: TextExtents
    cairo_text_extents(cr, label.cstring, ext)
    let
      bx = r.x
      by = if r.y > 24: r.y - 6 else: r.y + r.h + 18
    cairo_set_source_rgba(cr, 0, 0, 0, 0.7)
    cairo_rectangle(cr, bx - 4, by - ext.height - 4, ext.width + 8, ext.height + 8)
    cairo_fill(cr)
    cairo_set_source_rgba(cr, 1, 1, 1, 1)
    cairo_move_to(cr, bx, by)
    cairo_show_text(cr, label.cstring)

proc closeOverlay() =
  if app.overlay != nil:
    gtk4.destroy(app.overlay)
    app.overlay = nil
  app.win.setVisible(true)
  app.win.present

proc finishRegion() =
  let r = selRect()
  closeOverlay()
  if r.w < 2 or r.h < 2:
    say("Selection cancelled")
    return
  let (offX, offY, scale) = mapping(app.area.getWidth.float, app.area.getHeight.float)
  app.shot = app.shot.crop(int((r.x - offX) * scale), int((r.y - offY) * scale),
                           int(r.w * scale), int(r.h * scale))
  if app.wantRecord:
    beginRecording(geometry(app.shot.originX, app.shot.originY,
                            app.shot.w, app.shot.h, app.shot.scale), "")
  else:
    showShot()

proc onDragBegin(g: GestureDrag; x, y: cdouble) =
  app.sel = [x, y, x, y]
  app.hasSel = true
  app.area.queueDraw

proc onDragUpdate(g: GestureDrag; dx, dy: cdouble) =
  app.sel[2] = app.sel[0] + dx
  app.sel[3] = app.sel[1] + dy
  app.area.queueDraw

proc onDragEnd(g: GestureDrag; dx, dy: cdouble) =
  app.sel[2] = app.sel[0] + dx
  app.sel[3] = app.sel[1] + dy
  finishRegion()

proc onOverlayKey(c: EventControllerKey; keyval, keycode: int;
                  state: ModifierType): bool =
  if keyval == KeyEscape:
    closeOverlay()
    say("Cancelled")
    return true
  false

proc showOverlay() =
  ## A frozen full-screen copy with a rubber band over it - the same trick
  ## Spectacle uses, and it needs no layer-shell.
  app.win.setVisible(false)
  app.hasSel = false
  let w = newWindow()
  app.overlay = w
  w.setDecorated(false)
  w.fullscreen

  let pic = newPicture()
  pic.setPaintable(app.shot.toPaintable)
  pic.setContentFit(ContentFit.contain)

  app.area = newDrawingArea()
  app.area.setDrawFunc(drawOverlay, nil, nil)

  let ov = newOverlay()
  ov.setChild(pic)
  ov.addOverlay(app.area)
  w.setChild(ov)

  let drag = newGestureDrag()
  drag.connect("drag-begin", onDragBegin)
  drag.connect("drag-update", onDragUpdate)
  drag.connect("drag-end", onDragEnd)
  app.area.addController(drag)

  let keys = newEventControllerKey()
  keys.connect("key-pressed", onOverlayKey)
  w.addController(keys)

  w.present

# --- taking the shot -------------------------------------------------------

proc doCapture(data: pointer): gboolean {.cdecl.} =
  try:
    if app.wantRecord and app.cfg.mode == mScreen:
      beginRecording("", app.recOutput)
      return gboolean(false)
    app.shot = capture(app.cfg.includePointer)
    if app.cfg.mode == mRegion:
      showOverlay()
    else:
      app.win.setVisible(true)
      showShot()
  except CatchableError as e:
    app.win.setVisible(true)
    say(e.msg)
  gboolean(false)   # one-shot timeout

proc takeShot(record = false) =
  if app.recActive: return
  if app.encoding:
    say("Still finishing the last recording")
    return
  keepVideo()
  app.wantRecord = record
  if record:
    # Full-screen recording is one output: the one this window is on.
    let m = app.win.getDisplay.getMonitorAtSurface(app.win.getSurface)
    app.recOutput = if m != nil: m.getConnector else: ""
  say(if record: "Starting recording..." else: "Capturing...")
  app.cfg.delay = delayValue()
  app.cfg.includePointer = app.pointerSw.getActive
  app.cfg.hideWindow = app.hideSw.getActive
  app.cfg.mode = if app.regionBtn.getActive: mRegion else: mScreen
  saveConfig(app.cfg)
  # Region mode always hides the window: it is about to cover the screen anyway.
  # A recording keeps the window up for its stop button.
  let hide = app.cfg.mode == mRegion or (app.cfg.hideWindow and not record)
  if hide: app.win.setVisible(false)
  # Give the compositor a frame to actually unmap the window before grabbing.
  let ms = int(app.cfg.delay * 1000) + (if hide: 250 else: 0)
  discard timeoutAdd(0, max(ms, 1), doCapture, nil, nil)

# --- preferences -----------------------------------------------------------

proc cardRow(label: string; w: Widget): Box =
  result = newBox(Orientation.horizontal, 12)
  result.addCssClass("settings-row")
  let l = newLabel(cstring(label))
  l.setXalign(0)
  l.setHexpand(true)
  w.setValign(Align.center)
  result.append(l)
  result.append(w)

proc row(box: Box; label: string; w: Widget) =
  box.append(cardRow(label, w))

# GtkText only pastes text/plain, so a path copied from a file manager (a
# file:// URI) never arrives. Read the clipboard ourselves, in the capture
# phase so this runs before GtkText's own Ctrl+V.

const KeyV = 0x76

proc gdk_clipboard_read_text_finish(cb, res, err: pointer): cstring {.
    importc, cdecl, dynlib: "libgtk-4.so.1".}
proc g_free(p: pointer) {.importc, cdecl, dynlib: "libglib-2.0.so.0".}

var pasteTarget: Entry

proc pastedPath(s: string): string =
  for line in s.splitLines:
    let t = line.strip
    if t.len == 0: continue
    return if t.startsWith("file://"): decodeUrl(t[7 .. ^1], decodePlus = false)
           else: t

proc onClipboardText(src: ptr gobject.Object00; res: ptr gio.AsyncResult00;
                     data: pointer) {.cdecl.} =
  let raw = gdk_clipboard_read_text_finish(src, res, nil)
  if raw.isNil: return
  let s = pastedPath($raw)
  g_free(raw)
  if s.len == 0 or pasteTarget == nil: return
  pasteTarget.deleteSelection()
  var pos = pasteTarget.getPosition
  pasteTarget.insertText(cstring(s), s.len, pos)
  pasteTarget.setPosition(pos)

proc onPathKey(c: EventControllerKey; keyval, keycode: int;
               state: ModifierType; e: Entry): bool =
  if ModifierFlag.control in state and (keyval or 0x20) == KeyV:
    pasteTarget = e
    e.getDisplay.getClipboard.readTextAsync(nil, onClipboardText, nil)
    return true
  false

proc pastable(e: Entry) =
  let keys = newEventControllerKey()
  keys.setPropagationPhase(PropagationPhase.capture)
  keys.connect("key-pressed", onPathKey, e)
  e.addController(keys)

proc setKey(a: Application; action, key: string) =
  if key.len > 0: a.setAccelsForAction(cstring(action), key)
  else: a.setAccelsForAction(cstring(action))

proc applyRecordKeys(a: Application) =
  a.setKey("app.record", app.cfg.recordKey)
  a.setKey("app.pause", app.cfg.pauseKey)

proc validKey(s: string): bool =
  var key: int
  var mods: ModifierType
  s.len == 0 or acceleratorParse(cstring(s), key, mods)

type Prefs = ref object
  win: gtk4.Window
  autoSw, copySw, closeSw, lightSw: Switch
  dirEntry, nameEntry, fpsEntry, recordKeyEntry, pauseKeyEntry: Entry
  formatDrop: DropDown

proc onCopyToggled(sw: Switch; state: bool; p: Prefs): bool =
  p.closeSw.setSensitive(state)   # closing only makes sense once copying is on
  false

proc onFolderResponse(d: FileChooserDialog; response: int; p: Prefs) =
  if response == ResponseType.accept.ord:
    let f = d.getFile
    if f != nil: p.dirEntry.setText(cstring(f.getPath))
  gtk4.destroy(d)

proc onPickFolder(b: Button; p: Prefs) =
  let d = newFileChooserDialog("Save Folder", p.win,
                               FileChooserAction.selectFolder)
  discard d.addButton("_Cancel", ResponseType.cancel.ord)
  discard d.addButton("_Select", ResponseType.accept.ord)
  try:
    discard d.setCurrentFolder(gio.newGFileForPath(cstring(p.dirEntry.getText)))
  except CatchableError:
    discard
  d.connect("response", onFolderResponse, p)
  d.show

proc savePrefs(p: Prefs) =
  app.cfg.autoSave = p.autoSw.getActive
  app.cfg.copyOnCapture = p.copySw.getActive
  app.cfg.closeOnCapture = p.closeSw.getActive
  app.cfg.lightTheme = p.lightSw.getActive
  app.cfg.saveDir = p.dirEntry.getText
  app.cfg.filename = p.nameEntry.getText
  app.cfg.videoFormat = VideoFormat(clamp(p.formatDrop.getSelected, 0, VideoFormat.high.ord))
  app.cfg.fps = try: clamp(parseInt(p.fpsEntry.getText.strip), 1, 120)
                except ValueError: app.cfg.fps
  # A typo in a shortcut keeps the old one rather than silently unbinding it.
  for (e, key) in [(p.recordKeyEntry, addr app.cfg.recordKey),
                   (p.pauseKeyEntry, addr app.cfg.pauseKey)]:
    let t = e.getText.strip
    if validKey(t): key[] = t
  applyRecordKeys(app.win.getApplication)
  saveConfig(app.cfg)

proc onPrefsCloseRequest(w: gtk4.Window; p: Prefs): bool =
  savePrefs(p)
  false

proc onPrefsClose(b: Button; p: Prefs) = p.win.close

proc showPrefs() =
  let p = Prefs(win: newWindow(), autoSw: newSwitch(), copySw: newSwitch(),
                closeSw: newSwitch(), lightSw: newSwitch(),
                dirEntry: newEntry(), nameEntry: newEntry(), fpsEntry: newEntry(),
                recordKeyEntry: newEntry(), pauseKeyEntry: newEntry(),
                formatDrop: newDropDownFromStrings(VideoFormat.mapIt($it)))
  p.win.setTitle("Preferences")
  p.win.setTransientFor(app.win)
  p.win.setModal(true)
  p.win.setDefaultSize(480, 260)

  let box = newBox(Orientation.vertical, 12)
  box.setMarginTop(18); box.setMarginBottom(18)
  box.setMarginStart(18); box.setMarginEnd(18)

  p.autoSw.setActive(app.cfg.autoSave)
  p.autoSw.setHalign(Align.`end`)
  box.row("Save automatically after each capture", p.autoSw)

  p.copySw.setActive(app.cfg.copyOnCapture)
  p.copySw.setHalign(Align.`end`)
  p.copySw.connect("state-set", onCopyToggled, p)
  box.row("Copy to clipboard after each capture", p.copySw)

  p.closeSw.setActive(app.cfg.closeOnCapture)
  p.closeSw.setHalign(Align.`end`)
  p.closeSw.setSensitive(app.cfg.copyOnCapture)
  box.row("    ...then close the window", p.closeSw)

  p.lightSw.setActive(app.cfg.lightTheme)
  p.lightSw.setHalign(Align.`end`)
  box.row("Light appearance (restart to apply)", p.lightSw)

  p.dirEntry.setText(cstring(app.cfg.saveDir))
  p.dirEntry.setHexpand(true)
  pastable(p.dirEntry)
  let pick = newButtonFromIconName("folder-symbolic")
  pick.setTooltipText("Choose folder")
  pick.connect("clicked", onPickFolder, p)
  let dirBox = newBox(Orientation.horizontal, 6)
  dirBox.setHexpand(true)
  dirBox.append(p.dirEntry)
  dirBox.append(pick)
  box.row("Save folder", dirBox)

  p.nameEntry.setText(cstring(app.cfg.filename))
  p.nameEntry.setHexpand(true)
  pastable(p.nameEntry)
  box.row("File name", p.nameEntry)

  let hint = newLabel("File name is a Nim time format - literal text goes in " &
                      "single quotes, e.g. 'shot_'yyyy'-'MM'-'dd'.png'")
  hint.setXalign(0)
  hint.setWrap(true)
  hint.setOpacity(0.7)
  box.append(hint)

  p.formatDrop.setSelected(app.cfg.videoFormat.ord)
  box.row("Recording format", p.formatDrop)

  p.fpsEntry.setText(cstring($app.cfg.fps))
  p.fpsEntry.setWidthChars(4)
  box.row("Recording frames per second", p.fpsEntry)

  for (e, key) in [(p.recordKeyEntry, app.cfg.recordKey),
                   (p.pauseKeyEntry, app.cfg.pauseKey)]:
    e.setText(cstring(key))
    e.setPlaceholderText("none")
  box.row("Start/stop recording shortcut", p.recordKeyEntry)
  box.row("Pause/resume recording shortcut", p.pauseKeyEntry)

  let keyHint = newLabel("Shortcuts use GTK syntax, e.g. <Control><Shift>r. " &
                         "They work while this window has focus.")
  keyHint.setXalign(0)
  keyHint.setWrap(true)
  keyHint.setOpacity(0.7)
  box.append(keyHint)

  let close = newButton("Close")
  close.setHalign(Align.`end`)
  close.connect("clicked", onPrefsClose, p)
  box.append(close)

  p.win.connect("close-request", onPrefsCloseRequest, p)
  p.win.setChild(box)
  p.win.present

# --- main window -----------------------------------------------------------

proc onActNew(a: gio.SimpleAction; v: glib.Variant) = takeShot()
proc onActCopy(a: gio.SimpleAction; v: glib.Variant) =
  if hasResult(): copyShot()
proc onActSave(a: gio.SimpleAction; v: glib.Variant) =
  if hasResult(): saveShot(savePath())
proc onActSaveAs(a: gio.SimpleAction; v: glib.Variant) =
  if hasResult(): saveAs()
proc onActPrefs(a: gio.SimpleAction; v: glib.Variant) = showPrefs()
proc onActQuit(a: gio.SimpleAction; v: glib.Variant) = app.win.close
proc onActRecord(a: gio.SimpleAction; v: glib.Variant) =
  if app.recActive: stopRecording() else: takeShot(record = true)
proc onActPause(a: gio.SimpleAction; v: glib.Variant) = togglePause()

proc addAccels(application: Application) =
  ## gintro's connect macro needs a literal handler symbol, so no loop here.
  let ga = cast[gio.GApplication](application)
  var act = newSimpleAction("new")
  act.connect("activate", onActNew)
  ga.addAction(act)
  application.setAccelsForAction("app.new", "<Control>n")
  act = newSimpleAction("copy")
  act.connect("activate", onActCopy)
  ga.addAction(act)
  application.setAccelsForAction("app.copy", "<Control>c")
  act = newSimpleAction("save")
  act.connect("activate", onActSave)
  ga.addAction(act)
  application.setAccelsForAction("app.save", "<Control>s")
  act = newSimpleAction("saveas")
  act.connect("activate", onActSaveAs)
  ga.addAction(act)
  application.setAccelsForAction("app.saveas", "<Control><Shift>s")
  act = newSimpleAction("prefs")
  act.connect("activate", onActPrefs)
  ga.addAction(act)
  application.setAccelsForAction("app.prefs", "<Control>comma")
  act = newSimpleAction("quit")
  act.connect("activate", onActQuit)
  ga.addAction(act)
  application.setAccelsForAction("app.quit", "<Control>q")
  act = newSimpleAction("record")
  act.connect("activate", onActRecord)
  ga.addAction(act)
  act = newSimpleAction("pause")
  act.connect("activate", onActPause)
  ga.addAction(act)
  applyRecordKeys(application)

proc onNew(b: Button) = takeShot()
proc onCopy(b: Button) = copyShot()
proc onSave(b: Button) = saveShot(savePath())
proc onSaveAs(b: Button) = saveAs()
proc onPrefs(b: Button) = showPrefs()
proc onRecord(b: Button) = takeShot(record = true)
proc onPauseClicked(b: Button) = togglePause()
proc onStopClicked(b: Button) = stopRecording()

proc onWinClose(w: ApplicationWindow): bool =
  ## wf-recorder would outlive us and keep recording; save what we have.
  stopRecording()
  if app.encoding:
    var code = app.rec.poll
    while code == -1:
      sleep(100)
      code = app.rec.poll
    # Not `encoded`: close-on-copy would destroy the window mid close-request.
    if code == 0:
      app.video = app.rec.output
      app.videoStaged = true
  keepVideo()
  false

const Css = """
.mode-button { padding: 14px 8px; }
.settings-row { padding: 10px 12px; }
.section-label { font-weight: bold; }
.rec-time { font-size: 36px; font-weight: bold; font-feature-settings: "tnum"; }
.rec-button { font-size: 20px; padding: 20px 28px; }
"""

proc modeButton(icon, label: string): ToggleButton =
  result = newToggleButton()
  let inner = newBox(Orientation.vertical, 6)
  inner.setHalign(Align.center)
  let img = newImageFromIconName(cstring(icon))
  img.setPixelSize(32)
  inner.append(img)
  inner.append(newLabel(cstring(label)))
  result.setChild(inner)
  result.addCssClass("mode-button")
  result.setHexpand(true)

proc buildUi(application: Application) =
  addAccels(application)

  app.win = newApplicationWindow(application)
  app.win.setTitle("Screenshot")
  app.win.setDefaultSize(460, 420)

  # The bundled capture-area icons have to win over the system theme.
  let icons = getIconThemeForDisplay(app.win.getDisplay)
  var paths: seq[string]
  for dir in [getAppDir() / "data" / "icons",                  # built in-tree
              getAppDir().parentDir / "data" / "icons",         # bin/ subdir
              getAppDir().parentDir / "share" / "gtk-wl-capture" / "icons",
              "/usr/share/gtk-wl-capture/icons"]:
    if dirExists(dir): paths.add dir
  if paths.len > 0:
    icons.setSearchPath(paths & icons.getSearchPath)

  let css = newCssProvider()
  css.loadFromString(Css)
  addProviderForDisplay(app.win.getDisplay, css, 600)

  let header = newHeaderBar()
  header.setDecorationLayout("close,maximize,minimize:")
  let takeBtn = newButton("Take Screenshot")
  takeBtn.addCssClass("suggested-action")
  takeBtn.connect("clicked", onNew)
  header.packStart(takeBtn)
  let recBtn = newButton("Record")
  recBtn.connect("clicked", onRecord)
  header.packStart(recBtn)
  let prefsBtn = newButtonFromIconName("open-menu-symbolic")
  prefsBtn.setTooltipText("Preferences")
  prefsBtn.connect("clicked", onPrefs)
  header.packEnd(prefsBtn)
  app.win.setTitlebar(header)

  let body = newBox(Orientation.vertical, 12)
  body.setMarginTop(14); body.setMarginBottom(14)
  body.setMarginStart(14); body.setMarginEnd(14)

  let areaLabel = newLabel("Capture Area")
  areaLabel.setXalign(0)
  areaLabel.addCssClass("section-label")
  body.append(areaLabel)

  let modeBox = newBox(Orientation.horizontal, 0)
  modeBox.addCssClass("linked")
  modeBox.setHomogeneous(true)
  app.screenBtn = modeButton("gwc-screen-symbolic", "Screen")
  app.regionBtn = modeButton("gwc-selection-symbolic", "Selection")
  app.regionBtn.setGroup(app.screenBtn)
  if app.cfg.mode == mRegion: app.regionBtn.setActive(true)
  else: app.screenBtn.setActive(true)
  modeBox.append(app.screenBtn)
  modeBox.append(app.regionBtn)
  body.append(modeBox)

  let card = newBox(Orientation.vertical, 0)
  app.pointerSw = newSwitch()
  app.pointerSw.setActive(app.cfg.includePointer)
  app.pointerSw.setHalign(Align.`end`)
  card.append(cardRow("Show Pointer", app.pointerSw))
  card.append(newSeparator(Orientation.horizontal))
  # Hand-rolled stepper: GtkSpinButton's built-in +/- icons render blank on
  # adwaita-icon-theme 50.
  let stepper = newBox(Orientation.horizontal, 0)
  stepper.addCssClass("linked")
  app.delayEntry = newEntry()
  app.delayEntry.setMaxWidthChars(3)
  app.delayEntry.setWidthChars(3)
  app.delayEntry.setAlignment(0.5)
  setDelay(app.cfg.delay)
  let minusBtn = newButton("\u2212")
  let plusBtn = newButton("+")
  minusBtn.connect("clicked", onDelayMinus)
  plusBtn.connect("clicked", onDelayPlus)
  stepper.append(app.delayEntry)
  stepper.append(minusBtn)
  stepper.append(plusBtn)
  card.append(cardRow("Delay in Seconds", stepper))
  card.append(newSeparator(Orientation.horizontal))
  app.hideSw = newSwitch()
  app.hideSw.setActive(app.cfg.hideWindow)
  app.hideSw.setHalign(Align.`end`)
  card.append(cardRow("Hide This Window", app.hideSw))
  let cardFrame = newFrame()
  cardFrame.setChild(card)
  body.append(cardFrame)

  app.resultBox = newBox(Orientation.vertical, 8)
  app.thumb = newPicture()
  app.thumb.setContentFit(ContentFit.contain)
  app.thumb.setSizeRequest(-1, 150)
  app.thumbFrame = newFrame()
  app.thumbFrame.setChild(app.thumb)
  app.resultBox.append(app.thumbFrame)

  let actions = newBox(Orientation.horizontal, 6)
  actions.setHomogeneous(true)
  app.copyBtn = newButton("Copy to Clipboard")
  app.saveBtn = newButton("Save")
  app.saveAsBtn = newButton("Save As...")
  app.copyBtn.connect("clicked", onCopy)
  app.saveBtn.connect("clicked", onSave)
  app.saveAsBtn.connect("clicked", onSaveAs)
  for b in [app.copyBtn, app.saveBtn, app.saveAsBtn]:
    actions.append(b)
  app.resultBox.append(actions)
  app.resultBox.setVisible(false)
  body.append(app.resultBox)

  app.status = newLabel("Ready")
  app.status.setXalign(0)
  app.status.setWrap(true)
  app.status.setOpacity(0.7)
  body.append(app.status)

  let recPage = newBox(Orientation.vertical, 18)
  recPage.setValign(Align.center)
  recPage.setMarginStart(24); recPage.setMarginEnd(24)
  app.recTime = newLabel("00:00")
  app.recTime.addCssClass("rec-time")
  recPage.append(app.recTime)
  app.pauseBtn = newButton("Pause")
  app.pauseBtn.connect("clicked", onPauseClicked)
  let stopBtn = newButton("Stop")
  stopBtn.addCssClass("destructive-action")
  stopBtn.connect("clicked", onStopClicked)
  for b in [app.pauseBtn, stopBtn]:
    b.addCssClass("rec-button")
    recPage.append(b)
  app.recHint = newLabel("")
  app.recHint.setOpacity(0.7)
  recPage.append(app.recHint)

  app.stack = newStack()
  discard app.stack.addNamed(body, "main")
  discard app.stack.addNamed(recPage, "rec")
  app.win.setChild(app.stack)
  app.win.connect("close-request", onWinClose)
  app.win.present

# --- entry point -----------------------------------------------------------

proc cli(): bool =
  ## Returns true when the whole job was done without a UI.
  let args = commandLineParams()
  if args.len == 0: return false
  case args[0]
  of "--shot":
    if args.len < 2: quit("usage: gtk-wl-capture --shot FILE", 2)
    let cfg = loadConfig()
    try:
      capture(cfg.includePointer).savePng(args[1])
    except CatchableError as e:
      quit("gtk-wl-capture: " & e.msg, 1)
    true
  of "--help", "-h":
    echo """gtk-wl-capture - GTK4 screenshot tool for Wayland

  gtk-wl-capture              open the window
  gtk-wl-capture --shot FILE  capture every output to FILE and exit

Settings live in """ & configPath()
    true
  else:
    quit("unknown option: " & args[0] & " (try --help)", 2)

proc main =
  app = App(cfg: loadConfig())
  if cli(): return
  # GTK reads GTK_THEME once at startup; an explicit one from the user wins.
  if app.cfg.lightTheme and getEnv("GTK_THEME").len == 0:
    putEnv("GTK_THEME", "Adwaita")
  let application = newApplication(AppId)
  application.connect("activate", buildUi)
  discard application.run

main()
