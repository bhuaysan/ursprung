# Ursprung — RetroArch Shaders and Shader Editor: Plan

5 October 2026 · based on commit 164002d (main). Status: all phases done (0 spike, 1 dependency, 2 render path, 3 shader library, 4 player panel, 5 shader editor, 6 polish).

Ursprung renders every frame through one built-in Metal shader (`Ursprung/Emulation/ShaderSource.swift`, 7 fixed filters). This plan adds RetroArch slang shader presets through librashader, and a shader editor with live preview on top of it.

## Decisions

| Topic | Decision |
|---|---|
| Shader runtime | librashader (approved third-party dependency, second after rcheevos) |
| Editor scope | Preset editor (passes, pass options, parameters, textures) **and** a `.slang` source editor with highlighting, inline errors and live recompile |
| Preview | The running game (editor next to the player), and still images when no game runs |
| Shader source | libretro `shaders_slang.zip` downloaded on demand (like cores), plus a user folder and import |
| Built-in filters | Stay as the fast default and the fallback; presets are an additional category in the same picker |
| Player panel | Overlay at the trailing edge, not a sidebar: the game keeps its real output size (see Q1) |
| Editor entry points | Player, Settings, menu bar and the library (still-image mode) (see Q2) |
| Backup | `Shaders/User/` is backed up; the pack and drafts are not (see Q3) |
| Assignment | Per game, per system, all systems; resolved in that order (see Q4) |

Non-goals: `.glslp`/`.cgp` presets (librashader only reads slang), a node graph editor, HDR output, Vulkan.

## Background

### librashader (as of v0.12.0, 2026-07-04)

- Rust library with a C API (`librashader.h`, ABI 2 / API 5). Fully supports Metal. Prebuilt `librashader-aarch64-macos-v0.12.0-optimized.zip` (11.6 MB) is on GitHub releases, so no Rust toolchain is needed.
- Licence: MPL-2.0 or GPL-3.0, both compatible with GPL-3.0-or-later. Shipping the dylib requires stating where its source is (upstream tag).
- Metal API:
  - `libra_mtl_filter_chain_create(preset, queue, opts, out)` / `_create_deferred(…, commandBuffer, …)`
  - `libra_mtl_filter_chain_frame(chain, commandBuffer, frameCount, inputTexture, outputTexture, viewport, mvp, opts)`. `frame_mtl_opt_t` has `clear_history`, `frame_direction`, `rotation`, `aspect_ratio`, `frames_per_second`, `frametime_delta`, …
  - `libra_mtl_filter_chain_set_param` / `get_param`: live parameter changes without a recompile.
  - `libra_mtl_filter_chain_set_active_pass_count`: renders only the first N passes. The editor uses this for "show output of pass N".
- Presets are loaded **only from file paths** (`libra_preset_create*`); there is no in-memory API. The editor therefore writes working copies to disk.
- `libra_preset_get_runtime_params` lists parameters (name, description, initial/min/max/step). Pass options (scale, filter, wrap, formats, aliases) are **not** exposed in structured form. The editor needs its own `.slangp` model.
- "The Metal runtime is not thread safe." Only GPU resource creation can be deferred to a command buffer. Compiling large presets (Mega Bezel, crt-royale) takes seconds of CPU.
- Wildcard context (`libra_preset_ctx_*`): core name, content directory, rotation, aspect orientation. These feed `$CORE$`-style paths in presets.
- Mipmaps are never generated for the input texture; the chain never renders to the backbuffer itself.

### Ursprung today

- `URLibretroCore` converts every core frame (software, or GL readback for hardware cores) to XRGB8888. `MetalRenderer.uploadFrameIfNeeded` copies it into a BGRA8 `MTLTexture` (mipmapped for the ambient light) once per new `frameSerial`.
- `MetalRenderer.draw` (main thread, `MTKView` at up to 120 Hz) draws ambient light → game quad (rotation, aspect, integer scaling, filter via `Uniforms.filter`) → bezel image.
- Filters are chosen by `VideoFilter` (`Support/Preferences.swift`), globally (`videoFilter`) or per system (`videoFilter.<systemID>`); `PlayerView.filter` resolves them and passes them to `GameMetalView`.
- Screenshots are aspect-corrected and resampled (`ScreenshotStore.render`). They are **not** native-resolution frames, so they are a poor shader preview source.
- The app is not sandboxed and has `disable-library-validation` (for downloaded cores).

## Architecture

