import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum StudioPanels {
    @MainActor static func choose(_ title: String, directories: Bool = false, files: Bool = true,
                                  multiple: Bool = false, types: [UTType] = []) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Choose"
        panel.canChooseDirectories = directories
        panel.canChooseFiles = files
        panel.allowsMultipleSelection = multiple
        panel.resolvesAliases = true
        if !types.isEmpty { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor static func save(_ source: URL, studio: StudioStore) {
        let panel = NSSavePanel()
        let originalType = UTType(filenameExtension: source.pathExtension)
        let format = ExportFormat.allCases.first { $0.contentType == originalType } ?? studio.exportFormat
        panel.directoryURL = studio.outputDirectory
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = copyName(for: source, in: studio.outputDirectory, format: format)
        panel.isExtensionHidden = false
        panel.accessoryView = SaveFormatPicker(panel: panel, source: source, initial: format)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do { try studio.save(source, to: target) }
        catch { studio.notice = error.localizedDescription }
    }

    static func copyName(for source: URL, in directory: URL, format: ExportFormat) -> String {
        let stem = source.deletingPathExtension().lastPathComponent + " copy"
        var number = 1
        while true {
            let name = stem + (number == 1 ? "" : " \(number)") + "." + format.fileExtension
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path),
               !FileManager.default.fileExists(atPath: candidate.appendingPathExtension("json").path) { return name }
            number += 1
        }
    }
}

private extension ExportFormat {
    var contentType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        }
    }
}

@MainActor private final class SaveFormatPicker: NSStackView {
    private weak var panel: NSSavePanel?
    private let source: URL
    private var suggestedName: String

    init(panel: NSSavePanel, source: URL, initial: ExportFormat) {
        self.panel = panel
        self.source = source
        suggestedName = panel.nameFieldStringValue
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        let picker = NSPopUpButton()
        for format in ExportFormat.allCases {
            picker.addItem(withTitle: format.rawValue.uppercased())
            picker.lastItem?.representedObject = format.rawValue
        }
        picker.selectItem(withTitle: initial.rawValue.uppercased())
        picker.target = self
        picker.action = #selector(selectFormat(_:))
        picker.setAccessibilityLabel("File format")
        let label = NSTextField(labelWithString: "Format:")
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        addArrangedSubview(label)
        label.widthAnchor.constraint(equalToConstant: 72).isActive = true
        addArrangedSubview(picker)
        picker.setContentHuggingPriority(.required, for: .horizontal)
        addArrangedSubview(NSView())
        setFrameSize(fittingSize)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func selectFormat(_ sender: NSPopUpButton) {
        guard let panel, let raw = sender.selectedItem?.representedObject as? String,
              let format = ExportFormat(rawValue: raw) else { return }
        let previous = panel.nameFieldStringValue
        let directory = panel.directoryURL ?? source.deletingLastPathComponent()
        let nextSuggestion = StudioPanels.copyName(for: source, in: directory, format: format)
        let previousType = UTType(filenameExtension: (previous as NSString).pathExtension)
        let hasFormatExtension = ExportFormat.allCases.contains { $0.contentType == previousType }
        let stem = hasFormatExtension ? (previous as NSString).deletingPathExtension : previous
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = previous == suggestedName ? nextSuggestion : stem + "." + format.fileExtension
        suggestedName = nextSuggestion
    }
}

enum Workspace: Hashable { case generate, enhance }

@MainActor final class StudioFileSelection: ObservableObject {
    @Published var workspace: Workspace = .generate
    @Published var inputs: [URL] = []
    @Published private(set) var openRequest = 0

    func openForEnhancement(_ urls: [URL]) {
        let accepted = urls.filter { url in
            guard url.isFileURL,
                  let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey]) else { return false }
            return info.isDirectory == true || info.contentType?.conforms(to: .image) == true
        }
        guard !accepted.isEmpty else { return }
        for url in accepted.map(\.standardizedFileURL) where !inputs.contains(url) { inputs.append(url) }
        workspace = .enhance
        openRequest += 1
    }
}

struct StudioView: View {
    @EnvironmentObject private var studio: StudioStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var fileSelection: StudioFileSelection
    @State private var showQueue = false
    @State private var showInspector = true
    private var workspace: Workspace { fileSelection.workspace }
    private var inputs: [URL] { fileSelection.inputs }
    @State private var generationResult: StudioResult?
    @State private var enhancementResult: StudioResult?
    @State private var targetingCanvas = false
    @State private var hiddenSourcePreviews: Set<Workspace> = []

    private var activeResult: StudioResult? { workspace == .generate ? generationResult : enhancementResult }

    private var sourcePreview: URL? {
        guard !hiddenSourcePreviews.contains(workspace) else { return nil }
        if workspace == .generate { return studio.generation.reference }
        return inputs.first.flatMap { isImage($0) ? $0 : nil }
    }

