# rcheevos

[rcheevos](https://github.com/RetroAchievements/rcheevos) 12.5.0 by
RetroAchievements.org, MIT License (see `LICENSE`). Ursprung uses it for
RetroAchievements: `rc_client` signs in, identifies games and evaluates
achievements; `rc_libretro` maps the memory of libretro cores.

Copied unchanged from the v12.5.0 release, without the Windows-only
RAIntegration files, `rc_client_external.c`, the 3DS decryption
(`hash_encrypted.c`, `aes.c`, `aes.h`), the Swift package module map
and the Visual Studio debugger files. Compiled with `RC_DISABLE_LUA`,
`RC_CLIENT_SUPPORTS_HASH` and `RC_HASH_NO_ENCRYPTED` (see `project.yml`).

To update, replace `include/` and `src/` with those of a newer release and
remove the same files again.
