#!/usr/bin/env python3
"""Install everything gtk-wl-capture needs to build, and patch the one
dependency that ships broken code.

    ./install_deps.py            # install system packages + nimble deps + patch
    ./install_deps.py --check    # report what is missing, change nothing
    ./install_deps.py --patch    # only re-apply the gintro patches

System packages need root, so that step re-runs itself under sudo.
"""

import argparse
import glob
import os
import re
import shutil
import subprocess
import sys

# Build deps. wl-clipboard is optional but makes "copy" survive app exit.
PACKAGES = {
    "dnf": ["nim", "gtk4-devel", "gobject-introspection-devel", "wayland-devel",
            "wayland-protocols-devel", "cairo-devel", "gcc", "wl-clipboard"],
    "apt": ["nim", "libgtk-4-dev", "libgirepository1.0-dev", "libwayland-dev",
            "wayland-protocols", "libcairo2-dev", "gcc", "wl-clipboard"],
}

# gintro 1.0.0 generates a handful of files that do not compile. Each entry is
# (file, broken, fixed); applying a patch twice is a no-op.
GINTRO_PATCHES = [
    ("glib.nim",
     "copyMem(unsafeaddr end[0], end_00, maxLen.int * sizeof(end[0]))",
     "copyMem(unsafeaddr `end`[0], end_00, maxLen.int * sizeof(`end`[0]))"
     "  # patched: codegen dropped the backticks around the `end` keyword"),
    # cairo.nim declares an opaque Glyph00 that clashes with the real one in
    # cairoimpl.nim, which it includes further down. Drop the stub and the
    # three procs that use it; nothing else in gintro references them.
    ("cairo.nim",
     """type
  Glyph00* {.pure.} = object
  Glyph* = ref object of RootRef
    impl*: ptr Glyph00
    ignoreFinalizer*: bool

proc cairo_gobject_glyph_get_type*(): GType {.importc, libprag.}

proc gBoxedFreeCairoGlyph*(self: Glyph) =
  if not self.ignoreFinalizer and  self.impl != nil:
    boxedFree(cairo_gobject_glyph_get_type(), cast[ptr Glyph00](self.impl))
    self.impl = nil

when defined(gcDestructors):
  proc `=destroy`*(self: var typeof(Glyph()[])) =
    when defined(gintroDebug):
      echo "destroy ", $typeof(self), ' ', cast[int](unsafeaddr self)
    if not self.ignoreFinalizer and self.impl != nil:
      boxedFree(cairo_gobject_glyph_get_type(), cast[ptr Glyph00](self.impl))
      self.impl = nil

proc newWithFinalizer*(x: var Glyph) =
  when defined(gcDestructors):
    new(x)
  else:
    new(x, gBoxedFreeCairoGlyph)
""",
     "# patched: Glyph00/Glyph come from cairoimpl.nim, included below\n"),
    ("cairo.nim",
     """type
  TextCluster00* {.pure.} = object
  TextCluster* = ref object of RootRef
    impl*: ptr TextCluster00
    ignoreFinalizer*: bool

proc cairo_gobject_text_cluster_get_type*(): GType {.importc, libprag.}

proc gBoxedFreeCairoTextCluster*(self: TextCluster) =
  if not self.ignoreFinalizer and  self.impl != nil:
    boxedFree(cairo_gobject_text_cluster_get_type(), cast[ptr TextCluster00](self.impl))
    self.impl = nil

when defined(gcDestructors):
  proc `=destroy`*(self: var typeof(TextCluster()[])) =
    when defined(gintroDebug):
      echo "destroy ", $typeof(self), ' ', cast[int](unsafeaddr self)
    if not self.ignoreFinalizer and self.impl != nil:
      boxedFree(cairo_gobject_text_cluster_get_type(), cast[ptr TextCluster00](self.impl))
      self.impl = nil

proc newWithFinalizer*(x: var TextCluster) =
  when defined(gcDestructors):
    new(x)
  else:
    new(x, gBoxedFreeCairoTextCluster)
""",
     "# patched: TextCluster00/TextCluster come from cairoimpl.nim, included below\n"),
]

# Applied to every .nim in the package: the generator emits a bare ".int" as an
# array length in a few array-to-seq calls.
GINTRO_REGEX_PATCHES = [
    (r"ArrayToSeq\((\w+), \.int\)", r"ArrayToSeq(\1, 0)"),
]

BINARIES = ["nim", "nimble", "wayland-scanner", "gcc", "pkg-config"]
PKGCONFIG = ["gtk4", "wayland-client", "cairo"]


def run(cmd, **kw):
    print("  $", " ".join(cmd))
    return subprocess.run(cmd, **kw)


