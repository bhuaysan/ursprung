// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The trailing column of the shader editor: the selected pass's options,
/// the preset's parameters and its lookup textures.
struct ShaderEditorInspector: View {
    enum Page: String, CaseIterable, Identifiable {
        case pass, parameters, textures
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .pass: "Pass"
            case .parameters: "Parameters"
            case .textures: "Textures"
            }
        }
    }

    @Binding var page: Page

    var body: some View {
        VStack(spacing: 0) {
            Picker("Page", selection: $page) {
                ForEach(Page.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(AppSpacing.m)
            Divider()
            switch page {
            case .pass: PassInspector()
            case .parameters: ParameterInspector()
            case .textures: TextureInspector()
            }
        }
    }
}

// MARK: - Pass

private struct PassInspector: View {
    @Environment(ShaderEditor.self) private var editor
    @State private var replacesShader = false

    var body: some View {
        if let pass = editor.selectedPass, let index = editor.preset.passes.firstIndex(where: { $0.id == pass.id }) {
            Form {
                Section {
                    LabeledContent("Shader") {
                        Menu {
                            Button("Open") { editor.openSource(URL(filePath: pass.shader), for: pass.id) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: pass.shader)])
                            }
                            Divider()
                            Button("Choose Another Shader…") { replacesShader = true }
                        } label: {
                            Text(verbatim: URL(filePath: pass.shader).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    TextField("Name", text: binding(pass, \.alias, default: ""), prompt: Text("None"))
                        .help("Later passes and the shaders read this pass’s output by this name")
                } header: {
                    Text("Pass \(index + 1)")
                }

                Section("Size") {
                    ScaleRow(title: "Width", type: binding(pass, \.scaleTypeX), factor: binding(pass, \.scaleX))
                    ScaleRow(title: "Height", type: binding(pass, \.scaleTypeY), factor: binding(pass, \.scaleY))
                }

                Section("Sampling") {
                    OptionalBoolPicker(title: "Input Filter", value: binding(pass, \.filterLinear),
                                       on: "Linear", off: "Nearest")
                    Picker("Edges", selection: binding(pass, \.wrapMode)) {
                        Text("Default").tag(SlangPreset.WrapMode?.none)
                        Divider()
                        ForEach(SlangPreset.WrapMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(SlangPreset.WrapMode?.some(mode))
                        }
                    }
                    OptionalBoolPicker(title: "Mipmapped Input", value: binding(pass, \.mipmapInput), on: "On", off: "Off")
                }

                Section("Output") {
                    OptionalBoolPicker(title: "Float Framebuffer", value: binding(pass, \.floatFramebuffer), on: "On", off: "Off")
                    OptionalBoolPicker(title: "sRGB Framebuffer", value: binding(pass, \.srgbFramebuffer), on: "On", off: "Off")
                    TextField("Frame Count Modulo", value: binding(pass, \.frameCountMod), format: .number.grouping(.never),
                              prompt: Text("None"))
                        .help("FrameCount restarts at 0 after this many frames")
                }

                Section("Files") {
                    ForEach(editor.files(of: pass.id), id: \.self) { file in
                        Button {
                            editor.openSource(file, for: pass.id)
                        } label: {
                            Label(file.lastPathComponent,
                                  systemImage: file.pathExtension == "slang" ? "doc.text" : "doc.badge.ellipsis")
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .formStyle(.grouped)
            .fileImporter(isPresented: $replacesShader, allowedContentTypes: [UTType(filenameExtension: "slang") ?? .plainText]) { result in
                if case .success(let url) = result {
                    editor.updatePass(pass.id) { $0.shader = url.path(percentEncoded: false) }
                }
            }
        } else {
            ContentUnavailableView("No Pass Selected", systemImage: "square.stack.3d.down.right",
                                   description: Text("Choose a pass in the sidebar."))
        }
    }

    private func binding<Value: Equatable>(_ pass: SlangPreset.Pass, _ keyPath: WritableKeyPath<SlangPreset.Pass, Value>) -> Binding<Value> {
        Binding(get: { editor.preset.passes.first { $0.id == pass.id }?[keyPath: keyPath] ?? pass[keyPath: keyPath] },
                set: { value in editor.updatePass(pass.id) { $0[keyPath: keyPath] = value } })
    }

    /// An optional text as a plain text field: empty is nil.
    private func binding(_ pass: SlangPreset.Pass, _ keyPath: WritableKeyPath<SlangPreset.Pass, String?>,
                         default: String) -> Binding<String> {
        Binding(get: { editor.preset.passes.first { $0.id == pass.id }?[keyPath: keyPath] ?? `default` },
                set: { value in
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    editor.updatePass(pass.id) { $0[keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed }
                })
    }
}

/// A scale type and factor, e.g. "Viewport × 1" or "Absolute 640 px".
private struct ScaleRow: View {
    let title: LocalizedStringKey
    @Binding var type: SlangPreset.ScaleType?
    @Binding var factor: Double?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: AppSpacing.s) {
                Picker(title, selection: $type) {
                    Text("Default").tag(SlangPreset.ScaleType?.none)
                    Divider()
                    ForEach(SlangPreset.ScaleType.allCases, id: \.self) { type in
                        Text(type.title).tag(SlangPreset.ScaleType?.some(type))
                    }
                }
                .labelsHidden()
                .fixedSize()
                if type != nil {
                    TextField(title, value: $factor, format: .number.grouping(.never).precision(.fractionLength(0...4)),
                              prompt: Text(verbatim: "1"))
                        .labelsHidden()
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                    Text(type == .absolute ? "px" : "×")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .help("Source: a multiple of the previous pass. Viewport: of the screen. Original: of the game’s frame. Absolute: pixels.")
    }
}

/// Default / on / off for options librashader leaves at a default when unset.
private struct OptionalBoolPicker: View {
    let title: LocalizedStringKey
    @Binding var value: Bool?
    let on: LocalizedStringKey
    let off: LocalizedStringKey

    var body: some View {
        Picker(title, selection: $value) {
            Text("Default").tag(Bool?.none)
            Divider()
            Text(on).tag(Bool?.some(true))
            Text(off).tag(Bool?.some(false))
        }
    }
}

extension SlangPreset.ScaleType {
    var title: String {
        switch self {
        case .source: String(localized: "Source")
        case .viewport: String(localized: "Viewport")
        case .absolute: String(localized: "Absolute")
        case .original: String(localized: "Original")
        }
    }
}

extension SlangPreset.WrapMode {
    var title: String {
        switch self {
        case .clampToBorder: String(localized: "Clamp to Border")
        case .clampToEdge: String(localized: "Clamp to Edge")
        case .repeat: String(localized: "Repeat")
        case .mirroredRepeat: String(localized: "Mirrored Repeat")
        }
    }
}

// MARK: - Parameters

private struct ParameterInspector: View {
    @Environment(ShaderEditor.self) private var editor
    @State private var filter = ""

    var body: some View {
        let workspace = editor.workspace
        if workspace.parameters.isEmpty {
            ContentUnavailableView {
                Label("No Parameters", systemImage: "slider.horizontal.3")
            } description: {
                Text(workspace.isCompiling ? "The shader is compiling." : "The shaders declare parameters with “#pragma parameter”.")
            }
        } else {
            VStack(spacing: 0) {
                HStack {
                    TextField("Filter Parameters", text: $filter)
                        .textFieldStyle(.roundedBorder)
                    Button("Reset All", action: editor.resetAllParameters)
                        .disabled(!workspace.parameters.contains { editor.isParameterChanged($0.name) })
                }
                .padding(AppSpacing.m)
                List {
                    ForEach(groups, id: \.pass) { group in
                        Section(sectionTitle(group.pass)) {
                            ForEach(group.parameters, id: \.name) { parameter in
                                row(parameter)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var groups: [(pass: Int?, parameters: [ShaderParameter])] {
        let search = filter.trimmingCharacters(in: .whitespaces)
        return editor.parameterGroups().compactMap { group in
            let parameters = group.parameters.filter { parameter in
                search.isEmpty ? !parameter.isHeading || !parameter.label.isEmpty
                    : !parameter.isHeading && (parameter.label.localizedStandardContains(search)
                                               || parameter.name.localizedStandardContains(search))
            }
            return parameters.isEmpty ? nil : (group.pass, parameters)
        }
    }

    private func sectionTitle(_ pass: Int?) -> String {
        guard let pass, editor.preset.passes.indices.contains(pass) else { return String(localized: "Other") }
        let file = URL(filePath: editor.preset.passes[pass].shader).deletingPathExtension().lastPathComponent
        return String(localized: "Pass \(pass + 1): \(file)")
    }

    @ViewBuilder
    private func row(_ parameter: ShaderParameter) -> some View {
        if parameter.isHeading {
            Text(verbatim: parameter.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        } else {
            ParameterRow(parameter: parameter,
                         value: Binding(get: { editor.workspace.values[parameter.name] ?? parameter.initial },
                                        set: { editor.setParameter(parameter.name, to: ParameterRow.snapped($0, to: parameter)) }),
                         isModified: editor.isParameterChanged(parameter.name),
                         isDragged: false,
                         reset: { editor.resetParameter(parameter.name) },
                         editingChanged: { _ in })
                .listRowInsets(EdgeInsets(top: 0, leading: AppSpacing.xs, bottom: 0, trailing: AppSpacing.xs))
        }
    }
}

// MARK: - Textures

private struct TextureInspector: View {
    @Environment(ShaderEditor.self) private var editor
    @State private var addsTexture = false
    @State private var replacedTexture: SlangPreset.Texture.ID?

    var body: some View {
        VStack(spacing: 0) {
            if editor.preset.textures.isEmpty {
                ContentUnavailableView {
                    Label("No Textures", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Lookup textures are images the shaders read by name, such as phosphor masks or color tables.")
                }
            } else {
                Form {
                    ForEach(editor.preset.textures) { texture in
                        Section {
                            TextField("Name", text: Binding(
                                get: { texture.name },
                                set: { name in
                                    let cleaned = name.filter { $0.isLetter || $0.isNumber || $0 == "_" }
                                    if !cleaned.isEmpty { editor.updateTexture(texture.id) { $0.name = cleaned } }
                                }))
                            LabeledContent("Image") {
                                Button(URL(filePath: texture.path).lastPathComponent) { replacedTexture = texture.id }
                                    .buttonStyle(.link)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            OptionalBoolPicker(title: "Filter", value: textureBinding(texture, \.linear), on: "Linear", off: "Nearest")
                            Picker("Edges", selection: textureBinding(texture, \.wrapMode)) {
                                Text("Default").tag(SlangPreset.WrapMode?.none)
                                Divider()
                                ForEach(SlangPreset.WrapMode.allCases, id: \.self) { mode in
                                    Text(mode.title).tag(SlangPreset.WrapMode?.some(mode))
                                }
                            }
                            OptionalBoolPicker(title: "Mipmaps", value: textureBinding(texture, \.mipmap), on: "On", off: "Off")
                            Button("Remove Texture", role: .destructive) { editor.removeTexture(texture.id) }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            Divider()
            HStack {
                Button("Add Texture…", systemImage: "plus") { addsTexture = true }
                Spacer()
            }
            .padding(AppSpacing.m)
            // One file importer per view: this one adds, the stack's replaces.
            .fileImporter(isPresented: $addsTexture, allowedContentTypes: [.png, .jpeg, .image]) { result in
                if case .success(let url) = result { editor.addTexture(url) }
            }
        }
        .fileImporter(isPresented: Binding(get: { replacedTexture != nil }, set: { if !$0 { replacedTexture = nil } }),
                      allowedContentTypes: [.png, .jpeg, .image]) { result in
            if case .success(let url) = result, let id = replacedTexture {
                editor.updateTexture(id) { $0.path = url.path(percentEncoded: false) }
            }
            replacedTexture = nil
        }
    }

    private func textureBinding<Value: Equatable>(_ texture: SlangPreset.Texture,
                                                  _ keyPath: WritableKeyPath<SlangPreset.Texture, Value>) -> Binding<Value> {
        Binding(get: { editor.preset.textures.first { $0.id == texture.id }?[keyPath: keyPath] ?? texture[keyPath: keyPath] },
                set: { value in editor.updateTexture(texture.id) { $0[keyPath: keyPath] = value } })
    }
}
