// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

/// The Settings tabs. The selected one is stored, so other windows can open a specific tab.
enum SettingsTab: String {
    case general, metadata, emulation, controls, cores, bios
}

struct SettingsView: View {
    @AppStorage(PrefKey.settingsTab) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: .general) { GeneralSettingsView() }
            Tab("Metadata", systemImage: "sparkles", value: .metadata) { MetadataSettingsView() }
            Tab("Emulation", systemImage: "display", value: .emulation) { EmulationSettingsView() }
            Tab("Controls", systemImage: "gamecontroller", value: .controls) { ControlsSettingsView() }
            Tab("Cores", systemImage: "cpu", value: .cores) { CoresSettingsView() }
            Tab("BIOS", systemImage: "memorychip", value: .bios) { BIOSSettingsView() }
        }
        .scenePadding()
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.modelContext) private var context
    @State private var selection: URL?

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(library.folders, id: \.self) { folder in
                        Label {
                            VStack(alignment: .leading) {
                                Text(folder.lastPathComponent)
                                Text(folder.path(percentEncoded: false))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        } icon: {
                            Image(systemName: "folder.fill").foregroundStyle(.tint)
                        }
                        .tag(folder)
                    }
                }
                .frame(minHeight: 140)
                HStack {
                    Button("Add Folder…") { library.presentAddFolderPanel(context: context) }
                    Button("Remove") {
                        if let selection { library.removeFolder(selection, context: context) }
                        selection = nil
                    }
                    .disabled(selection == nil)
                    Spacer()
                    if library.isScanning { ProgressView().controlSize(.small) }
                    Button("Rescan") { Task { await library.rescan(context: context) } }
                        .disabled(library.isScanning || library.folders.isEmpty)
                }
                if let summary = library.lastScanSummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Library Folders")
            } footer: {
                Text("Name sub folders after the system (for example “PSX”, “Saturn” or “Arcade”) so disc images and archives are assigned correctly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                LabeledContent("Application Data") {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.root) }
                }
                LabeledContent("Battery Saves") {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.saves) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Metadata

struct MetadataSettingsView: View {
    @Environment(MetadataService.self) private var metadata
    @Environment(\.modelContext) private var context
    @Query private var games: [Game]

    @AppStorage(PrefKey.scraperUsername) private var username = ""
    @AppStorage(PrefKey.scraperLanguage) private var language = "en"
    @AppStorage(PrefKey.scraperRegion) private var region = "eu"
    @AppStorage(PrefKey.autoScrape) private var autoScrape = true
    @State private var password = ""

    private let languages = [("en", "English"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"), ("pt", "Português")]
    private let regions = [("eu", String(localized: "Europe")), ("us", String(localized: "North America")), ("jp", String(localized: "Japan")), ("wor", String(localized: "World"))]

    var body: some View {
        Form {
            Section {
                if !Secrets.hasScreenScraperCredentials {
                    Label("This build has no ScreenScraper developer credentials. See the README for how to add them.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .onSubmit { Keychain.setPassword(password, for: username) }
                    .onChange(of: password) { _, value in Keychain.setPassword(value, for: username) }
            } header: {
                Text("ScreenScraper Account")
            } footer: {
                Text("Optional. A free account at screenscraper.fr raises the daily request quota and speeds up scraping. The password is stored in your keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preferences") {
                Picker("Language", selection: $language) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Preferred Region", selection: $region) {
                    ForEach(regions, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Fetch metadata automatically for new games", isOn: $autoScrape)
            }

            Section("Library") {
                LabeledContent("Matched") {
                    Text("\(games.filter { $0.scrapeState == .matched }.count) of \(games.count)")
                        .monospacedDigit()
                }
                HStack {
                    Button("Fetch Missing") { metadata.enqueue(games, context: context) }
                    Button("Refetch All") { metadata.enqueue(games, force: true, context: context) }
                    Spacer()
                    if metadata.isRunning {
                        ProgressView(value: metadata.progress).frame(width: 120)
                        Button("Stop") { metadata.cancel() }
                    }
                }
                if let error = metadata.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { password = Keychain.password(for: username) ?? "" }
        .onChange(of: username) { _, value in password = Keychain.password(for: value) ?? "" }
    }
}

// MARK: - Emulation

struct EmulationSettingsView: View {
    @Environment(EmulationSession.self) private var session
    @AppStorage(PrefKey.videoFilter) private var filter: VideoFilter = .sharp
    @AppStorage(PrefKey.integerScaling) private var integerScaling = false
    @AppStorage(PrefKey.showFPS) private var showFPS = false
    @AppStorage(PrefKey.volume) private var volume = 1.0
    @AppStorage(PrefKey.pauseInBackground) private var pauseInBackground = true
    @State private var coreChoices: [String: String] = [:]

    var body: some View {
        Form {
            Section("Video") {
                Picker("Filter", selection: $filter) {
                    ForEach(VideoFilter.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Integer scaling", isOn: $integerScaling)
                Toggle("Show frame rate", isOn: $showFPS)
            }
            Section("Audio") {
                Slider(value: $volume, in: 0...1) {
                    Text("Volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill")
                }
                .onChange(of: volume) { _, value in session.setVolume(value) }
            }
            Section("Behaviour") {
                Toggle("Pause when Ursprung is in the background", isOn: $pauseInBackground)
            }
            Section {
                ForEach(SystemCatalog.all.filter { $0.cores.count > 1 }) { system in
                    Picker(system.name, selection: Binding(
                        get: { coreChoices[system.id] ?? Preferences.coreChoice(for: system.id) ?? system.defaultCore.id },
                        set: { coreChoices[system.id] = $0; Preferences.setCoreChoice($0, for: system.id) }
                    )) {
                        ForEach(system.cores) { core in
                            Group {
                                if core.id == system.defaultCore.id {
                                    Text("\(core.name) (Recommended)")
                                } else {
                                    Text(core.name)
                                }
                            }
                            .tag(core.id)
                        }
                    }
                }
            } header: {
                Text("Default Cores")
            } footer: {
                Text("Individual games can override the core in their info panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
