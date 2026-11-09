PREFIX ?= $(HOME)/.local
BIN    := $(DESTDIR)$(PREFIX)/bin
SHARE  := $(DESTDIR)$(PREFIX)/share/herd
VERSION := $(shell head -n1 VERSION)
GITHUB_REMOTE ?= github
HERDR  ?= herdr
# The Herdr app's home, and where `make desktop-install` puts the herd mod.
HERDR_APP_HOME ?= $(HOME)/.config/herdr-app
DESKTOP_MOD := $(HERDR_APP_HOME)/mods/herd

.PHONY: test install link uninstall plugin-link plugin-unlink desktop-install desktop-uninstall dist sync-github clean

test:
	bash -n bin/herd
	bash -n plugin/herd-plugin.sh
	bash -n plugin/dashboard.sh
	python3 -m py_compile serve/herd_serve.py
	shellcheck -S warning bin/herd plugin/herd-plugin.sh plugin/dashboard.sh tests/plan.sh tests/worktree.sh tests/pr.sh tests/args.sh tests/version.sh tests/plugin.sh tests/status.sh tests/serve.sh tests/desktop.sh packaging/release-assets.sh
	bash tests/plan.sh
	bash tests/worktree.sh
	bash tests/pr.sh
	bash tests/args.sh
	bash tests/version.sh
	bash tests/plugin.sh packaging/release-assets.sh
	bash tests/status.sh
	bash tests/serve.sh
	bash tests/desktop.sh

# Copy into $(PREFIX) (default ~/.local). PKGBUILD uses this with PREFIX=/usr. The herdr plugin
# lands in share/herd too, so `herdr plugin link $(PREFIX)/share/herd` registers it, and so do
# herd serve's server (serve/) and page (web/).
install:
	install -Dm755 bin/herd $(BIN)/herd
	install -Dm644 VERSION $(SHARE)/VERSION
	install -Dm644 examples/Tasks.example.herd $(SHARE)/Tasks.example.herd
	install -Dm644 examples/plan.example.md $(SHARE)/plan.example.md
	mkdir -p $(SHARE)/personas
	install -m644 personas/*.md $(SHARE)/personas/
	mkdir -p $(SHARE)/serve $(SHARE)/web/icons
	install -m644 serve/*.py $(SHARE)/serve/
	install -m644 web/*.* $(SHARE)/web/
	install -m644 web/icons/*.* $(SHARE)/web/icons/
	install -Dm644 herdr-plugin.toml $(SHARE)/herdr-plugin.toml
	install -Dm755 plugin/herd-plugin.sh $(SHARE)/plugin/herd-plugin.sh
	install -Dm644 plugin/dashboard.sh $(SHARE)/plugin/dashboard.sh

# Dev install: symlink, so edits in this checkout are live.
link:
	mkdir -p $(BIN)
	ln -sfn $(CURDIR)/bin/herd $(BIN)/herd

uninstall:
	rm -f $(BIN)/herd
	rm -rf $(SHARE)

# Register this checkout as herd's herdr plugin (edits are live, as with link), or unregister it.
plugin-link:
	$(HERDR) plugin link $(CURDIR)

plugin-unlink:
	$(HERDR) plugin unlink lordmuffin.herd

# Copy the herd mod into the Herdr app (mods are copied in, as the app's AGENTS.md says to), with
# this checkout's herd bundled in it, so the mod runs the herd it was built for. Then check it.
# Re-run after changing desktop/ or bin/herd; the app reloads the mod when its files change.
desktop-install:
	mkdir -p $(DESKTOP_MOD)/herd/bin $(DESKTOP_MOD)/herd/personas
	install -m644 desktop/mods/herd/mod.json desktop/mods/herd/*.js $(DESKTOP_MOD)/
	install -m755 bin/herd $(DESKTOP_MOD)/herd/bin/herd
	install -m644 VERSION $(DESKTOP_MOD)/herd/VERSION
	install -m644 personas/*.md $(DESKTOP_MOD)/herd/personas/
	herdr-app check $(DESKTOP_MOD)

desktop-uninstall:
	rm -rf $(DESKTOP_MOD)

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