```
                         ┌───────────────────────────┐
 Core frame (BGRA8) ───▶ │ MetalRenderer             │
                         │  built-in filter ─────────┼──▶ drawable (as today)
                         │  or ShaderChain:          │
                         │   librashader passes      │
                         │   → offscreen texture     │
                         │   (output size, unrotated)│
                         │   → existing quad pass    │──▶ drawable: rotation, ambient, bezel
                         └─────────────▲─────────────┘
                                       │ chain swaps, set_param
 ShaderLibrary (index, download) ──▶ ShaderWorkspace (selection, draft, compile state)
                                       ▲
                     Player shader panel · Shader editor window
```

### Rendering

- The chain renders into an **offscreen texture of exactly the on-screen size before rotation** (the `outputSize` the renderer already computes). The existing pipeline then draws that texture 1:1 (`filter = nearest`), with rotation, ambient light and bezel unchanged. As a result:
  - integer scaling, aspect, rotation, bezel and ambient light keep working;
  - screen-space effects (masks per output pixel) stay pixel-exact because the texture matches output pixels;
  - rotated (TATE) games get scanlines along the game's own lines, like a rotated CRT. Pass `rotation = 0` to librashader.
- `frameCount` follows the core's `frameSerial`, not display refreshes, so frame history and animated shaders follow emulation speed. `frame_direction = -1` while rewinding; `clear_history = true` after state load, reset and game change.
- On any create or frame error: keep the last good chain, or fall back to the built-in `sharp` filter. Show a toast in the player and the diagnostic in the editor.
- Threading (settled by S1): preset parse and chain creation run on a background queue. The finished chain is handed to the main thread, which renders it and is the only thread that touches it. The old chain renders until the swap and is freed after the swap.
- The chain gets its own command buffer, because librashader requires an empty one. It is committed before the main render buffer on the same queue, which keeps them in order.

### Model

- `ShaderSelection` (nonisolated, `Sendable`): `.builtin(VideoFilter)` or `.preset(ShaderPresetRef)`. `ShaderPresetRef` is a path relative to the shader root plus a source (`library`, `user`).
- It is stored in the existing keys: `videoFilter` / `videoFilter.<systemID>` keep the `VideoFilter` raw values, and presets are stored as `preset:<source>/<relative path>`. Old values stay valid; there is no migration.
- Per-game override: `videoFilter.game.<uuid>`. Resolution order: game → system → all systems (extends `VideoFilter.current(for:)`). The existing `videoFilter.` backup prefix covers it, and game IDs are stable since M1. Removing a game removes its key.
- `SlangPreset`: Ursprung's own `.slangp` parser and serializer (passes, all pass keys, aliases, textures, parameter overrides, `#reference`). Its only purpose is editing; runtime loading always goes through librashader.
- No SwiftData change: everything lives in prefs and files, and LibrarySchemaV4 stays frozen.

### Files

```
Application Support/Ursprung/Shaders/
  slang-shaders/      downloaded pack, read-only for Ursprung, replaced on update
  User/               user presets and edited shaders (part of the backup)
  Drafts/<uuid>/      editor working copies (autosaved, not backed up)
Extras/<game-id>/ShaderFrames/   native-resolution frames captured for the editor
```

Library shaders are never edited in place. Editing one copies it to `User/` first (copy-on-write), and the preset is rewritten to point at the copy.

## Phases

Effort as in FEATURE_EVALUATION: S = local change, M = several components, L = new subsystem.

### Phase 0 — Spike (S, throwaway branch)

Link the prebuilt dylib into `ursprung-smoke` and add `--shader <preset.slangp>`. It renders the smoke frame through librashader on Metal and writes `smoke.png`. Use it to answer:

- **S1** Is a chain created on a background thread safe to use on the main thread? How long do `crt-royale`, `crt-guest-advanced` and Mega Bezel take to compile?
- **S2** What do compile errors look like? Do they include file and line, and how do `#include` files show up?
- **S3** Does librashader resolve `#reference` presets and parameter overrides like RetroArch?
- **S4** Does the final pass clear the output texture? Does it honour the viewport origin?
- **S5** Where is the shader cache, and does it need a location under Application Support?
- **S6** Can `libra_preset_get_runtime_params` be called cheaply for indexing (parse without compile)?

#### Spike results (5 October 2026)

The spike ran as a standalone Objective-C program in a scratch folder instead of `ursprung-smoke`. It used librashader 0.12.0 (prebuilt aarch64 dylib) and the libretro pack (2,658 `.slangp`, 81 MB unpacked). The input was a 256×224 BGRA8 test pattern; the output was 1920×1080 BGRA8. Output was correct and upright: masks and scanlines visible, no Y flip needed.

| Preset | Passes | Compile, cold | Compile, warm | Frame (1080p, incl. GPU wait) |
|---|---|---|---|---|
| zfast-crt | 1 | 419 ms | 54 ms | 0.5 ms |
| crt-easymode / crt-lottes / crt-geom | 1 | 350–440 ms | — | — |
| crt-guest-advanced | 12 | 2.3 s | 99 ms | 2.5 ms |
| crt-royale | 12 | 3.6 s | 310 ms | 3.9 ms |
| Mega Bezel `MBZ__1__ADV` | 42 | 13.1 s | 3.8 s | 15.8 ms |

