import AppKit
import SwiftUI

struct QueueSheet: View {
    var showResult: (Bool, StudioResult) -> Void
    @EnvironmentObject private var studio: StudioStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Job Queue").font(.title2.bold())
                Spacer()
                Button("Cancel All Queued Jobs", role: .destructive) { studio.removeQueuedJobs() }
                    .disabled(!studio.jobs.contains { $0.status == .pending })
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
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
