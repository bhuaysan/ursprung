// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// libretro cores known to work on macOS / Apple Silicon.
nonisolated enum Cores {
    private static let assets = URL(string: "https://buildbot.libretro.com/assets/system/")!

    static let fceumm = CoreDefinition(id: "fceumm", name: "FCEUmm")
    static let nestopia = CoreDefinition(id: "nestopia", name: "Nestopia UE")
    static let mesen = CoreDefinition(id: "mesen", name: "Mesen")
    static let snes9x = CoreDefinition(id: "snes9x", name: "Snes9x")
    static let bsnes = CoreDefinition(id: "bsnes", name: "bsnes")
    static let mesen2 = CoreDefinition(id: "mesen2", name: "Mesen 2")
    // Mupen64Plus-Next renders with paraLLEl-RDP (accurate, on the GPU)
    // through Vulkan. Without Vulkan, N64 cores use the accurate software RDP
    // (angrylion): GLideN64's frame buffer emulation renders black on Apple's
    // OpenGL. The macOS build of ParaLLEl N64 has no paraLLEl-RDP.
    static let mupen64plusNext = CoreDefinition(id: "mupen64plus_next", name: "Mupen64Plus-Next",
                                                optionDefaults: ["mupen64plus-rdp-plugin": "angrylion"],
                                                renderer: .vulkan,
                                                vulkanOptionDefaults: ["mupen64plus-rdp-plugin": "parallel",
                                                                       "mupen64plus-rsp-plugin": "parallel"])
    static let parallelN64 = CoreDefinition(id: "parallel_n64", name: "ParaLLEl N64",
                                            optionDefaults: ["parallel-n64-gfxplugin": "angrylion"])
    static let gambatte = CoreDefinition(id: "gambatte", name: "Gambatte")
    static let sameboy = CoreDefinition(id: "sameboy", name: "SameBoy")
    static let mgba = CoreDefinition(id: "mgba", name: "mGBA")
    static let vbaNext = CoreDefinition(id: "vba_next", name: "VBA Next")
    static let melondsds = CoreDefinition(id: "melondsds", name: "melonDS DS")
    static let desmume = CoreDefinition(id: "desmume", name: "DeSmuME")
    // Dolphin's OpenGL backend needs more than Apple's OpenGL 4.1 offers.
    static let dolphin = CoreDefinition(id: "dolphin", name: "Dolphin", renderer: .vulkan, vulkanOptionDefaults: [:],
                                        systemAssets: assets.appending(path: "Dolphin.zip"), experimental: true)
    static let beetleVB = CoreDefinition(id: "mednafen_vb", name: "Beetle VB")
    static let genesisPlusGX = CoreDefinition(id: "genesis_plus_gx", name: "Genesis Plus GX")
    static let picodrive = CoreDefinition(id: "picodrive", name: "PicoDrive")
    static let blastem = CoreDefinition(id: "blastem", name: "BlastEm")
    static let gearsystem = CoreDefinition(id: "gearsystem", name: "Gearsystem")
    static let beetleSaturn = CoreDefinition(id: "mednafen_saturn", name: "Beetle Saturn")
    static let yabause = CoreDefinition(id: "yabause", name: "Yabause")
    // Per-pixel alpha sorting exists only in Flycast's Vulkan renderer on macOS.
    static let flycast = CoreDefinition(id: "flycast", name: "Flycast", renderer: .vulkan, vulkanOptionDefaults: [:])
    static let pcsxRearmed = CoreDefinition(id: "pcsx_rearmed", name: "PCSX ReARMed")
    static let swanstation = CoreDefinition(id: "swanstation", name: "SwanStation", renderer: .vulkan,
                                            vulkanOptionDefaults: ["swanstation_GPU_Renderer": "Vulkan"])
    static let beetlePSX = CoreDefinition(id: "mednafen_psx", name: "Beetle PSX")
    static let beetlePSXHW = CoreDefinition(id: "mednafen_psx_hw", name: "Beetle PSX HW", renderer: .vulkan,
                                            vulkanOptionDefaults: ["beetle_psx_hw_renderer": "hardware_vk"])
    static let ppsspp = CoreDefinition(id: "ppsspp", name: "PPSSPP", vulkanOptionDefaults: [:],
                                       systemAssets: assets.appending(path: "PPSSPP.zip"))
    static let beetlePCEFast = CoreDefinition(id: "mednafen_pce_fast", name: "Beetle PCE Fast")
    static let beetleSuperGrafx = CoreDefinition(id: "mednafen_supergrafx", name: "Beetle SuperGrafx")
    static let stella = CoreDefinition(id: "stella", name: "Stella")
    static let a5200 = CoreDefinition(id: "a5200", name: "a5200")
    static let atari800 = CoreDefinition(id: "atari800", name: "Atari800")
    static let prosystem = CoreDefinition(id: "prosystem", name: "ProSystem")
    static let handy = CoreDefinition(id: "handy", name: "Handy")
    static let beetleLynx = CoreDefinition(id: "mednafen_lynx", name: "Beetle Lynx")
    static let virtualJaguar = CoreDefinition(id: "virtualjaguar", name: "Virtual Jaguar")
    static let beetleNGP = CoreDefinition(id: "mednafen_ngp", name: "Beetle NeoPop")
    static let beetleWSwan = CoreDefinition(id: "mednafen_wswan", name: "Beetle Cygne")
    static let gearcoleco = CoreDefinition(id: "gearcoleco", name: "Gearcoleco")
    static let freeintv = CoreDefinition(id: "freeintv", name: "FreeIntv")
    static let vecx = CoreDefinition(id: "vecx", name: "vecx")
    static let fbneo = CoreDefinition(id: "fbneo", name: "FinalBurn Neo")
    static let mame2003Plus = CoreDefinition(id: "mame2003_plus", name: "MAME 2003-Plus")
    static let opera = CoreDefinition(id: "opera", name: "Opera")
    static let bluemsx = CoreDefinition(id: "bluemsx", name: "blueMSX", systemAssets: assets.appending(path: "blueMSX.zip"))
    static let fmsx = CoreDefinition(id: "fmsx", name: "fMSX")
    static let pokemini = CoreDefinition(id: "pokemini", name: "PokeMini")

    // MARK: Standalone emulators

    /// PlayStation 2 through ARMSX2's macOS build: no libretro core runs PS2
    /// games on Apple Silicon (docs/STANDALONE_PLAN.md).
    static let armsx2 = CoreDefinition(id: StandaloneEmulator.armsx2.id, name: StandaloneEmulator.armsx2.name,
                                       backend: .standalone(.armsx2))
}

