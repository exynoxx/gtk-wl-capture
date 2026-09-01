## gtk-wl-capture - a GTK4 screenshot tool for Wayland.
##
##   gtk-wl-capture              open the window
##   gtk-wl-capture --shot FILE  capture every output and write FILE, no UI

import std/[json, os, osproc, streams, strutils, times, uri]
import gintro/[gtk4, gdk4, gobject, gio, glib, cairo]
import capture

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

  App = ref object
    win: ApplicationWindow
    thumb: Picture
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

var app: App   # single window, single capture at a time

# --- settings --------------------------------------------------------------

proc picturesDir(): string =
  ## Never hardcode ~/Pictures: on this box it is ~/Billeder.
  result = getUserSpecialDir(UserDirectory.directoryPictures)
  if result.len == 0 or not dirExists(result):
    result = os.getHomeDir() / "Pictures"

proc defaultConfig(): Config =
  Config(autoSave: false, saveDir: picturesDir(),
         filename: "'Screenshot_'yyyy'-'MM'-'dd'_'HH'-'mm'-'ss'.png'",
         copyOnCapture: false, closeOnCapture: false,
         includePointer: false, hideWindow: true,
         delay: 0.0, lightTheme: true, mode: mRegion)

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
  except CatchableError:
    discard   # a corrupt config should never stop the app from starting

proc saveConfig(c: Config) =
  createDir(configPath().parentDir)
  writeFile(configPath(), (%*{
    "autoSave": c.autoSave, "saveDir": c.saveDir, "filename": c.filename,
    "copyOnCapture": c.copyOnCapture, "closeOnCapture": c.closeOnCapture,
    "includePointer": c.includePointer,
    "hideWindow": c.hideWindow, "delay": c.delay,
    "lightTheme": c.lightTheme, "mode": $c.mode
  }).pretty)

proc timestampedPath(c: Config): string =
  var name = try: now().format(c.filename)
             except CatchableError: now().format("'Screenshot_'yyyy'-'MM'-'dd'_'HH'-'mm'-'ss'.png'")
  if not name.endsWith(".png"): name.add ".png"
  c.saveDir / name

# --- result handling -------------------------------------------------------

proc say(msg: string) =
  if app.status != nil: app.status.setLabel(msg)

proc copyShot() =
  ## wl-copy forks a holder process, so the image survives this app exiting.
  ## GDK's clipboard cannot: Wayland requires the source client to stay alive.
  let png = app.shot.pngBytes()
  var size: uint64
  let data = png.getData(size)
  if findExe("wl-copy").len > 0:
    let p = startProcess("wl-copy", args = ["--type", "image/png"],
                         options = {poUsePath})
    p.inputStream.writeData(unsafeAddr data[0], data.len)
    p.inputStream.close()
    discard p.waitForExit()
    p.close()
    say("Copied to clipboard")
  else:
    let cb = app.win.getDisplay.getClipboard
    discard cb.setContent(newContentProviderForBytes("image/png", png))
    say("Copied (only while this window stays open - install wl-clipboard)")

proc saveShot(path: string) =
  try:
    createDir(path.parentDir)
    app.shot.savePng(path)
    say("Saved " & path)
  except CatchableError as e:
    say("Save failed: " & e.msg)

proc onSaveResponse(d: FileChooserDialog; response: int) =
  if response == ResponseType.accept.ord:
    let f = d.getFile
    if f != nil: saveShot(f.getPath)
  gtk4.destroy(d)

proc saveAs() =
  ## GtkFileChooserDialog is deprecated in favour of GtkFileDialog, whose
  ## gintro binding is raw-async only.
  let d = newFileChooserDialog("Save Screenshot", app.win, FileChooserAction.save)
  discard d.addButton("_Cancel", ResponseType.cancel.ord)
  discard d.addButton("_Save", ResponseType.accept.ord)
  let suggested = timestampedPath(app.cfg)
  d.setCurrentName(cstring(suggested.extractFilename))
  try:
    discard d.setCurrentFolder(gio.newGFileForPath(cstring(app.cfg.saveDir)))
  except CatchableError:
    discard
  d.connect("response", onSaveResponse)
  d.show

proc showShot() =
  ## Show the capture as a miniature with its save/copy buttons, then do
  ## whatever the settings ask for.
  app.thumb.setPaintable(app.shot.toPaintable)
  app.resultBox.setVisible(true)
  say($app.shot.w & " x " & $app.shot.h)
  if app.cfg.copyOnCapture: copyShot()
  if app.cfg.autoSave: saveShot(timestampedPath(app.cfg))
  if app.cfg.copyOnCapture and app.cfg.closeOnCapture:
    gtk4.destroy(app.win)

proc delayValue(): float =
  try: clamp(parseFloat(app.delayEntry.getText.strip), 0.0, 60.0)
  except ValueError: 0.0

proc setDelay(v: float) =
  app.delayEntry.setText(cstring($int(clamp(v, 0.0, 60.0))))

