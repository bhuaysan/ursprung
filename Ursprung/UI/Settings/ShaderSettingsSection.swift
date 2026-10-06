// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Settings › Emulation › RetroArch Shaders: the downloaded pack and the
/// user's own presets.
struct ShaderSettingsSection: View {
    @Environment(ShaderLibrary.self) private var shaders
    @State private var failure: String?
    @State private var updateCheckFailure: String?
    @State private var confirmsRemoval = false

    var body: some View {
        Section {
            LabeledContent {
                HStack(spacing: AppSpacing.m) {
                    ShaderPackProgress()
                    if shaders.isPackInstalled && !shaders.isInstallingPack {
                        if shaders.isCheckingForUpdates { ProgressView().controlSize(.small) }
                        packMenu
                    } else if !shaders.isInstallingPack {
                        Button("Download", action: install)
                    }
                }
            } label: {
                Text("Shader Pack")
                Text(packDescription)
            }
            if let failure {
                StatusLabel("The shaders couldn't be downloaded", kind: .error, detail: failure)
            } else if let updateCheckFailure {
                StatusLabel("Couldn't check for updates", kind: .error, detail: updateCheckFailure)
            }
            LabeledContent {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([shaders.makeUserDirectory()])
                }
            } label: {
                Text("Your Shaders")
                Text(userDescription)
            }
        } header: {
            Text("RetroArch Shaders")
        } footer: {
            Text("The libretro shader pack has more than 2,500 presets: CRT screens, handheld displays, scanlines, smoothing and more. Choose one with “RetroArch Shaders…” in a Filter menu, where you can also import your own. The shaders are separate open source projects with their own licenses. Your own shaders are part of backups; the pack is not.")
                .settingsFootnote()
        }
        .task { shaders.loadIfNeeded() }
        .confirmationDialog("Remove the RetroArch shader pack?", isPresented: $confirmsRemoval) {
            Button("Remove Shader Pack", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Systems set to one of its presets use the built-in Sharp filter until you download it again. Your own shaders stay.")
        }
    }

    private var packMenu: some View {
        Menu {
            Button("Check for Updates", action: checkForUpdates)
                .disabled(shaders.isCheckingForUpdates)
            Button(shaders.updateAvailable ? "Update" : "Download Again", action: install)
            Divider()
            Button("Remove…", role: .destructive) { confirmsRemoval = true }
        } label: {
            HStack(spacing: AppSpacing.xs) {
                if shaders.updateAvailable {
                    StatusLabel("Update Available", systemImage: "arrow.down.circle.fill", kind: .neutral)
                } else {
                    StatusLabel("Installed", kind: .success)
                }
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        // A plain button keeps the green symbol; borderless renders the label monochrome.
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// "2,658 presets · 81 MB · 5 Oct 2026", or why there is nothing.
    private var packDescription: String {
        guard let installed = shaders.packInstalled else { return String(localized: "Not downloaded (about 55 MB)") }
        var parts: [String] = []
        if shaders.hasIndex {
            let count = shaders.presets.filter { $0.ref.source == .library }.count
            parts.append(String(localized: "\(count) presets"))
        }
        if let size = shaders.packSize {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        parts.append(installed.formatted(date: .abbreviated, time: .omitted))
        if !shaders.updateAvailable, let checked = shaders.lastUpdateCheck {
            parts.append(String(localized: "Up to date, checked \(checked.formatted(date: .omitted, time: .shortened))"))
        }
        return parts.joined(separator: " · ")
    }

    private var userDescription: String {
        guard shaders.hasIndex else { return "" }
        let count = shaders.presets.filter { $0.ref.source == .user }.count
        return count == 0 ? String(localized: "None yet") : String(localized: "\(count) presets")
    }

    private func install() {
        failure = nil
        Task {
            do {
                try await shaders.installPack()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func checkForUpdates() {
        updateCheckFailure = nil
        Task {
            do {
                try await shaders.checkForUpdates()
            } catch {
                updateCheckFailure = error.localizedDescription
            }
        }
    }

    private func remove() {
        do {
            try shaders.removePack()
        } catch {
            failure = error.localizedDescription
        }
    }
}
