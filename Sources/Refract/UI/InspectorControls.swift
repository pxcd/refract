import SwiftUI
import UniformTypeIdentifiers

private struct ControlSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GenerationControls: View {
    @EnvironmentObject private var studio: StudioStore
    @EnvironmentObject private var models: ModelStore
    @State private var advanced = false
    @State private var referenceDimensions: (URL, ModelImageSize)?

    private var usesReferenceResolution: Bool { studio.generation.reference != nil && studio.generation.preserveReferenceSize == true }

    private var outputDimensions: ModelImageSize? {
        if usesReferenceResolution {
            return referenceDimensions.flatMap { $0.0 == studio.generation.reference ? $0.1 : nil }
        }
        return ModelImageSize(width: studio.generation.width, height: studio.generation.height)
    }

    private let presets = [(1024, 1024, "Square"), (832, 1216, "Portrait"),
                           (1216, 832, "Landscape"), (768, 1344, "Tall"), (1344, 768, "Wide")]

    var body: some View {
        Section {
            ModelPicker(title: "Checkpoint", kind: .generation, id: $studio.activeGenerationID)
        }
        Section("Prompt") {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $studio.generation.prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 102)
                    .accessibilityLabel("Positive prompt")
                if studio.generation.prompt.isEmpty {
                    Text("Describe the image you want to make")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 5)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        Section("Reference image") {
            if let reference = studio.generation.reference {
                HStack {
                    ImageThumb(url: reference).frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(reference.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { studio.generation.reference = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("Remove reference")
                }
                Toggle("Use Reference Resolution", isOn: Binding(
                    get: { studio.generation.preserveReferenceSize == true },
                    set: { studio.generation.preserveReferenceSize = $0 }
                ))
                .toggleStyle(.switch)
                ValueSlider(label: "Denoise strength", value: $studio.generation.strength, range: 0.01...1)
            } else {
                Button {
                    if let url = StudioPanels.choose("Choose reference image", types: [.image]).first { setReference(url) }
                } label: {
                    Label("Add Image…", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.link)
                .accessibilityHint("Switches to image-to-image generation")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first, UTType(filenameExtension: first.pathExtension)?.conforms(to: .image) == true else { return false }
            setReference(first)
            return true
        }
        .task(id: studio.generation.reference) {
            guard let url = studio.generation.reference else {
                referenceDimensions = nil
                return
            }
            let dimensions = await Task.detached(priority: .utility) { try? ImageFiles.dimensions(of: url) }.value
            if !Task.isCancelled {
                referenceDimensions = dimensions.map { (url, ModelImageSize(width: $0.0, height: $0.1)) }
            }
        }
        Section("Output") {
            if usesReferenceResolution {
                if let size = outputDimensions {
                    Text("\(size.width) × \(size.height) px").monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text("Reference dimensions unavailable").foregroundStyle(.secondary)
                }
            } else {
                Picker("Aspect ratio", selection: Binding(get: {
                    presets.firstIndex { $0.0 == studio.generation.width && $0.1 == studio.generation.height } ?? -1
                }, set: { index in
                    if presets.indices.contains(index) {
                        studio.generation.width = presets[index].0
                        studio.generation.height = presets[index].1
                    }
                })) {
                    if !presets.contains(where: { $0.0 == studio.generation.width && $0.1 == studio.generation.height }) {
                        Text("Custom").tag(-1)
                    }
                    ForEach(presets.indices, id: \.self) { idx in
                        Text("\(presets[idx].2) · \(presets[idx].0) × \(presets[idx].1)").tag(idx)
                    }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    NumberInput("Width", value: $studio.generation.width)
                    Text("×").foregroundStyle(.secondary)
                    NumberInput("Height", value: $studio.generation.height)
                }
            }
            Stepper(value: $studio.generation.count, in: 1...100) {
                LabeledContent("Images") { Text(studio.generation.count, format: .number).monospacedDigit() }
            }
        }
        Section {
            Toggle("Enhance after generation", isOn: $studio.generation.autoEnhance)
                .toggleStyle(.switch)
            if studio.generation.autoEnhance {
                ModelPicker(title: "Enhancement model", kind: .enhancement, id: $studio.activeEnhancementID)
                OutputScaleControl()
                if let size = outputDimensions {
                    TargetSizeLine(width: size.width, height: size.height, options: studio.enhancement)
                }
            }
        }
        Section {
            advancedControls
        }
    }

    private var advancedControls: some View {
        DisclosureGroup("Advanced", isExpanded: $advanced) {
            VStack(alignment: .leading, spacing: 14) {
                ControlSection(title: "Negative prompt") {
                    TextField("Exclude from image", text: $studio.generation.negativePrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...5)
                }
                Picker("Prediction", selection: $studio.generation.predictionType) {
                    Text("Checkpoint default").tag(nil as String?)
                    Text("Epsilon").tag(Optional("epsilon"))
                    Text("V-prediction").tag(Optional("v_prediction"))
                }
                Picker("Terminal SNR", selection: $studio.generation.zeroTerminalSNR) {
                    Text("Checkpoint default").tag(nil as Bool?)
                    Text("Zero").tag(Optional(true))
                    Text("Standard").tag(Optional(false))
                }
                Stepper("Steps: \(studio.generation.steps)", value: $studio.generation.steps, in: 1...150)
                ValueSlider(label: "Guidance", value: $studio.generation.guidance, range: 0...20, step: 0.1)
                Picker("Sampler", selection: $studio.generation.sampler) {
                    ForEach(["DPM++ 2M", "Euler", "Euler a", "DDIM"], id: \.self) { Text($0) }
                }
                .onChange(of: studio.generation.sampler) { _, sampler in
                    if !["DPM++ 2M", "Euler"].contains(sampler) { studio.generation.scheduler = "Default" }
                }
                Picker("Scheduler", selection: $studio.generation.scheduler) {
                    Text("Default").tag("Default")
                    Text("Karras").tag("Karras").disabled(!["DPM++ 2M", "Euler"].contains(studio.generation.sampler))
                }
                Toggle("Random seed", isOn: Binding(get: { studio.generation.seed == nil }, set: {
                    studio.generation.seed = $0 ? nil : 0
                }))
                if studio.generation.seed != nil {
                    NumberInput("Seed", value: Binding(get: { studio.generation.seed ?? 0 }, set: { studio.generation.seed = $0 }))
                }
                Divider()
                ControlSection(title: "LoRA adapters") {
                    ForEach($studio.generation.loras) { $choice in
                        HStack {
                            Text(models.models.first { $0.id == choice.modelID }?.name ?? "Missing adapter")
                                .lineLimit(1)
                            Spacer()
                            Button {
                                studio.generation.loras.removeAll { $0.modelID == choice.modelID }
                            } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Remove adapter")
                        }
                        ValueSlider(label: "Strength", value: $choice.scale, range: -2...2, step: 0.05)
                    }
                    Menu("Add adapter") {
                        ForEach(models.models.filter { $0.kind == .lora && !studio.generation.loras.map(\.modelID).contains($0.id) },
                                id: \.id) { model in
                            Button(model.name) { studio.generation.loras.append(.init(modelID: model.id)) }
                        }
                        Divider()
                        OpenModelManager(kind: .lora) { Text("Manage Adapters…") }
                    }.fixedSize()
                }
            }
            .padding(.top, 8)
        }
    }

    private func setReference(_ url: URL) {
        studio.generation.reference = url
        studio.selectedResult = nil
    }
}

struct EnhancementControls: View {
    @EnvironmentObject private var studio: StudioStore
    @Binding var inputs: [URL]
    @State private var dropTargeted = false

    var body: some View {
        Section {
            ModelPicker(title: "Restoration model", kind: .enhancement, id: $studio.activeEnhancementID)
        }
        Section("Source images") {
            Button {
                add(StudioPanels.choose("Add images or folders", directories: true, multiple: true, types: [.image]))
            } label: {
                Label("Add Images or Folders…", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.link)
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.primary)
            .help("Drop images or folders here, or click to browse")
            .dropDestination(for: URL.self) { urls, _ in add(urls); return !urls.isEmpty } isTargeted: { dropTargeted = $0 }
            ForEach(inputs, id: \.self) { input in
                HStack {
                    Image(systemName: input.hasDirectoryPath ? "folder" : "photo").foregroundStyle(.secondary)
                    Text(input.lastPathComponent).lineLimit(1).truncationMode(.middle).help(input.path)
                    Spacer()
                    Button { inputs.removeAll { $0 == input } } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("Remove \(input.lastPathComponent)")
                }
            }
            if inputs.count > 1 {
                Button("Clear Selection") { inputs.removeAll() }.buttonStyle(.borderless)
            }
        }
        Section("Output") {
            OutputScaleControl()
            if !inputs.isEmpty { BatchDimensions(inputs: inputs, options: studio.enhancement) }
            HStack {
                Label(studio.outputDirectory.lastPathComponent, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).help(studio.outputDirectory.path)
                Spacer()
                Button("Choose…") {
                    if let folder = StudioPanels.choose("Choose output folder", directories: true, files: false).first {
                        studio.outputDirectory = folder
                    }
                }
                .accessibilityLabel("Choose enhancement output folder")
            }
        }
        Section {
            ValueSlider(label: "Input softness", value: $studio.enhancement.softness, range: 0...1)
                .help("Downsample the conditioning image to soften input detail before restoration.")
        }
    }

    private func add(_ urls: [URL]) {
        for url in urls where !inputs.contains(url) { inputs.append(url) }
        if !urls.isEmpty { studio.selectedResult = nil }
    }
}


private struct TargetSizeLine: View {
    let width: Int
    let height: Int
    let options: EnhancementOptions

    var body: some View {
        if let target = try? ImageFiles.outputDimensions(width: width, height: height, options: options) {
            Text("\(width) × \(height) → \(target.0) × \(target.1) px")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if target == (width,height), max(width,height) <= 256 {
                Text("Refract restores this small image at 2× internally, then saves it at its original size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Output dimensions are outside the supported range.").font(.caption).foregroundStyle(.red)
        }
    }
}

private struct SourceDimensions: Identifiable {
    let id: URL
    let width: Int
    let height: Int
}

private struct BatchDimensions: View {
    let inputs: [URL]
    let options: EnhancementOptions
    @State private var sources: [SourceDimensions] = []
    @State private var error: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let first = sources.first {
                if sources.count == 1 {
                    TargetSizeLine(width: first.width, height: first.height, options: options)
                } else {
                    DisclosureGroup("Output sizes (\(sources.count))", isExpanded: $expanded) {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(sources) { source in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.id.lastPathComponent).font(.caption).lineLimit(1)
                                    TargetSizeLine(width: source.width, height: source.height, options: options)
                                }
                            }
                        }.padding(.top, 4)
                    }
                }
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: inputs) {
            error = nil
            sources = []
            do {
                let values = try await Task.detached(priority: .utility) {
                    try ImageFiles.expand(inputs).map { file in
                        let (width, height) = try ImageFiles.dimensions(of: file.url)
                        return SourceDimensions(id: file.url, width: width, height: height)
                    }
                }.value
                if !Task.isCancelled { sources = values }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

private struct OutputScaleControl: View {
    @EnvironmentObject private var studio: StudioStore
    var body: some View {
        ControlSection(title: "Enhancement size") {
            Picker("Output scale", selection: Binding(get: {
                studio.enhancement.customLongEdge == nil ? Int(studio.enhancement.scale) : 0
            }, set: { scale in
                if scale == 0 { studio.enhancement.customLongEdge = 2048 }
                else { studio.enhancement.customLongEdge = nil; studio.enhancement.scale = Double(scale) }
            })) {
                Text("1×").tag(1); Text("2×").tag(2); Text("3×").tag(3); Text("4×").tag(4); Text("Custom").tag(0)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            if studio.enhancement.customLongEdge != nil {
                NumberInput("Long edge (px)", value: Binding(get: { studio.enhancement.customLongEdge ?? 2048 },
                    set: { studio.enhancement.customLongEdge = $0 }))
            }
        }
    }
}

private struct NumberInput: View {
    let label: String
    @Binding var value: Int
    init(_ label: String, value: Binding<Int>) { self.label = label; _value = value }

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: $value, format: .number.grouping(.never))
                .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
        }
    }
}

struct ValueSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 0.01

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(0...2)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step) { Text(label) }
                .labelsHidden()
        }
    }
}
