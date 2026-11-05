PREFIX ?= $(HOME)/.local
BIN    := $(DESTDIR)$(PREFIX)/bin
SHARE  := $(DESTDIR)$(PREFIX)/share/herd

.PHONY: test install link uninstall

test:
	bash -n bin/herd
	shellcheck -S warning bin/herd tests/plan.sh
	bash tests/plan.sh

# Copy into $(PREFIX) (default ~/.local). PKGBUILD uses this with PREFIX=/usr.
install:
	install -Dm755 bin/herd $(BIN)/herd
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
