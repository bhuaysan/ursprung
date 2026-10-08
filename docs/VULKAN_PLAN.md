# Ursprung — Vulkan Hardware Rendering through MoltenVK: Plan

7 October 2026 · based on commit 2b278e1 (main). Status: questions resolved (7 October 2026); spike and phases 1–4 done on branch `feature/vulkan` (8 October 2026); phase 5 not needed for now (S3); phase 6 blocked on test content. Comes after `docs/STANDALONE_PLAN.md` (Q6).

Ursprung gives libretro cores an OpenGL 4.1 context (`URGLContext`) and nothing else. `SET_HW_RENDER` refuses Vulkan, and `GET_PREFERRED_HW_RENDER` answers OpenGL core. This plan adds a Vulkan context through MoltenVK, so cores can use their Vulkan renderers. The result still goes through Ursprung's Metal presentation, shaders, screenshots and save states.

Acceptance is defined by two systems that gain the most: **N64** (paraLLEl-RDP instead of the angrylion software renderer) and **GameCube/Wii** (Dolphin's Vulkan backend instead of Apple's OpenGL).

## Decisions

| Topic | Decision |
|---|---|
| Vulkan implementation | MoltenVK (Apache-2.0), prebuilt from the KhronosGroup release, linked directly (no Vulkan loader), embedded in the app like librashader |
| Frame handoff, first version | Read back into the existing CPU frame buffer, like the GL path. Shaders, screenshots, rewind, autosave thumbnails and the smoke tool work unchanged |
| Frame handoff, later | Zero-copy into a Metal texture through `VK_EXT_metal_objects` (phase 5) |
| API per core | `CoreDefinition.renderer` (`.opengl` default, `.vulkan`) drives `GET_PREFERRED_HW_RENDER` and option defaults. Users can override it per core (Automatic / Vulkan / OpenGL) |
| Fallback | If MoltenVK or device creation fails, `SET_HW_RENDER` returns false and the core uses its OpenGL or software path. Ursprung shows a toast once |
| Systems in scope | N64, GameCube/Wii (acceptance); Dreamcast and PlayStation (defaults after the spike); PSP stays on OpenGL unless the spike shows a gain |
| Out of scope | PS2 (LRPS2 hangs regardless of renderer, see `docs/STANDALONE_PLAN.md`), Wii U (Cemu), Vulkan for Ursprung's own rendering, librashader's Vulkan runtime |

## Background

### Test results (7 October 2026)

There was no Vulkan support in Ursprung to test with. The tests used the official RetroArch 1.22.2 (MoltenVK 1.3.0), copied to a scratch folder with its own config, on an Apple M4, with buildbot cores (macOS arm64, 6 October). Each run lasted 30–45 s.

| System | Core / renderer | Game | Result |
|---|---|---|---|
| N64 | Mupen64Plus-Next, paraLLEl-RDP + paraLLEl-RSP | Ocarina of Time | Correct title screen, ~34 % CPU |
| GameCube | Dolphin, Vulkan | MGS: The Twin Snakes | Boots, intro renders |
| Dreamcast | Flycast, Vulkan, 1920×1440 | Sonic Adventure | Intro renders |
| PlayStation | SwanStation, Vulkan, 4× | Castlevania: SOTN | Intro renders |
| PlayStation | Beetle PSX HW, `hardware_vk` | Castlevania: SOTN | Boots (Konami logo) |
| PSP | PPSSPP, Vulkan | Valkyrie Profile | Title menu correct |
| PS2 | LRPS2, Vulkan | Persona 4 | Fails: `Failed to allocate expansion index buffer`, then a crash in `GSDeviceVK::Destroy` |
| PS2 | LRPS2, paraLLEl-GS | Persona 4 | Intro renders, then hangs on the loading icon (same as with the software renderer) |

All runs quit cleanly on SIGTERM. MoltenVK logs `VK_ERROR_FEATURE_NOT_PRESENT: Metal does not support disabling primitive restart` for paraLLEl-GS; the others ran without MoltenVK warnings in the filtered log.