- **S1 Threading**: creating a chain on a background queue and then rendering it on the main thread works. A second chain can compile in the background while the current one renders on the main thread. Under the Metal debug layer this ran without validation errors. During the Mega Bezel compile, crt-royale kept rendering 776 frames with a worst frame of 11.8 ms. "Not thread safe" means one chain must not be used from two threads at once. **Decision: compile on a background queue, swap on the main thread; no dedicated render thread.** Even single-pass presets take ~0.4 s cold, so compiling on the main thread is never acceptable.
- **S2 Errors**: glslang errors come back as `errno=6` with a Rust debug string containing `ERROR: <file name>:<line>: <message>`. The line is already mapped into `#include` files. Only the file's base name is given, not its path. Missing includes are `errno=4` with the absolute path. Preset errors are `errno=3` with a typed reason (e.g. `InvalidScaleType("nonsense")`) but no line number. The editor parses `ERROR: (.+?):(\d+): (.*)` and resolves the base name against the pass's include graph. Shader errors appear only when the chain is created, not when the preset is parsed. The editor must compile to validate, which takes ~50 ms for small shaders.
- **S3 `#reference`**: works, including multi-level Mega Bezel references. Parameter overrides in a referencing preset are reported as `initial` by `get_runtime_params`. "Reset to default" therefore needs the shader's own `#pragma parameter` value, which the editor reads itself. `set_param` changes a value live, and an unknown name returns `errno=5`.
- **S4 Output**: the final pass clears the **whole** output texture to transparent black (alpha 0), including the area outside the viewport. Inside the viewport, alpha is often 0 as well. This confirms the offscreen-texture design (drawing straight into the drawable would erase the ambient light), and the compositing pass must ignore alpha. The viewport origin is honoured.
- **S5 Cache**: the Metal runtime has no librashader cache (`filter_chain_mtl_opt_t` only has `force_no_mipmaps`). The cold/warm difference comes from the macOS Metal compiler cache (`$(getconf DARWIN_USER_CACHE_DIR)/com.apple.metal`). Ursprung needs no cache location of its own. Cold compiles of big presets need a progress indicator.
- **S6 Indexing**: `libra_preset_create_with_options` plus `get_runtime_params` parses without compiling in 0–2 ms (it reads the shader files for their pragmas). Mega Bezel reports **947 parameters**, so the parameter UI needs search, grouping (descriptions use indentation and header-like entries) and virtualised lists.
- **Other findings**:
  - The prebuilt dylib's install name is the CI build path (`/Users/runner/work/…/liblibrashader_capi.dylib`), so `install_name_tool -id @rpath/librashader.dylib` is required.
  - Its minimum macOS is 11.0, it is arm64 only and ad-hoc signed; Xcode re-signs it on embed.
  - The release zip has no licence file; take `LICENSE` from the upstream tag.
  - The zip also has a static `librashader.a` (25 MB), but upstream does not officially support static linking.
  - A preset declaring `shaders = 2` with only `shader0` loaded without error. `SlangPreset` should validate such presets itself.

### Phase 1 — Dependency (S)

- `ThirdParty/librashader/`: committed headers (`librashader.h`), a README (version, update steps, licence, source link) and `LICENSE`. Same pattern as rcheevos.
- `Scripts/fetch-librashader.sh`: downloads the pinned release zip, checks its SHA-256 and extracts `librashader.dylib` into a git-ignored folder. It sets the install name to `@rpath/librashader.dylib`. Called from `make project`; CI caches it.
- `project.yml`: link and embed the dylib (Frameworks, code-signed on copy), header search path, `LD_RUNPATH_SEARCH_PATHS` includes `@executable_path/../Frameworks`. Link directly; `librashader_ld` is not needed because the dylib always ships with the app.
- Update CLAUDE.md "Hard rules" (agreed dependencies), the About/acknowledgements and `docs/ARCHITECTURE.md`.
- Acceptance: `make build`, `make test`, CI and `make dist` (signing, notarization check) pass with the dylib embedded.

**Done 6 October 2026.**
- XcodeGen embeds the dylib through a `framework:` dependency. It also needs `LIBRARY_SEARCH_PATHS`, because XcodeGen only adds a framework search path.
- `URShaderPreset` (Bridge) reads a preset's parameters. It proves that the dylib loads at runtime and is used again in phases 3–4. `ShaderPresetTests` cover parameters, `#reference` overrides and errors.
- `make test`: 267 tests green.
- `SKIP_NOTARIZE=1 make dist`: the dylib is signed with the app's identity, hardened runtime and a timestamp. The Release app is 22 MB.

