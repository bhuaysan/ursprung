// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftData
import SwiftUI

struct PlayerView: View {
    @Environment(EmulationSession.self) private var session
    @Environment(CoreManager.self) private var cores
    @Environment(\.modelContext) private var context
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    @AppStorage(PrefKey.videoFilter) private var filter: VideoFilter = .sharp
    @AppStorage(PrefKey.integerScaling) private var integerScaling = false
    @AppStorage(PrefKey.showFPS) private var showFPS = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Created per game: SwiftUI reuses the player's views when the
            // window reopens, and a reused MTKView never resumes drawing.
            if session.phase == .running {
                GameMetalView(session: session, filter: filter, integerScaling: integerScaling)
                    .ignoresSafeArea()
            }

            switch session.phase {
            case .idle:
                EmptyView()
            case .preparing(let message):
                PreparingView(message: message, progress: currentDownloadProgress)
            case .failed(let message):
                FailureView(message: message,
                            openSettings: { openSettings() },
                            close: { dismissWindow(id: WindowID.player) })
            case .running:
                EmptyView()
            }

            if session.isMenuVisible {
                PauseMenuView(close: { dismissWindow(id: WindowID.player) })
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .overlay(alignment: .top) { ToastStack(toasts: session.toasts) }
        .overlay(alignment: .topTrailing) {
            if showFPS, session.phase == .running {
                Text("\(session.measuredFPS, format: .number.precision(.fractionLength(1))) fps")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .padding(12)
            }
        }
        .overlay(alignment: .bottom) {
            if session.isFastForwarding {
                Label("Fast Forward", systemImage: "forward.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .padding(20)
            }
        }
        .animation(.smooth(duration: 0.2), value: session.isMenuVisible)
        .animation(.smooth(duration: 0.2), value: session.toasts)
        .navigationTitle(session.gameTitle)
        .toolbar(session.phase == .running && !session.isMenuVisible ? .hidden : .automatic, for: .windowToolbar)
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
}

private struct PreparingView: View {
    let message: String
    let progress: Double?

    var body: some View {
        VStack(spacing: 14) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text(message)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .environment(\.colorScheme, .dark)
    }
}

private struct FailureView: View {
    let message: String
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
            Text("The game could not be started")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack {
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.glass)
                Button("Close", action: close)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .environment(\.colorScheme, .dark)
    }
}

private struct ToastStack: View {
    let toasts: [EmulationSession.Toast]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(toasts) { toast in
                Text(toast.text)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 18)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
    }
}