For comparison, Dolphin through Ursprung's OpenGL path (`ursprung-smoke`, same game) reaches the menu but shows *"Your OpenGL driver does not support ARB_buffer_storage"* and *"This device's performance may be poor"*.

### What each system gains

| System | Today | With Vulkan |
|---|---|---|
| N64 | angrylion (CPU, native resolution). GLideN64's frame buffer emulation renders black on Apple GL | paraLLEl-RDP: accurate like angrylion, on the GPU, with upscaling |
| GameCube / Wii | Dolphin on GL 4.1, "experimental", warns about poor performance | Dolphin's Vulkan backend; candidate to drop "experimental" |
| Dreamcast | Flycast on GL. The macOS build has no GL4 backend, so per-pixel alpha sorting (OIT) is missing | Flycast's Vulkan OIT renderer (`core/rend/vulkan/oit`) is compiled in |
| PlayStation | SwanStation GL; Beetle PSX is the software core | SwanStation Vulkan; **Beetle PSX HW** becomes a new core option (accurate, upscaling, PGXP) |
| PSP | PPSSPP on GL, works | Small gain |
| 3DS (new) | Not supported | Azahar's macOS build offers only Software and Vulkan. Untested (no 3DS games available); phase 6 |

### libretro's Vulkan contract

- The core asks with `SET_HW_RENDER` (`RETRO_HW_CONTEXT_VULKAN`) and usually with `SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE` (`retro_hw_render_context_negotiation_interface_vulkan`, v1 `create_device`, v2 `create_instance`/`create_device2`). The frontend creates the instance, lets the core pick device features, and creates the device.
- After `context_reset` the core gets `retro_hw_render_interface_vulkan` through `GET_HW_RENDER_INTERFACE`: `instance`, `gpu`, `device`, `queue`, `queue_index`, `get_*_proc_addr`, `set_image`, `get_sync_index`, `get_sync_index_mask`, `wait_sync_index`, `set_command_buffers`, `lock_queue`/`unlock_queue`, `set_signal_semaphore`.
- Per frame the core renders into its own `VkImage`, calls `set_image(image, semaphores, src_queue_family)` and then `video_refresh(RETRO_HW_FRAME_BUFFER_VALID, …)`. The image is in `SHADER_READ_ONLY_OPTIMAL`.
- Sync indices emulate a swapchain. The core keeps per-frame resources for each index and must not reuse them before the frontend's GPU work for that index is done.
- Some cores submit from their own threads (Dolphin, PPSSPP, LRPS2) and rely on `lock_queue`.
- The header is `libretro_vulkan.h` from libretro-common (MIT). RetroArch's `gfx/drivers/vulkan.c` and `gfx/common/vulkan_common.c` are the reference implementation (GPL-3.0-or-later, compatible).

### Ursprung today

- `URLibretroCore` answers `GET_PREFERRED_HW_RENDER` with `RETRO_HW_CONTEXT_OPENGL_CORE`, creates `URGLContext` in `SET_HW_RENDER`, and returns false for every other context type and for the negotiation and interface environment calls.
- `URCoreVideoRefresh` reads a GL frame back with `readPixelsWidth:height:bottomLeftOrigin:destination:` into `_back` (BGRA8, CPU) and publishes it. `MetalRenderer` uploads it into a texture once per new `frameSerial`; shaders, screenshots, rewind and thumbnails all start from that buffer.
- All `retro_*` calls run on the `UREmulationRunner` thread. `unloadGame` calls `context_destroy`, then `unload_game`, then `deinit` (same order as RetroArch).
- `ursprung-smoke` links the same bridge, so a Vulkan path in `URLibretroCore` is testable headlessly with `make smoke`.

## Architecture

```
 core (runner thread)
   │ SET_HW_RENDER(VULKAN) + negotiation
   ▼
 URVulkanContext ── MoltenVK (VkInstance, VkDevice, queue, lock)
   │ set_image(image, semaphores)          ┌───────────────────────────┐
   │ video_refresh(HW_FRAME_BUFFER_VALID) ─▶│ phase 2: copy image →      │
   │                                        │ host-visible buffer, fence │──▶ _back (BGRA8) ─▶ MetalRenderer (as today)
   │                                        │ phase 5: blit → VkImage    │
   │                                        │ backed by an MTLTexture    │──▶ MetalRenderer texture (no CPU copy)
   │                                        └───────────────────────────┘
   └ sync index ring (2 frames), fences per index
```

