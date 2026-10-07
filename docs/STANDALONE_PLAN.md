# Ursprung — Standalone Emulators and PlayStation 2: Plan

7 October 2026 · based on commit 2b278e1 (main). Status: planned, questions resolved (7 October 2026), phase 0 spike done (7 October 2026), phases 1–8 done on branch `feature/ps2-armsx2` (7 October 2026). Comes before `docs/VULKAN_PLAN.md`.

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

## Spike results (phase 0, 7 October 2026)

Nightly `nightly-20261006` (46c06fe7ca), Persona 4 (Europe), the user's EU/US/JP BIOS dumps, data and save folders laid out like Ursprung's, driven from shell scripts in the session scratchpad. Where the behaviour comes from source, the file at that commit is named.

### Distribution

- Asset `ARMSX2-nightly-20261006-46c06fe7ca-macOS-arm64.tar.xz`, SHA-256 `cfb15cb8c220de7172bcdb3a73f63fae6700b240bb2d671c93df574247e5fc8e`. The GitHub release API lists the same digest per asset (`digest: sha256:…`), but the pin still carries its own copy.
- The archive contains a single bundle named `armsx2-macos-arm64-sha[46c06fe7ca].app` (brackets included), not `ARMSX2.app`. The installer renames it while moving it into place.
- `codesign --verify --deep --strict -R='anchor apple generic and certificate leaf[subject.OU] = "L296QD7JFU"'` passes; `spctl` says "Notarized Developer ID"; identifier `net.armsx2.armsx2`, `CFBundleVersion` = the commit.
- The stable tag `2.8.2` (7 October) again has only Android APKs.

### S1 Folders: all honoured, absolute paths work

- `Bios`, `MemoryCards`, `Savestates` and `Snapshots` accept absolute paths outside the data folder (`EmuFolders::LoadConfig` in `pcsx2/Pcsx2Config.cpp` only prefixes relative paths). Missing folders are created on demand.
- ARMSX2 creates **two** 8 MB cards, `Mcd001.ps2` and `Mcd002.ps2`, unformatted until the game formats them. Ursprung writes `[MemoryCards] Slot2_Enable = false` so a game folder holds exactly one card.
- F8 (default hotkey) writes `<title>_<serial>_<yyyyMMddHHmmss>.png` straight into `Snapshots`, which fits `Extras/<game id>/Screenshots`.
- Side files: ARMSX2 writes `<bios name>.mec` next to the BIOS (and `.nvm` if missing), and `playtime.dat` and `secrets.ini` into `inis/`. It also stores window geometry in `PCSX2.ini` (`[UI] DisplayWindowGeometry`, `MainWindowGeometry`, `[GameListTableView]`).

### S2 Resume: `SaveStateOnShutdown` + SIGTERM

- SIGTERM runs `requestExit` → `requestShutdown(…, EmuConfig.SaveStateOnShutdown)` (`pcsx2-qt/QtHost.cpp`, `MainWindow.cpp`). With `SaveStateOnShutdown = true` it writes `<serial> (<CRC>).resume.p2s` and exits 0. A PINE save sent right before SIGTERM is also completed: shutdown joins the zip threads. Both were verified (valid zips after exit).
- `-statefile <resume.p2s>` resumes at the saved point (the intro FMV in the test), also when the state was written by a run that itself started from `-statefile`.
- **⌘Q in the game window and its close button quit cleanly (exit 0) but write no resume state.** The close button passes `default_save_to_state = false` by design (`DisplaySurface::handleCloseEvent`). Ursprung therefore cannot rely on a fresh resume state: if the session ends and `resume.p2s` is older than the session start, Ursprung deletes it, otherwise "Resume" would load a point older than the memory card.
- A second SIGTERM calls `_Exit(1)` at once without saving (`SignalHandler`). The escalation sends SIGTERM once, waits, then SIGKILL; never two SIGTERMs.
- Loading a state with an incompatible version opens a dialog (crash, see S5). `.p2s` carries `PCSX2 Savestate Version.id`: a little-endian `u32` (`0x9A590000` here, `g_SaveVersion` in `pcsx2/SaveState.h`) followed by a version string. ARMSX2 accepts states with the same upper 16 bits and a version not newer than its own. The pin records this value; Ursprung checks it before `-statefile` and before a PINE load, and hides incompatible states after a pin move.
- Decision for Q2: `SaveStateOnShutdown = true` (when resume is on) + one SIGTERM. A PINE save to a reserved slot gives nothing extra, because SIGTERM already waits for the write and the `.resume.p2s` name is what ARMSX2's own UI shows as the resume state.

### S3 PINE