### Phase 2 — Render path (M)

- `ShaderChain` (Objective-C in `Bridge/` or Swift over the C API): owns the `libra_shader_preset_t` and `libra_mtl_filter_chain_t`; `frame(input:output:commandBuffer:frameCount:options:)`, `setParameter`, `activePassCount`; error type carrying librashader's message.
- `MetalRenderer`:
  - `selection: ShaderSelection` replaces `filter`;
  - an offscreen render target, reallocated when the output size changes;
  - the chain pass is encoded before the main render pass;
  - frame bookkeeping (serial, direction, history clear).
- `EmulationSession` exposes rewind direction and history-clear events to the renderer.
- Acceptance: a library preset, set in prefs, runs on NES/SNES/GBA/PSX/N64 (GL core) with rotation, integer scaling, bezel and ambient light. Fallback works when a file is missing. A smoke render test runs in CI.

**Done 6 October 2026.**
- `ShaderChain` (Objective-C, `Bridge/URShaderChain`) wraps preset parsing with a wildcard context (core name, rotation), chain creation, `frame`, parameters and the active pass count.
- `ShaderSelection` / `ShaderPresetRef` decode the `videoFilter` keys (system → all systems; the per-game key follows in phase 4). Preset paths that leave their folder are rejected.
- `MetalRenderer`: `PresentationLayout` (pure, tested) places the picture on whole pixels, and the vertex shader got an `offset` uniform for it, so the chain output maps 1:1. The chain pass runs only when a new frame, a new output size or a new chain arrives. `frameCount` is the core's `frameSerial`, `frame_direction` is -1 while rewinding, and frame time and FPS feed the frametime uniforms.
- **No history clearing.** librashader 0.12.0 (also on master) clears the frame history in a render pass with one colour attachment per history texture. For presets without history the pass has no attachments: `frame` fails with `FailedToCreateCommandBuffer`, and under Metal API validation it is an assertion. The C API does not say whether a preset has history, so `clear_history` is never set and the session sends no history-clear events. After a state load or reset, history effects (motion blur, phosphor persistence) blend a few old frames. Revisit when `SlangPreset` (phase 5) can tell whether a preset uses `OriginalHistory`/feedback, or when upstream fixes it.
- librashader's `*_free` functions panic (and print) on null handles, although the header says they do nothing; the bridge only frees non-null handles.
- Verified: `ursprung-smoke` with `URSMOKE_SHADER=<preset>` (and `URSMOKE_SHADER_HEIGHT`) rendered crt-royale (NES), crt-guest-advanced (SNES), lcd-grid-v2 (GBA), zfast-crt (PSX, Swanstation hardware) and crt-easymode (N64, GLideN64). In the app: crt-royale with integer scaling and ambient light, a live switch to an LCD preset, the missing-file fallback with its toast, and crt-guest-advanced while rewinding, all at 60 fps. Rotation is covered by `PresentationLayoutTests` only; no vertical game was at hand.
- CI: `ShaderChainTests` render a fixture preset on the GPU and check pixels, parameter changes and compile errors. `make test`: 276 tests green.
- Prefs written from outside the app (`defaults write videoFilter.<system>`) only reach a running player when an `@AppStorage` key changes too; `UserDefaults.didChangeNotification` is in-process only. Settings changes made in the app are not affected.

### Phase 3 — Shader library (M)

- `ShaderLibrary` (`@Observable`, injected in `UrsprungApp`):
  - download `https://buildbot.libretro.com/assets/frontend/shaders_slang.zip` (~54 MB) with progress, unpack atomically (staging folder, then move), and run the update check via `Last-Modified` like `CoreManager`;
  - index all `.slangp` files: category = top folder (crt, handheld, scanlines, …), name, parameter count, pass count;
  - user folder, import via file picker, drag and drop of `.slangp`/folders, favorites.
- Settings › Emulation: "Shaders" section (download/update/remove, size, user folder in Finder). The filter picker gets a "RetroArch Shaders…" entry that opens a searchable browser with categories and favorites.
- Backup: `DataLocations` gains `shaders` (`Shaders/User/` only). `BackupService` writes and restores it like `bezels`. After a restore, if prefs point at library presets and the pack is missing, the app offers the download.
- Acceptance: the pack downloads, updates and is removable. The index finds all presets in under a second on warm launch, or is cached. A backup round trip restores user presets together with their assignments.

