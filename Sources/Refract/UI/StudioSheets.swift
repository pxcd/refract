import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension ModelKind {
    var title: String {
        switch self {
        case .generation: return "Generation"
        case .enhancement: return "Enhancement"
        case .lora: return "LoRA"
        }
    }
}

struct ModelsSheet: View {
    @EnvironmentObject private var studio: StudioStore
    @EnvironmentObject private var models: ModelStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ModelKind
    @State private var errorMessage: String?
    @State private var removing: StudioModel?
    @State private var importing = false

    init(initialKind: ModelKind = .generation) { _kind = State(initialValue: initialKind) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Models") { dismiss() }
            HStack {
                Picker("Workload", selection: $kind) {
                    ForEach(ModelKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if importing { ProgressView().controlSize(.small) }
                Button("Import…") { importModel() }.disabled(importing)
            }.padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            if let notice = models.notice {
                Label(notice, systemImage: "exclamationmark.triangle").font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8)
            }
            List {
                Section("Installed") {
                    let installed = models.models.filter { $0.kind == kind }
                    if installed.isEmpty {
                        Text("No \(kind.title.lowercased()) models installed.")
                            .foregroundStyle(.secondary).padding(.vertical, 4)
                    }
                    ForEach(installed) { model in installedRow(model) }
                }
                let catalog = ModelStore.catalog.filter { $0.kind == kind }
                if !catalog.isEmpty {
                    Section("Catalog") {
                        ForEach(catalog) { entry in catalogRow(entry) }
                    }
                }
            }.listStyle(.inset)
        }
        .frame(minWidth: 590, idealWidth: 650, minHeight: 410, idealHeight: 520)
        .alert("Model manager", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .confirmationDialog(removing?.managed == true ? "Delete downloaded weights?" : "Remove this model from Refract?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { model in
            Button(model.managed ? "Delete Weights" : "Remove Reference", role: .destructive) {
                do { try models.remove(model) } catch { errorMessage = error.localizedDescription }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { model in
            Text(model.managed ? "Refract will delete its downloaded copy of \(model.name)." : "The original file stays at \(model.path).")
        }
    }

    private func installedRow(_ model: StudioModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name).font(.headline)
                Text([model.variant, model.precision, ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)]
                    .joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(model.license).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(studio.memorySamples[model.id]?.description ?? model.memoryEstimate).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(model.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).help(model.path)
            }
            Spacer()
            if model.kind != .lora {
                if (model.kind == .generation ? studio.activeGenerationID : studio.activeEnhancementID) == model.id {
                    Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.tint).font(.caption)
                } else {
                    Button("Use") {
                        if model.kind == .generation { studio.activeGenerationID = model.id }
                        else { studio.activeEnhancementID = model.id }
                    }
                }
            }
            Menu {
                Button("Reveal in Finder") { studio.reveal(URL(fileURLWithPath: model.path)) }
                Button(model.managed ? "Delete Download…" : "Remove Reference…", role: .destructive) { removing = model }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(model.name)")
        }.padding(.vertical, 6)
    }

