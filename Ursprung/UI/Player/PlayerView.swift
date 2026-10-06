// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

/// The game edge to edge, with overlays in fixed zones so the middle of the
/// image is only covered by panels. See docs/DESIGN_SPEC.md, section I.
struct PlayerView: View {
    @Environment(EmulationSession.self) private var session
    @Environment(CoreManager.self) private var cores
    @Environment(\.modelContext) private var context
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @AppStorage(PrefKey.videoFilter) private var globalFilter = VideoFilter.sharp.rawValue
    @AppStorage(PrefKey.bezel) private var bezel: BezelStyle = .none
    @AppStorage(PrefKey.integerScaling) private var integerScaling = false
    /// Bumped when any preference changes: per-system filters and bezel
    /// images have no fixed key to observe.
    @State private var preferencesRevision = 0
    @AppStorage(PrefKey.showFPS) private var showFPS = false
    @AppStorage(PrefKey.settingsTab) private var settingsTab = SettingsTab.general
    /// The pause menu is in the view tree; it fades in with its insertion
    /// transition.
    @State private var showsMenu = false
    /// The pause menu is fading out. A removal transition is never animated
    /// here, so closing animates the opacity and removes the views afterwards.
    @State private var isMenuClosing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Created per game: SwiftUI reuses the player's views when the
            // window reopens, and a reused MTKView never resumes drawing.
            if session.phase == .running {
                GameMetalView(session: session, selection: shaderSelection, integerScaling: integerScaling, bezel: bezel,
                              bezelImage: bezelImage)
                    .ignoresSafeArea()
            }

            switch session.phase {
            case .idle, .running:
                EmptyView()
            case .preparing(let message):
                PreparingView(title: session.gameTitle, message: message, progress: currentDownloadProgress)
            case .failed(let failure):
                FailureView(failure: failure, openSettings: { open(failure.settingsTab) }, close: closePlayer)
            }

            // Always in the tree: its fade-out is animated only that way.
            // Clicking next to the panel resumes.
            Rectangle()
                .fill(.black.opacity(reduceTransparency ? 0.7 : 0.5))
                .ignoresSafeArea()
                .onTapGesture { session.isMenuVisible = false }
                .opacity(showsMenu && !isMenuClosing ? 1 : 0)
                .allowsHitTesting(showsMenu && !isMenuClosing)
                .accessibilityHidden(true)
            if showsMenu {
                GeometryReader { geometry in
                    PauseMenuView(maxHeight: min(600, geometry.size.height - 80), close: closePlayer)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.appFade(or: .opacity.combined(with: .scale(scale: 0.97)), reduceMotion: reduceMotion))
                .scaleEffect(isMenuClosing && !reduceMotion ? 0.97 : 1)
                .opacity(isMenuClosing ? 0 : 1)
                .allowsHitTesting(!isMenuClosing)
            }
        }
        .overlay(alignment: .top) {
            ToastStack(toasts: session.toasts)
                .padding(.top, AppSpacing.l)
        }
        .overlay(alignment: .topTrailing) {
            // Indicators that stay while their mode is on.
            VStack(alignment: .trailing, spacing: 6) {
                if showFPS, session.phase == .running {
                    HUDCapsule {
                        Text("\(session.measuredFPS, format: .number.precision(.fractionLength(1))) fps")
                            .font(.caption.monospacedDigit())
                    }
                }
                if session.isFastForwarding {
                    HUDCapsule { Label("Fast Forward", systemImage: "forward.fill") }
                        .transition(.opacity)
                }
                if session.isRewinding {
                    HUDCapsule { Label("Rewind", systemImage: "backward.fill") }
                        .transition(.opacity)
                }
                if session.isTyping {
                    HUDCapsule { Label("Typing", systemImage: "keyboard") }
                        .transition(.opacity)
                }
                if session.isHardcore {
                    HUDCapsule { Label("Hardcore", systemImage: "trophy.fill") }
                        .transition(.opacity)
                }
            }
            .padding(AppSpacing.l)
        }
        .overlay(alignment: .bottomTrailing) {
            AchievementIndicators(indicators: session.achievementIndicators)
                .padding(AppSpacing.l)
        }
        .appAnimation(AppAnimation.standard, value: session.toasts)
        .appAnimation(AppAnimation.standard, value: session.isFastForwarding)
        .appAnimation(AppAnimation.standard, value: session.isRewinding)
        .appAnimation(AppAnimation.standard, value: session.isTyping)
        .appAnimation(AppAnimation.standard, value: session.achievementIndicators)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            preferencesRevision += 1
        }
        .navigationTitle(session.gameTitle)
        .toolbar(session.phase == .running && !session.isMenuVisible ? .hidden : .automatic, for: .windowToolbar)
        .onChange(of: session.isMenuVisible, initial: true) { _, visible in
            if visible {
                withAppAnimation(AppAnimation.panel, reduceMotion: reduceMotion) {
                    showsMenu = true
                    isMenuClosing = false
                }
            } else if showsMenu {
                withAppAnimation(AppAnimation.panel, reduceMotion: reduceMotion) {
                    isMenuClosing = true
                } completion: {
                    // Reopened meanwhile: keep it.
                    guard !session.isMenuVisible else { return }
                    showsMenu = false
                    isMenuClosing = false
                }
            }
        }
        .onDisappear {
            Task { await session.stop(context: context) }
        }
        .onChange(of: session.coreTerminations) {
            // A core that shut itself down closes the player. Not tied to
            // phase == .idle: that also follows closing the window, and SwiftUI
            // delivers it when the window reopens, closing it right away.
            dismissWindow(id: WindowID.player)
        }
    }

    private var currentDownloadProgress: Double? {
        cores.downloads.values.first
    }

    /// The system's own filter or preset, or the one for all systems.
    private var shaderSelection: ShaderSelection {
        _ = (preferencesRevision, globalFilter)
        return ShaderSelection.current(for: session.systemID)
    }

    /// The system's bezel image, when the user chose one.
    private var bezelImage: URL? {
        _ = preferencesRevision
        return session.systemID.flatMap { BezelImages.image(for: $0) }
    }

    private func closePlayer() {
        dismissWindow(id: WindowID.player)
    }

    private func open(_ tab: SettingsTab?) {
        if let tab { settingsTab = tab }
        openSettings()
    }
}