**Done 6 October 2026.**
- `ShaderLibrary` (`Emulation/`) downloads the pack through `HTTPDownload` (shared with `CoreManager`), unpacks it next to `slang-shaders/` on all cores (0.6 s for 5,742 files) and swaps it in only when complete; an archive without presets leaves the installed pack alone. `pack.json` records the install date for the Last-Modified update check.
- Index: `ShaderIndex` lists every `.slangp` (2,658 in the pack) with category, folder, pass count and parameter count. Pass counts come from `SlangPresetFile`, a small reader for `#reference` and `key = value` lines that phase 5's `SlangPreset` can grow from; parameter counts and load problems come from librashader (parse only, concurrent). `Shaders/index.json` caches the results by file date: the first index takes 4.3 s in the background, later ones 0.5 s.
- 12 pack presets fail to parse in librashader 0.12.0 (missing textures in koko-aio PSP presets, a quoted path in the adamant WOLED presets, a bool parse error in `crt-black_crush-koko`, a directory include in a crt-beam-simulator preset). The browser marks them with a warning and librashader's message. Presets without a pass count are parameter fragments (`koko-aio/refs/`) and Mega Bezel's `$CORE$` wildcard examples.
- Import (file panel or drop on the browser) copies folders as they are. A single preset takes along every file it reads (`#reference`, shaders, `#include`, textures) in the same layout relative to their common folder, so its relative paths keep working; files it names but that don't exist are reported.
- UI: `ShaderPicker` replaces the filter pickers in Settings › Emulation (all systems and per system): built-in filters, favourites, the selected preset and "RetroArch Shaders…", which opens `ShaderBrowser` (categories, favourites, My Shaders, search, pass counts with a warning colour from 20 passes). The browser opens in the current preset's category and scrolls to it. Settings › Emulation has a "RetroArch Shaders" section for the pack (download, check for updates, download again, remove) and the user folder. Favourites are a backed-up pref (`shaderFavorites`).
- Backup: `DataLocations.shaders` = `Shaders/User/`, written as `Shaders/` and restored like bezel images (only missing files). After a restore with settings that name pack presets, the app offers to download the pack.
- SwiftUI's outline-based `List` crashes (`ViewListTree.visitItem`) when `ScrollViewReader.scrollTo` runs while the list's data is being replaced, e.g. right as the sheet opens and the index refreshes. The browser scrolls only after the index is done, and the library only republishes the preset list when it changed.
- Tests: `SlangPresetFileTests`, `ShaderLibraryTests` (index, cache, install/update/remove with a fake download, import, favourites) and an opt-in run against the real pack (`TEST_RUNNER_URSPRUNG_SHADER_PACK=<zip> make test`). Verified in the app: download from the buildbot, browser, favourites in the menus, per-system choice, update check.

### Phase 4 — Player shader panel (M)

- A panel in the player (pause menu entry plus a hotkey):
  - **Placement**: an overlay at the trailing edge, in the player's existing overlay zones. It is not a sidebar, so the game keeps its real output size; CRT masks and scanlines depend on it.
  - **Behaviour**: while a slider is dragged, everything but that slider fades out. Holding a key hides the panel entirely.
  - **Contents**:
    - switch presets with live preview (built-in and library);
    - parameter sliders from `get_runtime_params`, applied live with `set_param`, with reset per parameter and for all;
    - "Save as Preset…", which writes a `#reference` preset with parameter overrides to `User/` (RetroArch-compatible);
    - "Apply to": this game / this system / all systems;
    - "Open in Shader Editor".
- The game inspector in the library shows when a game has its own shader.
- Acceptance: parameter changes appear in the next frame without a recompile. Saved presets load in RetroArch too. Game → system → all resolution is covered by tests.

**Done 6 October 2026.**
- `ShaderScope` (game / system / all) stores a choice at one level; `videoFilter.game.<uuid>` wins over the system's and all systems' keys. Removing a game deletes its key; when discs join into one game, the surviving game takes over the other's key if it has none.
- `ShaderWorkspace` (owned by `EmulationSession` as `session.shader`) connects renderer and panel: compile status, parameters, live values and the values the preset sets. `ShaderChain` now reads the parameters during compilation (same wildcard context as rendering). A slider calls `set_param` and marks the chain pass dirty, so changes also show while paused.
- Panel (`ShaderPanel`, top trailing, 320 pt, dark-tinted glass): "Applies To" (this game / all games of the system / all systems), the `ShaderPicker` of that level with its inherited choice, compile and error status, and a note when a more specific level decides the picture. Parameters with search (from 9), section titles (min = max), per-parameter and "Reset All", values in accent colour when changed. Up to 24 parameters the panel hugs its content; more scroll in a lazy list. While a slider is dragged, everything else (including the glass) fades out and the row gets its own glass; holding ⌥ alone hides the panel. Esc and the menu key close it; opening the game menu closes it.
- The game keeps running with the panel open (pause button in the header), so animated and history effects can be tuned. Keys keep reaching the game until a field in the panel is clicked; clicking the game returns them.
- Entry points: pause menu row "Shader…", hotkey `shaderPanel` (F6, configurable), Game › Show Shader Panel. The library's game inspector has a "Shader" picker ("Same as System (…)" or the game's own).
- "Save as Preset…" (`ShaderPresetWriter`) writes a RetroArch simple preset: `#reference` (relative path) plus the parameters that differ from the referenced preset, quoted like RetroArch. Presets that only reference one preset and set its parameters are skipped as a base, so saving over a saved preset never references itself and references don't pile up; presets that change more than parameters stay the base. The file goes to `User/` (or next to the current user preset), replacing asks first, and the saved preset becomes the choice of the panel's level. Saving over the preset in use recompiles it.
- Not done here: "Open in Shader Editor" comes with the editor (phase 5). Unsaved parameter changes last until the game closes, like RetroArch.
- Verified in the app (NES, crt-geom): live parameter changes, save as preset (file content checked, NES switched to it), per-game built-in filter from the inspector applied to the running game, and the override note. Not verified with real input: slider drag fading and ⌥ peeking (no pointer or key events were sent). `make test`: 297 tests (1 opt-in skipped).