### Bridge

- `URVulkanContext` (Objective-C, `Ursprung/Bridge/`), parallel to `URGLContext`:
  - `-initWithNegotiation:(const struct retro_hw_render_context_negotiation_interface_vulkan *)…`: creates the instance (application info from the core if given, `VK_KHR_portability_enumeration` not needed without a loader), picks the Apple GPU, calls the core's `create_device`/`create_device2` or creates a default device with one graphics+compute queue. If the device exposes `VK_KHR_portability_subset`, it is enabled.
  - Implements `retro_hw_render_interface_vulkan` with C trampolines (like the other `URCore*` callbacks) and a queue mutex for `lock_queue`.
  - Per sync index: a command buffer, a fence and a readback buffer (`HOST_VISIBLE | HOST_COHERENT`), sized to `max_width × max_height × 4`.
  - `-readImageWidth:height:destination:`: records barrier + `vkCmdCopyImageToBuffer`, waits on the core's semaphores, submits with the index's fence, waits on it, converts the format into BGRA8 (`R8G8B8A8`, `B8G8R8A8` and `A2B10G10R10` are the formats seen in practice) and advances the sync index.
  - Teardown: `vkDeviceWaitIdle`, the core's `destroy_device` (negotiation v2), then the device and instance.
- `URLibretroCore`:
  - `GET_PREFERRED_HW_RENDER` returns the context type from `renderer`, which Swift sets before `loadGame` (`URLibretroCore.preferredRenderer`).
  - `SET_HW_RENDER` accepts `RETRO_HW_CONTEXT_VULKAN` and keeps the callback; `SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE` stores the core's interface; `GET_HW_RENDER_INTERFACE` returns the Vulkan interface after the context exists; `GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT` reports the supported version (2).
  - `loadGame` creates the Vulkan context where it calls `context_reset` today; `unloadGame` destroys it in the same place as GL.
  - `URCoreVideoRefresh`: `HW_FRAME_BUFFER_VALID` with a Vulkan context goes to `URVulkanContext` instead of `URGLContext`.
- MoltenVK is linked directly. `vkGetInstanceProcAddr` from the dylib is the only entry point handed to cores.

### Model and settings

- `CoreDefinition.renderer: HardwareRenderer` (`.opengl` default, `.vulkan`). It is what Ursprung asks the core for. A Vulkan core keeps working on GL when Vulkan is unavailable, because the core falls back itself.
- `Preferences.rendererChoice(for coreID:)`: `automatic` (catalog value), `vulkan`, `opengl`. Settings › Cores shows it only for cores whose catalog entry has Vulkan.
- Option defaults move with the renderer (applied only when the resolved renderer is Vulkan):
  - `mupen64plus_next`: `mupen64plus-rdp-plugin = parallel`, `mupen64plus-rsp-plugin = parallel`
  - `parallel_n64`: `parallel-n64-gfxplugin = parallel`
  - `mednafen_psx_hw` (new core): `beetle_psx_hw_renderer = hardware_vk`
  - `swanstation`: `swanstation_GPU_Renderer = Vulkan`
  - Dolphin and Flycast follow `GET_PREFERRED_HW_RENDER`; no option needed.
- Save states record the renderer in `SaveStateContext`. A state saved with paraLLEl-RDP may not load with angrylion (RDP state differs); the existing "made with another core version" warning gets a "made with another renderer" variant.

## Phases

Effort as in FEATURE_EVALUATION: S = local change, M = several components, L = new subsystem.

### Phase 0 — Spike (S–M, throwaway branch)

Add a minimal Vulkan context to `ursprung-smoke` only (readback, one sync index, no negotiation v2 if not needed). Run Mupen64Plus-Next (paraLLEl-RDP), Dolphin, Flycast and SwanStation against the user's games and write `smoke.png`. Answer:

