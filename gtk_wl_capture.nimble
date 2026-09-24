version       = "0.1.0"
author        = "Nicholas Tjornelund"
description   = "GTK4 screenshot tool for Wayland (wlr-screencopy, xdg-desktop-portal fallback)"
license       = "MIT"
srcDir        = "src"
bin           = @["gtk_wl_capture"]
namedBin["gtk_wl_capture"] = "gtk-wl-capture"

requires "nim >= 2.0.0"
requires "gintro >= 1.0.0"

import std/os

const protos = [
  ("protocols/wlr-screencopy-unstable-v1.xml", "wlr-screencopy-unstable-v1"),
  ("/usr/share/wayland-protocols/unstable/xdg-output/xdg-output-unstable-v1.xml", "xdg-output-unstable-v1"),
]

task gen, "generate wayland protocol glue with wayland-scanner":
  mkDir("src/protocols")
  for (xml, name) in protos:
    if not fileExists(xml):
      echo "missing protocol xml: ", xml
      quit(1)
    exec "wayland-scanner client-header " & xml & " src/protocols/" & name & "-client-protocol.h"
    exec "wayland-scanner private-code " & xml & " src/protocols/" & name & ".c"

before build:
  for (_, name) in protos:
    if not fileExists("src/protocols/" & name & ".c"):
      genTask()
      break

task test, "run the checks":
  exec "nim c -r --hints:off tests/tgeometry.nim"

# Called "stage", not "install": `nimble install` is a built-in command and
# would shadow a task of that name. Honours DESTDIR and PREFIX, so the deb and
# rpm scripts in packaging/ can both drive it.
task stage, "install the built tree into DESTDIR (packaging helper)":
  let
    destdir = getEnv("DESTDIR")
    prefix = (if getEnv("PREFIX").len > 0: getEnv("PREFIX") else: "/usr/local")
    bindir = destdir & prefix & "/bin"
    appdir = destdir & prefix & "/share/applications"
    icondir = destdir & prefix & "/share/icons/hicolor/scalable/apps"
    # The app prepends this to the GTK icon search path at runtime; the
    # capture-area buttons render broken glyphs without it.
    datadir = destdir & prefix & "/share/gtk-wl-capture"
    docdir = destdir & prefix & "/share/doc/gtk-wl-capture"

  if not fileExists("gtk-wl-capture"):
    echo "nothing built yet -- run `nimble build` first"
    quit(1)

  mkDir(bindir)
  cpFile("gtk-wl-capture", bindir / "gtk-wl-capture")
  exec "chmod 755 " & (bindir / "gtk-wl-capture")

  mkDir(appdir)
  cpFile("data/dev.gtkwlcapture.GtkWlCapture.desktop",
         appdir / "dev.gtkwlcapture.GtkWlCapture.desktop")

  mkDir(icondir)
  cpFile("data/dev.gtkwlcapture.GtkWlCapture.svg",
         icondir / "dev.gtkwlcapture.GtkWlCapture.svg")

  mkDir(datadir / "icons/hicolor/scalable/actions")
  cpFile("data/icons/hicolor/index.theme", datadir / "icons/hicolor/index.theme")
  for f in listFiles("data/icons/hicolor/scalable/actions"):
    cpFile(f, datadir / "icons/hicolor/scalable/actions" / f.extractFilename)
  cpFile("data/icons/LICENSE", datadir / "icons/LICENSE")

  mkDir(docdir)
  cpFile("README.md", docdir / "README.md")
  cpFile("LICENSE", docdir / "LICENSE")
  echo "staged into ", (if destdir.len > 0: destdir else: "/"), " under ", prefix
