# Architecture

Ursprung is a SwiftUI app with a small Objective-C/C libretro host. The only
third-party code is [rcheevos](https://github.com/RetroAchievements/rcheevos)
(MIT) in `ThirdParty/rcheevos`, compiled into the app for RetroAchievements.

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
                                   │ URRewindBuffer (state history) │
                                   │ URAchievements (rcheevos)      │
                                   └───────────────┬────────────────┘
                                                   ▼
                                   <core>_libretro.dylib (downloaded)
```

## Source layout

| Path | Purpose |
|---|---|
| `Ursprung/App` | App entry point, scenes, menu commands |
| `Ursprung/Systems` | `GameSystem`/`CoreDefinition` models and the `SystemCatalog` |
| `Ursprung/Library` | SwiftData `Game` model, folder scanner, `LibraryStore`, ROM patches and per-game extras |
| `Ursprung/Achievements` | RetroAchievements account (`AchievementService`) |
| `Ursprung/Metadata` | ScreenScraper API client and the scraping queue |
| `Ursprung/Cores` | Core download/installation and BIOS management |
| `Ursprung/Emulation` | Session control, input routing, Metal renderer, shaders |
| `Ursprung/Bridge` | Objective-C/C libretro host, `libretro.h`, rewind buffer, rcheevos client, bridging header |
| `Ursprung/UI` | SwiftUI views (library, player, settings, components) |
| `Ursprung/Support` | Paths, preferences, keychain, ZIP reader, secrets |
| `ThirdParty/rcheevos` | rcheevos 12.5.0 (see its README for what was left out) |
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
audio free of crackles without resampling. Fast forward runs at the chosen
speed (default 4×, or unthrottled) and drops audio. The renderer shows the
newest frame on every display refresh, so 60 Hz content on a 120 Hz ProMotion
display simply repeats frames.

After each frame the player sees, the runner may serialize the state:

- **Rewind** pushes it into `URRewindBuffer`, which keeps the newest state
  whole and every older one as the XOR difference to its successor,
  LZ4-compressed, dropping the oldest when the memory budget is used up.
  While rewinding, every frame pops one state, loads it and runs one silent
  frame to show it.
- **Run-ahead** (1–3 frames) runs the real frame with video off, saves the
  state, runs the extra frames silently with video only for the last one, and
  loads the saved state again, so the next input applies to the real frame.
  `GET_AUDIO_VIDEO_ENABLE` tells the core what is skipped.
- The runner's `frameHandler` then lets rcheevos evaluate achievements
  (`rc_client_do_frame`); while paused it calls `rc_client_idle`.

## Video

Cores deliver frames in `0RGB1555`, `RGB565`, `XRGB8888` or `XRGB2101010`.
`URLibretroCore` converts them to BGRA8 into a back buffer and swaps it with the
ready buffer. Hardware-rendered cores get an offscreen CGL context (OpenGL 4.1
core or 2.1 legacy) with an FBO; after each frame the FBO is read back with
`glReadPixels` (flipped for bottom-left origin) and published like a software
frame. The Metal shaders (compiled at runtime, so no Metal toolchain download
is needed) implement sharp bilinear, nearest, bilinear and scanline filtering,
aspect-correct fitting, integer scaling and core-requested rotation, plus CRT
(beam-width scanlines, aperture grille, optional curvature and vignette) and
handheld LCD grid filters; filters can be chosen per system. Two more passes
are optional: an *ambient light* pass draws a heavily blurred copy of the
frame (a high mip level, mipmaps generated per frame) behind the picture, and
an overlay pass draws a per-system bezel PNG over everything with alpha
blending.

## Input

`InputRouter` merges the keyboard (player 1), GameController pads, XInput pads
and generic HID gamepads into per-port RetroPad bitmasks and analog values.
Every controller first reports a positional RetroPad state; the active
`InputProfile` (the game's, else its system's, else the global one) then
remaps keys and controller buttons, and the stick dead zone is applied
radially. Controllers keep the player chosen for them in Settings
(`PortAssignment`, keyed by kind, name and occurrence); the others take the
free players in connection order, and player LEDs follow. Hotkeys
(`HotkeyMapping`) are handled by the player view before the router. Turbo
buttons of the profile are sent to the core as a per-port mask; the core
releases them every other `turboPeriod` frames.

Rumble requests from the core (`set_rumble_state`) reach `InputRouter`, which
drives the strong and weak motors of the controllers on that port: Core
Haptics on GameController pads (left/right handle where supported) and the
Xbox 360 rumble report on XInput pads. For computers (MSX), *typing mode*
sends the Mac keyboard to the core as `RETRO_DEVICE_KEYBOARD` state and
keyboard-callback events (`EmulatedKeyboard` maps keys by position) instead
of RetroPad buttons.

`XInputGamepadManager` opens USB interfaces speaking the Xbox 360 protocol
(class 0xFF, subclass 0x5D, protocol 0x01), which macOS has no driver for, with
IOUSBHost from user space, reads the 20-byte input reports on a private queue
and lights the player LED. Pads the
GameController framework rejects (for example 8BitDo pads in D-input mode) are
read by `HIDGamepadManager` through `IOHIDManager`; pads from Nintendo, Sony
and Microsoft, or whose name matches a GameController pad, are skipped so input
is not doubled. `HIDGamepadMapping` guesses a layout from the reported elements
(Android/8BitDo layout for 15+ buttons, DirectInput layout otherwise) and stores
user changes per vendor/product ID.

## libretro environment

`URCoreEnvironment` implements the commands real-world cores rely on, among
them: pixel formats, system/save directories, core options v0 (variables), v1,
v1 intl, v2 and v2 intl, variable updates, `SET_VARIABLE`, log/perf/rumble
interfaces, `SET_HW_RENDER` / `GET_PREFERRED_HW_RENDER`, geometry and A/V info
changes, disk control (v0 and ext), messages, rotation, input bitmasks,
language, JIT capability, keyboard callbacks, memory maps, cheats
(`retro_cheat_set`, optional symbols) and shutdown. Unsupported interfaces (Vulkan, VFS,
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
stage. `LibraryWatcher` (FSEvents, plus volume mounts) asks for rescans;
`RescanScheduler` waits for changes to settle and keeps automatic scans at
least 15 seconds apart. Scans also report unidentified files and disc
descriptors with missing tracks (Scan Report); a system the user chose
(`Game.systemOverride`) wins over detection. `LibraryStore` then queues new games for
`MetadataService`, which scrapes one game at a time (the anonymous ScreenScraper
quota allows a single thread). Its jobs are a full lookup, artwork only
(`mediaIncomplete`), or a match the user chose; fields the user edited
(`Game.lockedFields`) are never overwritten. Busy responses are retried;
quota, login and network problems stop the queue without marking games as
failed, and a reached daily quota pauses automatic fetching until midnight
in France. Media are downloaded into
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

Installing a core again keeps the previous dylib in `Cores/Previous/`;
`Cores/versions.json` records each version's install date and, once a game
has run with it, its `library_version`. Going back swaps the two. The update
check compares the buildbot's `Last-Modified` with the install date.

`BIOSManager` verifies BIOS files by MD5 and, on import, renames files to the
name the core expects (e.g. `SCPH1001.BIN` → `scph1001.bin`).

## RetroAchievements

`URAchievements` wraps one `rc_client` for the app session. Requests go
through an ephemeral `URLSession` on a private serial queue, which also runs
sign-in, game identification (rhash reads the file the core gets, after
patching) and unloading, so they stay in order. Memory is only read on the
emulation thread (`rc_client_set_allow_background_memory_reads(0)`):
`rc_libretro` maps RetroAchievements addresses to the core's memory map or
`retro_get_memory_data` regions, rebuilt when the core declares a new map.
Events (unlocks, progress, leaderboards, connection problems) are delivered on
the main queue to `EmulationSession`, which shows toasts and indicators. The
sign-in token lives in the keychain; hardcore mode restricts states, rewind
and cheats and uses rcheevos' list of core options it doesn't allow.
