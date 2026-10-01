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

- `ROMS/`, `BIOS/`, `.env`, `Secrets.generated.swift` must never be committed or pushed. Check `git status` before every commit.
- ScreenScraper media URLs embed API credentials: never log, print or persist them.
- New files start with `// SPDX-License-Identifier: GPL-3.0-or-later`.
- No third-party dependencies without discussion.
- User-facing strings must be localizable; add German to `Ursprung/Resources/Localizable.xcstrings`.

## Conventions

- Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency. Mark data types / helpers used off the main actor `nonisolated`; background work goes into `@concurrent` functions.
- Services are `@Observable` classes injected via `.environment(...)` in `UrsprungApp`.
- Only one core can run at a time (libretro callbacks are global C functions). All `retro_*` calls happen on the `UREmulationRunner` thread; use `performOnEmulationThread(_:)` from Swift.
- Systems, cores, BIOS files and core option defaults are data in `Ursprung/Systems/SystemCatalog.swift`.
- Shaders live in `Ursprung/Emulation/ShaderSource.swift` and are compiled at runtime (no Metal toolchain needed).

## Debugging without UI access

Debug builds: `URSPRUNG_SNAPSHOT_DIR=<dir>` writes window snapshots plus `frame.png`/`session.txt` of the running game; `URSPRUNG_AUTOPLAY=<title>` starts a game, `URSPRUNG_SELECT=<title>` selects one, `URSPRUNG_SYSTEM=<id>` shows one system, `URSPRUNG_METADATA_ERROR=<text>` shows the activity footer's error row (`quota` for the real quota copy), `URSPRUNG_CORE_LOG=1` mirrors core logs to stderr, `URSPRUNG_DEBUG_STATES=1` exercises save/load/quit. Liquid Glass and Metal layers do not appear in window snapshots.

## Known issues

- GLideN64 frame buffer emulation renders black on Apple OpenGL → N64 defaults to angrylion.
- Vulkan cores/renderers unsupported.
