#!/usr/bin/env bash
# Builds the release assets into dist/: the source tarball, SHA256SUMS, a PKGBUILD with the
# checksum filled in, and (when docker is available) the Arch package. CI runs this on both
# Forgejo and GitHub; it also works locally.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(head -n1 VERSION)
make dist

sum=$(cut -d' ' -f1 dist/SHA256SUMS)
sed -e "s/^pkgver=.*/pkgver=$version/" \
    -e "s/^sha256sums=.*/sha256sums=('$sum')/" \
    packaging/arch/herd/PKGBUILD >dist/PKGBUILD

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "release-assets: no usable docker, skipping the Arch package" >&2
  exit 0
fi

# makepkg refuses to run as root, so build as an unprivileged user in an Arch container,
# from the local tarball (byte-identical to the release asset).
rm -rf dist/arch && mkdir -p dist/arch
cp dist/herd-"$version".tar.gz LICENSE dist/arch/
# shellcheck disable=SC2016 # $pkgver is for makepkg, not this shell
sed -e 's|^source=.*|source=("herd-$pkgver.tar.gz")|' dist/PKGBUILD >dist/arch/PKGBUILD
docker run --rm -v "$PWD/dist/arch:/build" archlinux:base-devel bash -c '
  set -e
  pacman -Syu --noconfirm --needed shellcheck jq git util-linux
  useradd -m builder
  chown -R builder /build
  su builder -c "cd /build && makepkg -f --noconfirm"
'
cp dist/arch/*.pkg.tar.zst dist/
(cd dist && sha256sum herd-*.pkg.tar.zst >>SHA256SUMS)
