// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import Ursprung

/// Which graphics API a core is asked for, and what follows from it
/// (docs/VULKAN_PLAN.md, phase 3).
@Suite("Graphics API")
struct GraphicsAPITests {
    private let vulkanCore = CoreDefinition(id: "graphics-test", name: "Graphics Test",
                                            optionDefaults: ["rdp": "angrylion", "region": "auto"],
                                            renderer: .vulkan, vulkanOptionDefaults: ["rdp": "parallel"])
    private let openGLCore = CoreDefinition(id: "graphics-test-gl", name: "Graphics Test GL", vulkanOptionDefaults: [:])
    private let softwareCore = CoreDefinition(id: "graphics-test-sw", name: "Graphics Test SW")

    @Test func automaticFollowsTheCatalog() {
        #expect(vulkanCore.renderer(for: .automatic, vulkanAvailable: true) == .vulkan)
        #expect(openGLCore.renderer(for: .automatic, vulkanAvailable: true) == .opengl)
    }

    @Test func theUsersChoiceWins() {
        #expect(vulkanCore.renderer(for: .opengl, vulkanAvailable: true) == .opengl)
        #expect(openGLCore.renderer(for: .vulkan, vulkanAvailable: true) == .vulkan)
    }

    @Test func withoutVulkanEverythingUsesOpenGL() {
        #expect(vulkanCore.renderer(for: .automatic, vulkanAvailable: false) == .opengl)
        #expect(vulkanCore.renderer(for: .vulkan, vulkanAvailable: false) == .opengl)
        // What the session compares to tell the user once.
        #expect(vulkanCore.wantedRenderer(for: .automatic) == .vulkan)
    }

    @Test func coresWithoutVulkanIgnoreTheChoice() {
        #expect(!softwareCore.supportsVulkan)
        #expect(softwareCore.renderer(for: .vulkan, vulkanAvailable: true) == .opengl)
        #expect(vulkanCore.supportsVulkan && openGLCore.supportsVulkan)
    }

    @Test func optionDefaultsFollowTheRenderer() {
        #expect(vulkanCore.optionDefaults(for: .vulkan) == ["rdp": "parallel", "region": "auto"])
        #expect(vulkanCore.optionDefaults(for: .opengl) == ["rdp": "angrylion", "region": "auto"])
        #expect(softwareCore.optionDefaults(for: .vulkan) == [:])
    }

    @Test func catalogDefaults() throws {
        let n64 = try #require(SystemCatalog.system(withID: "n64"))
        let mupen = n64.defaultCore
        #expect(mupen.renderer == .vulkan)
        #expect(mupen.optionDefaults(for: .opengl)["mupen64plus-rdp-plugin"] == "angrylion", "Software RDP without Vulkan")
        #expect(mupen.optionDefaults(for: .vulkan)["mupen64plus-rdp-plugin"] == "parallel", "paraLLEl-RDP with Vulkan")
        #expect(!n64.core(withID: "parallel_n64").supportsVulkan, "Its macOS build has no paraLLEl-RDP")
        #expect(SystemCatalog.system(withID: "gamecube")?.defaultCore.renderer == .vulkan)
        #expect(SystemCatalog.system(withID: "psp")?.defaultCore.renderer == .opengl)

        let psx = try #require(SystemCatalog.system(withID: "psx"))
        #expect(psx.defaultCore.id == "pcsx_rearmed", "PCSX ReARMed stays the default")
        let beetleHW = psx.core(withID: "mednafen_psx_hw")
        #expect(beetleHW.id == "mednafen_psx_hw")
        #expect(beetleHW.optionDefaults(for: .vulkan)["beetle_psx_hw_renderer"] == "hardware_vk")
        #expect(psx.bios.contains { $0.isRequired(forCore: beetleHW.id) }, "Needs a BIOS like Beetle PSX")
    }

    @Test func choiceIsStoredPerCore() {
        let id = "graphics-test-\(UUID().uuidString)"
        defer { Preferences.setRendererChoice(.automatic, for: id) }
        #expect(Preferences.rendererChoice(for: id) == .automatic)
        Preferences.setRendererChoice(.opengl, for: id)
        #expect(Preferences.rendererChoice(for: id) == .opengl)
        Preferences.setRendererChoice(.automatic, for: id)
        #expect(UserDefaults.standard.object(forKey: PrefKey.rendererChoice(id)) == nil, "Automatic stores nothing")
    }
}

@Suite("Save states across renderers")
struct StateRendererTests {
    private let context = SaveStateContext(coreID: "mupen64plus_next", coreVersion: "2.6", gameCRC32: "AABBCCDD",
                                           gameFileName: "Zelda.z64", gameFileSize: 32)

    private func slot(renderer: String?) -> SaveStateSlot {
        let url = URL(filePath: "/tmp/slot1.state")
        var manifest = context.manifest()
        manifest.renderer = renderer
        return SaveStateSlot(slot: 1, date: .now, stateURL: url, thumbnailURL: url, manifestURL: url, manifest: manifest)
    }

    @Test func manifestsRecordTheRenderer() {
        #expect(context.rendering(with: .vulkan).manifest().renderer == "vulkan")
        #expect(context.manifest().renderer == nil)
    }

    @Test func anotherRendererIsAnIssue() {
        let current = context.rendering(with: .software)
        #expect(slot(renderer: "vulkan").issues(for: current) == [.renderer(.vulkan)])
        #expect(slot(renderer: "software").issues(for: current).isEmpty)
    }

    @Test func unknownRenderersAreNoIssue() {
        // States from before Ursprung recorded it, or a context without it (ARMSX2).
        #expect(slot(renderer: nil).issues(for: context.rendering(with: .vulkan)).isEmpty)
        #expect(slot(renderer: "vulkan").issues(for: context).isEmpty)
    }

    @Test func graphicsAPIsMapToStateRenderers() {
        #expect(StateRenderer(GraphicsAPI.none) == .software)
        #expect(StateRenderer(.openGL) == .opengl)
        #expect(StateRenderer(.vulkan) == .vulkan)
    }
}
