## Screen capture for Wayland.
##
## Primary path: zwlr_screencopy_unstable_v1 (wlroots-family compositors).
## Fallback:     org.freedesktop.portal.Screenshot over D-Bus (GNOME/KDE).
##
## Everything downstream of `capture` sees a `Shot`: 32-bit BGRA rows, plus the
## logical-coordinate origin and scale needed to map a screen rectangle onto it.

import std/[os, osproc, strutils, posix, times, uri, sequtils, streams]
import gintro/[gdk4, glib]

const protoDir = currentSourcePath().parentDir / "protocols"

{.passC: "-D_GNU_SOURCE -I" & protoDir.}
{.passL: "-lwayland-client".}
{.compile: protoDir / "wlr-screencopy-unstable-v1.c".}
{.compile: protoDir / "xdg-output-unstable-v1.c".}

{.pragma: wl, header: "<wayland-client.h>".}
{.pragma: sc, header: "wlr-screencopy-unstable-v1-client-protocol.h".}
{.pragma: xo, header: "xdg-output-unstable-v1-client-protocol.h".}

# --- opaque wayland objects ------------------------------------------------

type
  WlDisplay {.importc: "struct wl_display", incompleteStruct, wl.} = object
  WlRegistry {.importc: "struct wl_registry", incompleteStruct, wl.} = object
  WlInterface {.importc: "struct wl_interface", incompleteStruct, wl.} = object
  WlOutput {.importc: "struct wl_output", incompleteStruct, wl.} = object
  WlShm {.importc: "struct wl_shm", incompleteStruct, wl.} = object
  WlShmPool {.importc: "struct wl_shm_pool", incompleteStruct, wl.} = object
  WlBuffer {.importc: "struct wl_buffer", incompleteStruct, wl.} = object
  ScMgr {.importc: "struct zwlr_screencopy_manager_v1", incompleteStruct, sc.} = object
  ScFrame {.importc: "struct zwlr_screencopy_frame_v1", incompleteStruct, sc.} = object
  XoMgr {.importc: "struct zxdg_output_manager_v1", incompleteStruct, xo.} = object
  XoOutput {.importc: "struct zxdg_output_v1", incompleteStruct, xo.} = object

proc wl_display_connect(name: cstring): ptr WlDisplay {.importc, wl.}
proc wl_display_disconnect(d: ptr WlDisplay) {.importc, wl.}
proc wl_display_roundtrip(d: ptr WlDisplay): cint {.importc, wl.}
proc wl_display_dispatch(d: ptr WlDisplay): cint {.importc, wl.}
proc wl_display_get_registry(d: ptr WlDisplay): ptr WlRegistry {.importc, wl.}
proc wl_registry_add_listener(r: ptr WlRegistry; l: pointer; data: pointer): cint {.importc, wl.}
proc wl_registry_bind(r: ptr WlRegistry; name: uint32; iface: ptr WlInterface;
                      version: uint32): pointer {.importc, wl.}
proc wl_shm_create_pool(shm: ptr WlShm; fd: cint; size: int32): ptr WlShmPool {.importc, wl.}
proc wl_shm_pool_create_buffer(p: ptr WlShmPool; offset, width, height, stride: int32;
                               format: uint32): ptr WlBuffer {.importc, wl.}
proc wl_shm_pool_destroy(p: ptr WlShmPool) {.importc, wl.}
proc wl_buffer_destroy(b: ptr WlBuffer) {.importc, wl.}

var wl_shm_interface {.importc, wl.}: WlInterface
var wl_output_interface {.importc, wl.}: WlInterface
var zwlr_screencopy_manager_v1_interface {.importc, sc.}: WlInterface
var zxdg_output_manager_v1_interface {.importc, xo.}: WlInterface

proc zwlr_screencopy_manager_v1_capture_output(m: ptr ScMgr; overlayCursor: int32;
                                               o: ptr WlOutput): ptr ScFrame {.importc, sc.}
