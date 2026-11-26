import SwiftUI

struct HistorySheet: View {
    let showResult: (StudioResult) -> Void

    @EnvironmentObject private var studio: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var legacyDates: [URL: Date] = [:]
    @State private var confirmClear = false
    @State private var errorMessage: String?

    var body: some View {
        let history = studio.generationHistory
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let filtered = history.filter { $0.matches(terms, date: date(for: $0)) }.sorted {
            (date(for: $0) ?? .distantPast) > (date(for: $1) ?? .distantPast)
        }
        let legacyURLs = history.compactMap { $0.result.createdAt == nil ? $0.result.original : nil }

        VStack(spacing: 0) {
            HStack {
                Text("Render History").font(.title2.bold())
                Spacer()
                Button("Clear History…", role: .destructive) { confirmClear = true }
                    .disabled(history.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)

            TextField("Search prompt, model, or date", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider()
            if history.isEmpty {
                ContentUnavailableView("History is empty", systemImage: "clock.arrow.circlepath",
                                       description: Text("New renders will appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { entry in
                    historyRow(entry).padding(.vertical, 5)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 570, idealWidth: 660, minHeight: 380, idealHeight: 520)
        .task(id: legacyURLs) {
            let lookup = Task.detached(priority: .utility) {
                var dates: [URL: Date] = [:]
                for url in legacyURLs {
                    if Task.isCancelled { break }
                    let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                    dates[url] = values?.creationDate ?? values?.contentModificationDate
                }
                return dates
            }
            let dates = await withTaskCancellationHandler { await lookup.value } onCancel: { lookup.cancel() }
            if !Task.isCancelled { legacyDates = dates }
        }
        .confirmationDialog("Clear render history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                do { try studio.clearGenerationHistory() }
                catch { errorMessage = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your image files and job queue will remain available.")
        }
        .alert("Render History", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func date(for entry: GenerationHistoryEntry) -> Date? {
        entry.result.createdAt ?? legacyDates[entry.result.original]
    }

    private func historyRow(_ entry: GenerationHistoryEntry) -> some View {
        HStack(spacing: 12) {
            Button {
                open(entry.result)
            } label: {
                HStack(spacing: 12) {
                    ImageThumb(url: entry.imageURL)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.prompt).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(entry.modelName).lineLimit(1)
                            if let date = date(for: entry) {
                                Text("·")
                                Text(date.formatted(date: .abbreviated, time: .omitted)).fixedSize()
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open image in Generate")

            Button("Use Settings") {
                do {
                    try studio.useGenerationSettings(from: entry.id, in: entry.jobID)
                    open(entry.result)
                } catch { errorMessage = error.localizedDescription }
            }
            .buttonStyle(.bordered)
            .fixedSize()
        }
        .contextMenu {
            Button("Show in Finder", systemImage: "folder") { studio.reveal(entry.imageURL) }
        }
    }

    private func open(_ result: StudioResult) {
        showResult(result)
        dismiss()
    }
}