private struct PreparingView: View {
    let title: String
    let message: String
    let progress: Double?

    /// Quick starts finish before the panel appears, so they show no flash.
    @State private var isShown = false

    var body: some View {
        PlayerPanel {
            VStack(spacing: AppSpacing.m) {
                VStack(spacing: AppSpacing.xs) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 240)
                } else {
                    ProgressView()
                }
            }
            .multilineTextAlignment(.center)
            .frame(width: 300 - 2 * AppSpacing.xl)
        }
        .opacity(isShown ? 1 : 0)
        .appAnimation(AppAnimation.standard, value: isShown)
        .accessibilityElement(children: .combine)
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            isShown = true
        }
    }
}

private struct FailureView: View {
    let failure: EmulationSession.Failure
    let openSettings: () -> Void
    let close: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        PlayerPanel(padding: 28) {
            VStack(spacing: AppSpacing.l) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(spacing: AppSpacing.s) {
                    Text("The game couldn't be started")
                        .font(.title3.weight(.semibold))
                    Text(failure.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                HStack {
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.glass)
                    Button("Close", action: close)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
            .frame(maxWidth: 420 - 2 * 28)
        }
        // Focused so Esc reaches it: Esc closes, like the Close button.
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onExitCommand(perform: close)
        .onAppear { isFocused = true }
    }
}

private struct ToastStack: View {
    let toasts: [EmulationSession.Toast]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: AppSpacing.s) {
            ForEach(toasts) { toast in
                HUDCapsule {
                    Label {
                        if let detail = toast.detail {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(toast.text)
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(toast.text)
                        }
                    } icon: {
                        if let imageURL = toast.imageURL {
                            RemoteBadge(url: imageURL, size: 32)
                        } else if let symbol = symbol(for: toast.kind) {
                            Image(systemName: symbol)
                                .foregroundStyle(toast.kind == .warning ? AnyShapeStyle(.orange)
                                                 : toast.kind == .achievement ? AnyShapeStyle(.yellow) : AnyShapeStyle(.primary))
                        }
                    }
                    .labelStyle(ToastLabelStyle())
                }
                .transition(.appFade(or: .move(edge: .top).combined(with: .opacity), reduceMotion: reduceMotion))
            }
        }
    }

    private func symbol(for kind: EmulationSession.Toast.Kind) -> String? {
        switch kind {
        case .info: nil
        case .saved: "square.and.arrow.down"
        case .loaded: "square.and.arrow.up"
        case .warning: "exclamationmark.triangle.fill"
        case .screenshot: "camera.fill"
        case .achievement: "trophy.fill"
        }
    }
}

/// Running challenges, achievement progress and leaderboard values, in the
/// bottom corner where they cover the least of the game.
private struct AchievementIndicators: View {
    let indicators: [EmulationSession.AchievementIndicator]

    var body: some View {
        HStack(spacing: AppSpacing.s) {
            ForEach(indicators) { indicator in
                HUDCapsule {
                    HStack(spacing: 6) {
                        if let url = indicator.imageURL {
                            RemoteBadge(url: url, size: 22)
                        } else if indicator.kind == .tracker {
                            Image(systemName: "stopwatch")
                        }
                        if let value = indicator.value {
                            Text(value)
                                .monospacedDigit()
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A RetroAchievements badge, loaded from the web.
struct RemoteBadge: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().interpolation(.medium)
        } placeholder: {
            Image(systemName: "trophy.fill")
                .foregroundStyle(.yellow)
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size / 6))
        .accessibilityHidden(true)
    }
}

/// Icon and title like `.titleAndIcon`, without the gap an empty icon leaves.
private struct ToastLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}