nonisolated extension StandaloneEmulator {
    /// Tested with the checklist in docs/STANDALONE_PLAN.md ("Spike results").
    static let armsx2 = StandaloneEmulator(
        id: "armsx2", name: "ARMSX2", repository: "ARMSX2/ARMSX2",
        release: Release(tag: "nightly-20261006", assetName: "ARMSX2-nightly-20261006-46c06fe7ca-macOS-arm64.tar.xz",
                         sha256: "cfb15cb8c220de7172bcdb3a73f63fae6700b240bb2d671c93df574247e5fc8e",
                         commit: "46c06fe7ca"),
        teamIdentifier: "L296QD7JFU", executable: "Contents/MacOS/ARMSX2", saveStateVersion: 0x9A59_0000)
}

nonisolated enum SystemCatalog {
    static let all: [GameSystem] = [
        // MARK: Nintendo
        GameSystem(id: "nes", name: "Nintendo Entertainment System", shortName: "NES", manufacturer: "Nintendo", year: 1983,
                   kind: .console, screenScraperID: 3, extensions: ["nes", "unf", "unif"],
                   folderAliases: ["nes", "famicom", "fc", "nintendo", "nintendoentertainmentsystem"],
                   cores: [Cores.fceumm, Cores.nestopia, Cores.mesen],
                   accent: 0xC4312E, boxAspect: 0.72),
        GameSystem(id: "fds", name: "Famicom Disk System", shortName: "FDS", manufacturer: "Nintendo", year: 1986,
                   kind: .console, screenScraperID: 106, extensions: ["fds"],
                   folderAliases: ["fds", "famicomdisksystem"],
                   cores: [Cores.fceumm, Cores.nestopia, Cores.mesen],
                   bios: [BIOSFile(fileName: "disksys.rom", md5: "ca30b50f880eb660a320674ed365ef7a", required: true)],
                   accent: 0xB8860B, boxAspect: 0.72),
        GameSystem(id: "snes", name: "Super Nintendo", shortName: "SNES", manufacturer: "Nintendo", year: 1990,
                   kind: .console, screenScraperID: 4, extensions: ["sfc", "smc", "swc", "fig", "bs"],
                   folderAliases: ["snes", "sfc", "supernintendo", "superfamicom", "supernes"],
                   cores: [Cores.snes9x, Cores.bsnes, Cores.mesen2],
                   accent: 0x5A4E9B, boxAspect: 1.38),
        GameSystem(id: "n64", name: "Nintendo 64", shortName: "N64", manufacturer: "Nintendo", year: 1996,
                   kind: .console, screenScraperID: 14, extensions: ["n64", "z64", "v64"],
                   folderAliases: ["n64", "nintendo64"],
                   cores: [Cores.mupen64plusNext, Cores.parallelN64],
                   accent: 0x1F8A3B, boxAspect: 1.38),
        GameSystem(id: "gamecube", name: "GameCube", shortName: "GC", manufacturer: "Nintendo", year: 2001,
                   kind: .console, screenScraperID: 13, extensions: ["gcm", "gcz", "rvz"],
                   folderAliases: ["gc", "gamecube", "ngc", "nintendogamecube"],
                   cores: [Cores.dolphin], accent: 0x5B3E9E, boxAspect: 0.71),
        GameSystem(id: "wii", name: "Wii", shortName: "Wii", manufacturer: "Nintendo", year: 2006,
                   kind: .console, screenScraperID: 16, extensions: ["wbfs", "wad"],
                   folderAliases: ["wii", "nintendowii"],
                   cores: [Cores.dolphin], accent: 0x8E9BA8, boxAspect: 0.71),
        GameSystem(id: "gb", name: "Game Boy", shortName: "GB", manufacturer: "Nintendo", year: 1989,
                   kind: .handheld, screenScraperID: 9, extensions: ["gb", "dmg"],
                   folderAliases: ["gb", "gameboy"],
                   cores: [Cores.gambatte, Cores.sameboy, Cores.mgba],
                   accent: 0x8B9A3C, boxAspect: 1.0),
        GameSystem(id: "gbc", name: "Game Boy Color", shortName: "GBC", manufacturer: "Nintendo", year: 1998,
                   kind: .handheld, screenScraperID: 10, extensions: ["gbc"],
                   folderAliases: ["gbc", "gameboycolor", "gameboycolour"],
                   cores: [Cores.gambatte, Cores.sameboy, Cores.mgba],
                   accent: 0x7A3FA0, boxAspect: 1.0),
        GameSystem(id: "gba", name: "Game Boy Advance", shortName: "GBA", manufacturer: "Nintendo", year: 2001,
                   kind: .handheld, screenScraperID: 12, extensions: ["gba", "agb"],
                   folderAliases: ["gba", "gameboyadvance"],
                   cores: [Cores.mgba, Cores.vbaNext],
                   bios: [BIOSFile(fileName: "gba_bios.bin", md5: "a860e8c0b6d573d191e4ec7db1b1e4f6", required: false,
                                   note: String(localized: "Improves accuracy."))],
                   accent: 0x3F3FA8, boxAspect: 1.0),
        GameSystem(id: "nds", name: "Nintendo DS", shortName: "NDS", manufacturer: "Nintendo", year: 2004,
                   kind: .handheld, screenScraperID: 15, extensions: ["nds", "dsi", "ids"],
                   folderAliases: ["nds", "ds", "nintendods"],
                   cores: [Cores.melondsds, Cores.desmume],
                   bios: [BIOSFile(fileName: "bios7.bin", md5: "df692a80a5b1bc90728bc3dfc76cd948", required: false),
                          BIOSFile(fileName: "bios9.bin", md5: "a392174eb3e572fed6447e956bde4b25", required: false),
                          BIOSFile(fileName: "firmware.bin", md5: nil, required: false)],
                   accent: 0x6D6F72, boxAspect: 0.9),
        GameSystem(id: "virtualboy", name: "Virtual Boy", shortName: "VB", manufacturer: "Nintendo", year: 1995,
                   kind: .console, screenScraperID: 11, extensions: ["vb", "vboy"],
                   folderAliases: ["vb", "virtualboy"],
                   cores: [Cores.beetleVB], accent: 0xB3261E, boxAspect: 0.72),
        GameSystem(id: "pokemini", name: "Pokémon mini", shortName: "Mini", manufacturer: "Nintendo", year: 2001,
                   kind: .handheld, screenScraperID: 211, extensions: ["min"],
                   folderAliases: ["pokemini", "pokemonmini"],
                   cores: [Cores.pokemini], accent: 0xE3A21A, boxAspect: 1.0),

        // MARK: Sega
        GameSystem(id: "sg1000", name: "SG-1000", shortName: "SG-1000", manufacturer: "Sega", year: 1983,
                   kind: .console, screenScraperID: 109, extensions: ["sg"],
                   folderAliases: ["sg1000", "sg"],
                   cores: [Cores.genesisPlusGX, Cores.gearsystem], accent: 0x2D6FB5, boxAspect: 0.72),
        GameSystem(id: "mastersystem", name: "Master System", shortName: "SMS", manufacturer: "Sega", year: 1985,
                   kind: .console, screenScraperID: 2, extensions: ["sms"],
                   folderAliases: ["sms", "mastersystem", "segamastersystem", "mark3"],
                   cores: [Cores.genesisPlusGX, Cores.gearsystem, Cores.picodrive], accent: 0xC8102E, boxAspect: 0.72),
        GameSystem(id: "megadrive", name: "Mega Drive / Genesis", shortName: "MD", manufacturer: "Sega", year: 1988,
                   kind: .console, screenScraperID: 1, extensions: ["md", "gen", "smd", "mdx", "68k", "sgd"],
                   folderAliases: ["md", "megadrive", "genesis", "segagenesis", "segamegadrive", "gen"],
                   cores: [Cores.genesisPlusGX, Cores.picodrive, Cores.blastem], accent: 0x1A1A1A, boxAspect: 0.72),
        GameSystem(id: "segacd", name: "Mega-CD / Sega CD", shortName: "Sega CD", manufacturer: "Sega", year: 1991,
                   kind: .console, screenScraperID: 20, extensions: [],
                   folderAliases: ["segacd", "megacd", "scd", "megacdsegacd"],
                   cores: [Cores.genesisPlusGX, Cores.picodrive],
                   bios: [BIOSFile(fileName: "bios_CD_U.bin", md5: "2efd74e3232ff260e371b99f84024f7f", required: true, note: "USA", group: "region"),
                          BIOSFile(fileName: "bios_CD_E.bin", md5: "e66fa1dc5820d254611fdcdba0662372", required: true, note: "Europe", group: "region"),
                          BIOSFile(fileName: "bios_CD_J.bin", md5: "278a9397d192149e84e820ac621a8edd", required: true, note: "Japan", group: "region")],
                   accent: 0x264D8C, boxAspect: 0.88),
        GameSystem(id: "sega32x", name: "32X", shortName: "32X", manufacturer: "Sega", year: 1994,
                   kind: .console, screenScraperID: 19, extensions: ["32x"],
                   folderAliases: ["32x", "sega32x", "megadrive32x"],
                   cores: [Cores.picodrive], accent: 0xD4A017, boxAspect: 0.72),
        GameSystem(id: "gamegear", name: "Game Gear", shortName: "GG", manufacturer: "Sega", year: 1990,
                   kind: .handheld, screenScraperID: 21, extensions: ["gg"],
                   folderAliases: ["gg", "gamegear", "segagamegear"],
                   cores: [Cores.genesisPlusGX, Cores.gearsystem], accent: 0x333333, boxAspect: 0.72),
        GameSystem(id: "saturn", name: "Saturn", shortName: "Saturn", manufacturer: "Sega", year: 1994,
                   kind: .console, screenScraperID: 22, extensions: [],
                   folderAliases: ["saturn", "segasaturn", "ss"],
                   cores: [Cores.beetleSaturn, Cores.yabause],
                   bios: [BIOSFile(fileName: "sega_101.bin", md5: "85ec9ca47d8f6807718151cbcca8b964", required: true, note: "Japan", group: "region"),
                          BIOSFile(fileName: "mpr-17933.bin", md5: "3240872c70984b6cbfda1586cab68dbe", required: true, note: "USA / Europe", group: "region")],
                   accent: 0x3B3B6D, boxAspect: 0.62),
        GameSystem(id: "dreamcast", name: "Dreamcast", shortName: "DC", manufacturer: "Sega", year: 1998,
                   kind: .console, screenScraperID: 23, extensions: ["cdi", "gdi"],
                   folderAliases: ["dc", "dreamcast", "segadreamcast"],
                   cores: [Cores.flycast],
                   bios: [BIOSFile(fileName: "dc/dc_boot.bin", md5: "e10c53c2f8b90bab96ead2d368858623", required: false,
                                   note: String(localized: "Flycast includes an HLE BIOS.")),
                          BIOSFile(fileName: "dc/dc_flash.bin", md5: "0a93f7940c455905bea6e392dfde92a4", required: false)],
                   accent: 0xE35205, boxAspect: 1.0),

        // MARK: Sony
        GameSystem(id: "psx", name: "PlayStation", shortName: "PS1", manufacturer: "Sony", year: 1994,
                   kind: .console, screenScraperID: 57, extensions: [],
                   folderAliases: ["psx", "ps1", "playstation", "sonyplaystation", "playstation1"],
                   cores: [Cores.pcsxRearmed, Cores.swanstation, Cores.beetlePSX, Cores.beetlePSXHW],
                   bios: [BIOSFile(fileName: "scph5500.bin", md5: "8dd7d5296a650fac7319bce665a6a53c", required: false, note: "Japan",
                                   group: "region", requiredBy: [Cores.swanstation.id, Cores.beetlePSX.id, Cores.beetlePSXHW.id]),
                          BIOSFile(fileName: "scph5501.bin", md5: "490f666e1afb15b7362b406ed1cea246", required: false, note: "USA",
                                   group: "region", requiredBy: [Cores.swanstation.id, Cores.beetlePSX.id, Cores.beetlePSXHW.id]),
                          BIOSFile(fileName: "scph5502.bin", md5: "32736f17079d0b2b7024407c39bd3050", required: false, note: "Europe",
                                   group: "region", requiredBy: [Cores.swanstation.id, Cores.beetlePSX.id, Cores.beetlePSXHW.id]),
                          BIOSFile(fileName: "scph1001.bin", md5: "924e392ed05558ffdb115408c263dccf", required: false, note: "USA",
                                   group: "region", requiredBy: [Cores.swanstation.id, Cores.beetlePSX.id, Cores.beetlePSXHW.id])],
                   accent: 0x6B6B6B, boxAspect: 1.0),
        GameSystem(id: "psp", name: "PlayStation Portable", shortName: "PSP", manufacturer: "Sony", year: 2004,
                   kind: .handheld, screenScraperID: 61, extensions: ["cso"],
                   folderAliases: ["psp", "playstationportable"],
                   cores: [Cores.ppsspp], accent: 0x1E1E1E, boxAspect: 0.58),
        // `.cso` also stays a PSP extension: outside a PS2 folder it means PSP.
        GameSystem(id: "ps2", name: "PlayStation 2", shortName: "PS2", manufacturer: "Sony", year: 2000,
                   kind: .console, screenScraperID: 58, extensions: ["cso", "zso"],
                   folderAliases: ["ps2", "playstation2", "sonyplaystation2"],
                   cores: [Cores.armsx2],
                   biosFolder: BIOSFolder(path: "pcsx2/bios", kind: .playStation2, requiredBy: [Cores.armsx2.id]),
                   accent: 0x2B3990, boxAspect: 0.71),

        // MARK: NEC
        GameSystem(id: "pce", name: "PC Engine / TurboGrafx-16", shortName: "PCE", manufacturer: "NEC", year: 1987,
                   kind: .console, screenScraperID: 31, extensions: ["pce"],
                   folderAliases: ["pce", "pcengine", "tg16", "turbografx", "turbografx16"],
                   cores: [Cores.beetlePCEFast], accent: 0xE4572E, boxAspect: 0.9),
        GameSystem(id: "pcecd", name: "PC Engine CD", shortName: "PCE-CD", manufacturer: "NEC", year: 1988,
                   kind: .console, screenScraperID: 114, extensions: [],
                   folderAliases: ["pcecd", "pcenginecd", "tgcd", "turbografxcd", "tg16cd"],
                   cores: [Cores.beetlePCEFast],
                   bios: [BIOSFile(fileName: "syscard3.pce", md5: "38179df8f4ac870017db21ebcbf53114", required: true)],
                   accent: 0xC0392B, boxAspect: 0.88),
        GameSystem(id: "supergrafx", name: "SuperGrafx", shortName: "SGX", manufacturer: "NEC", year: 1989,
                   kind: .console, screenScraperID: 105, extensions: ["sgx"],
                   folderAliases: ["sgx", "supergrafx"],
                   cores: [Cores.beetleSuperGrafx], accent: 0x34495E, boxAspect: 0.9),

        // MARK: Atari
        GameSystem(id: "atari2600", name: "Atari 2600", shortName: "2600", manufacturer: "Atari", year: 1977,
                   kind: .console, screenScraperID: 26, extensions: ["a26"],
                   folderAliases: ["atari2600", "2600", "vcs"],
                   cores: [Cores.stella], accent: 0x8B5A2B, boxAspect: 0.72),
        GameSystem(id: "atari5200", name: "Atari 5200", shortName: "5200", manufacturer: "Atari", year: 1982,
                   kind: .console, screenScraperID: 40, extensions: ["a52"],
                   folderAliases: ["atari5200", "5200"],
                   cores: [Cores.a5200, Cores.atari800],
                   bios: [BIOSFile(fileName: "5200.rom", md5: "281f20ea4320404ec820fb7ec0693b38", required: true)],
                   accent: 0x4A4A4A, boxAspect: 0.72),
        GameSystem(id: "atari7800", name: "Atari 7800", shortName: "7800", manufacturer: "Atari", year: 1986,
                   kind: .console, screenScraperID: 41, extensions: ["a78"],
                   folderAliases: ["atari7800", "7800"],
                   cores: [Cores.prosystem],
                   bios: [BIOSFile(fileName: "7800 BIOS (U).rom", md5: "0763f1ffb006ddbe32e52d497ee848ae", required: false)],
                   accent: 0x7D3C98, boxAspect: 0.72),
        GameSystem(id: "lynx", name: "Atari Lynx", shortName: "Lynx", manufacturer: "Atari", year: 1989,
                   kind: .handheld, screenScraperID: 28, extensions: ["lnx", "lyx", "o"],
                   folderAliases: ["lynx", "atarilynx"],
                   cores: [Cores.handy, Cores.beetleLynx],
                   bios: [BIOSFile(fileName: "lynxboot.img", md5: "fcd403db69f54290b51035d82f835e7b", required: true)],
                   accent: 0xF39C12, boxAspect: 0.72),
        GameSystem(id: "jaguar", name: "Atari Jaguar", shortName: "Jaguar", manufacturer: "Atari", year: 1993,
                   kind: .console, screenScraperID: 27, extensions: ["j64", "jag"],
                   folderAliases: ["jaguar", "atarijaguar"],
                   cores: [Cores.virtualJaguar], accent: 0xA93226, boxAspect: 0.72),

        // MARK: Handhelds (other)
        GameSystem(id: "ngp", name: "Neo Geo Pocket", shortName: "NGP", manufacturer: "SNK", year: 1998,
                   kind: .handheld, screenScraperID: 25, extensions: ["ngp"],
                   folderAliases: ["ngp", "neogeopocket"],
                   cores: [Cores.beetleNGP], accent: 0x2C3E50, boxAspect: 0.72),
        GameSystem(id: "ngpc", name: "Neo Geo Pocket Color", shortName: "NGPC", manufacturer: "SNK", year: 1999,
                   kind: .handheld, screenScraperID: 82, extensions: ["ngc", "ngpc"],
                   folderAliases: ["ngpc", "neogeopocketcolor"],
                   cores: [Cores.beetleNGP], accent: 0x16A085, boxAspect: 0.72),
        GameSystem(id: "wonderswan", name: "WonderSwan", shortName: "WS", manufacturer: "Bandai", year: 1999,
                   kind: .handheld, screenScraperID: 45, extensions: ["ws"],
                   folderAliases: ["ws", "wonderswan"],
                   cores: [Cores.beetleWSwan], accent: 0x7F8C8D, boxAspect: 0.72),
        GameSystem(id: "wonderswancolor", name: "WonderSwan Color", shortName: "WSC", manufacturer: "Bandai", year: 2000,
                   kind: .handheld, screenScraperID: 46, extensions: ["wsc"],
                   folderAliases: ["wsc", "wonderswancolor"],
                   cores: [Cores.beetleWSwan], accent: 0x2980B9, boxAspect: 0.72),

        // MARK: Other consoles
        GameSystem(id: "colecovision", name: "ColecoVision", shortName: "Coleco", manufacturer: "Coleco", year: 1982,
                   kind: .console, screenScraperID: 48, extensions: ["col"],
                   folderAliases: ["coleco", "colecovision"],
                   cores: [Cores.gearcoleco],
                   bios: [BIOSFile(fileName: "colecovision.rom", md5: "2c66f5911e5b42b8ebe113403548eee7", required: true)],
                   accent: 0x1B4F72, boxAspect: 0.72),
        GameSystem(id: "intellivision", name: "Intellivision", shortName: "Intv", manufacturer: "Mattel", year: 1979,
                   kind: .console, screenScraperID: 115, extensions: ["int"],
                   folderAliases: ["intellivision", "intv"],
                   cores: [Cores.freeintv],
                   bios: [BIOSFile(fileName: "exec.bin", md5: "62e761035cb657903761800f4437b8af", required: true),
                          BIOSFile(fileName: "grom.bin", md5: "0cd5946c6473e42e8e4c2137785e427f", required: true)],
                   accent: 0x7E5109, boxAspect: 0.72),
        GameSystem(id: "vectrex", name: "Vectrex", shortName: "Vectrex", manufacturer: "GCE", year: 1982,
                   kind: .console, screenScraperID: 102, extensions: ["vec"],
                   folderAliases: ["vectrex"],
                   cores: [Cores.vecx], accent: 0x212F3D, boxAspect: 0.72),
        GameSystem(id: "3do", name: "3DO", shortName: "3DO", manufacturer: "Panasonic", year: 1993,
                   kind: .console, screenScraperID: 29, extensions: [],
                   folderAliases: ["3do", "panasonic3do"],
                   cores: [Cores.opera],
                   bios: [BIOSFile(fileName: "panafz10.bin", md5: "51f2f43ae2f3508a14d9f56597e2d3ce", required: true)],
                   accent: 0x922B21, boxAspect: 0.88),

        // MARK: Computers
        GameSystem(id: "msx", name: "MSX / MSX2", shortName: "MSX", manufacturer: "Microsoft / ASCII", year: 1983,
                   kind: .computer, screenScraperID: 113, extensions: ["mx1", "mx2", "dsk", "cas"],
                   folderAliases: ["msx", "msx1", "msx2"],
                   cores: [Cores.bluemsx, Cores.fmsx], accent: 0x1F618D, boxAspect: 0.72),

        // MARK: Arcade
        GameSystem(id: "arcade", name: "Arcade", shortName: "Arcade", manufacturer: "Various", year: 1978,
                   kind: .arcade, screenScraperID: 75, extensions: [],
                   folderAliases: ["arcade", "mame", "fbneo", "fba", "finalburn", "cps1", "cps2", "cps3", "neogeo", "mame2003"],
                   cores: [Cores.fbneo, Cores.mame2003Plus],
                   bios: [BIOSFile(fileName: "fbneo/neogeo.zip", md5: nil, required: false,
                                   note: String(localized: "Required for Neo Geo games."))],
                   archivesAreNative: true, accent: 0xB7950B, boxAspect: 0.75),
    ]

    private static let byID: [String: GameSystem] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func system(withID id: String) -> GameSystem? { byID[id] }

    /// Extensions that are shared by several disc/cartridge systems and need
    /// the folder name to be resolved.
    static let ambiguousExtensions: Set<String> = ["bin", "iso", "cue", "chd", "img", "m3u", "zip", "7z", "rom", "mdf", "toc", "ccd", "pbp"]

    /// Systems a game with the given extension could belong to.
    static func candidates(forExtension ext: String) -> [GameSystem] {
        let ext = ext.lowercased()
        if let exact = extensionIndex[ext] { return exact }
        switch ext {
        case "cue", "chd", "iso", "bin", "img", "m3u", "mdf", "toc", "ccd":
            return all.filter { discSystems.contains($0.id) }
        case "pbp":
            return all.filter { $0.id == "psx" || $0.id == "psp" }
        case "zip", "7z":
            return all
        case "rom":
            return all.filter { ["msx", "atari5200", "atari7800", "colecovision", "intellivision", "atari2600"].contains($0.id) }
        default:
            return []
        }
    }

    /// Systems whose games are commonly stored as disc images.
    static let discSystems: Set<String> = ["psx", "psp", "ps2", "segacd", "saturn", "dreamcast", "pcecd", "3do", "gamecube", "wii"]

    /// Cartridge systems whose ROMs Ursprung can patch (IPS, UPS, BPS):
    /// not disc images, and not arcade sets, which cores read as archives.
    static func supportsPatches(_ system: GameSystem) -> Bool {
        !discSystems.contains(system.id) && !system.archivesAreNative
    }

    private static let extensionIndex: [String: [GameSystem]] = {
        var index: [String: [GameSystem]] = [:]
        for system in all {
            for ext in system.extensions { index[ext, default: []].append(system) }
        }
        return index
    }()

    /// Maps a folder name to a system via the alias table.
    static func system(forFolderName name: String) -> GameSystem? {
        let normalized = normalize(name)
        return aliasIndex[normalized]
    }

    private static let aliasIndex: [String: GameSystem] = {
        var index: [String: GameSystem] = [:]
        for system in all {
            index[system.id] = system
            for alias in system.folderAliases where index[alias] == nil { index[alias] = system }
        }
        return index
    }()

    static func normalize(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
