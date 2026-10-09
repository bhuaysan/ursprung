# MoltenVK

[MoltenVK](https://github.com/KhronosGroup/MoltenVK) 1.4.2 by the Khronos
Group. It implements Vulkan on top of Metal; Ursprung uses it to give
libretro cores a Vulkan context (paraLLEl-RDP, Dolphin, Flycast, …), see
`docs/VULKAN_PLAN.md`. Ursprung's own rendering stays on Metal.

## Licences

- MoltenVK is available under the Apache License 2.0 (`LICENSE`), which is
  compatible with Ursprung's GPL-3.0-or-later. Its source code is at
  <https://github.com/KhronosGroup/MoltenVK/tree/v1.4.2>.
- The Vulkan headers in the release (`include/vulkan`, `include/vk_video`)
  are from Khronos' Vulkan-Headers, under the Apache License 2.0 or the MIT
  licence (see the header comments).
- `Ursprung/Bridge/libretro_vulkan.h` is from libretro-common (MIT, see its
  header), unchanged.

## What is here

- `LICENSE`: from the release archive.
- `lib/` and `include/`: not committed. `Scripts/fetch-moltenvk.sh` (run by
  `make project` and `Scripts/dist.sh`) downloads `MoltenVK-macos.tar` from
  the GitHub release, checks its SHA-256, thins `libMoltenVK.dylib` to arm64
  (5 MB instead of 11 MB) and copies the C headers. The release already uses
  `@rpath/libMoltenVK.dylib` as install name. Xcode links the dylib directly
  (no Vulkan loader) and embeds it, re-signed, in
  `Ursprung.app/Contents/Frameworks`.
- `libvulkan.1.dylib`: a symlink to `libMoltenVK.dylib`, made by the fetch
  script in `lib/` and by a build phase in the app's `Frameworks`. Dolphin
  `dlopen`s that name at boot; dyld finds it through the rpath and returns the
  MoltenVK that is already loaded.

## Updating

1. Pick a release on <https://github.com/KhronosGroup/MoltenVK/releases> and
   read its `Docs/Whats_New.md` for changed defaults (`MVK_CONFIG_*`).
2. In `Scripts/fetch-moltenvk.sh`, set `VERSION` and `SHA256`. GitHub shows
   the archive's digest:
   `gh api repos/KhronosGroup/MoltenVK/releases/tags/v<version> -q '.assets[] | select(.name=="MoltenVK-macos.tar") | .digest'`
3. Replace `LICENSE` if it changed, and update the version and links in this
   README.
4. Run `make test` (the Vulkan tests drive the test core through MoltenVK),
   then the smoke checks from `docs/VULKAN_PLAN.md` ("Tests") for every core
   that defaults to Vulkan, including `URSMOKE_REPEAT=12`.
