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
            Tab("Metadata", systemImage: "text.below.photo", value: .metadata) { MetadataSettingsView() }
            Tab("Emulation", systemImage: "display", value: .emulation) { EmulationSettingsView() }
            Tab("Controls", systemImage: "gamecontroller", value: .controls) { ControlsSettingsView() }
            Tab("Cores", systemImage: "cpu", value: .cores) { CoresSettingsView() }
            Tab("BIOS", systemImage: "memorychip", value: .bios) { BIOSSettingsView() }
        }
        .scenePadding()
        .background { VerticallyResizableWindow() }
    }
}

/// The Settings scene's window is not resizable, and SwiftUI clears the flag
/// again after opening it. Long tabs like Controls and BIOS need more height,
/// so the window keeps a resize handle; the width stays fixed by the content.
private struct VerticallyResizableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizingView { ResizingView() }
    func updateNSView(_ view: ResizingView, context: Context) {}

    final class ResizingView: NSView {
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            guard let window else { return }
            window.styleMask.insert(.resizable)
            observation = window.observe(\.styleMask) { window, _ in
                MainActor.assumeIsolated {
                    if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
                }
            }
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(BackupService.self) private var backup
    @Environment(\.modelContext) private var context
    @State private var selection: URL?
    @State private var folderToRemove: FolderRemoval?

    private struct FolderRemoval: Identifiable {
        var folder: URL
        var gameCount: Int
        var id: URL { folder }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    List(selection: $selection) {
                        ForEach(library.folders, id: \.self) { folder in
                            folderRow(folder)
                        }
                    }
                    .listStyle(.bordered)
                    .alternatingRowBackgrounds(.disabled)
                    .frame(minHeight: 140)
                    .onDeleteCommand(perform: confirmRemoval)
                    HStack(spacing: AppSpacing.xs) {
                        Button {
                            library.presentAddFolderPanel(context: context)
                        } label: {
                            Label("Add Folder…", systemImage: "plus")
                        }
                        .help("Add Folder…")
                        Button(action: confirmRemoval) {
                            Label("Remove Folder…", systemImage: "minus")
                        }
                        .help("Remove Folder…")
                        .disabled(selection == nil)
                    }
                    .buttonStyle(ListEditButtonStyle())
                    .padding(.top, AppSpacing.s)
                }
                HStack(spacing: AppSpacing.s) {
                    Spacer()
                    if library.isScanning { ProgressView().controlSize(.small) }
                    Button("Rescan") { Task { await library.rescan(context: context) } }
                        .disabled(library.isScanning || library.folders.isEmpty)
                }
            } header: {
                Text("Library Folders")
            } footer: {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    if let summary = library.lastScanSummary {
                        Text(summary)
                    }
                    Text("Name sub folders after the system (for example “PSX”, “Saturn” or “Arcade”) so disc images and archives are assigned correctly.")
                }
                .settingsFootnote()
            }

            Section {
                LabeledContent("Backup") {
                    HStack(spacing: AppSpacing.s) {
                        if let activity = backup.activity {
                            ProgressView().controlSize(.small)
                            Text(activity).foregroundStyle(.secondary)
                        }
                        Button("Back Up…") { backup.backUp() }
                        Button("Restore…") { backup.restore() }
                    }
                    .disabled(backup.isWorking)
                }
                LabeledContent("Application Data") {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.root) }
                }
                LabeledContent("Battery Saves") {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.saves) }
                }
            } header: {
                Text("Data")
            } footer: {
                Text("A backup contains your library, battery saves, save states, artwork and settings. BIOS files, cores and your ScreenScraper password are not included.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            Text("Remove “\(folderToRemove?.folder.lastPathComponent ?? "")” from the library?"),
            isPresented: Binding(get: { folderToRemove != nil }, set: { if !$0 { folderToRemove = nil } }),
            presenting: folderToRemove
        ) { removal in
            Button("Remove Folder", role: .destructive) {
                library.removeFolder(removal.folder, context: context)
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text("\(removal.gameCount) games will be removed from the library. The files stay on disk.")
        }
    }

    private func folderRow(_ folder: URL) -> some View {
        let isUnreachable = library.unreachableFolders.contains(folder)
        return Label {
            VStack(alignment: .leading) {
                Text(folder.lastPathComponent)
                Text(folder.path(percentEncoded: false))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            if isUnreachable {
                Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
            } else {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
            }
        }
        .help(isUnreachable ? String(localized: "Unavailable. Connect the drive, then rescan.") : "")
        .accessibilityValue(isUnreachable ? String(localized: "Unavailable") : "")
        .tag(folder)
    }

    private func confirmRemoval() {
        guard let selection else { return }
        folderToRemove = FolderRemoval(folder: selection,
                                       gameCount: library.games(leavingWith: selection, context: context).count)
    }
}

/// The square +/− buttons under an editable list, as in System Settings.
private struct ListEditButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .frame(width: 22, height: 22)
            .background(configuration.isPressed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary),
                        in: .rect(cornerRadius: 5))
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .contentShape(.rect)
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
    @State private var account = AccountStatus.unchecked

    private enum AccountStatus: Equatable {
        case unchecked, checking
        case valid(ScraperAccount)
        case failed(String)
    }

    private let languages = [("en", "English"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"), ("pt", "Português")]
    private let regions = [("eu", String(localized: "Europe")), ("us", String(localized: "North America")), ("jp", String(localized: "Japan")), ("wor", String(localized: "World"))]

    var body: some View {
        Form {
            Section {
                if !Secrets.hasScreenScraperCredentials {
                    StatusLabel("This build has no ScreenScraper developer credentials. See the README for how to add them.",
                                kind: .warning, prominent: true)
                }
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField(text: $password) {
                    Text("Password")
                    Text("Stored in your keychain.")
                }
                .textContentType(.password)
                .onSubmit { Keychain.setPassword(password, for: username) }
                .onChange(of: password) { _, value in
                    Keychain.setPassword(value, for: username)
                    account = .unchecked
                }
                HStack(alignment: .firstTextBaseline) {
                    accountStatus
                    Spacer(minLength: AppSpacing.s)
                    Button("Check Account", action: checkAccount)
                        .disabled(username.isEmpty || password.isEmpty || account == .checking)
                }
            } header: {
                Text("ScreenScraper Account")
            } footer: {
                Text("Optional. A free account at screenscraper.fr raises the daily request quota and speeds up scraping.")
                    .settingsFootnote()
            }

            Section("Preferences") {
                Picker("Language", selection: $language) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Preferred Region", selection: $region) {
                    ForEach(regions, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle(isOn: $autoScrape) {
                    Text("Fetch Metadata Automatically")
                    Text("New games get box art, descriptions and ratings as soon as a scan finds them.")
                }
            }

            Section("Library") {
                if metadata.isPausedForQuota, !metadata.isRunning {
                    StatusLabel("Daily ScreenScraper quota reached", kind: .warning, prominent: true,
                                detail: String(localized: "Fetching continues automatically tomorrow. Fetch Missing tries again now."))
                }
                if let failure = metadata.lastError {
                    HStack(alignment: .firstTextBaseline) {
                        StatusLabel("Metadata couldn't be fetched", kind: .error, prominent: true, detail: failure.message)
                        Spacer(minLength: AppSpacing.s)
                        Button("Retry") { metadata.enqueue(games, context: context) }
                            .buttonStyle(.link)
                    }
                }
                LabeledContent("Matched") {
                    Text("\(games.filter { $0.scrapeState == .matched }.count) of \(games.count)")
                        .monospacedDigit()
                }
                if metadata.isRunning {
                    LabeledContent("Fetching Metadata") {
                        HStack(spacing: AppSpacing.s) {
                            ProgressView(value: metadata.progress)
                                .frame(width: 120)
                            Button("Stop") { metadata.cancel() }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Refetch All") { metadata.enqueue(games, force: true, context: context) }
                    Button("Fetch Missing") { metadata.enqueue(games, context: context) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { password = Keychain.password(for: username) ?? "" }
        .onChange(of: username) { _, value in
            password = Keychain.password(for: value) ?? ""
            account = .unchecked
        }
    }

    @ViewBuilder
    private var accountStatus: some View {
        switch account {
        case .unchecked:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .valid(let info):
            if let used = info.requestsToday, let limit = info.maxRequestsPerDay {
                StatusLabel("Signed in", kind: .success,
                            detail: String(localized: "\(used) of \(limit) requests used today"))
            } else {
                StatusLabel("Signed in", kind: .success)
            }
        case .failed(let message):
            StatusLabel("Account couldn't be checked", kind: .error, detail: message)
        }
    }

    private func checkAccount() {
        Keychain.setPassword(password, for: username)
        account = .checking
        Task {
            do {
                account = .valid(try await metadata.checkAccount())
            } catch {
                account = .failed(MetadataFailure(error).message)
            }
        }
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
    @AppStorage(PrefKey.autosaveOnQuit) private var autosaveOnQuit = true
    @AppStorage(PrefKey.periodicAutosave) private var periodicAutosave = false
    @AppStorage(PrefKey.resumeAutomatically) private var resumeAutomatically = true
    @State private var coreChoices: [String: String] = [:]

    var body: some View {
        Form {
            Section("Video") {
                Picker("Filter", selection: $filter) {
                    ForEach(VideoFilter.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $integerScaling) {
                    Text("Integer Scaling")
                    Text("Scales the picture by whole multiples only, so every pixel has the same size. Leaves a border around the picture.")
                }
                Toggle(isOn: $showFPS) {
                    Text("Show Frame Rate")
                    Text("Shows frames per second in the corner of the player.")
                }
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
            Section("Behavior") {
                Toggle(isOn: $pauseInBackground) {
                    Text("Pause in Background")
                    Text("Pauses the game while another app is active.")
                }
            }
            Section {
                Toggle(isOn: $autosaveOnQuit) {
                    Text("Save When Quitting a Game")
                    Text("Keeps where you are in an automatic save state, apart from your slots.")
                }
                Toggle(isOn: $periodicAutosave) {
                    Text("Also Save Every 5 Minutes")
                    Text("Protects your progress if the game or the Mac stops unexpectedly.")
                }
                .disabled(!autosaveOnQuit)
                Toggle(isOn: $resumeAutomatically) {
                    Text("Resume Where You Left Off")
                    Text("Play continues from the automatic state. Start from Beginning is in the game's menu.")
                }
            } header: {
                Text("Resume")
            } footer: {
                Text("Some cores can't save states; their games always start from the beginning. Battery saves are kept either way.")
                    .settingsFootnote()
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
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
    }
}
