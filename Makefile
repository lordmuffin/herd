PREFIX ?= $(HOME)/.local
BIN    := $(DESTDIR)$(PREFIX)/bin
SHARE  := $(DESTDIR)$(PREFIX)/share/herd

.PHONY: test install link uninstall

test:
	bash -n bin/herd
	shellcheck -S warning bin/herd

# Copy into $(PREFIX) (default ~/.local). PKGBUILD uses this with PREFIX=/usr.
# No install -D: macOS's BSD install doesn't have it.
install:
	install -d $(BIN) $(SHARE)
	install -m755 bin/herd $(BIN)/herd
	install -m644 examples/tasks.example.txt $(SHARE)/tasks.example.txt

# Dev install: symlink, so edits in this checkout are live.
link:
	mkdir -p $(BIN)
	ln -sfn $(CURDIR)/bin/herd $(BIN)/herd

uninstall:
	rm -f $(BIN)/herd
	rm -rf $(SHARE)
