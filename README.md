<p align="center">
  <img src="docs/icon.png" width="128" alt="Ursprung app icon">
</p>

<h1 align="center">Ursprung</h1>

<p align="center">
  A native retro game library for macOS — organise your games, see their covers and stories, and play them with one click.<br>
  Built with SwiftUI and Metal on Apple Silicon, powered by <a href="https://www.libretro.com">libretro</a>, with metadata from <a href="https://www.screenscraper.fr">ScreenScraper</a>.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: GPL v3" src="https://img.shields.io/badge/license-GPLv3-blue.svg"></a>
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-black">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-black">
</p>

---

> **Status:** early development (0.1). The core experience — library, metadata,
> playing, save states, controllers — works. Expect rough edges.

## Features

- **A library, not a file browser.** Point Ursprung at your game folders; it
  identifies the system of every game from file types and folder names, hides
  disc track files, and rescans by itself when files change. A scan report
  lists files it could not identify (add them with a system of your choice)
  and discs with missing tracks; games can be hidden instead of removed. Drop
  games or folders on the window, or open them from the Finder.
- **Organised your way.** Collections such as “Couch Co-op”, a play status
  (Up Next, Playing, Completed, Abandoned) and filters for genre, players,
  decade, metadata and missing files. Select several games to favourite, tag,
  scrape or hide them at once, or switch to a sortable list (⌘2). Regions,
  revisions, translations and hacks of a game show as one entry with the
  version you prefer.
- **Covers and details from ScreenScraper.** Box art, screenshots, fan art,
  logos, descriptions, developer, publisher, genre, release date and rating —
  in your language and region (e.g. German titles and box art). Edit any
  detail, choose your own cover or pick the right match by hand; your edits
  survive every later fetch.
- **Native and fast.** SwiftUI interface with the macOS 26 design language,
  Metal presentation, audio-synchronised frame pacing, OpenGL and Vulkan
  (through MoltenVK) for 3D cores: paraLLEl-RDP for N64, Dolphin, Flycast,
  PlayStation and PSP renderers.
- **libretro cores on demand.** The right core is downloaded automatically from
  the libretro buildbot the first time you start a game — nothing to configure.
- **Save states with thumbnails and names**, quick save/load, battery saves,
  core options per core or per game. Overwritten and deleted states can be
  brought back, and every state can start its game from the library. Quitting
  a game keeps where you are, and Play resumes there.
- **Rewind, fast forward and run-ahead.** Hold a key to run the game
  backwards, fast forward at 2× to 8× (held or switched on), and hide a game's
  built-in input lag with run-ahead. Turbo buttons fire repeatedly while held.
- **Looks like the real thing.** CRT (flat or curved), handheld LCD,
  scanlines and sharp-pixel filters, per system or per game, with ambient
  light or your own bezel image around the picture.
