# Ursprung — Standalone Emulators and PlayStation 2: Plan

7 October 2026 · based on commit 2b278e1 (main). Status: planned, questions resolved (7 October 2026), nothing implemented. Comes before `docs/VULKAN_PLAN.md`.

Ursprung runs every game in-process through a libretro core. PlayStation 2 has no libretro core that works on macOS arm64 today (see *Background*). This plan adds a second kind of emulator, a **standalone emulator** that Ursprung downloads, configures and launches as a separate process. The first and only one in this plan is ARMSX2, which makes PlayStation 2 playable.

## Decisions

| Topic | Decision |
|---|---|
| PS2 emulator | ARMSX2 standalone (macOS arm64 nightly, Metal renderer) |
| Distribution | Downloaded on first use from the ARMSX2 GitHub releases (like cores from the buildbot), never bundled. Ursprung pins one tested nightly per release; checks SHA-256 and the Developer ID team |
| Model | A standalone emulator is a `CoreDefinition` with `backend = .standalone(…)`. The core picker, per-game core choice, BIOS checks and the save-state folder keep working |
| Window | No Ursprung player window. The library shows the game as running in ARMSX2, with Save State / Load State / Quit |
| Configuration | Ursprung owns ARMSX2's data folder (`-datapath`) and writes `PCSX2.ini` before every launch. The user never sees ARMSX2's setup wizard |
| Saves | Memory cards per game under `Saves/ps2/<game id>/`; save states under `States/<game id>/armsx2/`. Both are in backups |
| Control | Process lifetime for play time; SIGTERM to quit; PINE (Unix socket) for save/load state and status |
| BIOS | Any PS2 BIOS dump in `System/pcsx2/bios/`, recognised by content, not by a fixed file name or MD5 |
| Achievements | ARMSX2's own login; Ursprung's token is not handed over (Q4) |

Non-goals: other standalone emulators (the model allows them later), embedding ARMSX2's video in Ursprung's player, Vulkan / MoltenVK, Play! or PCSX2 libretro cores (see *Background*).

## Background

### Why not a libretro core (tested 7 October 2026)

Smoke tests with `Persona 4 (Europe).iso` and the user's BIOS dumps:

| Option | Result |
|---|---|
| `play_libretro` (Play!, buildbot arm64) | Reaches the main menu without a BIOS, save states work. **2 of 12 runs crashed in `retro_deinit`**: the core frees its GL programs while the VM still queues a flip (`CGSH_OpenGL::CopyToFb`, null deref). Core bug; Ursprung's teardown order matches RetroArch. In the app this would crash about every sixth game exit. |
| `pcsx2_libretro` (LRPS2, buildbot arm64) | OpenGL renderer refuses: needs `GL_ARB_shading_language_420pack`, Apple's GL stops at 4.1 → no video. `Software (SW)` renders but Persona 4 hangs on the loading icon (6,000 frames). `retro_unserialize` crashes (SIGBUS, reads past the buffer). |
| ARMSX2 libretro core | Linux-only builds. On Apple the core is built for Vulkan only (GL is excluded, the software renderer presents through Vulkan too), so it needs Vulkan support in Ursprung. |

### ARMSX2 standalone (nightly-20261006, 46c06fe7ca)

- PCSX2 fork with native ARM64 recompilers (EE, IOP, VU0/VU1, fastmem). GPL-3.0. The macOS build ships only as nightly (`ARMSX2-nightly-<date>-<commit>-macOS-arm64.tar.xz`, 34 MB, 160 MB unpacked, Qt 6 + MoltenVK + SDL3). Stable releases (2.8.x) are Android-only.
- Signed with Developer ID (team `L296QD7JFU`) and notarized: `spctl` accepts it.
- Persona 4 PAL runs at full speed (50 fps) with the **Metal** renderer, EE load 12 %.
- Command line: `-batch`, `-nogui`, `-fullscreen`/`-nofullscreen`, `-fastboot`/`-slowboot`, `-statefile <file>`, `-state <slot>`, `-datapath <dir>`, `-logfile <file>`, `-bios`, `-- <file>`.
- `-datapath D` stores everything under `D/ARMSX2/` (`inis/`, `bios/`, `memcards/`, `sstates/`, `snaps/`, `cache/`, `covers/`, …).
- A `PCSX2.ini` without `[UI] SettingsVersion = 1` and `SetupWizardIncomplete = false` makes ARMSX2 show a dialog or the setup wizard.
- **Qt message boxes crash on macOS 27**: an `NSAlert` raises in CoreUI while rasterising its icon (`CUINamedVectorGlyph`), and the app aborts. Any error ARMSX2 shows as a dialog therefore ends the process. Ursprung must avoid dialogs (complete config, BIOS present, readable file) and treat an abnormal exit as a launch failure with the log tail.
- SIGTERM shuts the VM down cleanly (DEV9 closed, NVRAM written, exit 0).
- PINE IPC (`[EmuCore] EnablePINE`, socket `pcsx2.sock` in the temp folder, slot-numbered) is compiled in.

