# Supported systems

Ursprung supports every system below out of the box. The core is downloaded
automatically when you start the first game of a system; you can pick another
core per system in **Settings → Emulation** or per game in its info panel.

**Folder names** are matched case-insensitively, ignoring spaces and
punctuation (`Mega Drive`, `megadrive` and `MEGA-DRIVE` are the same). They are
required for disc images and archives, and optional for cartridge games whose
file type is unique. Zipped cartridge games are extracted to a cache on launch;
arcade sets are passed to the core as they are.

| System | Folder names | Extensions | Cores (default first) | BIOS |
|---|---|---|---|---|
| **Nintendo Entertainment System** (Nintendo) | `nes`, `famicom`, `fc`, `nintendo` | .nes, .unf, .unif, .zip | FCEUmm, Nestopia UE, Mesen | – |
| **Famicom Disk System** (Nintendo) | `fds`, `famicomdisksystem` | .fds, .zip | FCEUmm, Nestopia UE, Mesen | `disksys.rom` (required) |
| **Super Nintendo** (Nintendo) | `snes`, `sfc`, `supernintendo`, `superfamicom` | .sfc, .smc, .swc, .fig, .bs, .zip | Snes9x, bsnes, Mesen 2 | – |
| **Nintendo 64** (Nintendo) | `n64`, `nintendo64` | .n64, .z64, .v64, .zip | Mupen64Plus-Next, ParaLLEl N64 | – |
| **GameCube** (Nintendo) | `gc`, `gamecube`, `ngc`, `nintendogamecube` | .iso, .gcm, .gcz, .rvz | Dolphin | – |
| **Wii** (Nintendo) | `wii`, `nintendowii` | .iso, .wbfs, .wad | Dolphin | – |
| **Game Boy** (Nintendo) | `gb`, `gameboy` | .gb, .dmg, .zip | Gambatte, SameBoy, mGBA | – |
| **Game Boy Color** (Nintendo) | `gbc`, `gameboycolor`, `gameboycolour` | .gbc, .zip | Gambatte, SameBoy, mGBA | – |
| **Game Boy Advance** (Nintendo) | `gba`, `gameboyadvance` | .gba, .agb, .zip | mGBA, VBA Next | `gba_bios.bin` |
| **Nintendo DS** (Nintendo) | `nds`, `ds`, `nintendods` | .nds, .dsi, .ids, .zip | melonDS DS, DeSmuME | `bios7.bin`, `bios9.bin`, `firmware.bin` |
| **Virtual Boy** (Nintendo) | `vb`, `virtualboy` | .vb, .vboy, .zip | Beetle VB | – |
| **Pokémon mini** (Nintendo) | `pokemini`, `pokemonmini` | .min, .zip | PokeMini | – |
| **SG-1000** (Sega) | `sg1000`, `sg` | .sg, .zip | Genesis Plus GX, Gearsystem | – |
| **Master System** (Sega) | `sms`, `mastersystem`, `segamastersystem`, `mark3` | .sms, .zip | Genesis Plus GX, Gearsystem, PicoDrive | – |
| **Mega Drive / Genesis** (Sega) | `md`, `megadrive`, `genesis`, `segagenesis` | .md, .gen, .smd, .mdx, .68k, .sgd, .zip | Genesis Plus GX, PicoDrive, BlastEm | – |
| **Mega-CD / Sega CD** (Sega) | `segacd`, `megacd`, `scd`, `megacdsegacd` | .cue, .chd, .iso, .m3u | Genesis Plus GX, PicoDrive | `bios_CD_U.bin` (required), `bios_CD_E.bin` (required), `bios_CD_J.bin` (required) |
| **32X** (Sega) | `32x`, `sega32x`, `megadrive32x` | .32x, .zip | PicoDrive | – |
| **Game Gear** (Sega) | `gg`, `gamegear`, `segagamegear` | .gg, .zip | Genesis Plus GX, Gearsystem | – |
| **Saturn** (Sega) | `saturn`, `segasaturn`, `ss` | .cue, .chd, .iso, .m3u | Beetle Saturn, Yabause | `sega_101.bin` (required), `mpr-17933.bin` (required) |
| **Dreamcast** (Sega) | `dc`, `dreamcast`, `segadreamcast` | .cdi, .gdi, .cue, .chd, .iso, .m3u | Flycast | `dc/dc_boot.bin`, `dc/dc_flash.bin` |
| **PlayStation** (Sony) | `psx`, `ps1`, `playstation`, `sonyplaystation` | .cue, .chd, .iso, .m3u, .pbp | PCSX ReARMed, SwanStation, Beetle PSX | `scph5500.bin`, `scph5501.bin`, `scph5502.bin`, `scph1001.bin` |
| **PlayStation Portable** (Sony) | `psp`, `playstationportable` | .cso, .iso, .pbp, .chd | PPSSPP | – |
| **PC Engine / TurboGrafx-16** (NEC) | `pce`, `pcengine`, `tg16`, `turbografx` | .pce, .zip | Beetle PCE Fast | – |
| **PC Engine CD** (NEC) | `pcecd`, `pcenginecd`, `tgcd`, `turbografxcd` | .cue, .chd, .iso, .m3u | Beetle PCE Fast | `syscard3.pce` (required) |
| **SuperGrafx** (NEC) | `sgx`, `supergrafx` | .sgx, .zip | Beetle SuperGrafx | – |
| **Atari 2600** (Atari) | `atari2600`, `2600`, `vcs` | .a26, .zip | Stella | – |
| **Atari 5200** (Atari) | `atari5200`, `5200` | .a52, .zip | a5200, Atari800 | `5200.rom` (required) |
| **Atari 7800** (Atari) | `atari7800`, `7800` | .a78, .zip | ProSystem | `7800 BIOS (U).rom` |
| **Atari Lynx** (Atari) | `lynx`, `atarilynx` | .lnx, .lyx, .o, .zip | Handy, Beetle Lynx | `lynxboot.img` (required) |
| **Atari Jaguar** (Atari) | `jaguar`, `atarijaguar` | .j64, .jag, .zip | Virtual Jaguar | – |
| **Neo Geo Pocket** (SNK) | `ngp`, `neogeopocket` | .ngp, .zip | Beetle NeoPop | – |
| **Neo Geo Pocket Color** (SNK) | `ngpc`, `neogeopocketcolor` | .ngc, .ngpc, .zip | Beetle NeoPop | – |
| **WonderSwan** (Bandai) | `ws`, `wonderswan` | .ws, .zip | Beetle Cygne | – |
| **WonderSwan Color** (Bandai) | `wsc`, `wonderswancolor` | .wsc, .zip | Beetle Cygne | – |
| **ColecoVision** (Coleco) | `coleco`, `colecovision` | .col, .zip | Gearcoleco | `colecovision.rom` (required) |
| **Intellivision** (Mattel) | `intellivision`, `intv` | .int, .zip | FreeIntv | `exec.bin` (required), `grom.bin` (required) |
| **Vectrex** (GCE) | `vectrex` | .vec, .zip | vecx | – |
| **3DO** (Panasonic) | `3do`, `panasonic3do` | .cue, .chd, .iso, .m3u | Opera | `panafz10.bin` (required) |
| **MSX / MSX2** (Microsoft / ASCII) | `msx`, `msx1`, `msx2` | .mx1, .mx2, .dsk, .cas, .zip | blueMSX, fMSX | – |
| **Arcade** (Various) | `arcade`, `mame`, `fbneo`, `fba` | .zip | FinalBurn Neo, MAME 2003-Plus | `fbneo/neogeo.zip` |

