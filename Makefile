PREFIX ?= /usr/local
BINDIR ?= $(DESTDIR)$(PREFIX)/bin

BUILD_DIR = .build/arm64-apple-macosx

build:
	swift build -c release

install: build
	install -d "$(BINDIR)"
	install "$(BUILD_DIR)/release/darkroom" "$(BINDIR)/darkroom"
	install "$(BUILD_DIR)/release/darkroomd" "$(BINDIR)/darkroomd"

uninstall:
	rm -f "$(BINDIR)/darkroom" "$(BINDIR)/darkroomd"

clean:
	swift package clean