### Ursprung today

- `GameSystem.cores: [CoreDefinition]`; the first is the default. `Game.effectiveCore`, `Preferences.coreChoice(for:)`, `BIOSManager.missingRequired(for:coreID:)` and `SaveStateStore.directory(…coreID:)` all key on `CoreDefinition.id`.
- `LibraryView.play` opens the player window, then calls `EmulationSession.launch`, which installs the core (`CoreManager.ensureInstalled`), checks BIOS, loads the core in-process and records play time on stop.
- The scanner already assigns ambiguous extensions (`.iso`, `.chd`, `.bin`, …) to the system of the nearest folder alias. A `ps2` system with aliases is enough for `ROMS/PS2/*.iso`; no header sniffing is needed.
- BIOS files are fixed names with optional MD5 (`BIOSFile`). PS2 dumps come in dozens of versions with arbitrary names and side files (`.EROM`, `.ROM1`, `.ROM2`, `.NVM`), so that model does not fit.
- The app is not sandboxed, so launching a helper process and opening a Unix socket need no new entitlements.

## Architecture

```
 LibraryView.play ──▶ EmulationSession.launch
                        │ definition.backend
          ┌─────────────┴──────────────┐
          ▼ .libretro (unchanged)      ▼ .standalone(ARMSX2)
   player window, LibretroCore     ExternalSession
                                     ├─ EmulatorManager.ensureInstalled  (download, verify, versions)
                                     ├─ PCSX2Config.write                (PCSX2.ini, per launch)
                                     ├─ Process(ARMSX2 -datapath … -batch -nogui -- game)
                                     ├─ PINEClient                       (status, save/load state)
                                     └─ on exit: play time, failure + log tail, states refresh
```

### Model

- `CoreDefinition.backend: CoreBackend` with `.libretro` (default, everything today) and `.standalone(StandaloneEmulator)`.
- `StandaloneEmulator` (nonisolated, `Sendable`): `id` (`armsx2`), `name`, pinned `release` (tag, asset name, SHA-256), `teamIdentifier`, bundle-relative executable path, `minimumVersionNote`.
- `CoreDefinition.fileName` and the buildbot code paths are only reached for `.libretro`; `CoreManager.allCores` filters on backend.
- New system in `SystemCatalog`:
  - `ps2`, "PlayStation 2", Sony, 2000, `.console`, ScreenScraper 58, extensions `["cso", "zso"]` (plus the ambiguous `iso`/`chd`/`bin`/`cue` through the folder), aliases `ps2`, `playstation2`, `sonyplaystation2`, `boxAspect` 0.71 (DVD case), added to `discSystems` and to `stickDrivesDPad`'s exclusion list.
  - `cores: [Cores.armsx2]`.
- `BIOSFile` gets a folder variant (or a sibling `BIOSFolder`): "at least one valid PS2 BIOS in `pcsx2/bios/`". Validity: 4 MB file whose ROMDIR contains `RESET`, `ROMVER` and `OSDSYS`; `ROMVER` gives region and version for the BIOS settings list. Import accepts any file name and copies side files with the same base name.

### Process and window

- Launch: `ARMSX2 -datapath <Emulators/ARMSX2/data> -batch -nogui -logfile <tmp>/armsx2.log [-fullscreen] [-statefile <state>] -- <game>`.
- `-nogui` hides ARMSX2's main window; only the game window opens. Fullscreen follows a new preference (default: the player window's last mode).
- `LibraryView.play` does not open the player window for `.standalone`. `EmulationSession` gets `phase = .external(name)` so that "one game at a time", the toolbar state and the inspector's Play button keep working. The inspector and toolbar show "Running in ARMSX2" with Save State, Load State and Quit.
- Quit from Ursprung: PINE save of the resume state if enabled (see *Saves*), then SIGTERM, then SIGKILL after 10 s. Quitting Ursprung quits ARMSX2 the same way.
- Exit with a signal or non-zero status before the first frame → `phase = .failed` with the last 20 log lines. A crash report path is not needed.