### Phase 5 — Shader editor (L)

A separate window (`WindowID.shaderEditor`), opened from:

- the player panel;
- Settings;
- the menu bar (Window › Shader Editor);
- the library: the context menu of a system or game. From a game, the editor opens in still mode with that game's captured frames.

If a game starts while the editor is open, the editor switches to live preview; only one core runs at a time.

- **Pass list** (sidebar):
  - add passes from the library or a new empty pass (template);
  - reorder by drag;
  - duplicate and remove;
  - preset-level LUT textures and aliases.
- **Pass inspector**:
  - `scale_type` / `scale_x` / `scale_y`, `filter_linear`, `wrap_mode`, `mipmap_input`, `float_framebuffer`, `srgb_framebuffer`, `frame_count_mod`, `alias`;
  - every change rewrites the draft `.slangp` and recompiles.
- **Source editor** for the selected pass's `.slang`:
  - `NSTextView` (TextKit 2) in `NSViewRepresentable`;
  - own tokenizer for GLSL/slang highlighting (keywords, types, builtins, `#pragma parameter`/`stage`/`name`, `#include`, numbers, comments);
  - line-number ruler, `NSTextFinder` find/replace, undo;
  - opens `#include`d files in tabs;
  - live recompile 400 ms after the last keystroke, on a background queue; the last good chain keeps rendering;
  - errors listed below and marked inline in the gutter; click to jump (line mapping per S2).
- **Parameters**: sliders as in phase 4, grouped by pass.
- **Preview**:
  - *Live*: the editor drives the running player through `ShaderWorkspace`, and the player window is the preview. The game can be paused and stepped frame by frame from the editor.
  - *Still*: an embedded `MTKView` with the same `MetalRenderer`, fed from:
    - built-in test patterns generated in code (colour bars, grey ramp, checkerboard/dither, 1-px grid, small text) at 160×144, 256×224, 320×240 and 640×480;
    - captured native frames ("Capture Frame for Shader Editor" in the pause menu);
    - any image file (with a source resolution field).
  - `frameCount` advances so time-based shaders animate.
  - Tools:
    - before/after split slider;
    - zoom loupe (1×–8×, nearest);
    - "show output after pass N" via `set_active_pass_count`;
    - output size presets (window, 1080p, 1440p, 4K);
    - GPU time per frame from `MTLCommandBuffer.gpuStartTime/gpuEndTime`.
- **Drafts**:
  - autosave to `Drafts/<uuid>/`;
  - "Save" writes to `User/`, with copy-on-write for library shaders;
  - "Revert";
  - "Reveal in Finder";
  - "Export…" as a folder or zip with all referenced user shaders.
- Acceptance:
  - a new preset can be built from two library passes plus an edited copy of one shader, saved, and assigned to a system;
  - a syntax error shows inline within a second and the previous image keeps running;
  - all of this works without a running game.