    private func catalogRow(_ entry: CatalogModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.headline)
                    Text(entry.detail).font(.callout).foregroundStyle(.secondary)
                    Text([entry.variant, entry.precision, entry.license] +
                         (entry.bytes > 0 ? [ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)] : []),
                         format: .list(type: .and, width: .narrow))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(entry.memoryEstimate).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let transfer = models.downloads[entry.id], transfer.isRunning {
                    Button("Cancel") { models.cancelDownload(entry.id) }
                } else if entry.canDownload && !models.models.contains(where: { $0.id == entry.identity }) {
                    Button {
                        Task {
                            do { try await models.download(entry) }
                            catch { if !(error is CancellationError) { errorMessage = error.localizedDescription } }
                        }
                    } label: { Image(systemName: "arrow.down.circle") }.help("Download \(entry.name)")
                }
            }
            if let transfer = models.downloads[entry.id] {
                if transfer.isRunning { ProgressView(value: min(1, max(0, transfer.fraction))) }
                if !transfer.message.isEmpty { Text(transfer.message).foregroundStyle(.secondary).font(.caption) }
            }
            Link("Model source and license", destination: entry.sourceURL).font(.caption)
        }.padding(.vertical, 6)
    }

    private func importModel() {
        let selectedKind = kind
        let safetensors = UTType(filenameExtension: "safetensors") ?? .data
        guard let source = StudioPanels.choose("Import \(kind.title.lowercased()) model",
            directories: kind == .enhancement, files: kind != .enhancement,
            types: kind == .enhancement ? [] : [safetensors]).first else { return }
        importing = true
        Task {
            defer { importing = false }
            do { try await models.importModel(at: source, kind: selectedKind) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

struct QueueSheet: View {
    var showResult: (Bool, StudioResult) -> Void
    @EnvironmentObject private var studio: StudioStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Job Queue") { dismiss() }
            Divider()
            if studio.jobs.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "list.bullet.rectangle",
                    description: Text("Generation and enhancement jobs appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(studio.jobs) { job in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(job.status)).foregroundStyle(job.status == .failed ? .red : Color.secondary)
                            .frame(width: 20).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(job.title).font(.headline)
                                Spacer()
                                Text(job.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                if job.elapsed > 0 {
                                    Text(Duration.seconds(job.elapsed).formatted(.time(pattern: .minuteSecond)))
                                        .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(job.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            if job.status == .running {
                                if let fraction = job.progress { ProgressView(value: min(1, max(0, fraction))) }
                                else { ProgressView().progressViewStyle(.linear) }
                            }
                            HStack {
                                if let model = job.recipe.generator ?? job.recipe.enhancer {
                                    Text(model.name).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !job.results.isEmpty {
                                    Menu("Results (\(job.results.count))") {
                                        ForEach(job.results) { result in
                                            Button((result.enhanced ?? result.original).lastPathComponent) {
                                                studio.selectedResult = result
                                                showResult(job.recipe.generator != nil, result)
                                                dismiss()
                                            }
                                        }
                                    }.fixedSize()
                                }
                                if [.pending, .running].contains(job.status) {
                                    Button("Cancel") { studio.cancel(job.id) }
                                } else if [.failed, .cancelled].contains(job.status) {
                                    Button("Retry") { studio.retry(job.id) }
                                }
                            }.controlSize(.small)
                        }
                    }.padding(.vertical, 6)
                }.listStyle(.inset)
            }
        }
        .frame(minWidth: 540, idealWidth: 600, minHeight: 360, idealHeight: 480)
    }

    private func icon(_ status: JobStatus) -> String {
        switch status {
        case .pending: return "clock"
        case .running: return "gearshape.2"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "minus.circle"
        }
    }
}

private struct SheetHeader: View {
    let title: String
    let done: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.title2.bold())
            Spacer()
            Button("Done", action: done).keyboardShortcut(.defaultAction)
        }.padding(.horizontal, 20).padding(.vertical, 15)
    }
}

struct StudioSettingsView: View {
    @EnvironmentObject private var studio: StudioStore
    @EnvironmentObject private var models: ModelStore
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Files") {
                directoryRow("Output folder", url: studio.outputDirectory) {
                    if let directory = StudioPanels.choose("Choose output folder", directories: true, files: false).first {
                        studio.outputDirectory = directory
                    }
                }
                directoryRow("Model downloads", url: models.modelDirectory) {
                    if let directory = StudioPanels.choose("Choose model storage", directories: true, files: false).first {
                        do { try models.setModelDirectory(directory) } catch { errorMessage = error.localizedDescription }
                    }
                }
            }
            Section("Export") {
                Picker("Format", selection: $studio.exportFormat) {
                    Text("PNG").tag(ExportFormat.png)
                    Text("JPEG").tag(ExportFormat.jpeg)
                    Text("TIFF").tag(ExportFormat.tiff)
                }
                if studio.exportFormat == .jpeg {
                    ValueSlider(label: "JPEG quality", value: $studio.jpegQuality, range: 0...1)
                }
            }
        }
        .formStyle(.grouped).frame(width: 540).fixedSize(horizontal: true, vertical: true)
        .alert("Model storage", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func directoryRow(_ title: String, url: URL, action: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url.path(percentEncoded: false)).font(.callout).lineLimit(1).truncationMode(.middle).help(url.path)
                Button("Choose…", action: action)
            }
        }
    }
}