### Configuration (`PCSX2Config`)

Written before every launch (nonisolated, pure function from settings to ini text, so it is unit-testable):

- `[UI]` `SettingsVersion = 1`, `SetupWizardIncomplete = false`, `ConfirmShutdown = false`, `StartFullscreen`, `HideMouseCursor = true`.
- `[AutoUpdater] CheckAtStartup = false` (Ursprung manages versions).
- `[Folders]` `Bios` → `System/pcsx2/bios`, `MemoryCards` → `Saves/ps2/<game id>`, `Savestates` → `States/<game id>/armsx2`, `Snapshots` → the game's screenshot folder in `Extras`.
- `[EmuCore]` `EnableFastBoot`, `EnablePINE = true`, `PINESlot = <free slot>`, `SaveStateOnShutdown` (see Q2).
- `[EmuCore/GS] Renderer` = Metal.
- `[Pad1]`/`[Pad2]` and `[Hotkeys]` from Ursprung's input profile (phase 6). Until then ARMSX2's SDL automapping and default keyboard map.
- Keys Ursprung does not manage are kept from the existing file, so changes the user makes in ARMSX2's own settings survive (see Q5).

### Saves

- **Memory cards**: one `Mcd001.ps2` per game under `Saves/ps2/<game id>/`, created by ARMSX2 on first boot. This matches Ursprung's per-game save model, backups and `GameSaveFiles.changeSystem`. The cost: games that read another game's save (e.g. a sequel's bonus) do not see it (see *Resolved questions*, Q1).
- **Save states**: ARMSX2 names them `<serial> (<CRC>).<slot>.p2s` in the `Savestates` folder. `.p2s` is a zip with `Screenshot.png`, so `SaveStatesBrowser` can show thumbnails through `ZipArchive`. `SaveStateStore` learns a second file layout for `coreID == "armsx2"` (list, delete, rename via a sidecar `.json` manifest, no slot copying).
- **Resume**: with resume on, quitting writes the resume state (PINE `MsgSaveState` to a reserved slot, or `SaveStateOnShutdown`), and "Resume" launches with `-statefile`. Which mechanism works is spike question S2.

### Distribution and updates (`EmulatorManager`)

- Installs to `Application Support/Ursprung/Emulators/ARMSX2/<commit>/ARMSX2.app`; the data folder `Emulators/ARMSX2/data/` is shared across versions.
- Download from `github.com/ARMSX2/ARMSX2/releases/download/<tag>/<asset>` through `HTTPDownload`, check SHA-256, extract `.tar.xz` (`/usr/bin/tar` in a `@concurrent` function), then verify with `SecStaticCodeCheckValidity` against `anchor apple generic and certificate leaf[subject.OU] = "L296QD7JFU"`.
- Like cores: progress in the preparing UI and in Settings › Cores, the previous version stays available ("go back"), remove frees the space.
- The pinned release lives in `SystemCatalog` and moves with Ursprung releases after a smoke test. There is no "Use newest nightly" option (Q3).
- Licence: ARMSX2 is GPL-3.0 and not redistributed by Ursprung; the About window credits it and links its source.

## Phases

Effort as in FEATURE_EVALUATION: S = local change, M = several components, L = new subsystem.

### Phase 0 — Spike (S, scratch folder)

A shell script in the scratchpad drives the downloaded nightly with a prepared data folder. Answer:

- **S1** Which `[Folders]` overrides are honoured (Bios, MemoryCards, Savestates, Snapshots), and are absolute paths outside the data folder accepted?
- **S2** Does SIGTERM honour `SaveStateOnShutdown`? Does `-statefile` resume reliably, also after an ARMSX2 update? Does a PINE `MsgSaveState` finish before SIGTERM, and how does Ursprung know it has (`MsgStatus`, file appears)?
- **S3** PINE on macOS: socket path (`$TMPDIR` or `/tmp`), naming with `PINESlot`, protocol of `MsgSaveState`/`MsgLoadState`/`MsgStatus`/`MsgTitle`/`MsgID`.
- **S4** Does ARMSX2 write anything outside `-datapath` (Qt `QSettings` in `~/Library/Preferences/net.armsx2.armsx2.plist`, caches, the shader cache)?
- **S5** Which situations still open a dialog (missing BIOS, unreadable ISO, a memory card in use, unsupported ini value)? Each one crashes on macOS 27; list the guards Ursprung needs.
- **S6** Window: does `-nogui` + `-fullscreen` behave with Spaces and the menu bar? Is ⌘Q in the game window a clean shutdown? Does the game window take focus?
- **S7** Input: does SDL3 automapping pick up the controllers Ursprung supports (Xbox, DualSense, Switch Pro, 8BitDo)? What does a keyboard binding look like in `[Pad1]`?
- **S8** Is the `.p2s` thumbnail usable at grid size, and is the `<serial> (<CRC>)` prefix stable across BIOS versions?

### Phase 1 — Model and catalog (S–M)

- `CoreBackend`, `StandaloneEmulator`, `Cores.armsx2`, the `ps2` system, folder aliases, `discSystems`.
- BIOS folder requirement, content check (ROMDIR), import of arbitrary names plus side files, Settings › BIOS shows found dumps with region and version.
- `CoreManager.allCores` and the core settings list skip standalone emulators; Settings › Cores gets a "Standalone emulators" section (filled in phase 2).
- Tests: scanner assigns `ROMS/PS2/x.iso` to `ps2`; BIOS recognition with a synthetic ROMDIR; catalog invariants (every system has a default core, standalone IDs unique).
- Acceptance: Persona 4 shows up in the library under PlayStation 2; Play shows "ARMSX2 is not installed yet" instead of crashing.

### Phase 2 — Emulator manager (M)

- `EmulatorManager` (`@Observable`, injected like `CoreManager`): `ensureInstalled`, progress, versions, previous version, remove.
- Download, SHA-256, `tar` extraction, code signature check, atomic move into place.
- Settings › Cores section: installed version, size, Update, Go Back, Remove.
- Tests with a fake downloader and a fixture tarball (signature check behind a protocol so tests can stub it).

### Phase 3 — Launch and lifecycle (M)

- `ExternalSession`: `Process`, environment, termination handler, stderr/log capture, SIGTERM/SIGKILL escalation, generation guard like `EmulationSession.launch`.
- `PCSX2Config.write`: merges managed keys into the existing ini.
- `EmulationSession` branches on `backend`; `.external` phase; play time and `lastPlayed`; failure with log tail; app quit stops the process.
- `LibraryView.play` skips the player window; inspector and toolbar show the running state.
- Debug: `URSPRUNG_AUTOPLAY` works for PS2, so the `debug-without-ui` skill can verify a launch headlessly.
- Tests: ini generation (golden files), argument building, lifecycle against a fake executable in `Tools/` that sleeps, traps TERM and exits with a chosen status.

### Phase 4 — Saves and states (M)

- Per-game memory card folder; `GameSaveFiles` knows `.ps2` cards (move on system change, merge conflicts, backup count).
- `SaveStateStore` layout for `armsx2`: list `.p2s`, thumbnail from the zip, manifest sidecar for names, delete and archive.
- Resume per the spike result (S2); `hasAutosave` in `GameActions` works for PS2.
- Tests: `.p2s` listing and thumbnails from fixture zips; backup round trip includes memory cards and `.p2s`.

### Phase 5 — PINE control (S–M)

- `PINEClient` (nonisolated, `@concurrent` I/O): connect with retry until the socket appears, `status`, `title`, `saveState(slot)`, `loadState(slot)`.
- Save State / Load State in the inspector, the Game menu and the Save States browser while ARMSX2 runs; toast in Ursprung when done.
- Tests against an in-process fake PINE server on a temp socket.

### Phase 6 — Input (M)

- Translate the active `InputProfile` into `[Pad1]`/`[Pad2]` (keyboard and SDL controller bindings) and `[Hotkeys]` (quit, save/load state, fast forward, fullscreen) so PS2 games use the same controls as everything else.
- Controls settings note that PS2 uses these mappings through ARMSX2, and which Ursprung features (turbo, stick-as-D-pad) do not apply.

### Phase 7 — Polish (S)

- "Open ARMSX2 Settings" in Settings › Cores and the PS2 game's inspector: starts ARMSX2 with its GUI on Ursprung's data folder (Q5).
- The achievements section of a PS2 game says that achievements are handled in ARMSX2 (Q4).
- German strings in `Localizable.xcstrings` for every new message.
- `docs/SUPPORTED_SYSTEMS.md` (PS2 supported through ARMSX2, BIOS required), `docs/ARCHITECTURE.md` (backends), `docs/BIOS.md` (PS2 folder), `docs/SAVES.md` (memory cards, `.p2s`), CLAUDE.md (agreed external emulator, Known issues).
- System icon and accent for PS2 (the hardware-identity design if it is merged by then).
- Upstream reports: the macOS 27 `NSAlert` crash to ARMSX2; the Play! `retro_deinit` race to Play!.

## Features for standalone games

| Feature | PS2 via ARMSX2 |
|---|---|
| Library, artwork, metadata, collections, ratings | Yes, unchanged |
| Play time, last played | Yes (process lifetime) |
| Resume, save states, Save States browser | Yes (phases 4–5) |
| Battery saves / memory cards in backups | Yes (phase 4) |
| Screenshots in the game's extras | Yes, through `Snapshots` (if S1 confirms) |
| Controls from Ursprung's profiles | Phase 6 |
| Player window, pause menu, toasts in the game | No — ARMSX2's own window and on-screen messages |
| Shaders (built-in filters, librashader) | No — ARMSX2 has its own post-processing |
| Rewind, turbo, cheats, ROM patches, core options UI | No; disabled for `.standalone` with a short explanation |
| RetroAchievements | In ARMSX2, with its own login (Q4) |

## Tests

- Unit: ini generation, launch arguments, BIOS ROMDIR parsing, `.p2s` listing and thumbnails, PINE encoding against a fake server, catalog invariants, `EmulatorManager` install/verify/rollback with fakes.
- Lifecycle: fake executable in `Tools/ursprung-test-standalone` (TERM handling, exit codes, a log file), copied into the test bundle like `ursprung-test-core`.
- Manual, per pinned release: Persona 4 boots, saves to its memory card, save/load state via PINE, resume after quit, ⌘Q in the game window, Ursprung quit while running, controller hot-plug.

## Risks

| Risk | Mitigation |
|---|---|
| Only nightlies for macOS; a nightly can regress | Pin a tested commit per Ursprung release; keep the previous version; "go back" in Settings |
| Qt dialogs crash on macOS 27 | Complete config, pre-flight checks (BIOS, file readable, free PINE slot), failure UI with log tail; report upstream |
| ARMSX2 changes its CLI, ini keys or `.p2s` naming | Golden-file tests describe what Ursprung relies on; the spike checklist is rerun before moving the pin |
| ARMSX2 writes outside `-datapath` (S4) | Document it; if it is user-visible (Qt prefs), clean or isolate via `HOME`/`XDG` variables if the spike shows they are honoured |
| The download host or team ID changes | SHA-256 and team check fail closed with a clear message; the next Ursprung release updates the pin |
| Two windows feel less integrated than libretro systems | Clear "Running in ARMSX2" state; fullscreen by default; revisit embedding only if ARMSX2 gains an embeddable mode |
| Third kind of dependency | Needs explicit agreement (CLAUDE.md "Hard rules"): downloaded at runtime like cores, not vendored or bundled |

## Resolved questions (7 October 2026)

The user followed the recommendations. Where the plan had none, the choice below was made with it.

1. **Q1 Memory cards: one per game.**
   - Matches Ursprung's save model: saves belong to the library entry, move with it and are in backups.
   - A shared card per system ("Use shared memory card") can be added later if a game needs another game's save; it is not part of this plan.
2. **Q2 Resume mechanism: decided by spike S2.**
   - Preferred order: PINE save to a reserved slot before SIGTERM (Ursprung knows when it is done), then `SaveStateOnShutdown` as the fallback.
3. **Q3 Updates: pinned releases only.**
   - A nightly can regress, and the CLI, ini keys and `.p2s` naming are what Ursprung relies on. The pin moves with Ursprung releases after the manual checks.
   - No "Use newest nightly" toggle.
4. **Q4 Achievements: ARMSX2's own login.**
   - Handing over Ursprung's RetroAchievements login would write the token into `PCSX2.ini` in plain text.
   - Ursprung explains in the game's achievements section that PS2 achievements are handled in ARMSX2.
5. **Q5 ARMSX2's own settings: yes, as "Open ARMSX2 Settings" in phase 7.**
   - Graphics options (upscaling, texture filtering, per-game fixes) are ARMSX2's strength, and duplicating them in Ursprung is out of proportion.
   - It starts ARMSX2 with its GUI on the same data folder. Keys Ursprung manages (folders, PINE, renderer, setup wizard) are rewritten before every launch; the settings note says so.
   - Its settings window uses Qt widgets, not message boxes; spike S5 checks it does not hit the macOS 27 dialog crash.
6. **Q6 Play!: not now.**
   - Report the `retro_deinit` race upstream (phase 7). Revisit when a fixed build passes the 12-run teardown check.
