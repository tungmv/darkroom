PREFIX ?= /usr/local
BINDIR ?= $(DESTDIR)$(PREFIX)/bin

# Where Darkroom.app is assembled and installed. Keep the bundle inside the
# build directory so `make clean` removes it too.
APP_NAME  ?= Darkroom
APP_DIR   ?= .build/$(APP_NAME).app
APP_DEST  ?= $(HOME)/Applications

# Escalate only for the privileged copy into $(BINDIR).
# Run the build as your normal user: `make install` (no sudo prefix).
# If you do `sudo make install`, the build still runs as root again; avoid that.
SUDO ?= sudo

BUILD_DIR ?= .build/$(shell uname -m)-apple-macosx

.PHONY: build install install-only uninstall clean gui app run-app kill-daemon test \
	check check-gui

build:
	swift build -c release

test:
	swift test

# Full verification: unit tests plus a GUI→daemon round trip.
check: test check-gui

# Build the app and drive its real panel offscreen, asserting the slider
# actually reaches the daemon at each step.
check-gui: app
	@"$(APP_DIR)/Contents/MacOS/$(APP_NAME)" --self-test

# Build as the invoking user, then copy into $(BINDIR) with sudo.
install: build app
	@if [ -x "$(BINDIR)/darkroom" ]; then \
		"$(BINDIR)/darkroom" stop >/dev/null 2>&1 || true; \
	fi
	$(SUDO) install -d "$(BINDIR)"
	$(SUDO) install "$(BUILD_DIR)/release/darkroom" "$(BINDIR)/darkroom"
	$(SUDO) install "$(BUILD_DIR)/release/darkroomd" "$(BINDIR)/darkroomd"
	@install -d "$(APP_DEST)"
	@rm -rf "$(APP_DEST)/$(APP_NAME).app"
	@cp -R "$(APP_DIR)" "$(APP_DEST)/$(APP_NAME).app"
	@echo "Installed $(APP_DEST)/$(APP_NAME).app"

# Install only (assumes you already built): `make build && sudo make install-only`
install-only:
	@if [ -x "$(BINDIR)/darkroom" ]; then \
		"$(BINDIR)/darkroom" stop >/dev/null 2>&1 || true; \
	fi
	install -d "$(BINDIR)"
	install "$(BUILD_DIR)/release/darkroom" "$(BINDIR)/darkroom"
	install "$(BUILD_DIR)/release/darkroomd" "$(BINDIR)/darkroomd"

# Assemble Darkroom.app around the release GUI binary. darkroomd is bundled
# inside so the app works even when the CLI is not installed. Note: the app
# executable is `Darkroom` (capital D); the CLI cannot be bundled alongside it
# because APFS is case-insensitive and `darkroom` would collide.
app: build
	@rm -rf "$(APP_DIR)"
	@mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	@install "$(BUILD_DIR)/release/darkroom-gui" "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	@install "$(BUILD_DIR)/release/darkroomd" "$(APP_DIR)/Contents/MacOS/darkroomd"
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'  <key>CFBundleName</key><string>$(APP_NAME)</string>' \
		'  <key>CFBundleDisplayName</key><string>$(APP_NAME)</string>' \
		'  <key>CFBundleIdentifier</key><string>sh.darkroom.app</string>' \
		'  <key>CFBundleExecutable</key><string>$(APP_NAME)</string>' \
		'  <key>CFBundlePackageType</key><string>APPL</string>' \
		'  <key>CFBundleShortVersionString</key><string>1.1.0</string>' \
		'  <key>CFBundleVersion</key><string>2</string>' \
		'  <key>LSMinimumSystemVersion</key><string>13.0</string>' \
		'  <key>LSUIElement</key><true/>' \
		'  <key>NSHighResolutionCapable</key><true/>' \
		'</dict>' \
		'</plist>' > "$(APP_DIR)/Contents/Info.plist"
	@codesign --force --sign - "$(APP_DIR)" 2>/dev/null || \
		echo "note: ad-hoc codesign skipped"
	@echo "Built $(APP_DIR)"
	@echo "Run it with: make run-app"

# Launch the app bundle that `make app` produced.
run-app: app
	@open "$(APP_DIR)"

gui: run-app

kill-daemon:
	@if [ -x "$(BINDIR)/darkroom" ]; then \
		"$(BINDIR)/darkroom" stop >/dev/null 2>&1 || true; \
	else \
		"$(BUILD_DIR)/release/darkroom" stop >/dev/null 2>&1 || true; \
	fi

uninstall: kill-daemon
	$(SUDO) rm -f "$(BINDIR)/darkroom" "$(BINDIR)/darkroomd"
	rm -rf "$(APP_DEST)/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf "$(APP_DIR)"
