# Contributing to Ursprung

Thanks for helping! Ursprung aims to be *the* calm, native way to play retro
games on a Mac. Bug reports, new systems, UI polish, translations and docs are
all welcome.

## Ground rules

- **Never commit games, BIOS files, credentials or `.env`.** `.gitignore`
  protects the usual paths — double-check `git status` before pushing anyway.
- Be kind. The [Code of Conduct](CODE_OF_CONDUCT.md) applies everywhere.
- By contributing you agree that your contribution is licensed under
  **GPL-3.0-or-later**. Add this header to new source files:

  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later
  ```

## Setting up

```sh
brew install xcodegen
cp .env.example .env   # optional, only needed for metadata scraping
make project
open Ursprung.xcodeproj
```

The Xcode project is generated from [`project.yml`](project.yml) and is not
committed. Add new files to the folders under `Ursprung/`; run `make project`
again afterwards (XcodeGen picks them up automatically).

Useful commands:

| Command | What it does |
|---|---|
| `make run` | Build and launch the debug app |
| `make test` | Run the unit tests (Swift Testing) |
| `make smoke CORE=… ROM=…` | Run a core headlessly and write the last frame to `smoke.png` |
| `make icon` | Re-render the app icon |

## Code style

- Swift 6 with **MainActor default isolation** and approachable concurrency.
  Pure data types and background helpers are marked `nonisolated`; heavy work
  runs in `@concurrent` functions.
- Follow the existing structure (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).
  Keep views small, put logic into the observable services.
- Keep comments short and about *why*, not *what*.
- Prefer system frameworks over dependencies. The project currently has none,
  and new ones need a very good reason.
- All user-facing strings must be localizable (`Text("…")`, `String(localized:)`).
  If you can, add the German translation to `Ursprung/Resources/Localizable.xcstrings`.

The libretro host (`Ursprung/Bridge/`) is Objective-C/C on purpose: libretro
callbacks are C function pointers (one of them variadic), and the hot paths
(video conversion, audio ring buffer, input state) should not touch Swift
runtime machinery.

## Debugging aids

Debug builds understand a few environment variables (set them in the Xcode
scheme or on the command line):

| Variable | Effect |
|---|---|
| `URSPRUNG_CORE_LOG=1` | Mirror core log output to stderr |
| `URSPRUNG_AUTOPLAY=<title>` | Start the first matching game on launch |
| `URSPRUNG_SELECT=<title>` | Select the first matching game on launch |
| `URSPRUNG_SNAPSHOT_DIR=<dir>` | Write window snapshots, the current emulator frame and session state to `<dir>` |
| `URSPRUNG_DEBUG_STATES=1` | After launch: save state, load it again, quit (exercises the save paths) |

The headless smoke tool additionally supports `URSMOKE_REALTIME=1` (pace frames
in real time, needed for cores such as PPSSPP that boot asynchronously) and
`URSMOKE_OPTIONS="key=value;key=value"` (core option overrides).

## Adding a system

1. Find a libretro core that is built for `apple/osx/arm64` on the
   [buildbot](https://buildbot.libretro.com/nightly/apple/osx/arm64/latest/).
2. Add a `CoreDefinition` to `Cores` and a `GameSystem` entry to
   `SystemCatalog.all` in `Ursprung/Systems/SystemCatalog.swift`: extensions,
   folder aliases, the ScreenScraper system ID
   ([`systemesListe`](https://www.screenscraper.fr/webapi2.php)), BIOS files with
   MD5 checksums, and any frontend defaults for core options.
3. Verify the core with `make smoke` and in the app, then update
   [docs/SUPPORTED_SYSTEMS.md](docs/SUPPORTED_SYSTEMS.md) and, if needed,
   [docs/BIOS.md](docs/BIOS.md).

## Pull requests

- One topic per PR, with a short description of what and why.
- `make test` must pass. Mention which systems/cores you tried.
- UI changes: include a screenshot or short recording.
- Keep commits focused; the history should read like a changelog.

## Translations

The UI is English with a German localization. To add a language, open
`Localizable.xcstrings` in Xcode, add the language and translate — Xcode shows
which strings are still missing.