- Unix socket `$TMPDIR/pcsx2.sock` for the default slot 28011, `$TMPDIR/pcsx2.sock.<slot>` otherwise (`/tmp` only when `TMPDIR` is unset). The socket exists about 2 s after launch and is removed on exit.
- Before binding, ARMSX2 **unlinks whatever is at that path**, so a second instance (or a stale socket) is silently replaced and a collision is not detectable. Ursprung sets `TMPDIR` for the child to its own folder (`$TMPDIR/Ursprung-PINE/`, 79 bytes for the full socket path here; `sun_path` allows 104) and still picks a free slot. Verified: the socket then appears only there.
- Wire format (`pcsx2/PINE.cpp`): request = `u32 total size` (including itself) + opcode + arguments; reply = `u32 total size` + result byte (`0` OK, `0xFF` fail) + payload. Strings come back as `u32 length` + NUL-terminated bytes. All little-endian. Several commands can be batched in one request.
- Opcodes used: `MsgVersion 0x08` ("ARMSX2 46c06fe7ca"), `MsgSaveState 0x09 <u8 slot>`, `MsgLoadState 0x0A <u8 slot>`, `MsgTitle 0x0B` ("Shin Megami Tensei - Persona 4"), `MsgID 0x0C` ("SLES-55474"), `MsgUUID 0x0D` (disc CRC "117d1977"), `MsgGameVersion 0x0E`, `MsgStatus 0x0F` (`u32` 0 running, 1 paused, 2 shutdown). ARMSX2-only: `MsgGetStats 0x10` (JSON with `fps`, `speed`, `frame_number`, `renderer`, …), `MsgGetSetting 0x11`, `MsgSetSetting 0x12`, `MsgFrameAdvance 0x13`, `MsgGSDump 0x14`, `MsgGetEffectiveSetting 0x15`.
- Save and load are **fire-and-forget**: the reply is OK as soon as the job is queued on the CPU thread; errors only appear as ARMSX2 on-screen messages. Completion of a save = the final `<serial> (<CRC>).<NN>.p2s` appears with a new modification date (ARMSX2 writes `….p2s.<random>.part` and renames it), about 0.1 s after the request.
- PINE is switched off in RetroAchievements hardcore mode (`VMManager.cpp`), so Save/Load State from Ursprung is unavailable then; the inspector says so when `MsgVersion` does not answer.
- "First frame" for failure detection: socket present and `MsgGetStats.frame_number > 0`.

### S4 Writes outside `-datapath`

- Normal runs: nothing. No `~/Library/Preferences/net.armsx2.armsx2.plist`, no caches, no saved application state.
- Crashes (S5) leave `ARMSX2-<date>.ips` in `~/Library/Logs/DiagnosticReports` and a `CrashReporter/ARMSX2_<uuid>.plist`.
- About 40 s after the first dialog crash, launchd started ARMSX2 **without arguments**: the user had clicked "Reopen" in the crash alert. It created `~/Library/Application Support/ARMSX2/` with default settings and showed the setup wizard. Preventing the crashes (S5) is the fix. If Ursprung sees that folder appear, it does not touch it, because the user may run ARMSX2 on their own.

### S5 Dialog cases (each dialog crashes on macOS 27: exit by SIGTRAP, status 133)

| Situation | Result | Guard in Ursprung |
|---|---|---|
| BIOS folder without a dump | crash | pre-flight: at least one valid dump (phase 1 BIOS check) |
| `[Filenames] BIOS` names a missing file | runs, ARMSX2 picks a dump itself | always write an existing file |
| No `[Filenames] BIOS`, several dumps | runs with the **JP** dump for a PAL disc | choose by disc region: serial prefix `SLES`/`SCES` → EU, `SLUS`/`SCUS` → US, `SLPS`/`SLPM`/`SCPS` → JP; fallback any |
| Game file missing | crash | pre-flight: file exists |
| Game file unreadable (no permission) | crash | pre-flight: open for reading |
| Game file not a PS2 image (random bytes) | runs, "Unknown game" in the BIOS browser | none needed |
| `Renderer = 12` (OpenGL) | crash ("failed to create render device") | Ursprung always writes `Renderer = -1` (automatic, which is Metal on macOS; phase 8) |
| `Renderer = 99` | runs | — |
| `-statefile` missing or not a zip | crash | pre-flight: file exists, opens as zip, version compatible (S2) |
| Memory card file read-only | crash | pre-flight: card files writable |
| Data folder or `inis/` read-only | crash ("failed to save settings") | pre-flight: write the ini (Ursprung does that anyway) |
| Savestates folder read-only | runs; a save fails with an on-screen message | — |
| `PCSX2.ini` missing | setup wizard (Qt widgets, no crash); SIGTERM then exits 1 | always write the ini |
| Quit while the memory card is being written | from source: `shouldAbortForMemcardBusy` shows a message box → crash, card may be corrupted | not detectable over PINE; report upstream (phase 7); not reproduced |

### S6 Window

- `-nogui` keeps the main window hidden (it exists off-screen); only the game window shows. Windowed: 640 × 512 pt, centred; position and size are saved in `PCSX2.ini`.
- The game window takes focus at launch, windowed and fullscreen.
- `-fullscreen` is native macOS fullscreen (`AXFullScreen = true`) in its own Space, placed below the notch (y = 33). SIGTERM leaves the Space, exits 0 and focus returns to the previous app.
- ⌘Q and the close button: clean shutdown (DEV9 closed, NVRAM checked, exit 0) but no resume state (S2).

### S7 Input: no bindings without the setup wizard

