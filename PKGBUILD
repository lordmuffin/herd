# Maintainer: Andrew Jackson <dorkmeisterx69@gmail.com>
pkgname=herd-git
pkgver=r1.0000000
pkgrel=1
pkgdesc="Fan out coding agents into git worktrees, one Herdr workspace each"
arch=('any')
url="https://github.com/lordmuffin/herd"
license=('MIT')
depends=('bash' 'git' 'jq' 'curl' 'util-linux')
makedepends=('git')
checkdepends=('shellcheck' 'python')
optdepends=('github-cli: PR merge check in herd done for github.com repos'
            'fzf: pickers in the herdr plugin'
            'forgejo-cli: Forgejo login used by herd done to check PR merge state'
            'python: herd serve, the web page and its API')
provides=('herd')
conflicts=('herd')
# Public GitHub mirror; the canonical (private) repo is on Forgejo. herdr itself is not packaged;
# install it from https://herdr.dev (it lands in ~/.local/bin). The herd herdr plugin is installed
# to /usr/share/herd; register it with: herdr plugin link /usr/share/herd
source=("herd::git+https://github.com/lordmuffin/herd.git")
sha256sums=('SKIP')

pkgver() {
  cd herd
  printf "r%s.%s" "$(git rev-list --count HEAD)" "$(git rev-parse --short=7 HEAD)"
}

check() {
  cd herd
  make test
}

package() {
  cd herd
  make install DESTDIR="$pkgdir" PREFIX=/usr
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
