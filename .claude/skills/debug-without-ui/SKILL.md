---
name: debug-without-ui
description: Debug-build environment variables for inspecting or driving Ursprung without UI access (window snapshots, autoplay, select a game/system, core logs, save-state and play-feature exercises). Use when verifying UI or emulation changes headlessly.
---

# Debugging without UI access

Debug builds: `URSPRUNG_SNAPSHOT_DIR=<dir>` writes window snapshots plus `frame.png`/`session.txt` of the running game; `URSPRUNG_AUTOPLAY=<title>` starts a game, `URSPRUNG_SELECT=<title>` selects one, `URSPRUNG_SYSTEM=<id>` shows one system, `URSPRUNG_METADATA_ERROR=<text>` shows the activity footer's error row (`quota` for the real quota copy), `URSPRUNG_CORE_LOG=1` mirrors core logs to stderr, `URSPRUNG_DEBUG_STATES=1` exercises save/load/quit, `URSPRUNG_SHADER_EDITOR=<preset:library/path.slangp|preset:user/path.slangp|system id|new>` opens the shader editor with that preset, `URSPRUNG_DEBUG_PLAY=1` takes a screenshot, rewinds, fast forwards and quits (`session.txt` shows rewind seconds, run-ahead, cheats and patch). Liquid Glass and Metal layers do not appear in window snapshots.