proc zwlr_screencopy_frame_v1_add_listener(f: ptr ScFrame; l: pointer; data: pointer): cint {.importc, sc.}
proc zwlr_screencopy_frame_v1_copy(f: ptr ScFrame; b: ptr WlBuffer) {.importc, sc.}
proc zwlr_screencopy_frame_v1_destroy(f: ptr ScFrame) {.importc, sc.}
proc zxdg_output_manager_v1_get_xdg_output(m: ptr XoMgr; o: ptr WlOutput): ptr XoOutput {.importc, xo.}
proc zxdg_output_v1_add_listener(x: ptr XoOutput; l: pointer; data: pointer): cint {.importc, xo.}
proc zxdg_output_v1_destroy(x: ptr XoOutput) {.importc, xo.}

proc memfd_create(name: cstring; flags: cuint): cint
  {.importc, header: "<sys/mman.h>".}

# wl_shm / DRM fourcc pixel formats we accept
const
  fmtArgb8888 = 0'u32
  fmtXrgb8888 = 1'u32
  fmtAbgr8888 = 0x34324241'u32
  fmtXbgr8888 = 0x34324258'u32

# --- public shot type ------------------------------------------------------

type
  Shot* = object
    data*: seq[uint8]     ## 32-bit BGRA, premultiplied, `stride` bytes per row
    w*, h*: int          ## pixels
    stride*: int
    hasAlpha*: bool
    scale*: float        ## image pixels per logical unit
    originX*, originY*: int  ## logical coords of the image's top-left corner

  CaptureError* = object of CatchableError

func isEmpty*(s: Shot): bool = s.w == 0 or s.h == 0

func px*(s: Shot; lx, ly: int): (int, int) =
  ## logical screen coords -> image pixel coords
  (int((lx - s.originX).float * s.scale), int((ly - s.originY).float * s.scale))

func crop*(s: Shot; x, y, w, h: int): Shot =
  ## Crop in image pixel coords, clamped to the image.
  let
    x0 = clamp(x, 0, s.w)
    y0 = clamp(y, 0, s.h)
    x1 = clamp(x + w, x0, s.w)
    y1 = clamp(y + h, y0, s.h)
    cw = x1 - x0
    ch = y1 - y0
  result = Shot(w: cw, h: ch, stride: cw * 4, hasAlpha: s.hasAlpha,
                scale: s.scale,
                originX: s.originX + int(x0.float / s.scale),
                originY: s.originY + int(y0.float / s.scale))
  if cw == 0 or ch == 0: return
  result.data = newSeq[uint8](ch * result.stride)
  for row in 0 ..< ch:
    copyMem(addr result.data[row * result.stride],
            addr s.data[(y0 + row) * s.stride + x0 * 4], cw * 4)

func blit(dst: var Shot; src: Shot; dx, dy, dw, dh: int) =
  ## Nearest-neighbour blit of `src` into `dst` at dx,dy scaled to dw x dh.
  for ry in 0 ..< dh:
    let sy = min(ry * src.h div max(dh, 1), src.h - 1)
    let dRow = (dy + ry) * dst.stride
    let sRow = sy * src.stride
    if dy + ry notin 0 ..< dst.h: continue
    for rx in 0 ..< dw:
      let sx = min(rx * src.w div max(dw, 1), src.w - 1)
      if dx + rx notin 0 ..< dst.w: continue
      copyMem(addr dst.data[dRow + (dx + rx) * 4], addr src.data[sRow + sx * 4], 4)

# --- wlr-screencopy --------------------------------------------------------

