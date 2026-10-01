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
    @State private var metadata: MetadataService
    @State private var library: LibraryStore
    @State private var cores = CoreManager()
    @State private var bios = BIOSManager()
    @State private var session: EmulationSession
    @State private var systemMedia = SystemMediaStore()

    private let container: ModelContainer

    init() {
        Preferences.registerDefaults()
        #if DEBUG
        DebugSnapshots.startIfRequested()
        #endif
        let metadata = MetadataService()
        let cores = CoreManager()
        let bios = BIOSManager()
        _metadata = State(initialValue: metadata)
        _library = State(initialValue: LibraryStore(metadata: metadata))
        _cores = State(initialValue: cores)
        _bios = State(initialValue: bios)
        _session = State(initialValue: EmulationSession(cores: cores, bios: bios))

        let storeURL = AppPaths.root.appending(path: "Library.store")
        do {
            container = try LibraryDatabase.open(
                at: storeURL,
                make: { try ModelContainer(for: Game.self, configurations: ModelConfiguration(url: $0)) },
                recover: LibraryDatabase.askUser)
        } catch {
            // The library is never deleted here: without a usable store the app
            // quits and leaves the files for the user (or a later version) to recover.
            LibraryDatabase.reportFailure(error)
            exit(EXIT_FAILURE)
        }
    }

    var body: some Scene {
        Window("Ursprung", id: WindowID.library) {
            LibraryView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            AppCommands(session: session)
            SidebarCommands()
            InspectorCommands()
        }
        .environment(metadata)
        .environment(library)
        .environment(cores)
        .environment(bios)
        .environment(session)
        .environment(systemMedia)
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
        .modelContainer(container)

        Settings {
            SettingsView()
                .frame(width: 720, height: 560)
        }
        .environment(metadata)
        .environment(library)
        .environment(cores)
        .environment(bios)
        .environment(session)
        .modelContainer(container)
    }
}

enum WindowID {
    static let library = "library"
    static let player = "player"
}
