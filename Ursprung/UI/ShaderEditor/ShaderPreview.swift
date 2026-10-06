// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import MetalKit
import SwiftUI
import UniformTypeIdentifiers

/// The shader editor's preview: the draft on a still picture, or, while a
/// game runs, controls for the player window, which shows the draft.
struct ShaderPreview: View {
    @Environment(ShaderEditor.self) private var editor
    @Environment(EmulationSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            PreviewBar()
            Divider()
            if editor.isLive {
                livePlaceholder
            } else {
                ZStack {
                    Color.black
                    if let frame = editor.stillFrame, let draft = editor.draftRef {
                        StillPreviewView(frame: frame, selection: .preset(draft), workspace: editor.stillWorkspace)
                            .overlay { ZoomDragArea() }
                    }
                    if let error = editor.stillSourceError {
                        Text(error).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var livePlaceholder: some View {
        VStack(spacing: AppSpacing.m) {
            Image(systemName: "gamecontroller")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("“\(session.gameTitle)” shows your shader in the player window.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Changes appear there as you make them. The tools above apply to the player while this window is open.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack {
                Button(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill") {
                    session.togglePause()
                }
                Button("Next Frame", systemImage: "forward.frame.fill") { session.stepFrame() }
                    .disabled(!session.isPaused)
                Button("Capture Frame", systemImage: "camera.viewfinder") { session.captureShaderFrame() }
                    .help("Saves the game’s picture at its own resolution for the still preview")
            }
            .padding(.top, AppSpacing.s)
        }
        .padding(AppSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Source, output size, zoom, comparison, pass output and GPU time.
private struct PreviewBar: View {
    @Environment(ShaderEditor.self) private var editor
    @Environment(EmulationSession.self) private var session
    @State private var choosesImage = false

    private var workspace: ShaderWorkspace { editor.workspace }

    var body: some View {
        // Scrolls sideways when the window is narrow, so it never sets the column's minimum width.
        ScrollView(.horizontal) {
            controls
                .padding(.horizontal, AppSpacing.m)
                .padding(.vertical, 6)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .fileImporter(isPresented: $choosesImage, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { editor.stillSource = .image(url, width: nil, height: nil) }
        }
    }

    private var controls: some View {
        @Bindable var workspace = workspace
        return HStack(spacing: AppSpacing.m) {
            if !editor.isLive {
                sourceMenu
                Button(isPaused ? "Animate" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill") {
                    editor.stillFrame?.isPaused.toggle()
                    stillPausedRevision += 1
                }
                .labelStyle(.iconOnly)
                .help(isPaused ? "Lets time run, so animated shaders move" : "Stops time for the shader")
                Button("Next Frame", systemImage: "forward.frame.fill") { editor.stillFrame?.step() }
                    .labelStyle(.iconOnly)
                    .disabled(!isPaused)
                    .help("Next Frame")
            }
            Picker("Output", selection: $workspace.previewTools.outputSize) {
                Text("Window").tag(CGSize?.none)
                Text(verbatim: "1080p").tag(CGSize?.some(CGSize(width: 1920, height: 1080)))
                Text(verbatim: "1440p").tag(CGSize?.some(CGSize(width: 2560, height: 1440)))
                Text(verbatim: "4K").tag(CGSize?.some(CGSize(width: 3840, height: 2160)))
            }
            .fixedSize()
            .help("The screen size the shader renders for")
            Picker("Zoom", selection: $workspace.previewTools.zoom) {
                ForEach([1.0, 2, 4, 8], id: \.self) { Text(verbatim: "\(Int($0))×").tag($0) }
            }
            .fixedSize()
            .help("Magnifies the picture without smoothing; drag the picture to move")
            Toggle(isOn: Binding(get: { workspace.previewTools.split != nil },
                                 set: { workspace.previewTools.split = $0 ? 0.5 : nil })) {
                Label("Compare", systemImage: "rectangle.split.2x1")
            }
            .toggleStyle(.button)
            .help("Shows the picture without the shader on the left")
            if let split = workspace.previewTools.split {
                Slider(value: Binding(get: { split }, set: { workspace.previewTools.split = $0 }), in: 0...1)
                    .frame(width: 90)
                    .accessibilityLabel("Comparison Position")
            }
            if editor.preset.passes.count > 1 {
                @Bindable var editor = editor
                Picker("Show", selection: $editor.passLimit) {
                    Text("All Passes").tag(Int?.none)
                    Divider()
                    ForEach(1..<editor.preset.passes.count, id: \.self) { pass in
                        Text("Up to Pass \(pass)").tag(Int?.some(pass))
                    }
                }
                .fixedSize()
                .help("Shows the output of an earlier pass")
            }
            Spacer(minLength: AppSpacing.s)
            if let gpu = workspace.gpuTime {
                Text("GPU \(gpu * 1000, format: .number.precision(.fractionLength(1))) ms")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(gpu > 1 / 60 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .help("Time the GPU needs for the shader per frame")
            }
        }
        .controlSize(.small)
        .labelsHidden()
    }

    /// Bumped to redraw the play button; `StillFrame` isn't observable.
    @State private var stillPausedRevision = 0
    private var isPaused: Bool {
        _ = stillPausedRevision
        return editor.stillFrame?.isPaused ?? false
    }

    private var sourceMenu: some View {
        Menu {
            Section("Test Pictures") {
                ForEach(ShaderTestPattern.allCases) { pattern in
                    Menu(pattern.title) {
                        ForEach(ShaderTestPattern.sizes, id: \.width) { size in
                            Button("\(size.width) × \(size.height)") {
                                editor.stillSource = .pattern(pattern, width: size.width, height: size.height)
                            }
                        }
                    }
                }
            }
            let _ = session.shaderFrameRevision
            let frames = editor.capturedFrames()
            if !frames.isEmpty {
                Section("Captured Frames") {
                    ForEach(frames.prefix(12), id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { editor.stillSource = .frame(url) }
                    }
                }
            }
            Divider()
            Button("Choose Image…") { choosesImage = true }
        } label: {
            Label(sourceTitle, systemImage: "photo")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("The picture the shader is applied to")
    }

    private var sourceTitle: String {
        switch editor.stillSource {
        case .pattern(let pattern, let width, let height): "\(pattern.title), \(width) × \(height)"
        case .frame(let url): url.deletingPathExtension().lastPathComponent
        case .image(let url, _, _): url.lastPathComponent
        }
    }
}

/// Dragging the zoomed picture moves the point the zoom centres on.
private struct ZoomDragArea: View {
    @Environment(ShaderEditor.self) private var editor
    @State private var start: CGPoint?

    var body: some View {
        let tools = editor.stillWorkspace.previewTools
        GeometryReader { geometry in
            Color.clear
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard tools.zoom > 1 else { return }
                        let origin = start ?? tools.focus
                        if start == nil { start = origin }
                        // The picture moves with the pointer, so the focus moves against it.
                        let scale = tools.zoom * min(geometry.size.width, geometry.size.height)
                        editor.stillWorkspace.previewTools.focus = CGPoint(
                            x: min(max(origin.x - value.translation.width / scale, 0), 1),
                            y: min(max(origin.y - value.translation.height / scale, 0), 1))
                    }
                    .onEnded { _ in start = nil })
                .onTapGesture(count: 2) {
                    editor.stillWorkspace.previewTools.zoom = tools.zoom > 1 ? 1 : 4
                }
        }
        .allowsHitTesting(true)
    }
}

/// An MTKView with its own renderer, fed from a still picture.
private struct StillPreviewView: NSViewRepresentable {
    let frame: StillFrame
    let selection: ShaderSelection
    let workspace: ShaderWorkspace

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: MetalRenderer?
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: nil)
        let renderer = MetalRenderer(view: view)
        renderer?.workspace = workspace
        context.coordinator.renderer = renderer
        view.setAccessibilityLabel(String(localized: "Shader Preview"))
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        renderer.source = frame
        renderer.selection = selection
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.renderer = nil
    }
}