type
  FrameState = enum fsWaitBuffer, fsCopying, fsReady, fsFailed

  OutRec = object
    wlOut: ptr WlOutput
    xdg: ptr XoOutput
    lx, ly, lw, lh: int32          # logical position/size
    name: string
    fmt, pw, ph, pstride: uint32   # pixel geometry from the buffer event
    frame: ptr ScFrame
    buf: ptr WlBuffer
    pool: ptr WlShmPool
    mem: pointer
    memSize: int
    fd: cint
    state: FrameState
    yInvert: bool

  WlState = object
    shm: ptr WlShm
    scMgr: ptr ScMgr
    xoMgr: ptr XoMgr
    registry: ptr WlRegistry
    outs: seq[OutRec]

  RegistryListener = object
    global: proc (data: pointer; r: ptr WlRegistry; name: uint32;
                  iface: cstring; version: uint32) {.cdecl.}
    globalRemove: proc (data: pointer; r: ptr WlRegistry; name: uint32) {.cdecl.}

  XoListener = object
    logicalPosition: proc (data: pointer; x: ptr XoOutput; px, py: int32) {.cdecl.}
    logicalSize: proc (data: pointer; x: ptr XoOutput; w, h: int32) {.cdecl.}
    done: proc (data: pointer; x: ptr XoOutput) {.cdecl.}
    name: proc (data: pointer; x: ptr XoOutput; n: cstring) {.cdecl.}
    description: proc (data: pointer; x: ptr XoOutput; d: cstring) {.cdecl.}

  ScListener = object
    buffer: proc (data: pointer; f: ptr ScFrame; fmt, w, h, stride: uint32) {.cdecl.}
    flags: proc (data: pointer; f: ptr ScFrame; flags: uint32) {.cdecl.}
    ready: proc (data: pointer; f: ptr ScFrame; secHi, secLo, nsec: uint32) {.cdecl.}
    failed: proc (data: pointer; f: ptr ScFrame) {.cdecl.}
    damage: proc (data: pointer; f: ptr ScFrame; x, y, w, h: uint32) {.cdecl.}
    linuxDmabuf: proc (data: pointer; f: ptr ScFrame; fmt, w, h: uint32) {.cdecl.}
    bufferDone: proc (data: pointer; f: ptr ScFrame) {.cdecl.}

proc onGlobal(data: pointer; r: ptr WlRegistry; name: uint32;
              iface: cstring; version: uint32) {.cdecl.} =
  let st = cast[ptr WlState](data)
  case $iface
  of "wl_shm":
    st.shm = cast[ptr WlShm](wl_registry_bind(r, name, addr wl_shm_interface, 1))
  of "zwlr_screencopy_manager_v1":
    st.scMgr = cast[ptr ScMgr](wl_registry_bind(r, name,
                 addr zwlr_screencopy_manager_v1_interface, min(version, 3)))
  of "zxdg_output_manager_v1":
    st.xoMgr = cast[ptr XoMgr](wl_registry_bind(r, name,
                 addr zxdg_output_manager_v1_interface, min(version, 2)))
  of "wl_output":
    let o = cast[ptr WlOutput](wl_registry_bind(r, name, addr wl_output_interface, min(version, 4)))
    st.outs.add OutRec(wlOut: o, state: fsWaitBuffer)
  else: discard

proc onGlobalRemove(data: pointer; r: ptr WlRegistry; name: uint32) {.cdecl.} = discard

proc onLogicalPosition(data: pointer; x: ptr XoOutput; px, py: int32) {.cdecl.} =
  let o = cast[ptr OutRec](data); o.lx = px; o.ly = py
proc onLogicalSize(data: pointer; x: ptr XoOutput; w, h: int32) {.cdecl.} =
  let o = cast[ptr OutRec](data); o.lw = w; o.lh = h
proc onXoDone(data: pointer; x: ptr XoOutput) {.cdecl.} = discard
proc onXoName(data: pointer; x: ptr XoOutput; n: cstring) {.cdecl.} =
  cast[ptr OutRec](data).name = $n
proc onXoDescription(data: pointer; x: ptr XoOutput; d: cstring) {.cdecl.} = discard

