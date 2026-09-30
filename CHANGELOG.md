# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Sidebar: each system is marked with a dot in its colour.
- System banner above each system's games with the official logo and a console
  photo, and official logos on placeholder covers (downloaded from ScreenScraper
  on first use, never bundled).

### Fixed
- Artwork with an empty placeholder (e.g. the game logo in the inspector) never
  loaded.

## [0.1.0] - 2026-09-28

First public development version.

### Added
- Game library with automatic system detection from file types and folder
  names, multi-file disc support (`.cue`, `.gdi`, `.m3u`, `.ccd`) and zipped
  games.
- Metadata and artwork from ScreenScraper (box art, screenshot, fan art, logo,
  description, developer, publisher, genre, release date, players, rating),
  honouring the preferred language and region.
- libretro host in Objective-C: software and OpenGL (hardware-rendered) cores,
  core options (v0/v1/v2), battery saves, save states, disc swapping, rotation,
  pointer input, audio-synchronised frame pacing.
- On-demand download of libretro cores and core system assets from the libretro
  buildbot.
- Support for 40 systems from NES to Dreamcast, PSP and arcade.
- Player window with Metal presentation (sharp bilinear, pixel perfect, smooth
  and scanline filters, integer scaling), pause menu, save state slots with
  thumbnails, core options, fast forward.
- Game controller support (up to four players) and remappable keyboard.
- BIOS manager with checksum verification and automatic renaming on import.
- English and German localization.
- Headless `ursprung-smoke` tool and unit tests.

### Known issues
- GLideN64's frame buffer emulation renders black on Apple's OpenGL; the N64
  core therefore defaults to the angrylion software renderer.
- Vulkan-only cores and renderers (e.g. ParaLLEl-RDP) are not supported.