proc onDelayMinus(b: Button) = setDelay(delayValue() - 1)
proc onDelayPlus(b: Button) = setDelay(delayValue() + 1)

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
  showShot()

proc onDragBegin(g: GestureDrag; x, y: float) =
  app.sel = [x, y, x, y]
  app.hasSel = true
  app.area.queueDraw

proc onDragUpdate(g: GestureDrag; dx, dy: float) =
  app.sel[2] = app.sel[0] + dx
  app.sel[3] = app.sel[1] + dy
  app.area.queueDraw

proc onDragEnd(g: GestureDrag; dx, dy: float) =
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
  ## One overlay window: on a multi-head setup the whole desktop is
  ## letterboxed onto one screen.
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

proc takeShot() =
  say("Capturing...")
  app.cfg.delay = delayValue()
  app.cfg.includePointer = app.pointerSw.getActive
  app.cfg.hideWindow = app.hideSw.getActive
  app.cfg.mode = if app.regionBtn.getActive: mRegion else: mScreen
  saveConfig(app.cfg)
  # Region mode always hides the window: it is about to cover the screen anyway.
  let hide = app.cfg.hideWindow or app.cfg.mode == mRegion
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

# Ctrl+V in the path fields: GtkText only pastes text/plain, so a path copied
# from a file manager (a file:// URI list) lands nowhere. Read the clipboard
# ourselves in the capture phase and insert whatever it holds as a path.

const KeyV = 0x76   # 'v'; shifted is 'V'

proc gdk_clipboard_read_text_finish(cb, res, err: pointer): cstring {.
    importc, cdecl, dynlib: "libgtk-4.so.1".}
proc g_free(p: pointer) {.importc, cdecl, dynlib: "libglib-2.0.so.0".}

var pasteTarget: Entry   # one modal Preferences window, so one target is enough

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

type Prefs = ref object
  win: gtk4.Window
  autoSw, copySw, closeSw, lightSw: Switch
  dirEntry, nameEntry: Entry

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
  saveConfig(app.cfg)

proc onPrefsCloseRequest(w: gtk4.Window; p: Prefs): bool =
  savePrefs(p)   # the window's X goes through here too, so it saves as well
  false          # let the close proceed

# Route the button through close() so both ways out share the one handler.
proc onPrefsClose(b: Button; p: Prefs) = p.win.close

proc showPrefs() =
  let p = Prefs(win: newWindow(), autoSw: newSwitch(), copySw: newSwitch(),
                closeSw: newSwitch(), lightSw: newSwitch(),
                dirEntry: newEntry(), nameEntry: newEntry())
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
  if not app.shot.isEmpty: copyShot()
proc onActSave(a: gio.SimpleAction; v: glib.Variant) =
  if not app.shot.isEmpty: saveShot(timestampedPath(app.cfg))
proc onActSaveAs(a: gio.SimpleAction; v: glib.Variant) =
  if not app.shot.isEmpty: saveAs()
proc onActPrefs(a: gio.SimpleAction; v: glib.Variant) = showPrefs()
proc onActQuit(a: gio.SimpleAction; v: glib.Variant) = gtk4.destroy(app.win)

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

proc onNew(b: Button) = takeShot()
proc onCopy(b: Button) = copyShot()
proc onSave(b: Button) = saveShot(timestampedPath(app.cfg))
proc onSaveAs(b: Button) = saveAs()
proc onPrefs(b: Button) = showPrefs()

const Css = """
.mode-button { padding: 14px 8px; }
.settings-row { padding: 10px 12px; }
.section-label { font-weight: bold; }
"""

proc modeButton(icon, label: string): ToggleButton =
  ## Icon over label, the way the old GNOME Screenshot capture-area buttons look.
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

  # Our capture-area icons live with the app. They go in front of the system
  # theme, which also lets the bundled +/- stand in on desktops whose Adwaita
  # fails to render them.
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
  let takeBtn = newButton("Take Screenshot")
  takeBtn.addCssClass("suggested-action")
  takeBtn.connect("clicked", onNew)
  header.packStart(takeBtn)
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

  # Settings card: the two options that belong next to the capture button.
  let card = newBox(Orientation.vertical, 0)
  app.pointerSw = newSwitch()
  app.pointerSw.setActive(app.cfg.includePointer)
  app.pointerSw.setHalign(Align.`end`)
  card.append(cardRow("Show Pointer", app.pointerSw))
  card.append(newSeparator(Orientation.horizontal))
  # Hand-rolled stepper rather than GtkSpinButton - GTK 4.22's
  # built-in value-increase/decrease icons render blank on adwaita-icon-theme
  # 50, and its resource icons win over any icon search path we can set.
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

  # Miniature of the last capture, hidden until there is one.
  app.resultBox = newBox(Orientation.vertical, 8)
  app.thumb = newPicture()
  app.thumb.setContentFit(ContentFit.contain)
  app.thumb.setSizeRequest(-1, 150)
  let thumbFrame = newFrame()
  thumbFrame.setChild(app.thumb)
  app.resultBox.append(thumbFrame)

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

  app.win.setChild(body)
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