proc onBuffer(data: pointer; f: ptr ScFrame; fmt, w, h, stride: uint32) {.cdecl.} =
  let o = cast[ptr OutRec](data)
  # Keep the first format we can handle; later buffer events are alternatives.
  if o.pw == 0 and fmt in [fmtArgb8888, fmtXrgb8888, fmtAbgr8888, fmtXbgr8888]:
    o.fmt = fmt; o.pw = w; o.ph = h; o.pstride = stride

proc onFlags(data: pointer; f: ptr ScFrame; flags: uint32) {.cdecl.} =
  if (flags and 1) != 0: cast[ptr OutRec](data).yInvert = true

proc onReady(data: pointer; f: ptr ScFrame; secHi, secLo, nsec: uint32) {.cdecl.} =
  cast[ptr OutRec](data).state = fsReady

proc onFailed(data: pointer; f: ptr ScFrame) {.cdecl.} =
  cast[ptr OutRec](data).state = fsFailed

proc onDamage(data: pointer; f: ptr ScFrame; x, y, w, h: uint32) {.cdecl.} = discard
proc onLinuxDmabuf(data: pointer; f: ptr ScFrame; fmt, w, h: uint32) {.cdecl.} = discard
proc onBufferDone(data: pointer; f: ptr ScFrame) {.cdecl.} = discard

var
  registryListener = RegistryListener(global: onGlobal, globalRemove: onGlobalRemove)
  xoListener = XoListener(logicalPosition: onLogicalPosition, logicalSize: onLogicalSize,
                          done: onXoDone, name: onXoName, description: onXoDescription)
  scListener = ScListener(buffer: onBuffer, flags: onFlags, ready: onReady,
                          failed: onFailed, damage: onDamage,
                          linuxDmabuf: onLinuxDmabuf, bufferDone: onBufferDone)

proc allocBuffer(st: var WlState; o: var OutRec): bool =
  let size = int(o.pstride) * int(o.ph)
  o.fd = memfd_create("gtk-wl-capture", 0)
  if o.fd < 0: return false
  if ftruncate(o.fd, Off(size)) != 0: return false
  o.mem = mmap(nil, size, PROT_READ or PROT_WRITE, MAP_SHARED, o.fd, 0)
  if o.mem == MAP_FAILED: return false
  o.memSize = size
  o.pool = wl_shm_create_pool(st.shm, o.fd, int32(size))
  o.buf = wl_shm_pool_create_buffer(o.pool, 0, int32(o.pw), int32(o.ph),
                                    int32(o.pstride), o.fmt)
  o.buf != nil

proc release(o: var OutRec) =
  if o.buf != nil: wl_buffer_destroy(o.buf)
  if o.pool != nil: wl_shm_pool_destroy(o.pool)
  if o.mem != nil and o.mem != MAP_FAILED: discard munmap(o.mem, o.memSize)
  if o.fd > 0: discard close(o.fd)
  if o.frame != nil: zwlr_screencopy_frame_v1_destroy(o.frame)
  if o.xdg != nil: zxdg_output_v1_destroy(o.xdg)

proc toBgra(o: OutRec): Shot =
  ## Copy one output's shm buffer into a tight BGRA image, undoing y-invert
  ## and the R/B swap of the *BGR8888 formats.
  let
    w = int(o.pw)
    h = int(o.ph)
    swapRB = o.fmt in [fmtAbgr8888, fmtXbgr8888]
  result = Shot(w: w, h: h, stride: w * 4, data: newSeq[uint8](w * h * 4),
                hasAlpha: o.fmt in [fmtArgb8888, fmtAbgr8888],
                scale: 1.0, originX: int(o.lx), originY: int(o.ly))
  let src = cast[ptr UncheckedArray[uint8]](o.mem)
  for y in 0 ..< h:
    let sy = if o.yInvert: h - 1 - y else: y
    let sOff = sy * int(o.pstride)
    let dOff = y * result.stride
    copyMem(addr result.data[dOff], addr src[sOff], w * 4)
    if swapRB:
      for x in 0 ..< w:
        let i = dOff + x * 4
        swap(result.data[i], result.data[i + 2])

