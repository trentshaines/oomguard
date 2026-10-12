PREFIX ?= /usr/local

# Before Swift 6.4, Apple's Command Line Tools shipped Swift Testing off the default search path.
CLT := /Library/Developer/CommandLineTools
ifneq ($(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),)
ifeq ($(wildcard $(CLT)/usr/lib/swift/host/plugins/testing),)
TEST_FLAGS := -Xswiftc -F -Xswiftc $(CLT)/Library/Developer/Frameworks -Xlinker -rpath -Xlinker $(CLT)/Library/Developer/Frameworks -Xlinker -rpath -Xlinker $(CLT)/Library/Developer/usr/lib
endif
endif

AGENT := $(HOME)/Library/LaunchAgents/com.github.oomguard.plist

.PHONY: build test install install-service uninstall clean

build:
	swift build -c release --disable-sandbox

test:
	swift test $(TEST_FLAGS)

install: build
	install -d $(PREFIX)/bin
	install .build/release/oomguard $(PREFIX)/bin/oomguard

# Install the binary and run it at login as a launchd agent (no root needed with PREFIX=~/.local).
install-service: install
	sed 's|/usr/local/bin/oomguard|$(PREFIX)/bin/oomguard|' packaging/com.github.oomguard.plist > $(AGENT)
	launchctl bootout gui/$$(id -u)/com.github.oomguard 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(AGENT)

uninstall:
	launchctl bootout gui/$$(id -u)/com.github.oomguard 2>/dev/null || true
	rm -f $(AGENT) $(PREFIX)/bin/oomguard

clean:
	rm -rf .build