- With Ursprung's ini (wizard skipped) ARMSX2 has **no** bindings at all: on-screen "Controller 1 has no bindings configured", and no hotkeys (not even Esc or F8). The defaults are only written by `VMManager::SetDefaultSettings` when no valid ini exists.
- The defaults from a bootstrap run: `[InputSources] Keyboard/Mouse/SDL = true`, `SDLControllerEnhancedMode = true`; `[Pad1] Type = DualShock2`, `Up = Keyboard/Up`, …, `Cross = Keyboard/K`, `Circle = Keyboard/L`, `Square = Keyboard/J`, `Triangle = Keyboard/I`, `Start = Keyboard/Return`, `Select = Keyboard/Backspace`, `L1 = Keyboard/Q`, `R1 = Keyboard/E`, `L2 = Keyboard/1`, `R2 = Keyboard/3`, left stick WASD, right stick TFGH; `[Hotkeys]` e.g. `OpenPauseMenu = Keyboard/Escape`, `Screenshot = Keyboard/F8`, `SaveStateToSlot = Keyboard/F1`, `LoadStateFromSlot = Keyboard/F3`, `ToggleFullscreen = Keyboard/Alt & Keyboard/Return`.
- Controller bindings are explicit, per SDL player index: `SDL-0/FaceSouth`, `SDL-0/DPadUp`, `SDL-0/LeftShoulder`, `SDL-0/+LeftTrigger`, `SDL-0/-LeftX`, … ARMSX2 never maps a newly connected controller by itself; "automatic mapping" is a button in its settings.
- One button can have several bindings as **repeated keys** (`Cross = Keyboard/K` and `Cross = SDL-0/FaceSouth` on two lines). ARMSX2 loads and rewrites both. The ini merger therefore has to treat a section as an ordered list of key/value pairs, not a dictionary.
- Consequence: Ursprung writes `[InputSources]`, `[Pad1]` (keyboard + `SDL-0` bindings) and `[Hotkeys]` from phase 3 on, using ARMSX2's defaults; phase 6 replaces them with the input profile.
- Xbox Series X controller (Bluetooth), tested with the user at the controller: detected as `SDL-0` ("Xbox Series X Controller", rumble supported); D-pad, stick, A and Start drive Persona 4; a hotkey bound to `SDL-0/Back` takes screenshots. After switching the controller off and on, SDL gives it a new instance ID but the same player ID 0, so `SDL-0` bindings keep working without a restart.
- Not tested: DualSense, Switch Pro, 8BitDo. The binding names are the same for every gamepad type (only the display names differ), so the same `SDL-0` map should apply; a quick check per controller belongs to the manual tests.

### S8 Save state files

- Name `<serial> (<disc CRC>).<NN>.p2s`, `.resume.p2s`, `.autosave.p2s`, `.<NN>.p2s.backup` (`VMManager::GetSaveStateFileName`). The prefix comes from the disc only: `SLES-55474 (117D1977)` with the EU and the US BIOS alike.
- `.p2s` is a zip; `Screenshot.png` (640 × 480) is **stored** (method 0), so `ZipArchive` reads it; the other entries are zstd (method 93) and are not needed. 6–7 MB per state.
- `BackupSavestate` (default on) keeps the previous file as `.p2s.backup` when a slot is overwritten. Ursprung writes `BackupSavestate = false` (its own archive covers that) and ignores `.backup` files.

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

- Launch: `ARMSX2 -datapath <Emulators/ARMSX2/data> -batch -nogui -logfile <tmp>/armsx2.log [-fullscreen] [-statefile <state>] -- <game>`, environment `TMPDIR=$TMPDIR/Ursprung-PINE/` so the PINE socket lands in a folder only Ursprung uses (S3).
- Pre-flight before launch, because every ARMSX2 error dialog crashes (S5): a valid BIOS dump for the disc region, the game file opens for reading, the memory card files are writable, a `-statefile` exists, opens as zip and has a compatible save version (S2), and the ini was written.
- `-nogui` hides ARMSX2's main window; only the game window opens and takes focus. Fullscreen follows a new preference (default: the player window's last mode); it is native fullscreen in its own Space (S6).
- `LibraryView.play` does not open the player window for `.standalone`. `EmulationSession` gets `phase = .external(name)` so that "one game at a time", the toolbar state and the inspector's Play button keep working. The inspector and toolbar show "Running in ARMSX2" with Save State, Load State and Quit.
- Quit from Ursprung: one SIGTERM (ARMSX2 writes the resume state itself when `SaveStateOnShutdown` is on and waits for pending saves), then SIGKILL after 10 s. Never a second SIGTERM: ARMSX2 then exits at once without saving. Quitting Ursprung quits ARMSX2 the same way.
- The user can also quit in ARMSX2 (⌘Q, close button): exit 0, but no resume state (S2).
- Exit with a signal or non-zero status before the first frame (PINE `frame_number > 0`) → `phase = .failed` with the last 20 log lines; the log line `ReportErrorAsync: …` holds the reason. A crash report path is not needed.

### Configuration (`PCSX2Config`)

Written before every launch (nonisolated, pure function from settings to ini text, so it is unit-testable):

- `[UI]` `SettingsVersion = 1`, `SetupWizardIncomplete = false`, `ConfirmShutdown = false`, `StartFullscreen`, `HideMouseCursor = true`.
- `[AutoUpdater] CheckAtStartup = false` (Ursprung manages versions).
- `[Folders]` `Bios` → `System/pcsx2/bios`, `MemoryCards` → `Saves/ps2/<game id>`, `Savestates` → `States/<game id>/armsx2`, `Snapshots` → the game's screenshot folder in `Extras` (absolute paths, S1).
- `[Filenames] BIOS` = the dump matching the disc region (S5).
- `[MemoryCards] Slot1_Enable = true`, `Slot1_Filename = Mcd001.ps2`, `Slot2_Enable = false` (S1).
- `[EmuCore]` `EnableFastBoot`, `EnablePINE = true`, `PINESlot = <free slot>`, `SaveStateOnShutdown` = the resume preference (Q2), `BackupSavestate = false` (S8).
- `[EmuCore/GS] Renderer = -1` (automatic, which ARMSX2 resolves to Metal on macOS; OpenGL crashes, S5). Until phase 8 this was `17` (Metal by name), which made ARMSX2 show an "unsafe settings" message at every start.
- `[InputSources]`, `[Pad1]`, `[Pad2]` and `[Hotkeys]`: ARMSX2's default keyboard map plus `SDL-0` controller bindings in phase 3 (without the wizard there are none, S7); from phase 6 the game's input profile and Ursprung's hotkeys (`ARMSX2Controls`).
- Keys Ursprung does not manage are kept from the existing file, so changes the user makes in ARMSX2's own settings survive (see Q5). Sections are ordered lists of key/value pairs: a key may repeat (several bindings for one button, S7).