type
  Part* = object
    ## One output's pixels plus the logical rectangle it occupies.
    shot*: Shot
    lx*, ly*, lw*, lh*: int

proc compose*(parts: seq[Part]): Shot =
  ## Lay the per-output images out in logical space at the highest scale in use.
  if parts.len == 0: raise newException(CaptureError, "no usable outputs")
  if parts.len == 1: return parts[0].shot
  var minX, minY = int.high
  var maxX, maxY = int.low
  var scale = 1.0
  for p in parts:
    if p.lw <= 0 or p.lh <= 0: continue
    minX = min(minX, p.lx); minY = min(minY, p.ly)
    maxX = max(maxX, p.lx + p.lw); maxY = max(maxY, p.ly + p.lh)
    scale = max(scale, p.shot.w / p.lw)
  if minX == int.high: raise newException(CaptureError, "no usable outputs")
  result = Shot(w: int((maxX - minX).float * scale), h: int((maxY - minY).float * scale),
                hasAlpha: false, scale: scale, originX: minX, originY: minY)
  result.stride = result.w * 4
  result.data = newSeq[uint8](result.h * result.stride)
  for p in parts:
    if p.lw <= 0 or p.lh <= 0: continue
    result.blit(p.shot,
                int((p.lx - minX).float * scale), int((p.ly - minY).float * scale),
                int(p.lw.float * scale), int(p.lh.float * scale))

proc captureWlr(includeCursor: bool): Shot =
  let dpy = wl_display_connect(nil)
  if dpy == nil: raise newException(CaptureError, "no wayland display")
  defer: wl_display_disconnect(dpy)

  var st = WlState()
  st.registry = wl_display_get_registry(dpy)
  discard wl_registry_add_listener(st.registry, addr registryListener, addr st)
  discard wl_display_roundtrip(dpy)

  if st.scMgr == nil:
    raise newException(CaptureError, "compositor has no zwlr_screencopy_manager_v1")
  if st.shm == nil or st.outs.len == 0:
    raise newException(CaptureError, "compositor exposes no wl_shm or no outputs")

  defer:
    for o in st.outs.mitems: release(o)

  if st.xoMgr != nil:
    for o in st.outs.mitems:
      o.xdg = zxdg_output_manager_v1_get_xdg_output(st.xoMgr, o.wlOut)
      discard zxdg_output_v1_add_listener(o.xdg, addr xoListener, addr o)
    discard wl_display_roundtrip(dpy)

  for o in st.outs.mitems:
    o.frame = zwlr_screencopy_manager_v1_capture_output(st.scMgr,
                if includeCursor: 1'i32 else: 0'i32, o.wlOut)
    discard zwlr_screencopy_frame_v1_add_listener(o.frame, addr scListener, addr o)
  discard wl_display_roundtrip(dpy)   # delivers the buffer/buffer_done events

  for o in st.outs.mitems:
    if o.pw == 0:
      raise newException(CaptureError, "compositor offered no supported shm format")
    if not allocBuffer(st, o):
      raise newException(CaptureError, "cannot allocate shm buffer")
    zwlr_screencopy_frame_v1_copy(o.frame, o.buf)
    o.state = fsCopying

  while st.outs.anyIt(it.state == fsCopying):
    if wl_display_dispatch(dpy) < 0:
      raise newException(CaptureError, "wayland connection lost during copy")
  for o in st.outs:
    if o.state != fsReady:
      raise newException(CaptureError, "compositor refused the frame copy")

  var parts: seq[Part]
  for o in st.outs:
    # An output with no xdg_output info still needs a logical box.
    let lw = if o.lw > 0: int(o.lw) else: int(o.pw)
    let lh = if o.lh > 0: int(o.lh) else: int(o.ph)
    parts.add Part(shot: toBgra(o), lx: int(o.lx), ly: int(o.ly), lw: lw, lh: lh)
  compose(parts)

