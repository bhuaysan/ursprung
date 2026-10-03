# BIOS files

Some systems need the original firmware ("BIOS") of the console. Ursprung never
ships BIOS files — you have to dump them from hardware you own.

## Importing

1. Open **Settings → BIOS**.
2. Click **Import BIOS Files…** or drag files (or a whole folder) onto the
   window.
3. Ursprung recognises each file by its MD5 checksum or file name, renames it to
   what the core expects and copies it to
   `~/Library/Application Support/Ursprung/System/`.

The list shows a status for every file:

| Status | Meaning |
|---|---|
| **Verified** | Present, checksum matches the known good dump |
| **Present** | Present; no reference checksum is known |
| **Unknown Version** | Present, but the checksum differs — it may still work |
| **Missing** | Not found (red if the system cannot start without it) |

Which files are required depends on the core: some cores bring a built-in
BIOS. The list shows "Required for …" for such files, and a game's inspector
warns when the core it uses misses a BIOS, with a button to import it. If a
required BIOS is missing, starting a game shows which files are needed. For
systems with regional BIOS variants (Sega CD, Saturn, PlayStation) one of them
is enough.

## Reference

| System | File | Required | MD5 |
|---|---|---|---|
| Famicom Disk System | `disksys.rom` | yes | `ca30b50f880eb660a320674ed365ef7a` |
| Game Boy Advance | `gba_bios.bin` | no | `a860e8c0b6d573d191e4ec7db1b1e4f6` |
| Nintendo DS | `bios7.bin` | no | `df692a80a5b1bc90728bc3dfc76cd948` |
| Nintendo DS | `bios9.bin` | no | `a392174eb3e572fed6447e956bde4b25` |
| Nintendo DS | `firmware.bin` | no | – |
| Mega-CD / Sega CD | `bios_CD_U.bin` (USA) | one of three | `2efd74e3232ff260e371b99f84024f7f` |
| Mega-CD / Sega CD | `bios_CD_E.bin` (Europe) | one of three | `e66fa1dc5820d254611fdcdba0662372` |
| Mega-CD / Sega CD | `bios_CD_J.bin` (Japan) | one of three | `278a9397d192149e84e820ac621a8edd` |
| Saturn | `sega_101.bin` (Japan) | one of two | `85ec9ca47d8f6807718151cbcca8b964` |
| Saturn | `mpr-17933.bin` (USA/Europe) | one of two | `3240872c70984b6cbfda1586cab68dbe` |
| Dreamcast | `dc/dc_boot.bin` | no | `e10c53c2f8b90bab96ead2d368858623` |
| Dreamcast | `dc/dc_flash.bin` | no | `0a93f7940c455905bea6e392dfde92a4` |
| PlayStation | `scph5500.bin` (Japan) | one of four* | `8dd7d5296a650fac7319bce665a6a53c` |
| PlayStation | `scph5501.bin` (USA) | one of four* | `490f666e1afb15b7362b406ed1cea246` |
| PlayStation | `scph5502.bin` (Europe) | one of four* | `32736f17079d0b2b7024407c39bd3050` |
| PlayStation | `scph1001.bin` (USA) | one of four* | `924e392ed05558ffdb115408c263dccf` |
| PC Engine CD | `syscard3.pce` | yes | `38179df8f4ac870017db21ebcbf53114` |
| Atari 5200 | `5200.rom` | yes | `281f20ea4320404ec820fb7ec0693b38` |
| Atari 7800 | `7800 BIOS (U).rom` | no | `0763f1ffb006ddbe32e52d497ee848ae` |
| Atari Lynx | `lynxboot.img` | yes | `fcd403db69f54290b51035d82f835e7b` |
| ColecoVision | `colecovision.rom` | yes | `2c66f5911e5b42b8ebe113403548eee7` |
| Intellivision | `exec.bin` | yes | `62e761035cb657903761800f4437b8af` |
| Intellivision | `grom.bin` | yes | `0cd5946c6473e42e8e4c2137785e427f` |
| 3DO | `panafz10.bin` | yes | `51f2f43ae2f3508a14d9f56597e2d3ce` |
| Arcade (Neo Geo) | `fbneo/neogeo.zip` | for Neo Geo games | – |

\* Only for SwanStation and Beetle PSX. PCSX ReARMed (the default PlayStation
core) has a built-in HLE BIOS.

The authoritative source is `SystemCatalog.swift`; the checksums follow the
[libretro documentation](https://docs.libretro.com/).
