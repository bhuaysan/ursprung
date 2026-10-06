# Ursprung — notes for AI coding agents

Native macOS (26+, Apple Silicon) retro game library/emulator frontend.
SwiftUI + SwiftData UI, Objective-C/C libretro host, Metal presentation.
GPL-3.0-or-later. See `docs/ARCHITECTURE.md` for the full picture.

## Commands

- `make project` — regenerate `Ursprung.xcodeproj` from `project.yml` (never edit the xcodeproj; it is git-ignored). Run after adding/removing files.
- `make build` / `make test` / `make run`
- `make smoke CORE=<dylib> ROM=<file>` — headless core check, writes `smoke.png`.
- Tests use Swift Testing (`import Testing`), in `UrsprungTests/`.

## Hard rules

- `ROMS/`, `BIOS/`, `.env`, `Secrets.generated.swift`, `Config/Signing.local.xcconfig` must never be committed or pushed. Check `git status` before every commit.
- ScreenScraper media URLs embed API credentials: never log, print or persist them.
- New files start with `// SPDX-License-Identifier: GPL-3.0-or-later`.
- No third-party dependencies without discussion. Agreed so far: rcheevos in `ThirdParty/rcheevos` (MIT, vendored) and librashader in `ThirdParty/librashader` (MPL-2.0/GPL-3.0, prebuilt dylib fetched by `Scripts/fetch-librashader.sh`); see their READMEs for updating.
- User-facing strings must be localizable; add German to `Ursprung/Resources/Localizable.xcstrings`.

## Conventions

- Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency. Mark data types / helpers used off the main actor `nonisolated`; background work goes into `@concurrent` functions.
- Services are `@Observable` classes injected via `.environment(...)` in `UrsprungApp`.
- Only one core can run at a time (libretro callbacks are global C functions). All `retro_*` calls happen on the `UREmulationRunner` thread; use `performOnEmulationThread(_:)` from Swift.
- Systems, cores, BIOS files and core option defaults are data in `Ursprung/Systems/SystemCatalog.swift`.
- Shaders live in `Ursprung/Emulation/ShaderSource.swift` and are compiled at runtime (no Metal toolchain needed).

## Debugging without UI access

Debug builds read `URSPRUNG_*` environment variables (snapshots, autoplay, core logs, state/play exercises): see the `debug-without-ui` skill in `.claude/skills/`.

## Known issues

- GLideN64 frame buffer emulation renders black on Apple OpenGL → N64 defaults to angrylion.
- Vulkan cores/renderers unsupported.
