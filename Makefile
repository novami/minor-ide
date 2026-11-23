.PHONY: build test server bench bench-startup bundle run clean l10n l10n-check

# SwiftPM's default build system cannot load the Swift Testing macros with Command Line Tools
# only (no Xcode). The native build system plus explicit paths works with both setups.
SWIFT_BUILD := --build-system native
CLT := /Library/Developer/CommandLineTools
ifneq ($(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),)
TEST_FLAGS := -Xswiftc -F -Xswiftc $(CLT)/Library/Developer/Frameworks \
	-Xlinker -F -Xlinker $(CLT)/Library/Developer/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT)/Library/Developer/Frameworks \
	-Xswiftc -plugin-path -Xswiftc $(CLT)/usr/lib/swift/host/plugins/testing
endif

build:
	swift build $(SWIFT_BUILD)

server:
	cd server && go build -o bin/minoride-server ./cmd/minoride-server

test: server l10n-check
	cd server && go vet ./... && go test ./...
	swift test $(SWIFT_BUILD) $(TEST_FLAGS)

# Translations (docs/LOCALIZATION.md): l10n regenerates the Strings accessors from en-US.json,
# l10n-check validates all language files; Czech must always be complete.
L10N := swift run -q $(SWIFT_BUILD) L10nTool

l10n:
	$(L10N) generate

l10n-check:
	$(L10N) validate --require cs-CZ

bench:
	swift build -c release $(SWIFT_BUILD)
	.build/release/MinorIDE --bench

# First run after purging the file cache (needs passwordless sudo, else it is only the first run), then 5 warm runs.
bench-startup: bundle
	@sudo -n purge 2>/dev/null && echo "# cold (file cache purged)" || echo "# first run (file cache not purged)"
	@build/MinorIDE.app/Contents/MacOS/MinorIDE --bench-startup
	@for i in 1 2 3 4 5; do echo "# warm $$i"; MINORIDE_IDLE_SECONDS=0 build/MinorIDE.app/Contents/MacOS/MinorIDE --bench-startup; done

bundle: server
	tools/bundle.sh

run: bundle
	open build/MinorIDE.app

icon:
	swift tools/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

clean:
	rm -rf .build build server/bin
