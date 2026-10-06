// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The console itself as an icon, like Finder's device icons; the flat
/// identity dot until its photo has been downloaded. Decorative: a label
/// next to it always names the system.
struct SystemIcon: View {
    let system: GameSystem
    @Environment(SystemMediaStore.self) private var systemMedia

    var body: some View {
        ArtworkImage(url: systemMedia.photo(for: system), maxPixel: 96) {
            Circle()
                .fill(system.identityColor)
                // Keeps near-white and near-black systems visible on the sidebar material.
                .strokeBorder(.separator, lineWidth: 0.5)
                .frame(width: 8, height: 8)
        }
        .frame(width: 24, height: 18)
        .accessibilityHidden(true)
    }
}