- **RetroArch shaders and a shader editor.** More than 2,500 slang presets
  from the libretro shader pack (downloaded on demand) through
  [librashader](https://github.com/SnowflakePowered/librashader). Tune their
  parameters live in a panel beside the game, save your own presets
  (RetroArch can load them too), or build and edit shaders in the shader
  editor with syntax highlighting, inline errors, live recompiling and a
  preview on the running game or on test pictures. See
  [docs/SHADERS.md](docs/SHADERS.md).
- **Screenshots, manuals, patches and cheats.** Take screenshots while playing
  and browse them with the game's artwork; keep a manual (PDF or picture)
  that opens next to the game; play translations and hacks from IPS, UPS and
  BPS patches without touching the original ROM, each with its own saves;
  switch cheat codes on and off from the pause menu, or import RetroArch
  `.cht` files.
- **RetroAchievements.** Sign in with your
  [RetroAchievements](https://retroachievements.org) account to unlock
  achievements while you play, with badges, progress and leaderboards in the
  player and an optional hardcore mode.
- **Multi-disc games** with disc playlists Ursprung creates from loose discs,
  disc labels, reordering and a check for missing discs.
- **Your progress stays put.** Renamed or moved ROMs keep their favourites,
  play time and saves; missing files can be located again. One-file backups
  restore your library, saves, states and settings on another Mac.
- **Controllers and keyboard.** Xbox, PlayStation, Switch Pro and MFi
  controllers via the GameController framework, Xbox 360 protocol (XInput)
  pads and receivers over USB (e.g. 8BitDo 2.4 GHz dongles) and other
  USB/Bluetooth gamepads via IOKit. Up to four players, each controller on
  the player you choose; keyboard, controller buttons and hotkeys remappable
  for all systems, per system or per game; live input test; mouse as touch
  screen / pointer (Nintendo DS). Browse the library with a controller: the
  D-pad moves, the right face button plays, the top one toggles a favourite
  and the shoulder buttons switch lists. Rumble on controllers that have it;
  computers such as the MSX get the Mac keyboard as their keyboard.
- **Cores you can trust.** Check the buildbot for newer core builds; after an
  update the previous version stays installed, so you can go back if a game
  breaks.
- **BIOS management.** Drop BIOS files in and Ursprung recognises them by
  checksum and names them the way each core expects.
- **English and German** user interface.

## Supported systems

NES · Famicom Disk System · SNES · Nintendo 64 · Game Boy · Game Boy Color ·
Game Boy Advance · Nintendo DS · Virtual Boy · Pokémon mini · SG-1000 ·
Master System · Mega Drive / Genesis · Mega-CD / Sega CD · 32X · Game Gear ·
Saturn · Dreamcast · PlayStation · PSP · PC Engine / TurboGrafx-16 ·
PC Engine CD · SuperGrafx · Atari 2600 / 5200 / 7800 · Lynx · Jaguar ·
Neo Geo Pocket (Color) · WonderSwan (Color) · ColecoVision · Intellivision ·
Vectrex · 3DO · MSX · Arcade (FinalBurn Neo, MAME 2003-Plus) · GameCube / Wii
(experimental)

See [docs/SUPPORTED_SYSTEMS.md](docs/SUPPORTED_SYSTEMS.md) for file types, folder
names, cores and BIOS requirements per system.

## Requirements

- macOS 26 (Tahoe) or later
- A Mac with Apple Silicon
- Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) to build

## Building

```sh
brew install xcodegen
git clone https://github.com/bhuaysan/ursprung.git
cd ursprung
cp .env.example .env        # optional: add ScreenScraper developer credentials
make project                # downloads librashader and MoltenVK, generates Ursprung.xcodeproj
open Ursprung.xcodeproj     # then press ⌘R
```

Or entirely from the command line: `make run`. Other targets: `make test`,
`make release`, `make smoke` (headless core test), `make dist` (signed and
notarized disk image, see [docs/RELEASE.md](docs/RELEASE.md)), see the
[Makefile](Makefile).

Builds are signed ad hoc, so the Keychain treats every rebuild as a new app and
asks again for a stored ScreenScraper account password. To sign with your Apple
Development certificate instead, copy `Config/Signing.local.xcconfig.example` to
`Config/Signing.local.xcconfig` (git-ignored) and enter your team ID.

### ScreenScraper credentials

ScreenScraper requires *developer* credentials for every API client. They are
**not** part of this repository. Request your own developer access via the
[ScreenScraper](https://www.screenscraper.fr/) forum, put the credentials into
`.env` and rebuild — the build script embeds them in the app. Without them Ursprung works normally, it just can't fetch metadata.

Players can optionally enter their personal ScreenScraper account in
**Settings → Metadata** for a higher daily quota. Details:
[docs/METADATA.md](docs/METADATA.md).

## Getting started

1. On the first launch Ursprung offers to create `~/Ursprung` with `ROMs/` (one
   folder per system) and `BIOS/`: copy games and BIOS files in, and they show up
   by themselves. Or click **Add Folder…** and choose the folder with your games
   (**File → Set Up Game Folders…** offers the structure again later).
2. Sort games into sub folders named after the system (`SNES`, `PSX`, `Mega Drive`,
   `Arcade`, …). Cartridge games are recognised by file type anyway; for disc
   images (`.cue`, `.chd`, `.iso`) and archives the folder name decides.
3. Metadata and covers are fetched automatically. Double-click a game to play.
4. For systems that need a BIOS (PlayStation is optional, Sega CD, Saturn, PC
   Engine CD, Lynx … are required) open **Settings → BIOS** and drop the files in.
   See [docs/BIOS.md](docs/BIOS.md).

### Default keyboard layout

| RetroPad | Key | RetroPad | Key |
|---|---|---|---|
| D-pad | Arrow keys | Start / Select | Return / Right Shift |
| A / B | X / Z | X / Y | S / A |
| L / R | Q / W | L2 / R2 | E / R |
| L3 / R3 | 1 / 2 | Left stick | I J K L |
| Right stick | T F G H | | |

**Esc** opens the game menu, hold **Space** to fast forward, hold **⌫** to
rewind (turn rewinding on in **Settings → Emulation** first), **F2 / F4** quick
save / load, **⌘S / ⌘L** likewise from the menu bar, **F8** takes a
screenshot, **F12** switches the keyboard to typing on an emulated computer
(MSX) and back, **⌃⌘F** full screen. Fast forward on/off and turbo on/off have
no key until you give them one. All keys, including these hotkeys (esc always
opens the menu as well), can be changed in **Settings → Controls**.

## Your data

Everything lives in `~/Library/Application Support/Ursprung/`:

| Folder | Contents |
|---|---|
| `Library.store` | The library database. If it cannot be opened, Ursprung asks before moving it to `Library.store-backup-<date>/`; it is never deleted automatically |
| `Cores/` | Downloaded libretro cores |
| `System/` | BIOS files and core assets (the libretro system directory) |
| `Saves/<system>/<game-id>/` | Battery saves (`.srm`), one folder per game. Memory cards and other core saves live in `Saves/<system>/` |
| `States/<game-id>/<core>/` | Save states with thumbnails and manifests, one folder per core; `History/` keeps recently replaced ones |
| `Media/<game>/` | Artwork from ScreenScraper |
| `Extras/<game-id>/` | Your screenshots, the game's manual, ROM patches and cheats |
| `Bezels/` | Bezel images, one per system |
| `Shaders/` | The downloaded RetroArch shader pack, your own presets (`User/`) and the shader editor's draft |

Your game files are only ever read, never modified; a patched game is written
to the cache. File › Back Up Library… writes all of this except cores, BIOS
files, the shader pack and the editor's draft into one zip file. See
[docs/SAVES.md](docs/SAVES.md) for game identity, save state compatibility and
the backup format.

## Legal

Ursprung is an emulator frontend. It contains **no games, BIOS files or
copyrighted system software**, and it does not help you obtain them. Only use
games and BIOS files you have dumped from media and hardware you own.

The libretro cores are independent projects under their own licenses (GPL,
LGPL, MIT, and some non-commercial ones). They are downloaded from the libretro
buildbot at runtime and are not distributed with Ursprung.

Box art and other media are provided by ScreenScraper and its contributors.

## Contributing

Contributions are very welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) and the
[architecture overview](docs/ARCHITECTURE.md). Please follow the
[Code of Conduct](CODE_OF_CONDUCT.md). Security issues: [SECURITY.md](SECURITY.md).

## License

Copyright © 2026 Ursprung contributors.

Ursprung is free software: you can redistribute it and/or modify it under the
terms of the [GNU General Public License](LICENSE) as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.

`Ursprung/Bridge/libretro.h` is © The RetroArch team, MIT licensed.
`ThirdParty/rcheevos` is [rcheevos](https://github.com/RetroAchievements/rcheevos)
© RetroAchievements.org, MIT licensed.
The app embeds [librashader](https://github.com/SnowflakePowered/librashader)
0.12.0, available under the Mozilla Public License 2.0 or the GPL 3.0; its
source code is on GitHub (see `ThirdParty/librashader/README.md`).
It also embeds [MoltenVK](https://github.com/KhronosGroup/MoltenVK) 1.4.2
© The Khronos Group, under the Apache License 2.0 (see
`ThirdParty/moltenvk/README.md`); `Ursprung/Bridge/libretro_vulkan.h` is
© The RetroArch team, MIT licensed.

## Acknowledgements

- [libretro](https://www.libretro.com) and all core authors
- [ScreenScraper](https://www.screenscraper.fr) and its community of contributors
- [RetroAchievements](https://retroachievements.org) and the rcheevos authors
- [librashader](https://github.com/SnowflakePowered/librashader) and the authors of the RetroArch slang shaders
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) and the Khronos Group, and RetroArch's Vulkan driver as the reference for libretro's Vulkan interface
- [OpenEmu](https://openemu.org), for showing how good an emulator frontend on the Mac can be
