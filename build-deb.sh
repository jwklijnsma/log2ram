#!/usr/bin/env bash
# Build log2ram-guard_<version>_all.deb
#   ./build-deb.sh            version from the VERSION file
#   VERSION=1.0.0 ./build-deb.sh
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION 2>/dev/null)}"
VERSION="${VERSION:-0.0.0+$(git rev-parse --short HEAD 2>/dev/null || echo local)}"
PKG=log2ram-guard
OUT=dist
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
chmod 0755 "$ROOT"

install -Dm0755 log2ram-guard.sh             "$ROOT/usr/sbin/log2ram-guard"
install -Dm0644 debian/log2ram-guard.service "$ROOT/lib/systemd/system/log2ram-guard.service"
install -Dm0644 debian/log2ram-guard.timer   "$ROOT/lib/systemd/system/log2ram-guard.timer"
install -Dm0644 debian/log2ram-guard.default "$ROOT/etc/default/log2ram-guard"
install -Dm0644 README.md                    "$ROOT/usr/share/doc/$PKG/README.md"

mkdir -p "$ROOT/DEBIAN"
sed "s/@VERSION@/$VERSION/" debian/control.in > "$ROOT/DEBIAN/control"
echo "Installed-Size: $(du -sk --exclude=DEBIAN "$ROOT" | cut -f1)" >> "$ROOT/DEBIAN/control"
echo "/etc/default/log2ram-guard" > "$ROOT/DEBIAN/conffiles"
for s in postinst prerm postrm; do install -m0755 "debian/$s" "$ROOT/DEBIAN/$s"; done

mkdir -p "$OUT"
DEB="$OUT/${PKG}_${VERSION}_all.deb"
dpkg-deb --root-owner-group -Zxz --build "$ROOT" "$DEB" >/dev/null
echo "$DEB"
