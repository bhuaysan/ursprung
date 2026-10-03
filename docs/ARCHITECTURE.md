# Architecture

Ursprung is a SwiftUI app with a small Objective-C/C libretro host. There are
no third-party dependencies.

```
┌──────────────────────────── SwiftUI (MainActor) ────────────────────────────┐
│  LibraryView · SidebarView · GameGridView · GameInspector · SettingsView    │
│  PlayerView · PauseMenuView · GameMetalView (MTKView + keyboard/mouse)      │
└───────────────┬───────────────────────────────┬─────────────────────────────┘
                │                               │
   LibraryStore · MetadataService      EmulationSession · InputRouter
   CoreManager · BIOSManager            MetalRenderer (Metal, runtime shaders)
   SwiftData (Game)                             │
                │                               ▼
   LibraryScanner · ZipArchive     ┌──── Objective-C / C bridge ────┐
   ScreenScraperClient             │ UREmulationRunner  (thread,    │
                                   │   pacing, AVAudioEngine)       │
                                   │ URLibretroCore     (dlopen,    │
                                   │   callbacks, env, options,     │
                                   │   video, input, SRAM, states)  │
                                   │ URGLContext        (CGL + FBO) │
                                   │ URAudioRing        (SPSC ring) │
                                   └───────────────┬────────────────┘
                                                   ▼
                                   <core>_libretro.dylib (downloaded)
```

## Source layout

| Path | Purpose |
|---|---|
| `Ursprung/App` | App entry point, scenes, menu commands |
| `Ursprung/Systems` | `GameSystem`/`CoreDefinition` models and the `SystemCatalog` |
| `Ursprung/Library` | SwiftData `Game` model, folder scanner, `LibraryStore` |
| `Ursprung/Metadata` | ScreenScraper API client and the scraping queue |
| `Ursprung/Cores` | Core download/installation and BIOS management |
| `Ursprung/Emulation` | Session control, input routing, Metal renderer, shaders |
| `Ursprung/Bridge` | Objective-C/C libretro host, `libretro.h`, bridging header |
| `Ursprung/UI` | SwiftUI views (library, player, settings, components) |
| `Ursprung/Support` | Paths, preferences, keychain, ZIP reader, secrets |
| `Tools/ursprung-smoke` | Headless command-line harness for cores |
| `UrsprungTests` | Unit tests (Swift Testing) |

## Concurrency model

