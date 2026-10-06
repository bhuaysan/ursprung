// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The filter menu: the built-in filters, favourite RetroArch presets (and
/// the one in use), and "RetroArch Shaders…", which opens the browser.
struct ShaderPicker: View {
    let title: LocalizedStringKey
    /// Nil is the inherited choice, offered only with `inheritTitle`.
    @Binding var selection: ShaderSelection?
    var inheritTitle: String?

    @Environment(ShaderLibrary.self) private var shaders
    @State private var isBrowsing = false

    private enum Item: Hashable {
        case inherit
        case choice(ShaderSelection)
        case browse
    }

    var body: some View {
        Picker(title, selection: Binding(get: { selection.map(Item.choice) ?? .inherit }, set: { choose($0) })) {
            if let inheritTitle {
                Text(inheritTitle).tag(Item.inherit)
                Divider()
            }
            ForEach(VideoFilter.allCases) { filter in
                Text(filter.title).tag(Item.choice(.builtin(filter)))
            }
            if !presets.isEmpty {
                Divider()
                ForEach(presets, id: \.self) { preset in
                    Text(title(of: preset)).tag(Item.choice(.preset(preset)))
                }
            }
            Divider()
            Text("RetroArch Shaders…").tag(Item.browse)
        }
        .sheet(isPresented: $isBrowsing) {
            ShaderBrowser(current: currentPreset) { selection = .preset($0) }
        }
    }

    /// Favourites, and the selected preset when it isn't one.
    private var presets: [ShaderPresetRef] {
        guard let currentPreset, !shaders.favorites.contains(currentPreset) else { return shaders.favorites }
        return shaders.favorites + [currentPreset]
    }

    private var currentPreset: ShaderPresetRef? {
        if case .preset(let preset)? = selection { preset } else { nil }
    }

    private func title(of preset: ShaderPresetRef) -> String {
        shaders.exists(preset) ? preset.name : String(localized: "\(preset.name) (Missing)")
    }

    private func choose(_ item: Item) {
        switch item {
        case .inherit: selection = nil
        case .choice(let choice): selection = choice
        // The menu keeps showing the current choice.
        case .browse: isBrowsing = true
        }
    }
}
