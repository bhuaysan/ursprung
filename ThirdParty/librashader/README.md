# librashader

[librashader](https://github.com/SnowflakePowered/librashader) 0.12.0 by
SnowflakePowered and contributors. Ursprung uses it to run RetroArch slang
shader presets (`.slangp`) on Metal; see `docs/SHADER_PLAN.md`.

## Licences

- The implementation (`librashader.dylib`) is available under the Mozilla
  Public License 2.0 (`LICENSE.md`) or the GNU General Public License 3.0
  (`LICENSE-GPL.md`). Its source code is at
  <https://github.com/SnowflakePowered/librashader/tree/librashader-v0.12.0>.
- The C header `include/librashader.h` is MIT licensed (see its header).

## What is here

- `include/librashader.h`: copied unchanged from the `librashader-v0.12.0` tag
  (identical to the header in the release archive).
- `LICENSE.md`, `LICENSE-GPL.md`: from the same tag.
- `lib/`: not committed. `Scripts/fetch-librashader.sh` (run by
  `make project` and `Scripts/dist.sh`) downloads the prebuilt
  `librashader-aarch64-macos-v0.12.0-optimized.zip` from the GitHub release,
  checks its SHA-256, sets the install name to `@rpath/librashader.dylib` and
  puts the dylib here. Xcode links it and embeds it, re-signed, in
  `Ursprung.app/Contents/Frameworks`.

## Updating

1. Pick a release on <https://github.com/SnowflakePowered/librashader/releases>.
   Check that `LIBRASHADER_CURRENT_ABI` in its header is still the same:
   a new ABI may change function signatures.
2. In `Scripts/fetch-librashader.sh`, set `VERSION` and `SHA256`. GitHub shows
   the archive's digest:
   `gh api repos/SnowflakePowered/librashader/releases/tags/librashader-v<version> -q '.assets[] | select(.name|test("aarch64-macos")) | .digest'`
3. Replace `include/librashader.h`, `LICENSE.md` and `LICENSE-GPL.md` with the
   files of the new tag, and update the version and links in this README.
4. Run `make test`. Then try a few presets from the libretro pack
   (crt-royale, crt-guest-advanced, a Mega Bezel preset) in the app.