const PortalTimeout = 60.0   ## seconds to wait for the portal's Response

# --- xdg-desktop-portal fallback ------------------------------------------

proc shotFromPng*(path: string): Shot =
  ## Load a PNG through GDK and hand back BGRA rows.
  let tex = newTextureFromFilename(path.cstring)
  if tex == nil: raise newException(CaptureError, "cannot load " & path)
  result = Shot(w: tex.width, h: tex.height, hasAlpha: true, scale: 1.0)
  result.stride = result.w * 4
  result.data = newSeq[uint8](result.h * result.stride)
  tex.download(result.data, uint64(result.stride))

proc capturePortal(): Shot =
  ## org.freedesktop.portal.Screenshot hands back a PNG on disk. The URI comes
  ## on the Request object's Response signal, so the monitor has to be running
  ## before the call goes out.
  if findExe("gdbus").len == 0:
    raise newException(CaptureError, "no zwlr_screencopy and no gdbus for the portal fallback")
  # Wrapped in `timeout` so readLine cannot block forever: most portals put a
  # confirmation dialog in front of Screenshot, and the user may never answer.
  let mon = startProcess("timeout", args = [$int(PortalTimeout), "gdbus", "monitor",
                         "--session", "--dest", "org.freedesktop.portal.Desktop"],
                         options = {poUsePath})
  defer:
    mon.terminate(); mon.close()

  let token = "gtkwlcapture" & $getCurrentProcessId()
  let (reply, code) = execCmdEx("gdbus call --session " &
    "--dest org.freedesktop.portal.Desktop " &
    "--object-path /org/freedesktop/portal/desktop " &
    "--method org.freedesktop.portal.Screenshot.Screenshot " &
    "'' \"{'interactive': <false>, 'handle_token': <'" & token & "'>}\"")
  if code != 0:
    raise newException(CaptureError, "portal Screenshot failed: " & reply.strip)

  let deadline = epochTime() + PortalTimeout
  let outs = mon.outputStream
  var line: string
  while epochTime() < deadline:
    if not outs.readLine(line):
      break
    if "Response" in line and "file://" in line:
      let s = line.find("file://") + 7
      var e = line.find('\'', s)
      if e < 0: e = line.len
      let path = decodeUrl(line[s ..< e])
      result = shotFromPng(path)
      removeFile(path)          # the portal drops these in the user's cache
      return
  raise newException(CaptureError,
    "the desktop portal did not return a screenshot within " &
    $int(PortalTimeout) & "s - the request was denied, or its confirmation " &
    "dialog was never answered")

proc capture*(includeCursor: bool): Shot =
  ## Grab every output. Native protocol first, portal only when it is missing.
  if getEnv("GTK_WL_CAPTURE_FORCE_PORTAL").len > 0:
    return capturePortal()
  try:
    captureWlr(includeCursor)
  except CaptureError as e:
    if "zwlr_screencopy" in e.msg: capturePortal()
    else: raise

# --- handing a Shot to GTK -------------------------------------------------

proc toTexture*(s: Shot): Texture =
  ## Wrap the BGRA rows as a GdkTexture. No copy of the pixels beyond the
  ## GBytes; GTK owns it from here.
  let fmt = if s.hasAlpha: MemoryFormat.b8g8r8a8Premultiplied
            else: MemoryFormat.b8g8r8x8
  newMemoryTexture(s.w, s.h, fmt, newBytes(s.data), uint64(s.stride))

proc toPaintable*(s: Shot): Paintable =
  ## GdkTexture implements GdkPaintable; gintro keeps them as separate ref
  ## types, so the cast is how you cross the interface boundary.
  cast[Paintable](s.toTexture)

proc savePng*(s: Shot; path: string) =
  if not s.toTexture.saveToPng(path.cstring):
    raise newException(CaptureError, "could not write " & path)

proc pngBytes*(s: Shot): glib.Bytes =
  s.toTexture.saveToPngBytes()