### Saves

- **Memory cards**: one `Mcd001.ps2` per game under `Saves/ps2/<game id>/`, created by ARMSX2 on first boot. This matches Ursprung's per-game save model, backups and `GameSaveFiles.changeSystem`. The cost: games that read another game's save (e.g. a sequel's bonus) do not see it (see *Resolved questions*, Q1).
- **Save states**: ARMSX2 names them `<serial> (<CRC>).<NN>.p2s` in the `Savestates` folder. `.p2s` is a zip with a stored `Screenshot.png` (640 × 480), so `SaveStatesBrowser` can show thumbnails through `ZipArchive`. `SaveStateStore` learns a second file layout for `coreID == "armsx2"` (list, delete, rename via a sidecar `.json` manifest, no slot copying; ignore `.part` and `.backup` files).
- **Resume**: with resume on, `SaveStateOnShutdown = true` and Ursprung's single SIGTERM write `<serial> (<CRC>).resume.p2s`; "Resume" launches with `-statefile` (S2). When a session ends without a resume state newer than its start (quit in ARMSX2), Ursprung deletes the old one.

### Distribution and updates (`EmulatorManager`)

- Installs to `Application Support/Ursprung/Emulators/ARMSX2/<commit>/ARMSX2.app`; the data folder `Emulators/ARMSX2/data/` is shared across versions.
- Download from `github.com/ARMSX2/ARMSX2/releases/download/<tag>/<asset>` through `HTTPDownload`, check SHA-256, extract `.tar.xz` (`/usr/bin/tar` in a `@concurrent` function), rename the single `armsx2-macos-arm64-sha[<commit>].app` inside to `ARMSX2.app`, then verify with `SecStaticCodeCheckValidity` against `anchor apple generic and certificate leaf[subject.OU] = "L296QD7JFU"`.
- Like cores: progress in the preparing UI and in Settings › Cores, the previous version stays available ("go back"), remove frees the space.
- The pinned release lives in `SystemCatalog` and moves with Ursprung releases after a smoke test. There is no "Use newest nightly" option (Q3).
- Licence: ARMSX2 is GPL-3.0 and not redistributed by Ursprung; the About window credits it and links its source.

## Phases

Effort as in FEATURE_EVALUATION: S = local change, M = several components, L = new subsystem.

### Phase 0 — Spike (S, scratch folder) — done 7 October 2026

A shell script in the scratchpad drives the downloaded nightly with a prepared data folder. Results in *Spike results*. Questions:

- **S1** Which `[Folders]` overrides are honoured (Bios, MemoryCards, Savestates, Snapshots), and are absolute paths outside the data folder accepted?
- **S2** Does SIGTERM honour `SaveStateOnShutdown`? Does `-statefile` resume reliably, also after an ARMSX2 update? Does a PINE `MsgSaveState` finish before SIGTERM, and how does Ursprung know it has (`MsgStatus`, file appears)?
- **S3** PINE on macOS: socket path (`$TMPDIR` or `/tmp`), naming with `PINESlot`, protocol of `MsgSaveState`/`MsgLoadState`/`MsgStatus`/`MsgTitle`/`MsgID`.
- **S4** Does ARMSX2 write anything outside `-datapath` (Qt `QSettings` in `~/Library/Preferences/net.armsx2.armsx2.plist`, caches, the shader cache)?
- **S5** Which situations still open a dialog (missing BIOS, unreadable ISO, a memory card in use, unsupported ini value)? Each one crashes on macOS 27; list the guards Ursprung needs.
- **S6** Window: does `-nogui` + `-fullscreen` behave with Spaces and the menu bar? Is ⌘Q in the game window a clean shutdown? Does the game window take focus?
- **S7** Input: does SDL3 automapping pick up the controllers Ursprung supports (Xbox, DualSense, Switch Pro, 8BitDo)? What does a keyboard binding look like in `[Pad1]`?
- **S8** Is the `.p2s` thumbnail usable at grid size, and is the `<serial> (<CRC>)` prefix stable across BIOS versions?

### Phase 1 — Model and catalog (S–M) — done 7 October 2026

- `CoreBackend`, `StandaloneEmulator`, `Cores.armsx2`, the `ps2` system, folder aliases, `discSystems`.
- BIOS folder requirement, content check (ROMDIR), import of arbitrary names plus side files, Settings › BIOS shows found dumps with region and version.
- `CoreManager.allCores` and the core settings list skip standalone emulators; Settings › Cores gets a "Standalone emulators" section (filled in phase 2).
- Tests: scanner assigns `ROMS/PS2/x.iso` to `ps2`; BIOS recognition with a synthetic ROMDIR; catalog invariants (every system has a default core, standalone IDs unique).
- Acceptance: Persona 4 shows up in the library under PlayStation 2; Play shows "ARMSX2 is not installed yet" instead of crashing.

### Phase 2 — Emulator manager (M) — done 7 October 2026

- `EmulatorManager` (`@Observable`, injected like `CoreManager`): `ensureInstalled`, progress, versions, previous version, remove.
- Download, SHA-256, `tar` extraction, code signature check, atomic move into place.
- Settings › Cores section: installed version, size, Update, Go Back, Remove.
- Tests with a fake downloader and a fixture tarball (signature check behind a protocol so tests can stub it).
- As built: versions live in `Emulators/ARMSX2/<commit>/ARMSX2.app`, `Emulators/versions.json` records the active and the previous one. A version the user went back to stays active until the pin moves (`heldBackFrom`); "Update" switches back to the pinned release without downloading it again when it is the previous version. Remove keeps `Emulators/ARMSX2/data/`. Play installs ARMSX2 and then stops with "can’t start it yet" until phase 3. Checked against the real nightly: download, SHA-256 and the team check pass, 167 MB installed, `spctl` accepts the installed copy, no quarantine attribute.

### Phase 3 — Launch and lifecycle (M) — done 7 October 2026

- `ExternalSession`: `Process`, environment, termination handler, stderr/log capture, SIGTERM/SIGKILL escalation, generation guard like `EmulationSession.launch`.
- `PCSX2Config.write`: merges managed keys into the existing ini (ordered sections, repeated keys kept), including the default keyboard and `SDL-0` bindings and hotkeys.
- Pre-flight checks from *Spike results* S5, each with its own failure message instead of a launch.
- PINE socket folder via `TMPDIR`; the resume state is deleted when a session ends without a fresh one.
- `EmulationSession` branches on `backend`; `.external` phase; play time and `lastPlayed`; failure with log tail; app quit stops the process.
- `LibraryView.play` skips the player window; inspector and toolbar show the running state.
- Debug: `URSPRUNG_AUTOPLAY` works for PS2, so the `debug-without-ui` skill can verify a launch headlessly.
- Tests: ini generation (golden files), argument building, lifecycle against a fake executable in `Tools/` that sleeps, traps TERM and exits with a chosen status.
- As built: `PCSX2Config` (ordered `IniDocument`, managed keys replace all their lines in place), `ARMSX2Launch` (pre-flight, BIOS by disc region: serial from `SYSTEM.CNF` of `.iso`/raw `.bin`, else the file name's region, else the metadata region; newest dump of that region), `ExternalSession` (process, one SIGTERM, SIGKILL after 10 s; a synchronous variant for app quit). Resume via `-statefile` came forward from phase 4: a `.resume.p2s` with a compatible save version is passed when the game resumes, and Play shows "Resume" when one exists. Logs go to `Emulators/ARMSX2/Logs/last-run.log` (ARMSX2's `-logfile`) and `last-run-output.log` (stdout/stderr). Full screen is a setting in Settings › Cores (default on). No PINE yet, so any exit Ursprung did not ask for that is not clean counts as a failure, shown as an alert in the library with "Show Log"; first-frame detection comes with phase 5. The lifecycle tests write a shell script into a temp folder instead of a `Tools/` target. Checked live with Persona 4: download and launch in 9 s, EU BIOS chosen for the PAL disc, PINE socket in `Ursprung-PINE`, memory card in `Saves/ps2/<game id>/`, resume state written on Quit and loaded on the next launch, a SIGKILL from outside shows the failure alert and keeps the resume state.

### Phase 4 — Saves and states (M) — done 7 October 2026

- Per-game memory card folder; `GameSaveFiles` knows `.ps2` cards (move on system change, merge conflicts, backup count).
- `SaveStateStore` layout for `armsx2`: list `.p2s`, thumbnail from the zip, manifest sidecar for names, delete and archive.
- Resume per the spike result (S2); `hasAutosave` in `GameActions` works for PS2.
- Tests: `.p2s` listing and thumbnails from fixture zips; backup round trip includes memory cards and `.p2s`.
- As built: `ARMSX2States` (own file) reads the state folder: the newest `.resume.p2s` is the automatic state, `.<NN>.p2s` are slots (merged copies `… .03 (from backup …).p2s` count as their slot; `.backup`, `.part` and hidden files are skipped). `SaveStateStore.allStates`, `discard`, `rename`, `history` and `restore` handle both layouts, so the Save States browser and the inspector's count work unchanged. The thumbnail is the state file itself: `ArtworkCache` decodes `Screenshot.png` from the zip, keyed by the state's modification date. A name goes into `<state>.json` (a `SaveStateManifest` made when the state is first named); it records the state's date and is ignored once ARMSX2 writes a new state into that slot. Deleting moves a slot into `History/<time>-<state>.p2s` (with its `.json`); Restore puts it back under its own name and archives the state there; the automatic state is deleted for good. "Play from Here" starts ARMSX2 with that state (`-statefile`); a state with an incompatible save version is refused before launch. The memory card folder (`PS2MemoryCard`, `Saves/<system>/<game id>/Mcd001.ps2`) already moved with system changes, merges and backups through the existing folder code; the backup summary now counts `.p2s` as states. "Import Battery Save…" becomes "Import Memory Card…" for PS2 games: it takes a formatted card (by its header) or a blank one (by its size, 8–64 MB) and keeps the current card as a copy. States that ARMSX2 overwrites itself (its own save hotkeys) do not go into the history until phase 5 saves through PINE. Checked against the spike's real Persona 4 states: slots, save version and the 640 × 480 screenshot are read.

### Phase 5 — PINE control (S–M) — done 7 October 2026

- `PINEClient` (nonisolated, `@concurrent` I/O, wire format in *Spike results* S3): connect with retry until the socket appears, `version`, `status`, `title`, `serial`, `stats`, `saveState(slot)`, `loadState(slot)`.
- Save and load are acknowledged before they run: a save is done when the slot's `.p2s` appears with a newer date (timeout → error toast); a load is checked for a compatible save version first.
- Save State / Load State in the inspector, the Game menu and the Save States browser while ARMSX2 runs; toast in Ursprung when done. Without a PINE answer (e.g. hardcore mode) the actions are disabled with a short note.
- Tests against an in-process fake PINE server on a temp socket.
- As built: `PINEClient` (own file) opens one connection per request, because ARMSX2 serves one client at a time; 3 s send/receive timeout, `SO_NOSIGPIPE`, socket paths over 104 bytes count as unreachable. After launch the session retries `version` for up to 30 s (`externalControl` connecting → ready or unavailable), then polls `stats` until `frame_number > 0`; a crash before that first frame shows as “couldn't be started”, later (or without PINE) as “stopped”. `ARMSX2States.save` asks ARMSX2 for the disc's serial and CRC, copies the slot's current state (with its name) into the history, sends the save and waits up to 10 s for `<serial> (<CRC>).<NN>.p2s` to get a newer date; on a timeout the copy is dropped and the name goes back. Ursprung's Quick Save was ARMSX2 slot 0 (`.00.p2s`, outside ARMSX2's own slots 1–10); phase 6 moved it to slot 1 so that the Quick Save key works in ARMSX2's window too. `ARMSX2States.load` only sends a load for the running disc's slot file with a compatible save version; the resume state, merged copies and history states cannot be loaded by number while the game runs. A load brings ARMSX2's window to the front. Quick Save and Quick Load sit below the inspector's Switch button, in the toolbar's “Running in ARMSX2” menu and in the Game menu (⌘S, ⌘L); the Save States browser gets a Save State menu (Quick Save, slots 1–9) and Load State on slot cards. Toasts show at the bottom of the library. Without a PINE answer the inspector says to use ARMSX2's F1/F3 keys. `URSPRUNG_DEBUG_STATES=1` with `URSPRUNG_AUTOPLAY` saves to slot 1, loads it and quits. Checked live with Persona 4: save, load (“Status von Slot 1 geladen” in ARMSX2's log), the replaced state in the history, resume on quit.

### Phase 6 — Input (M) — done 7 October 2026

- Translate the active `InputProfile` into `[Pad1]`/`[Pad2]` (keyboard and SDL controller bindings) and `[Hotkeys]` (quit, save/load state, fast forward, fullscreen) so PS2 games use the same controls as everything else.
- Controls settings note that PS2 uses these mappings through ARMSX2, and which Ursprung features (turbo, stick-as-D-pad) do not apply.
- As built: `ARMSX2Controls` (own file) turns the game's resolved profile into bindings before every launch. PS2 buttons follow Ursprung's PlayStation layout (Cross = B, the bottom face button; Circle = A; Square = Y; Triangle = X); the controller mapping picks the SDL button by position (`FaceSouth`, …), so a remapped button carries over, and controller sticks stay unmapped as in Ursprung. `[Pad1]` gets the keyboard and `SDL-0`, `[Pad2]` (a DualShock 2; ARMSX2's default is none) gets `SDL-1`, because the keyboard always plays as player 1. ARMSX2 numbers SDL controllers in connection order, so the player chosen for a controller in Settings does not carry over. A key that is also a hotkey is left out of the pad, as in Ursprung's player. The dead zone becomes `Deadzone`; with Rumble off the motor bindings go. Ursprung owns the bindings: every binding key of `[Pad1]`/`[Pad2]` and the whole `[Hotkeys]` section are rewritten, other pad settings (`AxisScale`, …) stay.
- Keyboard keys are named as ARMSX2 (Qt) sees them: by the character the current layout types (`UCKeyTranslate`, so the key left of X is `Y` on a German layout), with fixed names for special keys (both Shift keys are `Shift`, ⌘ is `Meta`, Control is `Control`, keypad keys are `Numpad…`). Keys without a Qt name (`Ö`, `ß`, dead keys) cannot be bound in ARMSX2 and are skipped.
- Hotkeys with a counterpart: Game Menu → `OpenPauseMenu` (plus Escape and the controllers' Home button, `SDL-0/Guide`, like Ursprung's player), Fast Forward (hold) → `HoldTurbo`, Fast Forward (on/off) → `ToggleTurbo`, Quick Save → `SaveStateToSlot1`, Quick Load → `LoadStateFromSlot1`, Take Screenshot → `Screenshot`. Rewind, Turbo, Typing and Shader Panel have none. ARMSX2's own defaults without a counterpart (aspect ratio, interlace, OSD, mute, zoom, pause, frame limit, slow motion, `ToggleFullscreen` on ⌥↩, …) are kept on keys Ursprung's controls leave free; its slot hotkeys give way to Quick Save/Load, the developer tools (GS dumps, input recording) are left out. There is no quit hotkey: ARMSX2's pause menu closes the game and writes the resume state.
- Quick Save is now ARMSX2's slot 1: ARMSX2's hotkeys reach slots 1–10 only, so Ursprung's Quick Save (slot 0) and its slot 1 swap places in `ARMSX2States.armsx2Slot` (file `.01.p2s` = Quick Save, `.00.p2s` = Slot 1). The Quick Save key in ARMSX2's window and Quick Save in the library then keep the same state; ARMSX2's on-screen message says "slot 1" for it. States saved by the key do not go into the history (ARMSX2 overwrites them itself).
- Settings › Controls: the hotkeys footer says which hotkeys work in ARMSX2; with PlayStation 2 chosen under Layout, a note says that ARMSX2 gets these controls at launch, that turbo buttons don't apply, and how players are assigned.

### Phase 7 — Polish (S) — done 7 October 2026

- "Open ARMSX2 Settings" in Settings › Cores and the PS2 game's inspector: starts ARMSX2 with its GUI on Ursprung's data folder (Q5).
- The achievements section of a PS2 game says that achievements are handled in ARMSX2 (Q4).
- German strings in `Localizable.xcstrings` for every new message.
- `docs/SUPPORTED_SYSTEMS.md` (PS2 supported through ARMSX2, BIOS required), `docs/ARCHITECTURE.md` (backends), `docs/BIOS.md` (PS2 folder), `docs/SAVES.md` (memory cards, `.p2s`), CLAUDE.md (agreed external emulator, Known issues).
- System icon and accent for PS2 (the hardware-identity design if it is merged by then).
- Upstream reports: the macOS 27 `NSAlert` crash to ARMSX2, plus a request to skip the memory-card-busy message box on SIGTERM in batch mode; the Play! `retro_deinit` race to Play!.
- As built: "Open ARMSX2 Settings" starts ARMSX2 without a game (`ARMSX2Launch` with `game == nil`): `-datapath` and `-logfile` only, no `-batch`/`-nogui`, so ARMSX2 shows its main window (an empty game list) and its settings are in its Settings menu; closing the window quits it. The ini is written first with the same managed keys, but the memory card, state and snapshot folders point at ARMSX2's own (`data/ARMSX2/memcards`, `sstates`, `snaps`), so a game started from ARMSX2's window can't write into a library game's folders, and the BIOS is the newest dump of the metadata region. One such window at a time (a second click brings it to the front); it is unavailable while a PS2 game starts or runs, a PS2 launch quits it first (one SIGTERM, it saves its settings as they change), and quitting Ursprung quits it. Checked live: main window, Graphics and Achievements pages open without a crash (Qt widgets, no `NSAlert`), SIGTERM exits cleanly, nothing written to `~/Library/Application Support/ARMSX2`. The button is in Settings › Cores (row "ARMSX2 Settings"), in a PS2 game's inspector (Emulation section, below "Graphics: Set in ARMSX2" and "Achievements: Sign in to RetroAchievements in ARMSX2") and in Settings › Achievements (a PlayStation 2 section saying ARMSX2 has its own sign-in). There is no per-game achievements section in the inspector, so the note went into those two places. For standalone games the inspector also drops the Shader picker and the Cheats section, and the game's and the system's "Edit Shader…" items are hidden. Docs: `SUPPORTED_SYSTEMS.md` (PS2 row, notes, "Standalone emulators"), `BIOS.md` (PS2 dumps), `SAVES.md` (memory cards, `.p2s` layout, resume), `ARCHITECTURE.md` (backends), CLAUDE.md (convention, known issue). The PS2 accent (0x2B3990) exists since phase 1; the hardware-identity design is not merged, so no new icon. Upstream reports filed 7 October 2026 (crash backtraces from the spike's `.ips` files, Play!'s `retro_deinit` read at master 83700b2c31): [ARMSX2#811](https://github.com/ARMSX2/ARMSX2/issues/811) (message boxes crash on macOS 27), [ARMSX2#812](https://github.com/ARMSX2/ARMSX2/issues/812) (no Memory Card Busy dialog on SIGTERM / in batch mode), [Play-#1628](https://github.com/jpd002/Play-/issues/1628) (`retro_deinit` race).

### Phase 8 — Release check (S) — done 7 October 2026

The manual checks from *Tests*, run against the pinned nightly (46c06fe7ca) in the running app before the branch is merged, and again before the pin moves.

- Boot, memory card, save and load state through PINE, resume: `URSPRUNG_AUTOPLAY` with `URSPRUNG_DEBUG_STATES` (see the `debug-without-ui` skill), then a second launch without it.
- ARMSX2's window, windowed and full screen: Ursprung's keys for the pad and the hotkeys, ⌘Q, the close button, quitting Ursprung while the game runs.
- A controller: buttons, Guide, switching it off and on during the game.
- Fix what the checks turn up; record the results here.
- As built (results, 7 October 2026, Persona 4 (Europe), EU BIOS, German keyboard layout):
  - **Boot and memory card:** a new `Mcd001.ps2` (8 MB) is created in `Saves/ps2/<game id>/`; Persona 4's Load Game screen reads it ("No data"). Writing a save from inside the game was not checked (the first save point is about an hour in); the card is in backups either way.
  - **States:** save to Ursprung's slot 1 (ARMSX2 `.00.p2s`) and load it through PINE, the resume state written on Quit and passed with `-statefile` on the next launch, the game continuing there.
  - **Keys in ARMSX2's window:** F2 saves to `.01.p2s` (Quick Save) and F4 loads it (ARMSX2's log: "Status in Slot 1 gespeichert", "Status von Slot 1 geladen"); Escape opens ARMSX2's pause menu; `Y` (Cross on the German layout), `X` (Circle) and `K` (left stick down) skip the trailer, open the title menu and Load Game, go back and move the cursor. A key has to be held for a frame or two: a synthetic press (down and up at once, as `osascript … key code` sends it) reaches hotkeys but not the pad, which ARMSX2 polls once per frame. In the pause menu the keyboard drives ARMSX2's menu itself (arrows, Return, Escape), not the pad keys.
  - **Quitting:** ⌘Q and the close button exit cleanly; the library goes back to Play without an alert, the play time is recorded and the resume state from before the session is deleted (Q2). Quitting Ursprung during the game: ARMSX2 writes the resume state and exits within a second, the play time is recorded. Full screen (the default): the game window takes focus in its own Space; Quit from the library (through `URSPRUNG_DEBUG_PLAY`) leaves it cleanly and writes the resume state.
  - **Controller** (Xbox Series X, Bluetooth, with the user): A, D-pad and Guide (ARMSX2's pause menu) work; after switching it off and on, ARMSX2 shows "Controller SDL-0 angeschlossen" and keeps it as player 1, the buttons work again without a restart.
  - **Fix:** ARMSX2 showed "The graphics API is not set to Automatic" on screen at every start, because Ursprung wrote `Renderer = 17` (Metal). Ursprung now writes `-1` (automatic); `GSUtil::GetPreferredRenderer` resolves that to Metal on macOS, so the renderer is the same (log: "renderer=Metal") and the message is gone.
  - **Pin:** the newest release, ARMSX2 2.8.2 (7 October 2026), has Android builds only, so the pin stays on `nightly-20261006`. The upstream reports (#811, #812, Play-#1628) have no answer yet.
  - Not checked: DualSense, Switch Pro, 8BitDo (no such controller at hand); a save written by the game itself.

## Features for standalone games

| Feature | PS2 via ARMSX2 |
|---|---|
| Library, artwork, metadata, collections, ratings | Yes, unchanged |
| Play time, last played | Yes (process lifetime) |
| Resume, save states, Save States browser | Yes (phases 4–5) |
| Battery saves / memory cards in backups | Yes (phase 4) |
| Screenshots in the game's extras | Yes, through `Snapshots` (if S1 confirms) |
| Controls from Ursprung's profiles | Yes (phase 6): keyboard, controller layout, dead zone, rumble, six hotkeys; no turbo, no fixed player per controller |
| Player window, pause menu, toasts in the game | No — ARMSX2's own window and on-screen messages |
| Shaders (built-in filters, librashader) | No — ARMSX2 has its own post-processing |
| Rewind, turbo, cheats, ROM patches, core options UI | No; disabled for `.standalone` with a short explanation |
| RetroAchievements | In ARMSX2, with its own login (Q4) |

## Tests

- Unit: ini generation, launch arguments, BIOS ROMDIR parsing, `.p2s` listing and thumbnails, PINE encoding against a fake server, catalog invariants, `EmulatorManager` install/verify/rollback with fakes.
- Lifecycle: fake executable in `Tools/ursprung-test-standalone` (TERM handling, exit codes, a log file), copied into the test bundle like `ursprung-test-core`.
- Manual, per pinned release: Persona 4 boots, saves to its memory card, save/load state via PINE, resume after quit, Ursprung's keys and hotkeys in ARMSX2's window, ⌘Q and the close button in the game window, Ursprung quit while running, controller hot-plug. Phase 8 is the record of the first run and how each check was done.

## Risks

| Risk | Mitigation |
|---|---|
| Only nightlies for macOS; a nightly can regress | Pin a tested commit per Ursprung release; keep the previous version; "go back" in Settings |
| Qt dialogs crash on macOS 27 (S5) | Complete config, pre-flight checks (*Process and window*), failure UI with log tail; report upstream |
| Quit while the memory card is written opens a message box → crash, possibly a damaged card (S5, from source) | Not detectable over PINE; per-game card is in backups; report upstream |
| A crash alert's "Reopen" starts ARMSX2 without Ursprung's arguments (S4) | Avoid crashes through pre-flight; leave `~/Library/Application Support/ARMSX2` alone |
| Quit in ARMSX2 leaves a stale resume state (S2) | Delete a resume state older than the session start |
| ARMSX2 changes its CLI, ini keys or `.p2s` naming | Golden-file tests describe what Ursprung relies on; the spike checklist is rerun before moving the pin |
| ARMSX2 writes outside `-datapath` (S4) | Normal runs write nothing outside it; only crash reports and the "Reopen" case above |
| The download host or team ID changes | SHA-256 and team check fail closed with a clear message; the next Ursprung release updates the pin |
| Two windows feel less integrated than libretro systems | Clear "Running in ARMSX2" state; fullscreen by default; revisit embedding only if ARMSX2 gains an embeddable mode |
| Third kind of dependency | Needs explicit agreement (CLAUDE.md "Hard rules"): downloaded at runtime like cores, not vendored or bundled |

## Resolved questions (7 October 2026)

The user followed the recommendations. Where the plan had none, the choice below was made with it.

1. **Q1 Memory cards: one per game.**
   - Matches Ursprung's save model: saves belong to the library entry, move with it and are in backups.
   - A shared card per system ("Use shared memory card") can be added later if a game needs another game's save; it is not part of this plan.
2. **Q2 Resume mechanism: `SaveStateOnShutdown` + one SIGTERM (spike S2).**
   - SIGTERM waits for the resume state (and any pending PINE save) before ARMSX2 exits, so a PINE save to a reserved slot adds nothing.
   - Quitting in ARMSX2 itself (⌘Q, close button) writes no resume state; Ursprung then deletes the old one.
3. **Q3 Updates: pinned releases only.**
   - A nightly can regress, and the CLI, ini keys and `.p2s` naming are what Ursprung relies on. The pin moves with Ursprung releases after the manual checks.
   - No "Use newest nightly" toggle.
4. **Q4 Achievements: ARMSX2's own login.**
   - Handing over Ursprung's RetroAchievements login would write the token into ARMSX2's ini files (`inis/secrets.ini`) in plain text.
   - Hardcore mode switches PINE off, so Save/Load State from Ursprung is unavailable then (S3).
   - Ursprung explains in the game's achievements section that PS2 achievements are handled in ARMSX2.
5. **Q5 ARMSX2's own settings: yes, as "Open ARMSX2 Settings" in phase 7.**
   - Graphics options (upscaling, texture filtering, per-game fixes) are ARMSX2's strength, and duplicating them in Ursprung is out of proportion.
   - It starts ARMSX2 with its GUI on the same data folder. Keys Ursprung manages (folders, PINE, renderer, setup wizard) are rewritten before every launch; the settings note says so.
   - Its settings window uses Qt widgets, not message boxes. The spike saw the setup wizard (also Qt widgets) render without crashing; in phase 7 the main window and the settings window (Graphics, Achievements) opened without a crash too.
6. **Q6 Play!: not now.**
   - Report the `retro_deinit` race upstream (phase 7). Revisit when a fixed build passes the 12-run teardown check.