def package_manager():
    for pm in ("dnf", "apt"):
        if shutil.which(pm):
            return pm
    return None


def install_system_packages():
    pm = package_manager()
    if pm is None:
        sys.exit("no dnf or apt found - install the build deps by hand, see README")
    cmd = [pm, "install", "-y"] + PACKAGES[pm]
    if os.geteuid() != 0:
        cmd = ["sudo"] + cmd
    if run(cmd).returncode != 0:
        sys.exit("system package install failed")


def gintro_dir():
    hits = sorted(glob.glob(os.path.expanduser("~/.nimble/pkgs2/gintro-*/gintro")))
    return hits[-1] if hits else None


def install_nimble_deps():
    if gintro_dir():
        print("  gintro already installed")
        return
    # gintro's own package sets skipDirs=["tests"], but its install hook reads
    # tests/gen.nim - so installing from the registry fails. Clone and install
    # from the working tree instead.
    tmp = "/tmp/gintro-src"
    shutil.rmtree(tmp, ignore_errors=True)
    if run(["git", "clone", "--depth", "1",
            "https://github.com/KellerKev/gintro", tmp]).returncode != 0:
        sys.exit("could not clone gintro")
    if run(["nimble", "install", "-y"], cwd=tmp).returncode != 0:
        sys.exit("gintro install failed")


def dedupe_enum(path, enum_name):
    """Nim compares identifiers ignoring case and underscores, so gintro's
    generated GdkMemoryFormat has seven pairs that collide (G8_B8R8_420 vs
    G8_B8_R8_420 and friends). Suffix the later member of each pair."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    try:
        start = next(i for i, l in enumerate(lines) if enum_name + "* {" in l)
    except StopIteration:
        return False
    seen, changed = {}, False
    for i in range(start + 1, len(lines)):
        m = re.match(r"(\s{4})(\w+)( = \d+)$", lines[i])
        if not m:
            break
        indent, name, tail = m.groups()
        norm = name[0] + name[1:].replace("_", "").lower()
        if norm in seen:
            lines[i] = f"{indent}{name}p{tail}  # patched: collided with {seen[norm]}"
            changed = True
        else:
            seen[norm] = name
    if changed:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines))
    return changed


def patch_gintro():
    d = gintro_dir()
    if d is None:
        sys.exit("gintro is not installed; run without --patch first")
    applied = skipped = 0
    for path in glob.glob(os.path.join(d, "*.nim")):
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        new = text
        for pattern, repl in GINTRO_REGEX_PATCHES:
            new = re.sub(pattern, repl, new)
        if new != text:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(new)
            applied += 1
    if dedupe_enum(os.path.join(d, "gdk4.nim"), "MemoryFormat"):
        applied += 1
    for name, broken, fixed in GINTRO_PATCHES:
        path = os.path.join(d, name)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        if broken not in text:
            skipped += 1
            continue
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text.replace(broken, fixed))
        applied += 1
    print(f"  gintro patches: {applied} applied, {skipped} already in place")


def check():
    ok = True
    for b in BINARIES:
        found = shutil.which(b)
        print(f"  {'ok ' if found else 'MISSING'} {b}")
        ok &= bool(found)
    for p in PKGCONFIG:
        r = subprocess.run(["pkg-config", "--modversion", p],
                           capture_output=True, text=True)
        good = r.returncode == 0
        print(f"  {'ok ' if good else 'MISSING'} {p} {r.stdout.strip()}")
        ok &= good
    d = gintro_dir()
    print(f"  {'ok ' if d else 'MISSING'} gintro {d or ''}")
    ok &= bool(d)
    if d:
        for path in glob.glob(os.path.join(d, "*.nim")):
            with open(path, encoding="utf-8") as fh:
                if any(re.search(pat, fh.read()) for pat, _ in GINTRO_REGEX_PATCHES):
                    print(f"  MISSING gintro patch in {os.path.basename(path)} (run --patch)")
                    ok = False
        for name, broken, _ in GINTRO_PATCHES:
            with open(os.path.join(d, name), encoding="utf-8") as fh:
                if broken in fh.read():
                    print(f"  MISSING gintro patch in {name} (run --patch)")
                    ok = False
    if not shutil.which("wl-copy"):
        print("  note: wl-clipboard absent - clipboard contents will not "
              "outlive the app")
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="report only")
    ap.add_argument("--patch", action="store_true", help="only patch gintro")
    args = ap.parse_args()

    if args.check:
        sys.exit(0 if check() else 1)
    if args.patch:
        patch_gintro()
        return

    print("system packages:")
    install_system_packages()
    print("nimble packages:")
    install_nimble_deps()
    print("patches:")
    patch_gintro()
    print("check:")
    sys.exit(0 if check() else 1)


if __name__ == "__main__":
    main()
