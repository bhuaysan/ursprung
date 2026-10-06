// SPDX-License-Identifier: GPL-3.0-or-later
//
// Ursprung — a native retro game library for macOS, powered by libretro.
// Copyright (C) 2026 Ursprung contributors
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for details.

import SwiftData
import SwiftUI

@main
struct UrsprungApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var metadata: MetadataService
    @State private var library: LibraryStore
    @State private var cores = CoreManager()
    @State private var bios = BIOSManager()
    @State private var session: EmulationSession
    @State private var systemMedia = SystemMediaStore()
    @State private var backup: BackupService
    @State private var updates = UpdateChecker()
    @State private var achievements: AchievementService
    @State private var shaders: ShaderLibrary
    @State private var shaderEditor: ShaderEditor

    private let container: ModelContainer

    init() {
        Preferences.registerDefaults()
        #if DEBUG
        DebugSnapshots.startIfRequested()
        #endif
        let metadata = MetadataService()
        let cores = CoreManager()
        let bios = BIOSManager()
        let library = LibraryStore(metadata: metadata)
        let achievements = AchievementService()
        let session = EmulationSession(cores: cores, bios: bios, achievements: achievements)
        let shaders = ShaderLibrary()
        _shaders = State(initialValue: shaders)
        _shaderEditor = State(initialValue: ShaderEditor(session: session, shaders: shaders))
        _achievements = State(initialValue: achievements)
        _metadata = State(initialValue: metadata)
        _library = State(initialValue: library)
        _cores = State(initialValue: cores)
        _bios = State(initialValue: bios)
        _session = State(initialValue: session)

        let storeURL = AppPaths.root.appending(path: "Library.store")
        do {
            container = try LibraryDatabase.open(
                at: storeURL,
                make: { try ModelContainer.library(configuration: ModelConfiguration(url: $0)) },
                recover: LibraryDatabase.askUser)
        } catch {
            // The library is never deleted here: without a usable store the app
            // quits and leaves the files for the user (or a later version) to recover.
            LibraryDatabase.reportFailure(error)
            exit(EXIT_FAILURE)
        }
        _backup = State(initialValue: BackupService(container: container, library: library, session: session,
                                                    shaders: shaders))
    }

    var body: some Scene {
        Window("Ursprung", id: WindowID.library) {
            LibraryView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            AppCommands(session: session, backup: backup, updates: updates)
            SidebarCommands()
        }
        .environment(metadata)
        .environment(library)
        .environment(cores)
        .environment(bios)
        .environment(session)
        .environment(systemMedia)
        .environment(shaders)
        .environment(shaderEditor)
        .modelContainer(container)

        Window(String(localized: "Player"), id: WindowID.player) {
            PlayerView()
                .frame(minWidth: 480, minHeight: 360)
        }
        .defaultSize(width: 1024, height: 768)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .environment(session)
        .environment(cores)
        .environment(shaders)
        .environment(shaderEditor)
        .modelContainer(container)

        Window(String(localized: "Shader Editor"), id: WindowID.shaderEditor) {
            ShaderEditorWindow()
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1320, height: 880)
        .restorationBehavior(.disabled)
        .environment(session)
        .environment(shaders)
        .environment(shaderEditor)

        WindowGroup(String(localized: "Manual"), id: WindowID.manual, for: UUID.self) { $gameID in
            ManualView(gameID: gameID)
                .frame(minWidth: 480, minHeight: 400)
        }
        .defaultSize(width: 760, height: 900)
        .restorationBehavior(.disabled)
        .modelContainer(container)

        Settings {
            SettingsView()
                .frame(width: 700)
                .frame(minHeight: 440, idealHeight: 560, maxHeight: .infinity)
        }
        .defaultSize(width: 700, height: 560)
        .environment(metadata)
        .environment(library)
        .environment(cores)
        .environment(bios)
        .environment(session)
        .environment(backup)
        .environment(achievements)
        .environment(shaders)
        .environment(shaderEditor)
        .modelContainer(container)
    }
}

enum WindowID {
    static let library = "library"
    static let player = "player"
    static let manual = "manual"
    static let shaderEditor = "shader-editor"
}