    var body: some View {
        HStack(spacing: 0) {
            canvas
            if showInspector {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1)
                    .padding(.vertical, 12)
                    .accessibilityHidden(true)
                inspectorPane
                    .frame(width: 320)
                    .clipped()
            }
        }
        .frame(minWidth: 760, minHeight: 490)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Workspace", selection: $fileSelection.workspace) {
                    Text("Generate").tag(Workspace.generate)
                    Text("Enhance").tag(Workspace.enhance)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                OpenModelManager(kind: workspace == .generate ? .generation : .enhancement) {
                    Label("Models", systemImage: "square.3.layers.3d")
                }
                    .help("Manage models")
                Button { showQueue = true } label: { Label("Queue", systemImage: "list.bullet.rectangle") }
                    .help("View job queue")
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help(showInspector ? "Hide inspector" : "Show inspector")
                    .accessibilityValue(showInspector ? "Shown" : "Hidden")
            }
        }
        .sheet(isPresented: $showQueue) {
            QueueSheet { isGeneration, result in
                fileSelection.workspace = isGeneration ? .generate : .enhance
                if isGeneration { generationResult = result } else { enhancementResult = result }
            }
        }
        .onAppear {
            generationResult = studio.jobs.first(where: { $0.recipe.generator != nil && !$0.filmstripResults.isEmpty })?.filmstripResults.last
            if inputs.isEmpty {
                enhancementResult = studio.jobs.first(where: { $0.recipe.generator == nil && !$0.filmstripResults.isEmpty })?.filmstripResults.last
            }
        }
        .onChange(of: studio.generation.reference) { _, _ in
            generationResult = nil
            hiddenSourcePreviews.remove(.generate)
        }
        .onChange(of: fileSelection.inputs) { _, _ in
            enhancementResult = nil
            hiddenSourcePreviews.remove(.enhance)
        }
        .onChange(of: fileSelection.openRequest) { _, _ in
            showQueue = false
            showInspector = true
            hiddenSourcePreviews.remove(.enhance)
            enhancementResult = nil
            studio.selectedResult = nil
        }
        .onChange(of: studio.selectedResult) { _, result in
            guard let result else {
                if workspace == .generate { generationResult = nil } else { enhancementResult = nil }
                return
            }
            if let job = studio.jobs.first(where: { job in job.results.contains(where: { $0.id == result.id }) }) {
                if job.recipe.generator != nil { generationResult = result } else { enhancementResult = result }
            }
        }
        .alert("Refract", isPresented: Binding(get: { studio.notice != nil }, set: { if !$0 { studio.notice = nil } })) {
            Button("OK") { studio.notice = nil }
        } message: { Text(studio.notice ?? "") }
    }

    private var canvas: some View {
        resultArea
            .frame(minWidth: 360, maxWidth: .infinity, minHeight: 490, maxHeight: .infinity)
            .overlay {
                if activeResult == nil && sourcePreview == nil {
                    emptyPreview.allowsHitTesting(false)
                }
            }
            .overlay {
                if targetingCanvas {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                if workspace == .enhance {
                    for url in urls where !inputs.contains(url) { fileSelection.inputs.append(url) }
                    hiddenSourcePreviews.remove(.enhance)
                    enhancementResult = nil
                } else if let image = urls.first(where: isImage) {
                    studio.generation.reference = image
                    hiddenSourcePreviews.remove(.generate)
                    generationResult = nil
                } else { return false }
                studio.selectedResult = nil
                return !urls.isEmpty
            } isTargeted: { targetingCanvas = $0 }
    }

    private var emptyPreview: some View {
        let generating = workspace == .generate
        return VStack(spacing: 8) {
            Image(systemName: generating ? "photo" : "rectangle.split.2x1")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 36, alignment: .top)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                .padding(.bottom, 10)
            Text(generating ? "Image Preview" : "Compare Images")
                .font(.headline)
            Text(generating ? "Your generated images will appear here." : "Add a photo to enhance and compare it with the original.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, 16)
        .fixedSize(horizontal: false, vertical: true)
        // Center a shared frame so the icon's top edge is independent of line wrapping.
        .frame(height: 128, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    private var inspectorPane: some View {
        Form {
            if workspace == .generate {
                GenerationControls()
            } else {
                EnhancementControls(inputs: $fileSelection.inputs)
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if workspace == .generate {
                    generateButton
                } else {
                    Button {
                        studio.enhance(inputs)
                    } label: {
                        Label(inputs.count > 1 ? "Enhance \(inputs.count) items" : "Enhance", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(inputs.isEmpty || studio.activeEnhancementID.isEmpty)
                    .padding(14)
                }
            }
            .background(.regularMaterial)
        }
    }

    private var generateButton: some View {
        let jobs = studio.jobs.filter { $0.recipe.generator != nil }
        let queued = jobs.filter { $0.status == .pending }.count
        let generating = jobs.contains { job in
            job.status == .running && job.results.count + (job.trashedResultIndices?.count ?? 0) < job.recipe.seeds.count
        }
        return Button {
            studio.generate()
        } label: {
            Label(queued > 0 ? "Generate · \(queued) queued" : "Generate", systemImage: "sparkles")
                .monospacedDigit()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(studio.generation.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || studio.activeGenerationID.isEmpty)
        .overlay {
            if generating {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { tick in
                    let period = 2.4
                    let phase = reduceMotion ? 0 : tick.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                    let outline = AngularGradient(colors: [.cyan, .blue, .purple, .white, .cyan],
                                                  center: .center, angle: .degrees(phase * 360))
                    Capsule().strokeBorder(outline, lineWidth: 2)
                        .shadow(color: .cyan.opacity(0.4), radius: 4)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .accessibilityValue(generating ? "Generating" : "")
        .padding(14)
    }

    @ViewBuilder private var resultArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let result = activeResult {
                ImageViewport(original: result.original, enhanced: result.enhanced)
                    .frame(maxHeight: .infinity)
            } else if let sourcePreview {
                ImageViewport(original: sourcePreview).frame(maxHeight: .infinity)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let running = studio.jobs.first(where: { $0.status == .running }) {
                Button { showQueue = true } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            if let position = studio.generationBatchPosition(for: running) {
                                Text("Batch \(position.current) of \(position.total)")
                                    .fontWeight(.medium).monospacedDigit()
                                    .fixedSize()
                                Text("·").foregroundStyle(.secondary)
                            }
                            Text(running.message.isEmpty ? running.title : running.message).lineLimit(1)
                            Spacer()
                            Text("Queue").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        Group {
                            if let progress = running.progress {
                                ProgressView(value: progress)
                            } else {
                                ProgressView()
                            }
                        }
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Job progress")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            let recent = studio.jobs.filter { ($0.recipe.generator != nil) == (workspace == .generate) && !$0.filmstripResults.isEmpty }
            if !recent.isEmpty {
                HStack(spacing: 0) {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 6) {
                            ForEach(recent) { job in
                                ForEach(job.filmstripResults) { result in
                                    thumbnail(result, job: job)
                                }
                            }
                        }.padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    Button("Clear") {
                        let generated = workspace == .generate
                        if generated { generationResult = nil } else { enhancementResult = nil }
                        hiddenSourcePreviews.insert(workspace)
                        studio.clearFilmstrip(generated: generated)
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .accessibilityLabel("Clear filmstrip")
                    .help("Clear the preview and thumbnails while keeping their files and job history")
                }
                .frame(height: 70)
            }
        }
    }

    private func thumbnail(_ result: StudioResult, job: StudioJob) -> some View {
        let displayed = result.enhanced ?? result.original
        return Button {
            if workspace == .generate { generationResult = result } else { enhancementResult = result }
            studio.selectedResult = result
        } label: {
            ImageThumb(url: displayed)
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(activeResult?.id == result.id ? Color.accentColor : .clear, lineWidth: 3)
                }
        }
        .buttonStyle(.plain)
        .help(displayed.lastPathComponent)
        .accessibilityLabel(displayed.lastPathComponent)
        .contextMenu {
            Button("Show in Finder", systemImage: "folder") { studio.reveal(displayed) }
            Button("Save As…", systemImage: "square.and.arrow.up") { StudioPanels.save(displayed, studio: studio) }
            if result.enhanced != nil {
                Divider()
                Button("Show Original in Finder") { studio.reveal(result.original) }
                Button("Save Original As…") { StudioPanels.save(result.original, studio: studio) }
            }
            if job.recipe.generator != nil {
                Divider()
                Button("Move to Trash", systemImage: "trash", role: .destructive) {
                    do {
                        try studio.trashGeneratedResult(result.id)
                        if generationResult?.id == result.id {
                            generationResult = studio.jobs.first(where: { $0.id == job.id })?.filmstripResults.last
                                ?? studio.jobs.first(where: { $0.recipe.generator != nil && !$0.filmstripResults.isEmpty })?.filmstripResults.last
                        }
                    } catch { studio.notice = error.localizedDescription }
                }
                .disabled(!studio.canTrashGeneratedResult(job))
            }
        }
    }

    private func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true
    }
}

struct ImageThumb: View {
    let url: URL
    @State private var thumbnail: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .task(id: url) {
            thumbnail = nil
            let value = await Task.detached(priority: .utility) {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 144]
                return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }.value
            if !Task.isCancelled { thumbnail = value }
        }
    }
}

struct ModelPicker: View {
    @EnvironmentObject private var models: ModelStore
    let title: String
    let kind: ModelKind
    @Binding var id: String
    var showsTitle = true

    var body: some View {
        let choices = models.models.filter { $0.kind == kind }
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Picker(title, selection: $id) {
                if !choices.contains(where: { $0.id == id }) { Text("Choose a model").tag(id) }
                ForEach(choices, id: \.id) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
