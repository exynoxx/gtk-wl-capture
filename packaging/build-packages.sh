#!/usr/bin/env bash
# Build an rpm and a deb from the same staged tree into dist/.
#
#   packaging/build-packages.sh            release 1
#   RELEASE=3 packaging/build-packages.sh  release 3
#
# rpmbuild is needed for the rpm. The deb is assembled with ar and tar, so no
# dpkg tooling has to be installed.
set -euo pipefail

cd "$(dirname "$0")/.."
name=gtk-wl-capture
version=$(sed -n 's/^version *= *"\(.*\)"/\1/p' gtk_wl_capture.nimble)
release=${RELEASE:-1}
arch=$(uname -m)
debarch=$([ "$arch" = x86_64 ] && echo amd64 || echo "$arch")
dist=$PWD/dist
root=$dist/root

summary="GTK4 screenshot tool for Wayland"
descr="Full screen or rubber-band selection screenshots on any Wayland desktop,
via zwlr_screencopy with an xdg-desktop-portal fallback."

rm -rf "$dist"
mkdir -p "$dist"

nimble build -d:release
DESTDIR="$root" PREFIX=/usr nimble stage

# --- rpm -------------------------------------------------------------------
if command -v rpmbuild >/dev/null; then
  mkdir -p "$dist/rpmbuild/SPECS"
  cat > "$dist/rpmbuild/SPECS/$name.spec" <<SPEC
%global debug_package %{nil}
Name:           $name
Version:        $version
Release:        $release%{?dist}
Summary:        $summary
License:        MIT
BuildArch:      $arch
Requires:       gtk4
Requires:       libwayland-client
Recommends:     wl-clipboard

%description
$descr

%install
mkdir -p %{buildroot}
cp -a $root/. %{buildroot}/

%files
%license %{_datadir}/doc/$name/LICENSE
%{_bindir}/$name
%{_datadir}/applications/*.desktop
%{_datadir}/icons/hicolor/scalable/apps/*.svg
%{_datadir}/$name/
%{_datadir}/doc/$name/README.md
SPEC
  rpmbuild -bb --quiet --define "_topdir $dist/rpmbuild" \
           "$dist/rpmbuild/SPECS/$name.spec"
  mv "$dist/rpmbuild/RPMS/$arch"/*.rpm "$dist/"
else
  echo "rpmbuild not found - skipping the rpm (dnf install rpm-build)" >&2
fi

# --- deb -------------------------------------------------------------------
deb=$dist/deb
mkdir -p "$deb/DEBIAN"
cp -a "$root/." "$deb/"
cat > "$deb/DEBIAN/control" <<CONTROL
Package: $name
Version: $version-$release
Section: graphics
Priority: optional
Architecture: $debarch
Depends: libgtk-4-1, libwayland-client0, libglib2.0-0
Recommends: wl-clipboard
Installed-Size: $(du -ks "$root" | cut -f1)
Maintainer: gtk-wl-capture contributors <nobody@localhost>
Description: $summary
$(echo "$descr" | sed 's/^/ /')
CONTROL
(cd "$deb" && find . -path ./DEBIAN -prune -o -type f -print0 |
  xargs -0 md5sum | sed 's| \./| |' > DEBIAN/md5sums)
tar czf "$dist/control.tar.gz" -C "$deb/DEBIAN" .
tar czf "$dist/data.tar.gz" -C "$deb" --exclude=./DEBIAN .
echo 2.0 > "$dist/debian-binary"
(cd "$dist" && ar rc "${name}_${version}-${release}_${debarch}.deb" \
   debian-binary control.tar.gz data.tar.gz)
rm -f "$dist/debian-binary" "$dist/control.tar.gz" "$dist/data.tar.gz"

rm -rf "$dist/rpmbuild" "$deb" "$root"
ls -1 "$dist"