- **S1** Which negotiation versions and callbacks do these four cores use? Which device extensions and features do they request, and does MoltenVK 1.4.2 grant them?
- **S2** Speed: frames per second uncapped for Ocarina of Time (paraLLEl-RDP, 1× and 2×) and the Dolphin intro, compared with angrylion and Dolphin on GL in `ursprung-smoke`.
- **S3** Readback cost at 1×, 2×, 4× internal resolution (ms per frame). Is phase 5 needed for the acceptance games, or only for high upscaling?
- **S4** Image formats and orientation per core (origin, sRGB, 10-bit).
- **S5** Teardown: do the cores' `context_destroy`/`deinit` free cleanly with MoltenVK? Repeat each 12 times (the Play! check from `STANDALONE_PLAN.md`).
- **S6** Save states with paraLLEl-RDP and Dolphin Vulkan: save, load, size, and loading a state across renderers.
- **S7** MoltenVK configuration: does any core need `MVK_CONFIG_*` settings (e.g. `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS`, `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS`) for correctness or speed?

#### Spike results (8 October 2026)

The spike ran on the real bridge instead of a throwaway context: phases 1 and 2 were built first, and `ursprung-smoke` gained what the questions needed (`URSMOKE_RENDERER`, `URSMOKE_LIST_OPTIONS`, `URSMOKE_REPEAT`, `URSMOKE_SAVE_STATE`/`URSMOKE_LOAD_STATE`, the time per frame spent in the core, and `URSPRUNG_VULKAN_LOG=1` for the context's log). Apple M4, MoltenVK 1.4.2, buildbot cores of 8 October (PPSSPP of 29 September), the user's games. Besides the four cores of the plan, Beetle PSX HW, PPSSPP and Azahar were checked.

- **S1** Negotiation: Dolphin uses v2 (`create_instance` with `VK_EXT_layer_settings`, through which it configures MoltenVK itself, then `create_device2`); Mupen64Plus-Next (Granite), Flycast, SwanStation, Beetle PSX HW, PPSSPP and Azahar use v1 `create_device`. MoltenVK grants everything they ask for: paraLLEl-RDP enables 18 device extensions (8/16-bit storage, float16/int8, subgroup size control, timeline semaphores, synchronization2, …), Dolphin `VK_EXT_memory_budget` and `VK_KHR_sampler_mirror_clamp_to_edge`, Azahar `VK_EXT_shader_stencil_export` and `VK_EXT_external_memory_host`. One finding the plan had not foreseen: **Dolphin presents nothing without a `VkSurfaceKHR`**. It emulates a swapchain on top of the surface it gets in `create_device2` (RetroArch always passes one), so `URVulkanContext` creates a surface of a `CAMetalLayer` that is never shown, with `VK_KHR_surface` and `VK_EXT_metal_surface` on the instance and `VK_KHR_swapchain` on core-made devices, as RetroArch does. The only MoltenVK warning: paraLLEl-RDP enables blending on an `R8G8B8A8_UINT` attachment, which Metal ignores; the picture is correct.
- **S2** Speed (`ursprung-smoke`; uncapped frames per second and milliseconds per frame in the core, including the readback; Dolphin and PPSSPP boot in wall-clock time, so they ran paced and only the time in the core compares):

  | Game | OpenGL / software | Vulkan |
  |---|---|---|
  | Ocarina of Time, angrylion vs paraLLEl-RDP + RSP, 1× | 286 fps, 3.5 ms (3600 frames: 4.0 ms) | 160 fps, 6.2 ms (3600 frames: 8.3 ms) |
  | same, CPU time over 30 s paced | 117 % of a core (angrylion is threaded) | 39 % |
  | Ocarina of Time, paraLLEl-RDP 2× / 4× | – | 109 fps / 50 fps |
  | MGS: The Twin Snakes, paced, native / EFB 3× | 12.1 ms, warns about `ARB_buffer_storage` | 11.4 ms / 11.1 ms, no warning |
  | Sonic Adventure, 640×480 / 1920×1440 | 530 fps / 160 fps | 433 fps / 225 fps |
  | SOTN, SwanStation, 1× / 4× | 1106 fps / 333 fps | 1282 fps / 571 fps |
  | SOTN, Beetle PSX HW, 1× / 4× | 488 fps / – | 392 fps / 327 fps |
  | Valkyrie Profile, PPSSPP, paced | 2.3 ms | 3.0 ms (Debug conversion; about even without it) |

  paraLLEl-RDP is slower than angrylion in wall time on an M4 but needs a third of the CPU, and both are far above 60 fps at 1×; 4× upscaling is below full speed in the core itself.
- **S3** Readback: submitting the frame and waiting for the fence costs 0.8–1 ms at native resolution (this includes the core's own GPU work for that frame), 2–5 ms at 3–5 MP. Converting to BGRA8 costs 0.02–0.07 ms at native, 0.2–1 ms at 1–2.5 MP, 1.9 ms for Dolphin's 10-bit frames at 1920×1584 (with `-O2`; `URPixelConversion.c` is now optimised in Debug builds too, which were 5–10× slower). Phase 5 is not needed for the acceptance games; it would matter only at high upscaling, where the cores are the bottleneck first.
- **S4** Formats: `R8G8B8A8_UNORM` (Mupen64Plus-Next, Flycast, SwanStation, Azahar), `A2B10G10R10_UNORM_PACK32` (Dolphin), `B8G8R8A8_UNORM` (PPSSPP), `A1R5G5B5_UNORM_PACK16` (Beetle PSX HW, which the first version could not show), all in `SHADER_READ_ONLY_OPTIMAL`, all top-left origin, none sRGB.
- **S5** Teardown: twelve load/run/unload rounds in one process (`URSMOKE_REPEAT=12`) pass for all seven cores, with frames in every round; no crash.
- **S6** States: Ocarina of Time 16.8 MB with either renderer, and a paraLLEl-RDP state loads into angrylion and back (title and name entry screens). Dolphin 92 MB; a Vulkan state loads into OpenGL and Vulkan. The "made with another renderer" note stays a note (the state loads, with a hint if the game misbehaves).
- **S7** MoltenVK needs no configuration for correctness or speed. `URVulkanContext` only lowers `MVK_CONFIG_LOG_LEVEL` to warnings (MoltenVK logs every instance and device otherwise); an `MVK_CONFIG_*` set in the environment still wins.

### Phase 1 — Dependency (S)

- `Scripts/fetch-moltenvk.sh`: downloads the pinned `MoltenVK-macos.tar` (v1.4.2, 56 MB) from GitHub releases, checks its SHA-256, extracts `libMoltenVK.dylib`, thins it to arm64 (`lipo -thin`, roughly halves the universal 11 MB), sets the install name to `@rpath/libMoltenVK.dylib`. Called from `make project`; CI caches it. Same pattern as `fetch-librashader.sh`.
- `ThirdParty/moltenvk/`: README (version, update steps, licence, source link), `LICENSE`, the Vulkan headers from the release (or Vulkan-Headers at the matching tag) and `libretro_vulkan.h` in `Ursprung/Bridge/`.
- `project.yml`: link and embed for Ursprung, `ursprung-smoke` and the tests; header search paths.
- CLAUDE.md ("Hard rules": agreed dependencies; "Known issues": remove "Vulkan cores/renderers unsupported" when phase 4 lands), About/acknowledgements, `docs/ARCHITECTURE.md`.
- Acceptance: `make build`, `make test`, CI and `make dist` (signature, notarization check) pass with the dylib embedded.
- As built: `Scripts/fetch-moltenvk.sh` also copies the release's C headers (not the 20 MB of C++ bindings) to `ThirdParty/moltenvk/include`; `lib/` and `include/` are git-ignored, CI caches both. The release already has the `@rpath` install name. `make smoke` takes `RENDERER=vulkan`. The app links QuartzCore for the surface's layer. `make dist` is not run yet: it needs the Developer ID certificate (see `docs/RELEASE.md`).

### Phase 2 — Bridge (L)

- `URVulkanContext` and the `URLibretroCore` changes described above, with readback.
- `ursprung-smoke` gains `--renderer vulkan|opengl` (sets the preference and the option defaults), so every core can be checked headlessly.
- `Tools/ursprung-test-core` gets a Vulkan mode: it requests Vulkan, clears its image to a frame-dependent colour each frame and supports serialize. `EmulationRunnerTests` check the colour reaches `_back`, sync indices advance, and load/unload repeats without leaks or crashes. Tests skip when no Vulkan device exists (CI runner without a GPU).
- Acceptance: Ocarina of Time with paraLLEl-RDP and the Dolphin intro render through `make smoke` and the app; quitting a game twelve times in a row crashes nothing.
- As built: `URVulkanContext` (Objective-C) follows the design above with these differences: one command buffer, fence and readback buffer instead of one per sync index, because every frame is waited for (`wait_sync_index` returns at once; the core still sees two sync indices, `get_sync_index_mask` = `0b11`); cores' `vkGetInstanceProcAddr` routes `vkCreateDevice` through Ursprung, so cores that make the device themselves (v1) get `VK_KHR_portability_subset` and `VK_KHR_swapchain` too; the surface from S1. Work the core hands over without showing a frame (run-ahead or hidden frames, `video_refresh(NULL)`) is still submitted once after `retro_run`, so semaphores are waited for and command buffers run. `SET_HW_RENDER` refuses Vulkan when MoltenVK offers no device (probed once), so the core falls back; if the context then fails after `retro_load_game`, loading fails with a message instead (without writing the battery save). `retro_reset` forgets the core's image first. Teardown: wait idle, `context_destroy`, `retro_unload_game`, `retro_deinit`, then `destroy_device`, device, surface, instance, as in RetroArch. The pixel formats are converted in `URPixelConversion.c` (plain C, unit-tested): BGRA8, RGBA8, A2B10G10R10, A2R10G10B10, RGBA16F, RGB565, A1R5G5B5, R5G5B5A1. Run-ahead stays off for hardware-rendered games, as with OpenGL. `ursprung-smoke` takes `URSMOKE_RENDERER=vulkan` instead of `--renderer`; option defaults are passed with `URSMOKE_OPTIONS` (they live in the Swift catalog). The test core's Vulkan modes (submitting itself with a semaphore, or handing over command buffers) use negotiation v2 with `create_device2`; the tests (`EmulationRunnerTests` › "Vulkan rendering") check pixels, both sync indices, hidden frames, states, run-ahead and 13 load/unload rounds with `destroy_device` counted, and skip without a Vulkan device.

### Phase 3 — Model and settings (M)

- `HardwareRenderer`, `CoreDefinition.renderer`, `Preferences.rendererChoice`, resolution order (game override → core preference → catalog).
- Settings › Cores: "Graphics API" picker for Vulkan-capable cores, with a short explanation; the player's core options show the resolved renderer.
- Fallback: if Vulkan was preferred but the core ended up on GL or software, toast once per session ("Vulkan isn't available, using OpenGL").
- `SaveStateContext` records the renderer; the save state browser and loader warn across renderers.
- Tests: resolution order, option defaults per renderer, state warnings.
- As built: `HardwareRenderer` (`.opengl`, `.vulkan`), `CoreDefinition.renderer` and `vulkanOptionDefaults` (nil: the core has no Vulkan renderer; merged over `optionDefaults` when Vulkan is chosen), `RendererChoice` (automatic, vulkan, opengl) stored as `rendererChoice.<core>` and backed up. There is no separate per-game renderer: a game's own core options (merged last) already override the renderer's defaults, e.g. a game set to angrylion. Settings › Cores has a "Graphics API" section listing the Vulkan-capable cores ("Automatic (Vulkan)", Vulkan, OpenGL), disabled with a note on a Mac without Vulkan; the player's core options say how the game renders. The toast appears once per app session when Vulkan was wanted but this Mac has none. Manifests record `renderer` (`software`, `opengl`, `vulkan`); states without it raise no issue. Tests: `GraphicsAPITests`, `StateRendererTests`.

### Phase 4 — Systems (M)

- **N64**: Mupen64Plus-Next and ParaLLEl N64 default to Vulkan with paraLLEl-RDP/RSP at native resolution (Q1); angrylion stays selectable. Upscaling (`mupen64plus-parallel-rdp-upscaling`) in the core options.
- **GameCube / Wii**: Dolphin defaults to Vulkan. If the acceptance checks pass, drop `experimental` and update the note in `SUPPORTED_SYSTEMS.md`.
- **Dreamcast**: Flycast defaults to Vulkan if S2 shows no regression; per-pixel alpha sorting becomes available in its options.
- **PlayStation**: add Beetle PSX HW (`mednafen_psx_hw`) as a core with `hardware_vk`; SwanStation defaults to Vulkan if S2 shows no regression. PCSX ReARMed stays the default core.
- **PSP**: stays on OpenGL unless S2 shows a clear gain.
- Docs: `SUPPORTED_SYSTEMS.md` (renderers, Vulkan notes), CLAUDE.md Known issues (GLideN64 note becomes "use paraLLEl-RDP").
- Acceptance (manual, in the app):
  - Ocarina of Time: full speed with paraLLEl-RDP at 1× and 2×; save and load a state; screenshot; a librashader preset; resume after quit.
  - MGS: The Twin Snakes: no `ARB_buffer_storage` warning; full speed from the intro into the first playable scene; save and load a state; disc 2 swap via the `.m3u`.
- As built: Mupen64Plus-Next defaults to Vulkan with paraLLEl-RDP and paraLLEl-RSP; **ParaLLEl N64 has no paraLLEl-RDP in its macOS build** (its `gfxplugin` option offers gliden64, glide64, gln64, rice, angrylion), so it keeps angrylion and has no Vulkan choice. Dolphin, Flycast, SwanStation (faster in S2 at 1× and 4×) and Beetle PSX HW (new, third PlayStation core after Beetle PSX, needs a BIOS like it) default to Vulkan. Flycast is 0.4 ms per frame slower at native resolution but faster upscaled and the only renderer with per-pixel alpha sorting on the Mac, so it defaults to Vulkan too. PPSSPP can choose Vulkan but stays on OpenGL (no gain). Dolphin keeps `experimental` until the manual checks below are done.
- Checked in the app (Debug build, 8 October 2026, `URSPRUNG_AUTOPLAY`, the user's library restored afterwards): Ocarina of Time 60 fps with Vulkan (paraLLEl-RDP 1×), state saved and loaded (manifest `"renderer": "vulkan"`), screenshot, resume after quit, the crt-geom preset at 6 ms GPU time; MGS: The Twin Snakes 59.9 fps into the intro cutscene with no warning, state saved and loaded. Not checked yet (need hands on a controller): paraLLEl-RDP 2× in the app, the first playable scene of MGS, the disc 2 swap; then Dolphin can drop `experimental`.

### Phase 5 — Zero-copy presentation (M)

Only if S3 shows readback as a bottleneck at the upscaling factors users pick.

Status (8 October 2026): not needed for now. At native and 2× the readback costs about a millisecond; where it grows (3× and more), the cores are below full speed on their own first. Revisit when a core is fast enough at high upscaling to be held back by the copy.

- Copy the core's image into a frontend-owned `VkImage` created from an `MTLTexture` (`VK_EXT_metal_objects` import), or export the `MTLTexture` of a frontend image (`vkExportMetalObjectsEXT`). Signal an `MTLSharedEvent` exported from the copy's semaphore; `MetalRenderer` waits on it before sampling.
- `MetalRenderer` gets a texture input next to the CPU buffer upload. Shaders take that texture as input without change.
- Screenshots, rewind, autosave thumbnails and `copyFrameImage` read back on demand (a blit into a shared buffer) instead of every frame.
- Tests: the test core in Vulkan mode renders through the texture path; screenshot equals the CPU path.

### Phase 6 — Nintendo 3DS (spike first, M)

- Spike with Azahar (`azahar_libretro`, Software/Vulkan only on macOS): boots a game, speed, two screens layout options, touch input, save states. If it fails, stop here.
- If it works: `3ds` system in `SystemCatalog` (ScreenScraper 17, `.3ds`/`.cci`/`.cxi`/`.3dsx`, aliases `3ds`, `n3ds`, `nintendo3ds`), screen layout and stylus mapping like melonDS DS, BIOS/keys notes in `docs/BIOS.md`.
- Spike (8 October 2026): blocked on test content. `azahar_libretro` (2126.1.2, 31 MB) is on the buildbot for macOS arm64 and works with Ursprung's Vulkan context (negotiation v1, both screens stacked in one 400×480 `R8G8B8A8` frame, 3.5 MB states, twelve load/unload rounds). The only game at hand, the open-source homebrew Super Haxagon 3.9.1 (`.3dsx`), stops after its first second with a kernel error with both the Vulkan and the software renderer, so it says nothing about Azahar's rendering. The phase needs a decrypted dump of a real game (the user has none) before the system is added.

## Tests

- Unit: renderer resolution, option defaults, format conversion (`R8G8B8A8`/`B8G8R8A8`/`A2B10G10R10` → BGRA8), sync index ring logic (pure Swift/C, no GPU).
- Runner: test core in Vulkan mode (frames, sync indices, serialize, load/unload loops), skipped without a Vulkan device.
- Smoke: `make smoke CORE=… ROM=… RENDERER=vulkan` for the acceptance games before every MoltenVK or catalog change.
- Manual: the phase 4 acceptance list; plus one game each for Dreamcast, PlayStation (Beetle PSX HW) and PSP.

## Risks

| Risk | Mitigation |
|---|---|
| MoltenVK lacks a feature a renderer needs (seen: LRPS2's Vulkan GS) | Per-core renderer choice with OpenGL fallback; only cores verified in the spike default to Vulkan |
| Readback costs too much at high upscaling | Phase 5; until then cap the default upscaling at 2× |
| Cores crash in teardown (as Play! does with GL) | S5 loop test before a core defaults to Vulkan; keep the GL default for any core that fails it |
| Cores submit from their own threads | `lock_queue` mutex around every frontend submission; spike S1 lists which cores do this |
| CI runners have no GPU / no Vulkan device | Runner tests skip without a device; smoke tests run locally before release |
| App size grows (~5–6 MB thinned dylib) | Acceptable; same as librashader |
| A new dependency | Needs explicit agreement (CLAUDE.md "Hard rules"); Apache-2.0 is GPL-3.0 compatible; pinned release, SHA-256 checked |

## Resolved questions (7 October 2026)

The user followed the recommendations. Where the plan had none, the choice below was made with it.

1. **Q1 N64 default: paraLLEl-RDP at native resolution.**
   - Same look as angrylion (both are accurate low-level RDPs), with a fraction of the CPU load; upscaling stays an option in the core options.
   - angrylion stays selectable and remains the fallback when Vulkan is unavailable.
2. **Q2 Graphics API picker: visible, per core, in Settings › Cores.**
   - Only for cores whose catalog entry has Vulkan; "Automatic" is the default.
   - It is the user's way out when a game renders wrong on one API.
3. **Q3 Defaults for Flycast, SwanStation, PPSSPP: decided by spike S2.**
   - A core defaults to Vulkan only if it is at least as fast and as correct as on OpenGL and passes the teardown check (S5).
4. **Q4 MoltenVK: embedded in the app.**
   - Signed and notarized with Ursprung, no first-run download, works offline. About 5–6 MB after thinning to arm64.
5. **Q5 3DS: in this plan as phase 6, behind its own spike.**
   - Azahar on macOS has no OpenGL renderer, so 3DS exists only through this work. If the spike fails, the phase stops without affecting phases 1–5.
6. **Q6 Order: `STANDALONE_PLAN.md` first, then this plan.**
   - PS2 is the request that started both plans, and only the standalone route plays it today.
   - The standalone plan is smaller and touches different code (process launch, saves) than this one (bridge, renderer), so the two do not block each other. Vulkan's spike can start while the standalone plan is in its later phases.
