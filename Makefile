# Ursprung — developer shortcuts. Requires Xcode 26+ and XcodeGen (brew install xcodegen).

DERIVED_DATA ?= build/DerivedData
SCHEME = Ursprung
XCODEBUILD_BASE = xcodebuild -project Ursprung.xcodeproj -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS,arch=arm64'
XCODEBUILD = $(XCODEBUILD_BASE) -scheme $(SCHEME)

.PHONY: all project secrets librashader moltenvk build release dist test run smoke icon clean

all: build

secrets:
	@./Scripts/generate-secrets.sh .env Ursprung/Support/Secrets.generated.swift

librashader:
	@./Scripts/fetch-librashader.sh

moltenvk:
	@./Scripts/fetch-moltenvk.sh

project: secrets librashader moltenvk
	@xcodegen generate --quiet
	@echo "Generated Ursprung.xcodeproj — open it with: open Ursprung.xcodeproj"

build: project
	$(XCODEBUILD) -configuration Debug build -quiet

release: project
	$(XCODEBUILD) -configuration Release build -quiet
	@echo "App: $(DERIVED_DATA)/Build/Products/Release/Ursprung.app"

# Signed, notarized disk image for distribution; see Scripts/dist.sh.
dist:
	./Scripts/dist.sh

test: project
	$(XCODEBUILD) test -quiet

run: build
	open "$(DERIVED_DATA)/Build/Products/Debug/Ursprung.app"

# Headless core test: make smoke CORE=path/to/core.dylib ROM=path/to/game [FRAMES=600] [RENDERER=vulkan|opengl]
# [OPTIONS="key=value;key=value"] [ALLOW_FALLBACK=1]. RENDERER=vulkan fails when the game does not render with Vulkan.
smoke: project
	$(XCODEBUILD_BASE) -scheme ursprung-smoke -configuration Debug build -quiet
	URSMOKE_RENDERER=$(RENDERER) $(if $(OPTIONS),URSMOKE_OPTIONS="$(OPTIONS)") $(if $(ALLOW_FALLBACK),URSMOKE_ALLOW_FALLBACK=1) "$(DERIVED_DATA)/Build/Products/Debug/ursprung-smoke" "$(CORE)" "$(ROM)" $(or $(FRAMES),600) smoke.png

icon:
	swift Scripts/generate-icon.swift

clean:
	rm -rf build Ursprung.xcodeproj
