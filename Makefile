PREFIX ?= $(HOME)/.local
BIN    := $(DESTDIR)$(PREFIX)/bin
SHARE  := $(DESTDIR)$(PREFIX)/share/herd
VERSION := $(shell head -n1 VERSION)
GITHUB_REMOTE ?= github

.PHONY: test install link uninstall dist sync-github clean

test:
	bash -n bin/herd
	shellcheck -S warning bin/herd tests/plan.sh tests/worktree.sh tests/pr.sh tests/args.sh tests/version.sh
	bash tests/plan.sh
	bash tests/worktree.sh
	bash tests/pr.sh
	bash tests/args.sh
	bash tests/version.sh

# Copy into $(PREFIX) (default ~/.local). PKGBUILD uses this with PREFIX=/usr.
install:
	install -Dm755 bin/herd $(BIN)/herd
	install -Dm644 VERSION $(SHARE)/VERSION
	install -Dm644 examples/Tasks.example.herd $(SHARE)/Tasks.example.herd
	install -Dm644 examples/plan.example.md $(SHARE)/plan.example.md
	mkdir -p $(SHARE)/personas
	install -m644 personas/*.md $(SHARE)/personas/

# Dev install: symlink, so edits in this checkout are live.
link:
	mkdir -p $(BIN)
	ln -sfn $(CURDIR)/bin/herd $(BIN)/herd

uninstall:
	rm -f $(BIN)/herd
	rm -rf $(SHARE)

# Source tarball of HEAD plus SHA256SUMS in dist/ (what the release workflow publishes).
dist:
	mkdir -p dist
	git archive --format=tar.gz --prefix=herd-$(VERSION)/ -o dist/herd-$(VERSION).tar.gz HEAD
	cd dist && sha256sum herd-$(VERSION).tar.gz > SHA256SUMS

# Push main and all tags to the $(GITHUB_REMOTE) remote (add it once with
# `git remote add github git@github.com:OWNER/herd.git`). Forgejo's push mirror does this
# automatically; this is the manual fallback.
sync-github:
	@git remote get-url $(GITHUB_REMOTE) >/dev/null 2>&1 || { echo "no '$(GITHUB_REMOTE)' remote; see README (Publishing)" >&2; exit 1; }
	git push $(GITHUB_REMOTE) main
	git push $(GITHUB_REMOTE) --tags

clean:
	rm -rf dist