**Done 6 October 2026.**
- Model: `SlangPreset` reads and writes every pass, texture and value key (unknown keys are kept; comments are not). `SlangPreset.load` resolves `#reference` chains into one preset with absolute paths, fills RetroArch wildcards in referenced paths (falling back to the literal path, like RetroArch) and resolves texture paths that Mega Bezel's `.params` files set for names declared elsewhere. The opt-in round trip over the pack (`TEST_RUNNER_URSPRUNG_SHADER_PACK=<zip>`) writes every resolved preset next to its original and compares librashader's parameters: 2,626 presets checked, no differences. Presets with a line without `=` (patchy-ntsc) are skipped: librashader then also drops the next line.
- `SlangSource` reads `#pragma parameter` lines (the shader's own defaults), `#include` closures and glslang's `ERROR: file:line: message` lines; `SlangTokenizer` colours slang.
- Drafts (`ShaderDrafts`): `Shaders/Drafts/<id>/` with `draft.json`, `preset.slangp` and `files/`. The first change to a pack or user file copies the pass shader with all its includes into `files/library/…` or `files/user/…` (shared includes once), so relative includes keep working; the pack is never written. Save writes `User/<name>.slangp` and the draft's own files into `User/<name>/`; saving over the user preset the draft came from writes copies of user files back. After saving, the editor continues on the saved preset. Export copies the preset with every file it reads into a folder that works on its own (zip via `NSFileCoordinator`'s `.forUploading`). Only the current draft is kept.
- Renderer: `FrameSource` (the core or a `StillFrame`), so the editor's own `MTKView` uses the same `MetalRenderer`. A recompile of the preset that is showing keeps the previous chain when it fails (`ShaderWorkspace.compileError`). Preview tools in `ShaderWorkspace.previewTools`: split comparison (scissored second draw of the unprocessed frame), zoom 1–8× around a draggable focus (instead of a loupe that follows the pointer), output sizes 1080p/1440p/4K (rendered at that size and scaled into the view), GPU time from the chain's command buffer.
- **"Show output after pass N" does not use `set_active_pass_count`**: with crt-royale it makes librashader 0.12.0 panic in the next `frame` (index out of bounds in `framebuffer.rs`), which aborts the app. The editor writes `preview-<N>.slangp` with the first N passes next to the draft and compiles that.
- `EmulationRunner.stepFrame()` runs one frame while paused (no sound) for the editor's Next Frame.
- Editor window (`WindowID.shaderEditor`): passes in the sidebar (add from a preset or a template pass, duplicate, remove, reorder), the preview above the source, inspector pages Pass / Parameters (grouped by the pass that declares them, in declaration order; librashader's own list is unordered) / Textures. Source editor: TextKit 2 `NSTextView` per open tab (own undo), find bar, line-number ruler with error marks, error lines highlighted, recompile 400 ms after the last keystroke, error list that jumps to the line. With a game running, the player shows the draft (`ShaderWorkspace.editorPreset`) and the tools apply there.
- Entry points: Window › Shader Editor (⌥⌘E), the player's shader panel ("Open in Shader Editor"), Settings › Emulation, the Edit Shader… item of games and of systems in the sidebar (a game's captured frames become the still picture), pause menu "Capture Frame for Shader Editor" (`Extras/<game>/ShaderFrames/`, aspect ratio in the PNG description). ⌘S saves while the editor is the key window. Debug builds: `URSPRUNG_SHADER_EDITOR=<preset:library/…|preset:user/…|system id|new>`.
- AppKit traps: a `VSplitView` in the detail column sent AppKit into an endless constraint update loop (the preview bar's minimum width changes); the editor uses its own draggable split and a horizontally scrolling preview bar. `NSRulerView` subclasses don't clip their drawing (macOS 14+): the ruler painted its background over the text until it clipped to its bounds.
- Verified in the app: new shader, live recompile, syntax error inline while the last picture stays, crt-royale opened from the pack (12 passes, textures), copy on first edit, Save as "Royale Test" (file layout checked), parameters, live mode on Super Mario Bros. with compare and "up to pass 1". Not verified with real input: dragging the split divider and the zoom focus, Use For, export, adding passes from the browser. `make test`: 315 tests.

### Phase 6 — Polish (S–M)

- German localization for all new strings; accessibility labels on editor controls.
- The player's shader panel lists parameters in librashader's order, which can differ from the declaration order (crt-royale); sort them like the editor does.
- Performance warning when GPU time exceeds the frame budget.
- Docs: README feature list, ARCHITECTURE.md (render path, ShaderLibrary), a user-facing shader doc.
- `debug-without-ui` additions: `URSPRUNG_SHADER=<preset>`, `URSPRUNG_SHADER_PARAMS=…`, and a snapshot of the shader editor.

**Done 6 October 2026.**
- Localization: an `xcodebuild -exportLocalizations` run showed every shader string translated; the four new strings of this phase have German too. Accessibility: the editor's pass rows read as one element, icon-only marks (edited, not in preview, errors, GPU warning) have labels, decorative symbols are hidden, and the divider between preview and source is an adjustable element ("Preview Height").
- Parameter order: librashader lists parameters in an order of its own (crt-royale starts with `bloom_*`). `SlangSource.declarationOrder` reads the `#pragma parameter` lines pass by pass (each pass's file, then its includes); the renderer sorts the compiled chain's parameters by it on the compile task, so the panel and the editor's parameter list see the shaders' order. Names the files don't declare keep librashader's order at the end.
- Performance warning: the renderer passes the frame budget (`1 / fps` of the source) with every GPU time. `ShaderWorkspace.isTooSlow` turns on after two half-second averages over the budget and off after two within it. The panel shows "Too demanding for this Mac" with the times, the editor's GPU time turns orange with a warning symbol and the times in its help, and the player shows one toast per preset and app run (not while the editor previews on the game). Mega Bezel (SMOOTH-ADV-GLASS) on Super Mario Bros. in a 1024×768 window measured about 13 ms against 16.6 ms, so it doesn't warn there.
- Docs: `docs/SHADERS.md` (user guide), README feature list and data table, an ARCHITECTURE.md *Shaders* section.
- Debug builds: `URSPRUNG_SHADER=<filter|preset:…>` replaces the player's choice (the panel still shows the stored one), `URSPRUNG_SHADER_PARAMS=NAME=value,…` sets parameters of every preset that loads; with `URSPRUNG_SNAPSHOT_DIR`, the renderer writes the preset's output as `shader-output.png` (player) and `shader-editor-preview.png` (editor still preview) every two seconds, and `session.txt` adds status, GPU time, budget, `tooSlow` and the first parameters.
- Verified in the app: crt-royale on Super Mario Bros. with two parameters set from the environment (`session.txt` and the panel list the parameters in declaration order, `shader-output.png` shows the mask); with the budget divided by four in a temporary patch, the German toast and the panel's warning appeared; the editor's still preview snapshot. Not verified: the editor's orange GPU label (crt-royale stays under the budget in the small preview) and VoiceOver itself. `make test`: 317 tests.

## Tests

- `SlangPreset` round trip: parse and serialize every `.slangp` in the downloaded pack (opt-in test, needs the pack) plus checked-in fixtures (always run).
- Tokenizer: highlighting ranges for fixtures with comments, pragmas and includes.
- `ShaderSelection`: old pref values decode unchanged; preset refs round-trip; game → system → all resolution.
- Backup: `Shaders/User/` round trip; a removed game loses its `videoFilter.game.` key.
- `ShaderLibrary`: index, update replacement (staging), import, copy-on-write.
- Renderer: offscreen size and viewport math (pure functions extracted from `makeUniforms`).
- Smoke: `ursprung-smoke --shader` renders a fixture preset; pixel checks in CI (runners have Metal).

## Risks

| Risk | Mitigation |
|---|---|
| Metal runtime not thread safe → compile stalls the UI | Resolved by S1: background compile, main-thread use, one owner per chain |
| Large presets compile for seconds (Mega Bezel 13 s cold) | Background compile, last good chain keeps rendering, progress indicator |
| Error lines in `#include` files | Resolved by S2: messages carry base name and line; resolve against the include graph |
| Heavy presets miss the frame budget (Mega Bezel ~16 ms at 1080p) | GPU-time display and warning; note heavy presets in the browser |
| Huge parameter lists (947 in Mega Bezel) | Search, grouping, lazy lists in panel and editor |
| Upstream API/ABI changes | Pin the version and its checksum; update deliberately via the README steps |
| Shaders written for RetroArch quirks fail in librashader (stricter parser) | Show the error, fall back; list known-incompatible presets in the browser |
| Pack licences vary per shader | Ursprung does not redistribute the pack: users download it from libretro |
| Dylib size (+ ~25 MB unpacked) | Acceptable; check app size in `make dist` |

## Resolved questions (5 October 2026)

1. **Q1 Player panel: overlay, not a sidebar.**
   - A sidebar shrinks the game, which changes the output size that masks and scanlines depend on. Users would tune a shader at a size they don't play at, especially in full screen.
   - The player already places overlays in fixed zones.
   - Fading while dragging and hold-to-hide solve the occlusion. Longer sessions belong in the editor window, which sits next to the player.
2. **Q2 Editor from the library: yes.**
   - Still mode is needed anyway for when no game runs, so the extra entry points cost almost nothing.
   - Opening from a game preloads its captured frames.
3. **Q3 Back up `Shaders/User/`: yes, nothing else.**
   - Backups already carry `videoFilter.*` and bezel images. Restoring an assignment without its preset file would silently fall back to the default filter.
   - The pack (~100 MB) can be downloaded again, and drafts are temporary.
   - Captured frames are in `Extras/` and are already backed up.
4. **Q4 Per-game shaders: yes, in phase 4.**
   - It is one pref key, already covered by the backup prefix.
   - Real cases:
     - Mega Drive games that fake transparency with dithering want a blending shader that blurs other games;
     - vertical arcade games;
     - PS1 games that switch between 240p and 480i.
