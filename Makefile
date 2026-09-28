# Ursprung — developer shortcuts. Requires Xcode 26+ and XcodeGen (brew install xcodegen).

DERIVED_DATA ?= build/DerivedData
SCHEME = Ursprung
XCODEBUILD_BASE = xcodebuild -project Ursprung.xcodeproj -derivedDataPath $(DERIVED_DATA)
XCODEBUILD = $(XCODEBUILD_BASE) -scheme $(SCHEME)

.PHONY: all project secrets build release test run smoke icon clean

all: build

secrets:
	@./Scripts/generate-secrets.sh .env Ursprung/Support/Secrets.generated.swift

project: secrets
	@xcodegen generate --quiet
	@echo "Generated Ursprung.xcodeproj — open it with: open Ursprung.xcodeproj"

build: project
	$(XCODEBUILD) -configuration Debug build -quiet

release: project
	$(XCODEBUILD) -configuration Release build -quiet
	@echo "App: $(DERIVED_DATA)/Build/Products/Release/Ursprung.app"

test: project
	$(XCODEBUILD) test -quiet

run: build
	open "$(DERIVED_DATA)/Build/Products/Debug/Ursprung.app"

# Headless core test: make smoke CORE=path/to/core.dylib ROM=path/to/game [FRAMES=600]
smoke: project
	$(XCODEBUILD_BASE) -scheme ursprung-smoke -configuration Debug build -quiet
	"$(DERIVED_DATA)/Build/Products/Debug/ursprung-smoke" "$(CORE)" "$(ROM)" $(or $(FRAMES),600) smoke.png

icon:
	swift Scripts/generate-icon.swift

clean:
	rm -rf build Ursprung.xcodeproj