## Notes per system

- **Nintendo 64** — defaults to the angrylion software renderer, which is
  accurate and fast enough on Apple Silicon. GLideN64 (OpenGL, upscaling) can be
  selected in the core options, but its frame buffer emulation currently
  renders black on Apple's OpenGL implementation, so disable
  *Frame buffer emulation* when you use it.
- **PlayStation** — PCSX ReARMed includes an HLE BIOS, so a real BIOS is
  optional (but improves compatibility). SwanStation and Beetle PSX require one.
  Multi-disc games work best as an `.m3u` playlist listing the `.cue`/`.chd`
  files; swap discs from the game menu.
- **PSP** — PPSSPP renders with OpenGL. Its font and shader assets are
  downloaded into the system folder automatically.
- **Nintendo DS** — the mouse acts as the stylus on the touch screen. melonDS DS
  has a built-in BIOS; real BIOS/firmware files are optional.
- **Dreamcast** — Flycast renders with OpenGL and includes an HLE BIOS.
- **Arcade** — FinalBurn Neo is the default. ROM sets must match the core's
  version (FBNeo: the current nightly set; MAME 2003-Plus: its 0.78-based set).
  Put `neogeo.zip` next to your Neo Geo games, or import it in Settings → BIOS
  (it is stored as `System/fbneo/neogeo.zip`).
- **GameCube / Wii** — experimental. Dolphin's libretro core is heavy and
  depends on OpenGL; expect issues.

## Not supported (yet)

- Vulkan-only renderers (ParaLLEl-RDP, ParaLLEl-GS, Beetle PSX HW's Vulkan
  renderer).
- PlayStation 2, Nintendo 3DS, Xbox — their libretro cores are not in a usable
  state on macOS arm64 at the moment.
- Home computers beyond MSX (Amiga, C64, DOS, …) — the cores exist, but need
  keyboard and disk UI that Ursprung does not have yet.