The Swift target uses **MainActor default isolation** (Swift 6.2 "approachable
concurrency"). Services and views are MainActor; pure data types
(`GameSystem`, `ScannedROM`, `ScrapedGame`, …) are `nonisolated` and
`Sendable`. File system scans, hashing, ZIP extraction, network requests and
image decoding run in `@concurrent` functions.

Emulation has its own thread, owned by `UREmulationRunner`:

- **Emulation thread** — calls `retro_load_game`, `retro_run`,
  `retro_serialize` … Commands from the UI (save state, reset, disc change) are
  queued with `performOnEmulationThread` and run between frames.
- **Audio render thread** — `AVAudioSourceNode` pulls samples from the
  lock-free `URAudioRing`.
- **Main thread** — the `MTKView` draws at display refresh and copies the most
  recent frame under a short `os_unfair_lock`.

## Frame pacing

Audio is the master clock. The emulation thread sleeps until the next frame
deadline (`1 / fps`) and nudges the frame duration by up to ±0.5 % depending on
how far the audio ring buffer is from its target fill (~64 ms). This keeps
audio free of crackles without resampling. Fast forward runs at 4× and drops
audio. The renderer shows the newest frame on every display refresh, so 60 Hz
content on a 120 Hz ProMotion display simply repeats frames.

## Video

Cores deliver frames in `0RGB1555`, `RGB565`, `XRGB8888` or `XRGB2101010`.
`URLibretroCore` converts them to BGRA8 into a back buffer and swaps it with the
ready buffer. Hardware-rendered cores get an offscreen CGL context (OpenGL 4.1
core or 2.1 legacy) with an FBO; after each frame the FBO is read back with
`glReadPixels` (flipped for bottom-left origin) and published like a software
frame. The Metal shaders (compiled at runtime, so no Metal toolchain download
is needed) implement sharp bilinear, nearest, bilinear and scanline filtering,
aspect-correct fitting, integer scaling and core-requested rotation.

## Input

`InputRouter` merges the keyboard (player 1), GameController pads, XInput pads
and generic HID gamepads into per-port RetroPad bitmasks and analog values.

`XInputGamepadManager` opens USB interfaces speaking the Xbox 360 protocol
(class 0xFF, subclass 0x5D, protocol 0x01), which macOS has no driver for, with
IOUSBHost from user space, reads the 20-byte input reports on a private queue
and lights the player LED. Pads the
GameController framework rejects (for example 8BitDo pads in D-input mode) are
read by `HIDGamepadManager` through `IOHIDManager`; pads from Nintendo, Sony
and Microsoft, or whose name matches a GameController pad, are skipped so input
is not doubled. `HIDGamepadMapping` guesses a layout from the reported elements
(Android/8BitDo layout for 15+ buttons, DirectInput layout otherwise) and stores
user changes per vendor/product ID. Ports go to GameController pads first,
then XInput pads, then HID pads.

## libretro environment

`URCoreEnvironment` implements the commands real-world cores rely on, among
them: pixel formats, system/save directories, core options v0 (variables), v1,
v1 intl, v2 and v2 intl, variable updates, `SET_VARIABLE`, log/perf/rumble
interfaces, `SET_HW_RENDER` / `GET_PREFERRED_HW_RENDER`, geometry and A/V info
changes, disk control (v0 and ext), messages, rotation, input bitmasks,
language, JIT capability and shutdown. Unsupported interfaces (Vulkan, VFS,
camera, sensors, MIDI, microphone) return `false`, which cores handle
gracefully.

Frontend-specific core option defaults live in `SystemCatalog`
(`CoreDefinition.optionDefaults`); user changes are stored per core in
`UserDefaults` and applied on top.

## Library and metadata

`LibraryScanner` walks the library folders, groups files per directory, removes
files referenced by `.cue`/`.gdi`/`.m3u`/`.ccd`, and identifies the system:

1. The nearest folder whose name matches a system alias wins for ambiguous
   extensions (`.bin`, `.iso`, `.cue`, `.chd`, `.zip`, …).
2. Otherwise the file extension decides.
3. Zips without a helpful folder name are identified by their largest entry.

`LibraryStore` merges scan results into SwiftData. Games whose file is gone
stay as *missing*; `LibraryMatcher` recognises renamed and moved files by
checksum or size and modification date, so the entry keeps its UUID and with
it its saves (docs/SAVES.md). The SwiftData schema is versioned in
`LibrarySchema.swift`; a change to `Game` needs a new version and migration
stage. `LibraryStore` then queues new games for
`MetadataService`, which scrapes one game at a time (the anonymous ScreenScraper
quota allows a single thread). Media are downloaded into
`Media/<game-id>/`; only file names are stored in the database, because
ScreenScraper media URLs contain API credentials.

## Cores and BIOS

`CoreManager` downloads `<core>_libretro.dylib.zip` from
`buildbot.libretro.com/nightly/apple/osx/arm64/latest/`, extracts it with the
built-in ZIP reader, removes the quarantine attribute and stores it in `Cores/`.
Cores that need data files (PPSSPP, blueMSX, Dolphin) also get their
`assets/system/*.zip` extracted into the system directory once.

The app is not sandboxed and uses the hardened runtime with
`disable-library-validation`, `allow-jit` and
`allow-unsigned-executable-memory`, which dynamic recompilers need.

`BIOSManager` verifies BIOS files by MD5 and, on import, renames files to the
name the core expects (e.g. `SCPH1001.BIN` → `scph1001.bin`).
