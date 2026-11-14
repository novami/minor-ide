.PHONY: build test server bench bundle run clean l10n l10n-new l10n-check

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

# Translations: English is generated from L("…") in Sources/, Czech must always be complete.
L10N := cd server && go run ./cmd/l10n -sources ../Sources -resources ../Resources

l10n:
	$(L10N) sync

l10n-new:
	@test -n "$(LANG)" || { echo "usage: make l10n-new LANG=de" >&2; exit 2; }
	$(L10N) new $(LANG)

l10n-check:
	$(L10N) -require cs check

bench:
	swift build -c release $(SWIFT_BUILD)
	.build/release/MinorIDE --bench

bundle: server
	tools/bundle.sh

run: bundle
	open build/MinorIDE.app

clean:
	rm -rf .build build server/bin
