# Ursprung — notes for AI coding agents

Native macOS (26+, Apple Silicon) retro game library/emulator frontend.
SwiftUI + SwiftData UI, Objective-C/C libretro host, Metal presentation.
GPL-3.0-or-later. See `docs/ARCHITECTURE.md` for the full picture.

## Commands

- `make project` — regenerate `Ursprung.xcodeproj` from `project.yml` (never edit the xcodeproj; it is git-ignored). Run after adding/removing files.
- `make build` / `make test` / `make run`
- `make smoke CORE=<dylib> ROM=<file>` — headless core check, writes `smoke.png`.
- Tests use Swift Testing (`import Testing`), in `UrsprungTests/`.
- `Tools/ursprung-test-core` is a tiny libretro core copied into the test bundle; `EmulationRunnerTests` drive it frame by frame via `UREmulationRunner+Testing.h`.

## Hard rules

- `ROMS/`, `BIOS/`, `.env`, `Secrets.generated.swift`, `Config/Signing.local.xcconfig` must never be committed or pushed. Check `git status` before every commit.
- ScreenScraper media URLs embed API credentials: never log, print or persist them.
- New files start with `// SPDX-License-Identifier: GPL-3.0-or-later`.
- No third-party dependencies without discussion. Agreed so far: rcheevos in `ThirdParty/rcheevos` (MIT, vendored) and librashader in `ThirdParty/librashader` (MPL-2.0/GPL-3.0, prebuilt dylib fetched by `Scripts/fetch-librashader.sh`); MoltenVK in `ThirdParty/moltenvk` (Apache-2.0, prebuilt dylib and Vulkan headers fetched by `Scripts/fetch-moltenvk.sh`, linked directly, no Vulkan loader); see their READMEs for updating. ARMSX2 (GPL-3.0) runs PlayStation 2 games as a standalone emulator: downloaded at runtime from its GitHub releases (pinned in `SystemCatalog`), never bundled or vendored; see `docs/STANDALONE_PLAN.md`.
- User-facing strings must be localizable; add German to `Ursprung/Resources/Localizable.xcstrings`.

## Conventions

- Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency. Mark data types / helpers used off the main actor `nonisolated`; background work goes into `@concurrent` functions.
- Services are `@Observable` classes injected via `.environment(...)` in `UrsprungApp`.
- Only one core can run at a time (libretro callbacks are global C functions). All `retro_*` calls happen on the `UREmulationRunner` thread; use `performOnEmulationThread(_:)` from Swift.
- Systems, cores, BIOS files and core option defaults are data in `Ursprung/Systems/SystemCatalog.swift`.
- Shaders live in `Ursprung/Emulation/ShaderSource.swift` and are compiled at runtime (no Metal toolchain needed).
- Hardware rendering: `URGLContext` (OpenGL 4.1) or `URVulkanContext` (MoltenVK); both read frames back into the CPU frame buffer. Which API a core is asked for is `CoreDefinition.renderer` plus the user's choice (Settings › Cores); renderer-specific option defaults go in `vulkanOptionDefaults`. See `docs/VULKAN_PLAN.md`. Check a core with `make smoke … RENDERER=vulkan` (`URSPRUNG_VULKAN_LOG=1` for the context's log).
- Standalone emulators (`CoreBackend.standalone`, today only ARMSX2 for PS2) run as their own process: `EmulatorManager` installs, `ARMSX2Launch`/`PCSX2Config` write `PCSX2.ini` before every launch, `ExternalSession` quits with ONE SIGTERM (a second one makes ARMSX2 exit without saving), `PINEClient` saves/loads states. Never let ARMSX2 show a dialog: Qt message boxes crash it on macOS 27, so add a pre-flight check instead.

## Debugging without UI access

Debug builds read `URSPRUNG_*` environment variables (snapshots, autoplay, core logs, state/play exercises): see the `debug-without-ui` skill in `.claude/skills/`.

## Known issues

- GLideN64 frame buffer emulation renders black on Apple OpenGL → Mupen64Plus-Next uses paraLLEl-RDP (Vulkan), angrylion without Vulkan; ParaLLEl N64's macOS build has no paraLLEl-RDP.
- Dolphin presents nothing without a `VkSurfaceKHR`: `URVulkanContext` gives every core a surface of an unseen `CAMetalLayer`; keep it. Dolphin also `dlopen`s `libvulkan.1.dylib` at boot (else a “Failed to load Vulkan library” toast): keep the symlink to MoltenVK (build phase in `project.yml`, `Scripts/fetch-moltenvk.sh`).
- ARMSX2: every error dialog crashes it on macOS 27 (`NSAlert` icon rasterising in CoreUI); quitting while a memory card is being written may hit that too. Only macOS nightlies exist, so the pin in `SystemCatalog` moves after the manual checks in `docs/STANDALONE_PLAN.md`.
