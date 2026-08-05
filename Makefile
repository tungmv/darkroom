PREFIX ?= /usr/local
BINDIR ?= $(DESTDIR)$(PREFIX)/bin

# Escalate only for the privileged copy into $(BINDIR).
# Run the build as your normal user: `make install` (no sudo prefix).
# If you do `sudo make install`, the build still runs as root again; avoid that.
SUDO ?= sudo

BUILD_DIR ?= .build/$(shell uname -m)-apple-macosx

build:
	swift build -c release

# Build as the invoking user, then copy into $(BINDIR) with sudo.
install: build
	$(SUDO) install -d "$(BINDIR)"
	$(SUDO) install "$(BUILD_DIR)/release/darkroom" "$(BINDIR)/darkroom"
	$(SUDO) install "$(BUILD_DIR)/release/darkroomd" "$(BINDIR)/darkroomd"

# Install only (assumes you already built): `make build && sudo make install-only`
install-only:
	install -d "$(BINDIR)"
	install "$(BUILD_DIR)/release/darkroom" "$(BINDIR)/darkroom"
	install "$(BUILD_DIR)/release/darkroomd" "$(BINDIR)/darkroomd"

uninstall:
	$(SUDO) rm -f "$(BINDIR)/darkroom" "$(BINDIR)/darkroomd"

clean:
	swift package clean
